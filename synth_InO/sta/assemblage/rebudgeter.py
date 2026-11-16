#!/usr/bin/env python3
"""Rebudgetage des SDC de macros d'apres la STA d'assemblage de TAHX_1.

Usage : rebudgeter.py <chemins.txt> [--periode 25] [--incert 0.5] [--lambda 0.5]
                      [--biais 0.3] [--sortie dossier] [--macros ...] [--lat latences_slow.txt]
                      [--gmin MACRO=G ...] [--critiques N]
  --gmin : g minimal d'une macro, a la place de GMIN (ex. stack_unit_16_8=0.95 : effort modere).
  --critiques N : les N chemins de plus petite marge apres mise a l'echelle, segment par segment.
  --exclure MOTIF : ecarte les chemins passant par un point qui contient MOTIF (ex. RESET_i).
  --lat : latences internes mesurees (sortie de latences_macros.sh, lignes
          « LAT <module> bascules N min a moy b max c », moyenne retenue) au lieu de LAT.
  chemins.txt : sortie de releve_chemins.tcl (coin lent, fils du plan de puce).

Methode.
 1. Chaque chemin releve est decoupe aux broches des macros : segments internes a une
    macro M (horloge -> sortie, entree -> sortie, entree -> bascule, ce dernier etant le
    temps de setup du modele .lib) et segments de liaison (cellules et fils du sommet),
    fixes.
 2. Un facteur g_M <= 1 par macro multiplie ses segments internes. Programme lineaire
    en nombres mixtes (scipy.optimize.milp) : y_M = 1 si M est relancee, g_M >= g_min_M
    alors, g_M = 1 sinon ; pour chaque chemin, somme des segments mis a l'echelle <=
    periode - incertitude + z ; on minimise d'abord z (la periode atteignable est
    periode + z), puis le cout des relances (COUT) et l'effort (1 - g) / (1 - g_min) de
    chaque macro, ce qui repartit l'acceleration au lieu d'epuiser une seule macro.
 3. Avec ces g : pour chaque broche p d'une macro, arrivee a'(p) (pire prefixe mis a
    l'echelle) et requis r'(p) (pire suffixe), marge s' = r' - a' ; instant alloue
    tau(p) = a' + lambda * s' (la moitie de la marge restante a l'amont). La sortie d'une
    macro et l'entree qu'elle attaque recoivent ainsi le meme instant, au fil pres.
 4. SDC des macros relancees : copie de l'ancien SDC, ou set_input_delay -max =
    tau + biais, set_output_delay -max = periode - incertitude - tau + biais (biais : ecart
    d'horloge entre macros), par bus (pire bit) ; -min gardes de l'ancien SDC (hold) ;
    traversees combinatoires : set_max_delay par paire de bus = le plus grand, sur les
    paires de bits relevees, de entree + D + sortie + incertitude (OpenSTA la retire aussi
    d'un set_max_delay), D = budget interne alloue au chemin le
    plus serre qui traverse la paire de bits (au moins g_M * d).
    Insertion d'horloge interne des macros (LAT) : +L_A au depart d'un chemin lance par la
    macro A, -L_B a l'arrivee dans B (modeles .lib en horloge ideale) ; les SDC sont dans
    le repere de la broche d'horloge de la macro, ou son flux voit L en horloge propagee.
    Valeur d'un bus = celle de son pire bit, plus une valeur propre pour chaque bit qui
    s'en ecarte de plus de ECART (le pire bit d'un bus n'est pas forcement celui qui a
    le plus long chemin interne).
    Les broches hors des chemins releves gardent tau = arrivee + lambda * marge de la STA
    (marge plafonnee a 6 ns), ou l'ancienne valeur si elles ne sont pas contraintes.
"""
import argparse, math, os, re, sys
from collections import defaultdict

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.abspath(os.path.join(ICI, "..", "..", ".."))
MACROS = os.path.join(RACINE, "pnr_InO", "macros")

INST = {"u_instruction.u_fetch": "ino_fetch", "u_instruction.u_decode_predict": "ino_decode_predict",
        "u_decode_queue": "ino_decode_queue", "u_core.u_stack": "stack_unit_16_8",
        "u_core.u_backend.u_entier": "ino_exec_entier", "u_core.u_backend.u_arith": "ino_exec_arith",
        "u_core.u_system": "ino_system", "u_data_cache": "ino_data_cache"}
