#!/usr/bin/env python3
"""Positions des broches d'une macro d'apres son pin_order.cfg, et l'inverse.

Reproduit le placement de LibreLane (OpenROAD.CustomIOPlacement, scripts/odbpy/io_place.py,
LibreLane 3) et les pistes d'OpenROAD (InitFloorplan::makeTracks), sans lancer le flux.

Usage :
  position_broches.py <dossier de la macro> [--cfg f.cfg] [--detail] [--lef sortie.lef]
      positions des broches, cote par cote, groupe par groupe (centre de la broche, um ;
      x depuis la gauche sur N et S, y depuis le bas sur E et W) ;
      --lef : LEF minimal (taille et broches) pour essayer un placement de broches dans
      synth_InO/sta/plan_puce/canaux.py ou la STA d'assemblage (fils.py) avant de relancer.
  position_broches.py <dossier> --viser souhaits.txt --sortie pin_order.cfg
      ecrit le pin_order.cfg qui place chaque groupe a la position voulue.
  position_broches.py <dossier> --verifier-lef
      compare au LEF de vues/ (validation du modele, si le cfg n'a pas change depuis le run).

Le dossier est celui de pnr_InO/macros/<m> : config_25ns.yaml (DESIGN_NAME, DIE_AREA,
VERILOG_FILES, IO_PIN_ORDER_CFG ; --config pour un autre fichier) et la source Verilog
(ports de la macro).

Regles de io_place.py (a connaitre pour ecrire un cfg a la main) :
  - emplacements d'un cote : une piste sur ceil(d / pas) de la couche des broches (Metal2
    sur N et S, pas 0,48 ; Metal3 sur E et W, pas 0,42), d = largeur de broche (2 x 0,20)
    + espacement (0,21), ou @min_distance si plus grand : 0,96 um sur N/S, 0,84 um sur E/W ;
    S emplacements, en partant de la piste a un pas du bord ;
  - n = broches reelles (chaque bit) + somme des $N ; t = floor(S / n) ;
    u = S - (t (n - 1) + 1) emplacements inutilises, moitie de chaque cote ;
    rang de la i-eme entree (les $N comptent N) : floor(u / 2) + t i ;
  - ordre : croissant (gauche -> droite sur N/S, bas -> haut sur E/W) ; #NR, #ER... inversent
    la liste du cote ($ compris) ; dans un groupe, les bits sont tries (#BUS_SORT ou
    @bit_major : bit d'abord) ;
  - n = S exactement fait echouer io_place.py ($ non retires) : --viser vise n = S - 1
    (t = 1, u = 1, premier rang 0), ou chaque $N vaut alors N emplacements exactement.

Fichier de souhaits (--viser) : la syntaxe du pin_order.cfg (#N, #ER, #BUS_SORT,
@min_distance=..., $N, expressions), plus devant une expression :
    > 386.0  \\\\?reset_i           le groupe commence a 386,0 um de l'origine du cote ;
    >+20     \\\\?exec_req_i\\..*     20 um apres la fin du groupe precedent ;
    sans >   : juste a la suite du groupe precedent (ou au debut du cote) ;
    %pas 2   (dans un cote) : une broche tous les 2 emplacements (1,68 um sur E/W, 1,92 um
             sur N/S) au lieu de 1 ; les $N du fichier de souhaits comptent alors en pas.
Cote inverse (#NR, #SR, #ER, #WR) : l'origine passe a l'autre bout (droite pour N/S, haut
pour E/W) ; les groupes s'ecrivent dans l'ordre depuis ce bout, les > s'y mesurent, et les
bits de chaque groupe vont en decroissant le long de l'axe. Le R est reporte dans le cfg
ecrit, dont la liste garde l'ordre du souhait (io_place.py la retourne lui-meme).
Positions arrondies au pas du cote ; le cfg ecrit est relu et replace pour controle.
"""
import argparse, math, os, re, sys

DBU = 1000
# Pistes (tracks.info IHP, = PITCH / OFFSET du LEF technologique) et regles des couches
COUCHES = {   # couche : (pas x, pas y, decalage x, decalage y, largeur, espacement), dbu
    "Metal2": (480, 420, 0, 0, 200, 210),
    "Metal3": (480, 420, 0, 0, 200, 210),
    "Metal4": (480, 420, 0, 0, 200, 210),
    "Metal5": (480, 420, 0, 0, 200, 210),
}
MULT = 2            # IO_PIN_*_THICKNESS_MULT (defaut LibreLane)


