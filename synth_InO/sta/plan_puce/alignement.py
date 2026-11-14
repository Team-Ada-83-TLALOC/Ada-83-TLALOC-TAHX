#!/usr/bin/env python3
"""Alignement bit a bit des liaisons directes entre macros, pour un plan et ses LEF.

Usage : alignement.py [--plan v11h] [--lef v2] [--netlist TAHX_1.nl.v] [--detail]

Lit la netlist synthetisee du sommet de TAHX_1 (par defaut la plus recente de
pnr_InO/assemblage/runs/*/06-yosys-synthesis/TAHX_1.nl.v ; les ports des macros sont
les memes en v1 et en v2), garde les nets qui relient directement deux broches de
macros (sans cellule de liaison entre elles), et place chaque broche d'apres le plan
(canaux.PLANS) et les LEF de la version demandee.

Pour chaque couple (macro source, cote) -> (macro destination, cote) :
  - cotes en face (E -> O ou O -> E, N -> S ou S -> N) : decalage le long du cote
    (dy pour E/O, dx pour N/S, en um) ; 0 partout = bus droit ;
  - autres cotes (bus coude) : nombre de paires de bits croisees (ordre des bits
    inverse entre les deux cotes), et longueur Manhattan.
Controle aussi la grille du sommet : X des macros au pas de 0,48 um, bas des macros
au pas de 0,42 um (avec la marge de generer_config.py).
"""
import argparse, glob, os, re, sys
from collections import defaultdict

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import canaux as C

INST = {"u_instruction.u_fetch": "ino_fetch", "u_instruction.u_decode_predict": "ino_decode_predict",
        "u_decode_queue": "ino_decode_queue", "u_core.u_stack": "stack_unit_16_8",
        "u_core.u_backend.u_entier": "ino_exec_entier", "u_core.u_backend.u_arith": "ino_exec_arith",
        "u_core.u_system": "ino_system", "u_data_cache": "ino_data_cache"}
COURT = {"ino_fetch": "fetch", "ino_decode_predict": "predict", "ino_decode_queue": "dq",
         "stack_unit_16_8": "stack", "ino_exec_entier": "entier", "ino_exec_arith": "arith",
         "ino_system": "system", "ino_data_cache": "dcache"}
FACE = {("E", "W"), ("W", "E"), ("N", "S"), ("S", "N")}


def netlist_defaut():
    c = sorted(glob.glob(os.path.join(C.RACINE, "pnr_InO", "assemblage", "runs", "*",
                                      "06-yosys-synthesis", "TAHX_1.nl.v")))
    return c[-1] if c else None


def lire_lef_dir(chemin):
    """{broche: direction} d'un LEF."""
    d, cur = {}, None
    for l in open(chemin):
        t = l.split()
        if not t:
            continue
        if t[0] == "PIN":
            cur = t[1]
        elif t[0] == "DIRECTION" and cur:
            d[cur] = t[1].rstrip(";")
        elif t[0] == "END" and cur and len(t) > 1 and t[1] == cur:
            cur = None
    return d


def nom_net(s):
    s = s.strip()
    return s[1:].strip() if s.startswith("\\") else s


def lire_netlist(chemin, broches):
    """-> {net: [(macro, broche)]} pour les instances de macros."""
    texte = open(chemin).read()
    nets = defaultdict(list)
    for inst, m in INST.items():
        motif = re.compile(r"^\s*" + re.escape(m) + r"\s+\\?" + re.escape(inst) + r"\s*\(\s*$", re.M)
        r = motif.search(texte)
        if not r:
            print(f"instance absente de la netlist : {inst}")
            continue
        fin = texte.index("\n  );", r.end())
        corps = texte[r.end():fin]
        for p in re.finditer(r"\.(\\\S+\s|[A-Za-z_]\w*)\s*\((.*?)\)\s*,?\s*$", corps, re.M):
            port = nom_net(p.group(1))
            val = p.group(2).strip()
            if not val:
                continue
            if val.startswith("{"):
                bits = [nom_net(b) for b in val.strip("{} ").split(" , ")]
                bits = [b.strip(" ,") for b in bits]
            else:
                bits = [nom_net(val)]
            n = len(bits)
            for k, b in enumerate(bits):
                i = n - 1 - k
                cand = f"{port}[{i}]"
                if cand in broches[m]:
                    nets[b].append((m, cand))
                elif n == 1 and port in broches[m]:
                    nets[b].append((m, port))
    return nets


def cote(m, boites, pos):
    x, y = pos
    bx, by, bw, bh = boites[m]
    return min((abs(x - bx), "W"), (abs(x - bx - bw), "E"), (abs(y - by), "N"), (abs(y - by - bh), "S"))[1]


def fmt_cr(cr):
    return "croisements : n/a" if cr is None else f"paires croisees : {cr[0]}"