# Cout d'une relance (duree, sensibilite du flux) et acceleration jugee atteignable.
COUT = {"ino_exec_entier": 1.0, "ino_exec_arith": 1.0, "ino_system": 1.0, "ino_decode_queue": 1.0,
        "ino_decode_predict": 1.5, "stack_unit_16_8": 2.0, "ino_data_cache": 3.0, "ino_fetch": 4.0}
GMIN = {"ino_exec_entier": 0.55, "ino_system": 0.65, "ino_data_cache": 0.70, "stack_unit_16_8": 0.75}
GMIN_DEFAUT = 0.80
ECART = 0.25      # ns : ecart au pire bit du bus au-dela duquel un bit a sa propre valeur
# Insertion d'horloge interne des macros (ns, coin lent, moyenne aux bascules, horloge
# propagee ; latence_macros.tcl ; ino_data_cache : horloge des SRAM). Les modeles .lib
# des macros sont ecrits en horloge ideale : horloge -> sortie sans cette insertion,
# setup sans elle non plus. Un chemin de A vers B est donc plus long de L_A - L_B que dans
# la STA d'assemblage ; on l'ajoute en segments fixes (+L_A au depart, -L_B a l'arrivee).
LAT = {"ino_exec_entier": 1.01, "stack_unit_16_8": 1.20, "ino_data_cache": 2.22, "ino_system": 1.04,
       "ino_fetch": 2.39, "ino_decode_predict": 0.98, "ino_decode_queue": 0.71, "ino_exec_arith": 0.95}
EFFORT = 0.6       # poids de l'effort (1 - g) / (1 - g_min), a cote du cout d'une relance


# Macros dont les chemins critiques partent des SRAM : LAT = horloge des SRAM (LATSRAM)
LAT_PAR_SRAM = ("ino_data_cache",)


def charger_lat(fichier):
    """LAT d'apres latences_<coin>.txt (latences_macros.sh) : moyenne aux bascules ; pour
    LAT_PAR_SRAM, moyenne a l'horloge des SRAM (lignes LATSRAM) si elle est donnee."""
    par_module = {}                       # module = dossier de la macro
    sram = {}
    for l in open(fichier):
        t = l.split()
        if len(t) >= 10 and t[0] == "LATSRAM" and t[6] == "moy" and math.isfinite(float(t[7])):
            sram[par_module.get(t[1], t[1])] = float(t[7])
        if len(t) >= 10 and t[0] == "LAT" and t[6] == "moy":
            m, v = par_module.get(t[1], t[1]), float(t[7])
            if not math.isfinite(v) or not math.isfinite(float(t[5])) or not math.isfinite(float(t[9])):
                print(f"LAT de {m} non finie dans {fichier} ({' '.join(t[4:10])}) : "
                      f"valeur v1 gardee ({LAT.get(m, 0.0):.2f}) ; relancer latences_macros.sh")
                continue
            LAT[m] = v
    for m in LAT_PAR_SRAM:
        if m in sram:
            print(f"LAT de {m} : horloge des SRAM {sram[m]:.2f} (bascules {LAT.get(m, 0.0):.2f})")
            LAT[m] = sram[m]
    print("LAT (ns) : " + ", ".join(f"{m} {v:.2f}" for m, v in sorted(LAT.items())))


def macro_de(pin):
    i = pin.rfind("/")
    if i < 0:
        return None, pin
    inst = pin[:i].replace("\\", "")
    return INST.get(inst), pin[i + 1:].replace("\\", "")


def lire(fichier):
    chemins, broches = [], {}
    cur = None
    for ligne in open(fichier):
        t = ligne.split()
        if not t:
            continue
        if t[0] == "P":
            cur = dict(slack=float(t[1]) * 1e9, req=float(t[2]) * 1e9, fin=t[3], type=t[4], pts=[])
            chemins.append(cur)
        elif t[0] == "B":
            s = float(t[4]) if t[4] not in ("", "INF") else 1e30
            broches[t[1]] = (t[2], float(t[3]), s)
        else:
            cur["pts"].append((t[0], float(t[1]) * 1e9))
    return chemins, broches