# ---------------------------------------------------------------- lecture
def lire_yaml_simple(f):
    """Cles de premier niveau d'un config.yaml LibreLane (valeur ou liste)."""
    d, cle = {}, None
    for l in open(f):
        if not l.strip() or l.lstrip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*$", l)
        if m:
            cle, v = m.group(1), m.group(2)
            d[cle] = v if v else []
            continue
        m = re.match(r"^\s+-\s*(.+?)\s*$", l)
        if m and cle is not None and isinstance(d.get(cle), list):
            d[cle].append(m.group(1))
    return d


def chemin(dossier, v):
    v = v.strip().strip('"').strip("'")
    return os.path.join(dossier, v[5:]) if v.startswith("dir::") else v


def ports_verilog(fichiers, module):
    """Bits des ports du module (noms comme OpenROAD : sans '\\', bus en nom[i])."""
    for f in fichiers:
        t = open(f).read()
        m = re.search(r"\bmodule\s+" + re.escape(module) + r"\b(.*?)\bendmodule\b", t, re.S)
        if not m:
            continue
        corps = m.group(1)
        entete = re.match(r"\s*\((.*?)\)\s*;", corps, re.S)
        ordre = [p.strip().lstrip("\\").strip() for p in entete.group(1).split(",")] if entete else []
        decl = {}
        for d in re.finditer(r"\b(input|output|inout)\s+(?:wire\s+|reg\s+)?(\[\s*(\d+)\s*:\s*(\d+)\s*\])?\s*"
                             r"((?:\\\S+|[A-Za-z_][\w$]*)(?:\s*,\s*(?:\\\S+|[A-Za-z_][\w$]*))*)\s*;", corps):
            for n in re.split(r"\s*,\s*", d.group(5)):
                n = n.lstrip("\\").strip()
                if d.group(2):
                    a, b = int(d.group(3)), int(d.group(4))
                    decl[n] = [f"{n}[{i}]" for i in (range(b, a + 1) if a >= b else range(b, a - 1, -1))]
                else:
                    decl[n] = [n]
        bits = []
        for p in (ordre or list(decl)):
            bits += decl.get(p, [])
        return bits
    sys.exit(f"module {module} introuvable dans {fichiers}")


def lire_lef(f):
    """-> (largeur, hauteur, {broche: (couche, xc, yc)}) en um."""
    w = h = None
    pins, cur, couche = {}, None, None
    for l in open(f):
        t = l.split()
        if not t:
            continue
        if t[0] == "SIZE" and len(t) >= 4 and t[2] == "BY" and w is None:
            w, h = float(t[1]), float(t[3].rstrip(";"))
        elif t[0] == "PIN":
            cur = t[1]
        elif t[0] == "LAYER" and cur:
            couche = t[1]
        elif t[0] == "RECT" and cur and cur not in pins:
            x1, y1, x2, y2 = map(float, t[1:5])
            pins[cur] = (couche, (x1 + x2) / 2, (y1 + y2) / 2)
        elif t[0] == "END" and len(t) > 1 and t[1] == cur:
            cur = None
    return w, h, pins