def croisements(cs, cd, L):
    """Paires de bits dont les fils se croisent, pour un trace minimal :
    cotes en face -> ordre conserve le long de l'axe (canal) ; cotes perpendiculaires
    -> fil en L (sortie perpendiculaire au cote source, entree perpendiculaire au cote
    destination), test d'intersection des segments ; meme cote (U) : n/a."""
    if cs == cd:
        return None
    paires = []
    if (cs, cd) in FACE:
        axe = 1 if cs in "EW" else 0
        for i in range(len(L)):
            for j in range(i + 1, len(L)):
                a, b = L[i], L[j]
                if (a[3][axe] - b[3][axe]) * (a[4][axe] - b[4][axe]) < 0:
                    paires.append(((a[1], a[2]), (b[1], b[2])))
        return len(paires), paires
    def segs(t):
        (xs, ys), (xd, yd) = t[3], t[4]
        k = (xs, yd) if cs in "NS" else (xd, ys)
        return [((xs, ys), k), (k, (xd, yd))]
    def coupe(s1, s2):
        (a1, a2), (b1, b2) = s1, s2
        h1, h2 = a1[1] == a2[1], b1[1] == b2[1]
        if h1 == h2:
            return False
        hs, vs = (s1, s2) if h1 else (s2, s1)
        (hx1, hy), (hx2, _) = hs
        (vx, vy1), (_, vy2) = vs
        return (min(hx1, hx2) < vx < max(hx1, hx2)) and (min(vy1, vy2) < hy < max(vy1, vy2))
    S = [segs(t) for t in L]
    for i in range(len(L)):
        for j in range(i + 1, len(L)):
            if any(coupe(p, q) for p in S[i] for q in S[j]):
                paires.append(((L[i][1], L[i][2]), (L[j][1], L[j][2])))
    return len(paires), paires


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", default="v11h", choices=sorted(C.PLANS))
    ap.add_argument("--lef", default=None)
    ap.add_argument("--netlist", default=None)
    ap.add_argument("--marge", type=float, default=150.0, help="marge de generer_config.py")
    ap.add_argument("--detail", action="store_true")
    a = ap.parse_args()
    plan = C.PLANS[a.plan]
    vlef = C.version_lef(a.plan, a.lef)
    nl = a.netlist or netlist_defaut()
    if not nl:
        sys.exit("netlist du sommet introuvable (--netlist)")
    boites, broches, dirs = {}, {}, {}
    for m, (x0, y0) in plan["R"].items():
        f = C.lef_macro(m, vlef)
        w, h, pins = C.lire_lef(f)
        boites[m] = (x0, y0, w, h)
        broches[m] = {n: (x0 + px, y0 + (h - py)) for n, (px, py) in pins.items()}
        dirs[m] = lire_lef_dir(f)
    print(f"plan {a.plan}, LEF {vlef or 'v1'}, netlist {os.path.relpath(nl, C.RACINE)}")

    # grille du sommet (positions de generer_config.py)
    H = max(y + h for x, y, w, h in boites.values())
    mx, my = C.grille_pas(a.marge, 0.48), C.grille_pas(a.marge, 0.42)
    for m, (x, y, w, h) in boites.items():
        lx, ly = mx + x, my + H - y - h
        ok = abs(lx / 0.48 - round(lx / 0.48)) < 1e-6 and abs(ly / 0.42 - round(ly / 0.42)) < 1e-6
        if not ok:
            print(f"   hors grille : {m} ({lx:.3f}, {ly:.3f})")

    nets = lire_netlist(nl, broches)
    groupes = defaultdict(list)       # (ms, cs, md, cd) -> [(net, bs, bd, ps, pd)]
    for net, pts in nets.items():
        src = [p for p in pts if dirs[p[0]].get(p[1]) == "OUTPUT"]
        if len(src) != 1 or len(pts) < 2:
            continue
        ms, bs = src[0]
        ps = broches[ms][bs]
        for md, bd in pts:
            if (md, bd) == (ms, bs) or md == ms:
                continue
            pd = broches[md][bd]
            groupes[(ms, cote(ms, boites, ps), md, cote(md, boites, pd))].append((net, bs, bd, ps, pd))

    print(f"\n{sum(len(v) for v in groupes.values())} liaisons directes broche a broche\n")
    print(f"{'source':>16s} -> {'destination':16s} bits  type{'':38s}Manhattan max")
    tot_droit = tot_zero = 0
    for (ms, cs, md, cd), L in sorted(groupes.items(), key=lambda kv: -len(kv[1])):
        lab_s, lab_d = f"{COURT[ms]} {cs}", f"{COURT[md]} {cd}"
        manh = max(abs(ps[0] - pd[0]) + abs(ps[1] - pd[1]) for _, _, _, ps, pd in L)
        axe = 1 if cs in "EW" else 0
        if (cs, cd) in FACE:
            dec = [pd[axe] - ps[axe] for _, _, _, ps, pd in L]
            if axe == 1:                       # y vers le bas -> dy vers le haut (LEF)
                dec = [-d for d in dec]
            zero = sum(1 for d in dec if abs(d) < 0.005)
        cr = croisements(cs, cd, L)
        if (cs, cd) in FACE and zero == len(L):
            tot_droit += len(L); tot_zero += zero
            print(f"{lab_s:>16s} -> {lab_d:16s} {len(L):4d}  droit   decalage nul{'':17s}{manh / 1000:5.2f} mm")
        elif (cs, cd) in FACE:
            tot_droit += len(L); tot_zero += zero
            typ = "decale" if len(L) > 1 else "1 bit"
            print(f"{lab_s:>16s} -> {lab_d:16s} {len(L):4d}  {typ:7s} {min(dec):+9.2f} a {max(dec):+9.2f} um, "
                  f"{zero} a 0, {fmt_cr(cr)}  {manh / 1000:5.2f} mm")
        else:
            forme = "U" if cs == cd else "coude"
            print(f"{lab_s:>16s} -> {lab_d:16s} {len(L):4d}  {forme:7s} {fmt_cr(cr):40s}{manh / 1000:5.2f} mm")
        if a.detail and cr and cr[0]:
            for (b1, d1), (b2, d2) in cr[1][:6]:
                print(f"{'':22s}croise : {b1} -> {d1}  /  {b2} -> {d2}")
    print(f"\nbus droits : {tot_zero} bits a decalage nul sur {tot_droit}")


if __name__ == "__main__":
    main()