def segments(c, direction, periode, incert):
    """-> liste de (macro ou None, duree, broche de depart, broche d'arrivee) ; total =
    periode - incert - marge."""
    pts = c["pts"]
    seg = []
    m0, _ = macro_de(pts[0][0])
    # depart a la broche d'horloge d'une macro suivie de sa sortie : la sortie est le depart
    if (m0 and len(pts) > 1 and direction.get(pts[0][0]) == "input"
            and macro_de(pts[1][0])[0] == m0 and direction.get(pts[1][0]) == "output"
            and re.search(r"(^|/)clk", pts[0][0].split("/")[-1]) and pts[0][1] <= 1e-3):
        pts = pts[1:]
    if m0 and direction.get(pts[0][0]) == "output":
        seg.append((None, LAT.get(m0, 0.0), None, None))        # insertion d'horloge de la macro
        seg.append((m0, pts[0][1], None, pts[0][0]))            # horloge -> sortie
    else:
        seg.append((None, pts[0][1], None, pts[0][0]))          # port d'entree, retard exterieur
    for (u, au), (v, av) in zip(pts, pts[1:]):
        mu, _ = macro_de(u)
        mv, _ = macro_de(v)
        if mu and mu == mv and direction.get(u) == "input" and direction.get(v) == "output":
            seg.append((mu, av - au, u, v))
        else:
            seg.append((None, av - au, u, v))
    fin = pts[-1][0]
    mf, _ = macro_de(fin)
    d_fin = (periode - incert) - c["req"]
    seg.append((mf if (mf and c["type"] == "macro") else None, d_fin, fin, None))
    if mf and c["type"] == "macro":
        seg.append((None, -LAT.get(mf, 0.0), None, None))       # capture retardee d'autant
    return seg


def arcs_lib(m, coin="nom_slow_1p08V_125C", k=2):
    """Arcs combinatoires du modele .lib de la macro : (entree, sortie) -> retard (ns),
    pire de cell_rise / cell_fall a la k-ieme charge de la table (0,039 pF)."""
    f = os.path.join(MACROS, m, "vues", "lib", coin + ".lib")
    arcs, sortie, rel, comb = {}, None, None, False
    for l in open(f):
        mo = re.match(r'\s*pin\("(.+)"\)', l)
        if mo:
            sortie = mo.group(1)
            continue
        mo = re.match(r'\s*related_pin\s*:\s*"(.+)"', l)
        if mo:
            rel, comb = mo.group(1), False
            continue
        if "timing_type : combinational" in l:
            comb = True
            continue
        mo = re.match(r'\s*values\("([^"]+)"\)', l)
        if mo and comb and rel and sortie:
            v = [float(x) for x in mo.group(1).split(",")]
            arcs[(rel, sortie)] = max(arcs.get((rel, sortie), 0.0), v[min(k, len(v) - 1)])
            continue
    return arcs