def lire_cfg(texte):
    """Comme ioplace_parser : {cote: {"rev", "min", "tri", "pins": [regex | int]}}, et les
    lignes globales ; renvoie aussi, pour --viser, les marques '>' (index -> (abs, val))."""
    tri_global, min_global = "bus", None
    cotes, cur, marques, globales = {}, None, {}, []
    for brut in texte.splitlines():
        l = brut.strip()
        if not l:
            continue
        marque = None
        m = re.match(r"^>\s*(\+?)\s*(-?[\d.]+)\s+(\S+)\s*$", l)
        if m:
            marque = ("rel" if m.group(1) else "abs", float(m.group(2)))
            l = m.group(3)
        if l.startswith("#"):
            d = l[1:]
            if d == "BUS_SORT":
                tri_global = "bit"
                globales.append(l)
                continue
            if not re.match(r"^[NSEW]R?$", d):
                sys.exit(f"direction inconnue : {l}")
            cur = {"rev": len(d) == 2, "min": min_global, "tri": tri_global, "pins": [], "nom": d}
            cotes[d[0]] = cur
            continue
        if l.startswith("%"):                    # directive de --viser (pas du cote)
            m = re.match(r"^%pas\s+(\d+)$", l)
            if not m or cur is None:
                sys.exit(f"directive illisible ou hors d'un cote : {l}")
            cur["pas_t"] = int(m.group(1))
            continue
        if l.startswith("@"):
            m = re.match(r"^@(\w+)(?:\s*=\s*([\d.]+))?$", l)
            if not m:
                sys.exit(f"annotation illisible : {l}")
            a, v = m.group(1), m.group(2)
            if a == "min_distance":
                if cur is None:
                    min_global = float(v); globales.append(l)
                else:
                    cur["min"] = float(v)
            elif a in ("bus_major", "bit_major"):
                if cur is None:
                    tri_global = "bus" if a == "bus_major" else "bit"; globales.append(l)
                else:
                    cur["tri"] = "bus" if a == "bus_major" else "bit"
            else:
                sys.exit(f"annotation inconnue : {l}")
            continue
        if cur is None:
            sys.exit(f"'{l}' avant toute direction")
        if l.startswith("$"):
            cur["pins"].append(int(l[1:]))
        else:
            if marque:
                marques[(id(cur), len(cur["pins"]))] = marque
            cur["pins"].append(l)
    for s in "NESW":
        cotes.setdefault(s, {"rev": False, "min": min_global, "tri": tri_global, "pins": [], "nom": s})
    return cotes, marques, globales


# ---------------------------------------------------------------- modele io_place.py
_ident = re.compile(r"\b[A-Za-z_][A-Za-z_0-9]*\b")
_nombre = re.compile(r"\b\d+\b")
_rebut = re.compile(r"^[^\w\d]+$")


def trieur(nom, tri):
    """Copie de sorter() de io_place.py (y compris ses particularites)."""
    text, keys, prio = nom, [], []
    while _rebut.match(text) is None:
        m = _ident.search(text)
        if m:
            a, b = m.span(0)
            (prio if tri == "bus" else keys).append(m[0])
            text = text[:a] + text[b + 1:]
            continue
        m = _nombre.search(text)
        if m:
            (prio if tri == "bit" else keys).append(int(m[0]))
            text = text[:m.pos] + text[m.endpos + 1:]
            continue
        break
    return [prio, keys]


def pistes(longueur_dbu, pas, decalage, largeur):
    """InitFloorplan::makeTracks d'OpenROAD, sur un axe (origine 0)."""
    if decalage == 0:
        decalage = pas
    n = (longueur_dbu - decalage) // pas + 1
    o = decalage
    if o - largeur // 2 < 0:
        o += pas; n -= 1
    if o + (n - 1) * pas + largeur // 2 > longueur_dbu:
        n -= 1
    return [o + i * pas for i in range(n)]


def emplacements(cote, info, W, H, couche_h, couche_v):
    ns = cote in "NS"
    px, py, ox, oy, lw, sp = COUCHES[couche_v if ns else couche_h]
    largeur_broche = MULT * lw
    dmin = largeur_broche + sp
    if info["min"] is not None and info["min"] * DBU > dmin:
        dmin = int(round(info["min"] * DBU))
    if ns:
        tr, pas = pistes(W, px, ox, lw), px
    else:
        tr, pas = pistes(H, py, oy, lw), py
    k = math.ceil(dmin / pas)
    return [tr[i] for i in range(len(tr)) if i % k == 0], k * pas


def placer_cote(cote, info, bits, W, H, couche_h, couche_v):
    """-> (liste [(entree, [bits], [positions dbu])], resume) comme io_place.py."""
    slots, pas = emplacements(cote, info, W, H, couche_h, couche_v)
    pris = info["_pris"]
    liste = []
    for e in info["pins"]:
        if isinstance(e, int):
            liste.append((e, None))
            continue
        rx = re.compile("^" + e + "$")
        g = [b for b in bits if rx.match(b)]
        for b in g:
            if b in pris:
                sys.exit(f"{b} pris par deux expressions : {pris[b]} et {e}")
            pris[b] = e
        g.sort(key=lambda b: trieur(b, info["tri"]))
        liste.append((e, g))
    # une entree par broche (comme pin_placement de io_place.py), $ en entiers
    seq = []
    for e, g in liste:
        if g is None:
            seq.append(e)
        else:
            seq += [(e, b) for b in g]
    if info["rev"]:
        seq.reverse()
    reels = sum(1 for x in seq if not isinstance(x, int))
    virt = sum(x for x in seq if isinstance(x, int))
    n, S = reels + virt, len(slots)
    res = {"S": S, "n": n, "reels": reels, "virt": virt, "pas": pas, "t": None, "u": None, "r0": None}
    if n > S:
        sys.exit(f"cote {cote} : {n} broches pour {S} emplacements")
    pos = {}
    if n == S and virt:
        print(f"[attention] cote {cote} : n = S avec des $ : io_place.py echoue (assertion)", file=sys.stderr)
    if n == 0:
        return liste, pos, res
    if n == S:
        t, u, r = 1, 0, 0
        it = iter(slots)
        for x in seq:
            if not isinstance(x, int):
                pos[x[1]] = next(it)
    else:
        t = S // n
        u = S - (t * (n - 1) + 1)
        r = u // 2
        r0 = r
        for x in seq:
            if isinstance(x, int):
                r += t * x
            else:
                pos[x[1]] = slots[r]
                r += t
        r = r0
    res.update(t=t, u=u, r0=r, slots=slots)
    return liste, pos, res


def placer(bits, cotes, W, H, couche_h, couche_v):
    pris = {}
    out = {}
    for c in "NESW":
        cotes[c]["_pris"] = pris
        out[c] = placer_cote(c, cotes[c], bits, W, H, couche_h, couche_v)
    hors = [b for b in bits if b not in pris]
    return out, hors


def um(v):
    return v / DBU


# ---------------------------------------------------------------- commandes
def afficher(out, hors, detail, W, H):
    noms = {"N": "nord (x)", "S": "sud (x)", "E": "est (y)", "W": "ouest (y)"}
    for c in "NESW":
        liste, pos, r = out[c]
        if r["n"] == 0:
            continue
        print(f"\n== cote {noms[c]} : {r['reels']} broches + {r['virt']} virtuelles = n {r['n']} ; "
              f"S {r['S']} emplacements de {um(r['pas']):.2f} um ; t {r['t']} "
              f"(pas des broches {um(r['pas'] * r['t']):.2f} um) ; u {r['u']} ; premier rang {r['r0']}")
        for e, g in liste:
            if g is None:
                print(f"   ${e:<6d} {'':38s} {e * r['t']} emplacements = {um(e * r['t'] * r['pas']):8.2f} um")
                continue
            if not g:
                print(f"   {e:44s} (aucune broche)")
                continue
            ps = [pos[b] for b in g]
            print(f"   {e:44s} {len(g):4d} bits  {um(min(ps)):8.2f} -> {um(max(ps)):8.2f} um"
                  f"   ({g[0]} a {um(pos[g[0]]):.2f})")
            if detail:
                for b in g:
                    print(f"        {b:40s} {um(pos[b]):9.2f}")
    if hors:
        print(f"\n[attention] {len(hors)} broches sans expression (cote tire au hasard par io_place.py) : "
              + ", ".join(hors[:8]) + (" ..." if len(hors) > 8 else ""))


def toutes_positions(out, W, H, couche_h, couche_v):
    """broche -> (cote, couche, x, y) en dbu (centre)."""
    r = {}
    for c in "NESW":
        _, pos, _ = out[c]
        for b, p in pos.items():
            if c == "N":
                r[b] = (c, couche_v, p, H)
            elif c == "S":
                r[b] = (c, couche_v, p, 0)
            elif c == "E":
                r[b] = (c, couche_h, W, p)
            else:
                r[b] = (c, couche_h, 0, p)
    return r


def ecrire_lef(f, nom, W, H, posi):
    h = MULT * 200 // 2       # demi-largeur de broche
    L = 400                   # longueur de broche (aire minimale)
    o = open(f, "w")
    o.write(f"VERSION 5.8 ;\nMACRO {nom}\n  CLASS BLOCK ;\n  SIZE {um(W):.3f} BY {um(H):.3f} ;\n")
    for b, (c, couche, x, y) in sorted(posi.items()):
        if c == "N":
            r = (x - h, H - L, x + h, H)
        elif c == "S":
            r = (x - h, 0, x + h, L)
        elif c == "E":
            r = (W - L, y - h, W, y + h)
        else:
            r = (0, y - h, L, y + h)
        o.write(f"  PIN {b}\n    PORT\n      LAYER {couche} ;\n        RECT "
                + " ".join(f"{um(v):.3f}" for v in r) + " ;\n    END\n  END " + b + "\n")
    o.write(f"END {nom}\nEND LIBRARY\n")
    o.close()