def resoudre(chs, macros, periode, incert):
    import numpy as np
    from scipy.optimize import milp, LinearConstraint, Bounds
    M = list(macros)
    n = len(M)
    # variables : g_0..g_{n-1}, y_0..y_{n-1}, z
    nv = 2 * n + 1
    A, lo, hi = [], [], []
    for segs in chs:
        row = np.zeros(nv)
        fixe = 0.0
        for m, d, _, _ in segs:
            if m is None:
                fixe += d
            else:
                row[M.index(m)] += d
        row[-1] = -1.0
        A.append(row); lo.append(-np.inf); hi.append(periode - incert - fixe)
    for k, m in enumerate(M):                    # g_k + (1 - gmin) y_k >= 1
        row = np.zeros(nv); row[k] = 1.0; row[n + k] = 1.0 - GMIN.get(m, GMIN_DEFAUT)
        A.append(row); lo.append(1.0); hi.append(np.inf)
    c = np.zeros(nv)
    c[-1] = 1000.0
    for k, m in enumerate(M):
        c[n + k] = COUT.get(m, 1.0)
        # effort : rapprocher une macro de sa limite coute, pour repartir l'effort
        c[k] = -EFFORT / (1.0 - GMIN.get(m, GMIN_DEFAUT) + 1e-9)
    lb = [GMIN.get(m, GMIN_DEFAUT) for m in M] + [0] * n + [0]
    ub = [1.0] * n + [1] * n + [np.inf]
    integ = [0] * n + [1] * n + [0]
    r = milp(c, constraints=LinearConstraint(np.array(A), lo, hi), bounds=Bounds(lb, ub),
             integrality=integ)
    if not r.success:
        sys.exit("milp : " + r.message)
    g = {m: float(r.x[k]) for k, m in enumerate(M)}
    y = {m: bool(round(r.x[n + k])) for k, m in enumerate(M)}
    return g, y, float(r.x[-1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("chemins")
    ap.add_argument("--periode", type=float, default=25.0, help="periode cible des budgets")
    ap.add_argument("--periode-releve", type=float, default=25.0,
                    help="periode de la STA qui a produit chemins.txt")
    ap.add_argument("--incert", type=float, default=0.5)
    ap.add_argument("--lambda", dest="lam", type=float, default=0.5)
    ap.add_argument("--biais", type=float, default=0.3)
    ap.add_argument("--sortie", default=None, help="dossier des SDC rebudgetes")
    ap.add_argument("--macros", nargs="*", default=None,
                    help="macros autorisees a la relance (defaut : toutes)")
    ap.add_argument("--lat", default=None, help="latences_<coin>.txt de latences_macros.sh")
    ap.add_argument("--ecart", type=float, default=ECART,
                    help=f"ecart au pire bit au-dela duquel un bit a sa propre valeur (ns, {ECART})")
    ap.add_argument("--gmin", action="append", default=[], metavar="MACRO=G",
                    help="g minimal d'une macro (remplace GMIN ; repetable), ex. stack_unit_16_8=0.95")
    ap.add_argument("--critiques", type=int, default=0, metavar="N",
                    help="affiche les N chemins de plus petite marge apres mise a l'echelle")
    ap.add_argument("--exclure", action="append", default=[], metavar="MOTIF",
                    help="ecarte les chemins dont un point (port, broche) contient MOTIF, "
                         "ex. RESET_i : chemins de reset traites a part (multicycle, RTL)")
    a = ap.parse_args()
    globals()["ECART"] = a.ecart
    for x in a.gmin:
        m, v = x.split("=")
        GMIN[m] = float(v)
    if a.lat:
        charger_lat(a.lat)
    chemins, broches = lire(a.chemins)
    if a.exclure:
        n0 = len(chemins)
        chemins = [c for c in chemins if not any(m in p for m in a.exclure for p, _ in c["pts"])]
        print(f"--exclure {' '.join(a.exclure)} : {n0 - len(chemins)} chemins ecartes sur {n0}")
    direction = {p: v[0] for p, v in broches.items()}
    T, U = a.periode, a.incert
    chs = [segments(c, direction, a.periode_releve, U) for c in chemins]
    chs = [s for s in chs if any(m for m, _, _, _ in s)]
    if not chs:
        sys.exit("aucun chemin traversant une macro (--exclure trop large ?)")
    macros = sorted({m for s in chs for m, _, _, _ in s if m})
    if a.macros is not None:
        for m in macros:
            if m not in a.macros:
                GMIN[m] = 1.0
    g, y, z = resoudre(chs, macros, T, U)

    print(f"{len(chs)} chemins traversant des macros ; periode atteignable {T + z:.2f} ns "
          f"(cible {T}, incertitude {U})")
    print(f"{'macro':20s} {'relance':8s} {'g':>6s}  {'g_min':>6s}  pire chemin interne : avant -> apres")
    pire = defaultdict(float)
    for s in chs:
        for m, d, _, _ in s:
            if m:
                pire[m] = max(pire[m], d)
    for m in macros:
        print(f"{m:20s} {'oui' if y[m] else 'non':8s} {g[m]:6.3f}  {GMIN.get(m, GMIN_DEFAUT):6.2f}  "
              f"{pire[m]:6.2f} -> {pire[m] * g[m]:6.2f} ns")

    if a.critiques:
        # chemins qui fixent la periode : marge apres mise a l'echelle, segments
        def court(p):
            return "" if p is None else macro_de(p)[1] if macro_de(p)[0] else p.split("/")[-1]
        cl = []
        for c, s in zip([c for c in chemins], [segments(c, direction, a.periode_releve, U)
                                               for c in chemins]):
            if not any(m for m, _, _, _ in s):
                continue
            tot = sum(d * (g[m] if m else 1.0) for m, d, _, _ in s)
            cl.append(((T - U + z) - tot, c, s))
        cl.sort(key=lambda e: e[0])
        vus_c = set()
        n = 0
        for marge, c, s in cl:
            cle = tuple((m, round(d, 2)) for m, d, _, _ in s)
            if cle in vus_c:
                continue
            vus_c.add(cle)
            n += 1
            print(f"\nchemin critique {n} : marge {marge:+.3f} ns (a la periode {T + z:.2f}), "
                  f"extremite {c['fin']}")
            for m, d, u, v in s:
                x = d * (g[m] if m else 1.0)
                quoi = f"{m} (g {g[m]:.3f})" if m else \
                    ("insertion +L / -L" if u is None and v is None else "fixe")
                print(f"   {quoi:30s} {d:7.3f} -> {x:7.3f}   {court(u)} -> {court(v)}")
            if n >= a.critiques:
                break

    # Instants mis a l'echelle et marges.
    arr, req = defaultdict(lambda: -1e30), defaultdict(lambda: 1e30)
    feed = defaultdict(lambda: 1e30)             # (macro, entree, sortie) -> budget interne alloue
    gdmax = defaultdict(float)                   # ... au moins g d du plus long passage (fronts, transitions)
    for s in chs:
        dd = [d * (g[m] if m else 1.0) for m, d, _, _ in s]
        tot = sum(dd)
        marge = (T - U + z) - tot
        t = 0.0
        for (m, d, u, v), x in zip(s, dd):
            t += x
            if v is not None:
                arr[v] = max(arr[v], t)
                req[v] = min(req[v], t + marge)
        for (m, d, u, v), x in zip(s, dd):
            if m and u is not None and v is not None:
                internes = sum(xx for (mm, _, _, _), xx in zip(s, dd) if mm)
                part = x + a.lam * max(0.0, marge) * (x / internes if internes else 0)
                feed[(m, u, v)] = min(feed[(m, u, v)], part)
                gdmax[(m, u, v)] = max(gdmax[(m, u, v)], x)
    for k in feed:
        feed[k] = max(feed[k], gdmax[k])
    tau = {}
    for p in set(arr) | set(req):
        sp = req[p] - arr[p]
        tau[p] = arr[p] + a.lam * max(0.0, sp)
    for p, (dirn, ar, sl) in broches.items():   # broches hors des chemins releves
        if p not in tau and sl < 1e20 and macro_de(p)[0]:
            tau[p] = ar + a.lam * min(max(0.0, sl), 6.0)

    if not a.sortie:
        return
    os.makedirs(a.sortie, exist_ok=True)
    for m in macros:
        if not y[m]:
            continue
        ancien = sorted(f for f in os.listdir(os.path.join(MACROS, m)) if f.endswith("_25ns.sdc"))[0]
        src = open(os.path.join(MACROS, m, ancien)).read().splitlines()
        while src and src[0].startswith("#"):      # en-tete de sdc_macro.tcl, perime
            src.pop(0)
        # Ancien SDC deja rebudgete (P78) : lignes « -max V ... ;# avant H » et « -min H »,
        # surcharges « -max » par bit. On n'en garde que le -min (hold d'origine) par bus ;
        # les -max (bus et bits) sont remplaces. Format d'origine : « set_X_delay V ».
        anc_max = defaultdict(list)              # (in|out, bus) -> anciennes lignes -max
        anc_val = {}                             # (in|out, bus) -> ancienne valeur -max du bus
        for l in src:
            mo = re.match(r"set_(input|output)_delay\s+-max\s+(\S+)\s+-clock clk \[get_ports \{(.+)\}\]", l)
            if mo:
                k = ("in" if mo.group(1) == "input" else "out", re.sub(r"\[\d+\]$", "[*]", mo.group(3)))
                anc_max[k].append(l.split("   ;#")[0])
                if k[1] == mo.group(3):
                    anc_val[k] = mo.group(2)
        par_bus = defaultdict(lambda: None)
        par_bit = {}                             # (in|out, broche) -> valeur du bit
        for p, t in tau.items():
            mm, port = macro_de(p)
            if mm != m or port in ("clk_i", "CLK_i"):
                continue
            bus = re.sub(r"\[\d+\]$", "[*]", port)
            dirn = direction.get(p)
            if dirn == "input":
                v = t + a.biais
                par_bus[("in", bus)] = max(par_bus[("in", bus)] or -1e30, v)
                par_bit[("in", port)] = v
            elif dirn == "output":
                v = (T - U + z) - t + a.biais
                par_bus[("out", bus)] = max(par_bus[("out", bus)] or -1e30, v)
                par_bit[("out", port)] = v
        # Le pire bit fixe la valeur du bus ; les bits dont l'instant alloue s'en ecarte
        # de plus de ECART ns recoivent leur propre valeur (une commande posterieure sur
        # un bit remplace la valeur -max du bus pour ce bit). Sans cela, un bit a long
        # chemin interne (complete_i.fault[0] de stack_unit : 9,8 ns) herite de l'instant
        # tardif des autres bits du bus (1 ns de chemin interne) et n'aurait que 5,5 ns.
        surcharges = defaultdict(list)
        for (kind, port), v in sorted(par_bit.items()):
            bus = re.sub(r"\[\d+\]$", "[*]", port)
            if bus != port and par_bus[(kind, bus)] - v > ECART:
                surcharges[(kind, bus)].append((port, v))
        out, vus = [], set()
        out.append(f"# Rebudgete (rebudgeter.py, {os.path.basename(a.chemins)}) : periode {T} ns, "
                   f"atteignable {T + z:.2f} ; g = {g[m]:.3f} pour cette macro.")
        out.append("# -max : instants alloues par la STA d'assemblage (meme instant pour la sortie d'une")
        out.append(f"# macro et l'entree qu'elle attaque), biais {a.biais} ns ; -min : ancien SDC (hold).")
        out.append(f"# Repere : broche d'horloge de la macro ; l'insertion interne ({LAT.get(m, 0.0):.2f} ns) est vue")
        out.append("# par le flux en horloge propagee. Valeur d'un bus : son pire bit, puis les bits qui s'en")
        out.append("# ecartent. Traversees : set_max_delay par paire de bus. Ne pas modifier a la main.")
        for l in src:
            if l.startswith("create_clock"):
                # periode des SDC = periode atteignable (les budgets en dependent)
                out.append(re.sub(r"-period \S+", f"-period {T + z:g}", l))
                continue
            if re.match(r"set_(input|output)_delay\s+-max\s", l):
                continue                         # -max d'un SDC deja rebudgete : remplace
            mo = re.match(r"set_(input|output)_delay\s+-min\s+(\S+)\s+-clock clk \[get_ports \{(.+)\}\]", l) \
                or re.match(r"set_(input|output)_delay\s+([-0-9.]\S*)\s+-clock clk \[get_ports \{(.+)\}\]", l)
            if mo:
                kind = "in" if mo.group(1) == "input" else "out"
                v = par_bus[(kind, mo.group(3))]
                vus.add((kind, mo.group(3)))
                if v is not None:
                    avant = anc_val.get((kind, mo.group(3)), mo.group(2))
                    out.append(f"set_{mo.group(1)}_delay -max {v:7.3f} -clock clk [get_ports {{{mo.group(3)}}}]"
                               f"   ;# avant {avant}")
                    # -min <= -max (pire bit compris) : un -min plus grand, repris
                    # d'une ligne sans -min/-max (port « nouveau » d'un SDC rebudgete),
                    # rendrait le hold optimiste aux deux sens (entree et sortie).
                    vmin = min([float(mo.group(2)), v]
                               + [vb for _, vb in surcharges[(kind, mo.group(3))]])
                    out.append(f"set_{mo.group(1)}_delay -min {vmin:.3f} -clock clk [get_ports {{{mo.group(3)}}}]"
                               + ("" if vmin == float(mo.group(2)) else f"   ;# ancien -min {mo.group(2)}"))
                    for port, vb in surcharges[(kind, mo.group(3))]:
                        out.append(f"set_{mo.group(1)}_delay -max {vb:7.3f} -clock clk [get_ports {{{port}}}]")
                else:
                    out.extend(anc_max.get((kind, mo.group(3)), []))   # bus sans budget : ancien -max garde
                    out.append(l)
            elif l.startswith("set_max_delay") or l.startswith("# Traversees") or \
                    l.startswith("# du pire chemin") or l.startswith("# 0.5 de sa marge"):
                continue
            else:
                out.append(l)
        for (kind, bus), v in sorted(par_bus.items()):
            if (kind, bus) not in vus and v is not None:
                d = "input" if kind == "in" else "output"
                out.append(f"set_{d}_delay -max {v:7.3f} -clock clk [get_ports {{{bus}}}]   ;# nouveau")
                vmin = min([v] + [vb for _, vb in surcharges[(kind, bus)]])
                out.append(f"set_{d}_delay -min {vmin:.3f} -clock clk [get_ports {{{bus}}}]   ;# sans hold d'origine")
                for port, vb in surcharges[(kind, bus)]:
                    out.append(f"set_{d}_delay -max {vb:7.3f} -clock clk [get_ports {{{port}}}]")
        def val(kind, port):                     # valeur ecrite pour ce bit
            bus = re.sub(r"\[\d+\]$", "[*]", port)
            for pp, vb in surcharges[(kind, bus)]:
                if pp == port:
                    return vb
            return par_bus[(kind, bus)] or 0.0
        # (bus in, bus out) -> max_delay : le plus grand des (entree + D + sortie) des paires
        # de bits, pour que chaque paire ait au moins son budget D (le plus serre imposerait
        # le D d'une paire courte, issue_i.slot -> complete_o.valid, aux paires longues).
        # Arcs relevés (D alloue) et arcs du modele .lib absents du releve (D = g d) :
        # la borne d'une paire de bus est la plus large ; les paires de bits relevees
        # gardent leur borne par une surcharge bit a bit (OpenSTA retient, a priorite
        # egale, le set_max_delay le plus serre).
        paires = defaultdict(lambda: -1e30)
        dmin = defaultdict(lambda: 1e30)
        par_paire = {}
        for (mm, u, v), D in feed.items():
            if mm != m:
                continue
            pu, pv = macro_de(u)[1], macro_de(v)[1]
            bu = re.sub(r"\[\d+\]$", "[*]", pu)
            bv = re.sub(r"\[\d+\]$", "[*]", pv)
            # OpenSTA retire aussi l'incertitude d'horloge d'un set_max_delay entre ports
            # (requis = V - incertitude - sortie) : V = entree + D + sortie + U pour d <= D.
            x = val("in", pu) + D + val("out", pv) + U
            par_paire[(pu, pv)] = min(par_paire.get((pu, pv), 1e30), x)
            dmin[(bu, bv)] = min(dmin[(bu, bv)], D)
        for (pu, pv), x in par_paire.items():
            k = (re.sub(r"\[\d+\]$", "[*]", pu), re.sub(r"\[\d+\]$", "[*]", pv))
            paires[k] = max(paires[k], x)
        n_lib = 0
        for (pu, pv), d in arcs_lib(m).items():
            if (pu, pv) in par_paire or pu in ("clk_i", "CLK_i"):
                continue
            bu = re.sub(r"\[\d+\]$", "[*]", pu)
            bv = re.sub(r"\[\d+\]$", "[*]", pv)
            if par_bus[("in", bu)] is None or par_bus[("out", bv)] is None:
                continue                         # ports sans budget : rien a borner
            x = val("in", pu) + g[m] * d + val("out", pv) + U
            if x > paires[(bu, bv)]:
                paires[(bu, bv)] = x
                n_lib += 1
            dmin[(bu, bv)] = min(dmin[(bu, bv)], g[m] * d)
        if paires:
            out.append("# Traversees combinatoires : max_delay = entree + D + sortie + incertitude, D = budget interne")
            out.append("# alloue au chemin le plus serre qui traverse la paire.")
        n_sur = 0
        for (bu, bv), md in sorted(paires.items()):
            out.append(f"set_max_delay {md:7.3f} -from [get_ports {{{bu}}}] -to [get_ports {{{bv}}}]"
                       f"   ;# D min {dmin[(bu, bv)]:.3f} ns")
            for (pu, pv), x in sorted(par_paire.items()):
                if re.sub(r"\[\d+\]$", "[*]", pu) == bu and re.sub(r"\[\d+\]$", "[*]", pv) == bv \
                        and x < md - ECART:
                    out.append(f"set_max_delay {x:7.3f} -from [get_ports {{{pu}}}] -to [get_ports {{{pv}}}]")
                    n_sur += 1
        dst = os.path.join(a.sortie, ancien)
        open(dst, "w").write("\n".join(out) + "\n")
        print(f"   {dst} ({n_lib} paires elargies d'apres la .lib, {n_sur} surcharges de traversee)")


if __name__ == "__main__":
    main()