def viser(texte, bits, W, H, couche_h, couche_v):
    """Fichier de souhaits -> texte du pin_order.cfg (n = S - 1 par cote)."""
    cotes, marques, globales = lire_cfg(texte)
    pris = {}
    lignes = list(globales)
    rapport = []
    for c in "NESW":
        info = cotes[c]
        if not info["pins"]:
            continue
        slots, pas = emplacements(c, info, W, H, couche_h, couche_v)
        S = len(slots)
        # t emplacements par broche (%pas) ; n total choisi pour que io_place.py retombe
        # sur ce t avec le moins de marge possible (n = S - 1 pour t = 1 : n = S le fait
        # echouer) ; rangs j en unites de t a partir du premier emplacement utilise r0.
        t = info.get("pas_t", 1)
        ntot = S - 1 if t == 1 else S // t
        if S // ntot != t:
            sys.exit(f"cote {c} : pas {t} impossible ({S} emplacements)")
        u = S - (t * (ntot - 1) + 1)
        rev = info["rev"]
        Lc = W if c in "NS" else H
        # #XR : io_place.py retourne la liste ecrite ; le j-ieme rang de la liste ecrite
        # tombe donc a l'emplacement S - 1 - (u - u // 2) - t j, compte depuis l'autre
        # bout. Les positions (>) d'un cote inverse sont donc mesurees depuis ce bout-la
        # (haut pour E/W, droite pour N/S) et les groupes ecrits dans l'ordre depuis ce
        # bout ; la sortie garde l'ordre et le R.
        r0 = (u - u // 2) if rev else u // 2
        def slot_de(j):
            k = r0 + t * j
            return slots[max(0, S - 1 - k)] if rev else slots[min(k, S - 1)]
        def x_de(j):                             # coordonnee dans le repere du souhait
            return um(Lc - slot_de(j)) if rev else um(slot_de(j))
        groupes = []
        for i, e in enumerate(info["pins"]):
            if isinstance(e, int):
                groupes.append(("$", e, None))
                continue
            rx = re.compile("^" + e + "$")
            g = [b for b in bits if rx.match(b)]
            if not g:
                sys.exit(f"cote {c} : {e} ne correspond a aucune broche")
            for b in g:
                if b in pris:
                    sys.exit(f"{b} pris par deux expressions : {pris[b]} et {e}")
                pris[b] = e
            groupes.append((e, len(g), marques.get((id(info), i))))
        cur, sortie = 0, []
        for e, nb, mq in groupes:
            if e == "$":
                sortie.append(nb); cur += nb
                continue
            if mq is not None:
                if mq[0] == "abs":
                    r = round((mq[1] - x_de(0)) * DBU / (t * pas))
                else:
                    r = cur + round(mq[1] * DBU / (t * pas))
                if r < cur:
                    sys.exit(f"cote {c} : {e} demande {mq[1]} um mais le groupe precedent "
                             f"finit a {x_de(cur - 1):.2f} um")
                if r > cur:
                    sortie.append(r - cur)
                cur = r
            sortie.append(e)
            a0, a1 = sorted((um(slot_de(cur)), um(slot_de(cur + nb - 1))))
            rapport.append((c, e, nb, a0, a1, rev, um(Lc)))
            cur += nb
        if cur > ntot:
            sys.exit(f"cote {c} : {cur} rangs pour {ntot} au pas {t}")
        if ntot - cur > 0:
            sortie.append(ntot - cur)
        lignes.append("")
        lignes.append("#" + info["nom"])
        if info["min"] is not None and info["min"] != cotes.get("_", {}).get("min"):
            lignes.append(f"@min_distance={info['min']}")
        for x in sortie:
            lignes.append(f"${x}" if isinstance(x, int) else x)
    return "\n".join(lignes) + "\n", rapport, [b for b in bits if b not in pris]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dossier")
    ap.add_argument("--config", default="config_25ns.yaml")
    ap.add_argument("--cfg", help="pin_order.cfg (defaut : IO_PIN_ORDER_CFG de la config)")
    ap.add_argument("--detail", action="store_true")
    ap.add_argument("--lef", help="ecrit un LEF minimal des broches placees")
    ap.add_argument("--viser", help="fichier de souhaits -> pin_order.cfg (--sortie)")
    ap.add_argument("--sortie")
    ap.add_argument("--verifier-lef", action="store_true")
    ap.add_argument("--couche-h", default="Metal3")
    ap.add_argument("--couche-v", default="Metal2")
    a = ap.parse_args()

    cf = lire_yaml_simple(os.path.join(a.dossier, a.config))
    nom = cf["DESIGN_NAME"].strip('"')
    da = re.findall(r"[\d.]+", cf["DIE_AREA"] if isinstance(cf["DIE_AREA"], str) else " ".join(cf["DIE_AREA"]))
    x0, y0, x1, y1 = (int(round(float(v) * DBU)) for v in da)
    W, H = x1 - x0, y1 - y0
    vf = cf["VERILOG_FILES"]
    vf = [vf] if isinstance(vf, str) else vf
    bits = ports_verilog([chemin(a.dossier, v) for v in vf], nom)
    bits = [b for b in bits if b not in ("VPWR", "VGND", "VDD", "VSS")]
    ch = cf.get("IO_PIN_H_LAYER"); cv = cf.get("IO_PIN_V_LAYER")
    couche_h = ch.strip('"') if isinstance(ch, str) and ch else a.couche_h
    couche_v = cv.strip('"') if isinstance(cv, str) and cv else a.couche_v
    print(f"{nom} : {um(W):.2f} x {um(H):.2f} um, {len(bits)} bits de ports, broches {couche_v} (N/S), "
          f"{couche_h} (E/W)")

    if a.viser:
        if not a.sortie:
            sys.exit("--viser demande --sortie")
        texte, rapport, hors = viser(open(a.viser).read(), bits, W, H, couche_h, couche_v)
        open(a.sortie, "w").write(texte)
        print(f"{a.sortie} ecrit")
        # controle : on replace avec le cfg produit
        cotes, _, _ = lire_cfg(texte)
        out, hors2 = placer(bits, cotes, W, H, couche_h, couche_v)
        for c, e, nb, p0, p1, rev, Lc in rapport:
            liste, pos, _ = out[c]
            g = next(g for x, g in liste if x == e)
            ps = [um(pos[b]) for b in g]
            ok = abs(min(ps) - p0) < 0.01 and abs(max(ps) - p1) < 0.01
            if rev:      # depuis l'autre bout, comme dans le souhait, puis depuis l'origine
                q = f"{Lc - max(ps):8.2f} -> {Lc - min(ps):8.2f} um depuis l'autre bout " \
                    f"({min(ps):.2f} -> {max(ps):.2f} depuis l'origine)"
            else:
                q = f"{min(ps):8.2f} -> {max(ps):8.2f} um"
            print(f"   {c}{'R' if rev else ' '} {e:44s} {nb:4d} bits  {q}{'' if ok else '  ECART'}")
        if hors2:
            print(f"[attention] {len(hors2)} broches sans expression : " + ", ".join(hors2[:8]))
        return

    cfgf = a.cfg or chemin(a.dossier, cf["IO_PIN_ORDER_CFG"])
    cotes, _, _ = lire_cfg(open(cfgf).read())
    out, hors = placer(bits, cotes, W, H, couche_h, couche_v)
    afficher(out, hors, a.detail, W, H)
    posi = toutes_positions(out, W, H, couche_h, couche_v)
    if a.lef:
        ecrire_lef(a.lef, nom, W, H, posi)
        print(f"\n{a.lef} ecrit ({len(posi)} broches)")
    if a.verifier_lef:
        lef = os.path.join(a.dossier, "vues", f"{os.path.basename(os.path.normpath(a.dossier))}.lef")
        _, _, pl = lire_lef(lef)
        ecarts, n = [], 0
        for b, (c, couche, x, y) in posi.items():
            if b not in pl:
                ecarts.append((b, "absente du LEF")); continue
            n += 1
            lc, lx, ly = pl[b]
            if lc != couche or abs(lx - um(x)) > 0.25 or abs(ly - um(y)) > 0.25:
                ecarts.append((b, f"modele {c} {couche} ({um(x):.2f}, {um(y):.2f}), LEF {lc} ({lx:.2f}, {ly:.2f})"))
        print(f"\nverification contre {lef} : {n} broches comparees, {len(ecarts)} ecarts")
        for b, t in ecarts[:10]:
            print(f"   {b} : {t}")


if __name__ == "__main__":
    main()
