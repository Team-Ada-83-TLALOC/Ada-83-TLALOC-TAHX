#!/usr/bin/env python3
"""Nets qui traversent les zones congestionnees du routage global d'une macro.

Usage (OpenROAD, depuis le dossier du run) :
  openroad -python -exit pnr_InO/outils/congestion_nets.py -- \
      runs/RUN_.../39-openroad-globalrouting/<macro>.odb [--couche Metal3] [--marge 0]

Lit dans l'ODB :
  - les marqueurs de congestion du routage global (categorie du DRC Viewer dont le
    nom contient "route" ; ceux que GRT-0115 signale) : boites en um ;
  - les guides de routage global de chaque net (dbNet.getGuides()) sur la couche
    demandee (Metal3 : la couche horizontale qui deborde).
Ecrit :
  - l'enveloppe des marqueurs et leur repartition (grille de 100 um) ;
  - les nets dont un guide de la couche touche un marqueur, groupes :
      * par bus de broches de la macro (nets relies a un port : nom du port sans
        indice de bit), avec le cote du port (N/S/E/W) ;
      * pour les nets internes, par etendue horizontale (longueur en x de leurs
        guides) et par extremites : port le plus proche de chaque bout a 2 niveaux
        de cellules pres (pilote et charges directes seulement) ;
  - les 30 noms de nets les plus frequents une fois les indices retires.
Sur l'ODB d'un assemblage (macros placees), les nets entre macros sont aussi groupes
par broche de macro (instance:bus) : liste "relies a une macro".
Sert a savoir quels bus de broches alimentent la congestion (deplacement ou espacement
de groupes dans le wish_pin_order, sans toucher au floorplan).
"""
import collections, re, sys

import odb


def args():
    a = [x for x in sys.argv[1:] if x != "--"]
    if not a:
        sys.exit(__doc__)
    opt = {"--couche": "Metal3", "--marge": "0"}
    pos = []
    i = 0
    while i < len(a):
        if a[i] in opt:
            opt[a[i]] = a[i + 1]; i += 2
        else:
            pos.append(a[i]); i += 1
    return pos[0], opt["--couche"], float(opt["--marge"])


def categories(cat_list):
    for c in cat_list:
        yield c
        try:
            yield from categories(c.getMarkerCategories())
        except AttributeError:
            pass


def base(nom):
    return re.sub(r"\[\d+\]", "", nom.replace("\\", ""))


def main():
    chemin, couche, marge = args()
    db = odb.dbDatabase.create()
    odb.read_db(db, chemin)
    block = db.getChip().getBlock()
    u = block.getDbUnitsPerMicron()
    die = block.getDieArea()
    W, H = die.xMax() / u, die.yMax() / u

    # --- marqueurs de congestion
    boites = []
    for c in categories(block.getMarkerCategories()):
        nom = c.getName()
        try:
            ms = c.getMarkers()
        except AttributeError:
            continue
        if "route" not in nom.lower() and "congest" not in nom.lower():
            continue
        for m in ms:
            r = m.getBBox()
            boites.append((r.xMin() / u - marge, r.yMin() / u - marge, r.xMax() / u + marge, r.yMax() / u + marge))
    if not boites:
        cats = [c.getName() for c in categories(block.getMarkerCategories())]
        sys.exit(f"aucun marqueur de congestion ; categories presentes : {cats}")
    print(f"{chemin}\nboite {W:g} x {H:g} um ; {len(boites)} marqueurs de congestion")
    print("enveloppe : x %.0f..%.0f, y %.0f..%.0f um" % (min(b[0] for b in boites), max(b[2] for b in boites),
                                                         min(b[1] for b in boites), max(b[3] for b in boites)))
    grille = collections.Counter((int((b[0] + b[2]) / 200) * 100, int((b[1] + b[3]) / 200) * 100) for b in boites)
    print("marqueurs par case de 100 um (x0, y0 : nombre), les plus denses :")
    for (x, y), n in grille.most_common(12):
        print(f"   ({x:5d}, {y:5d}) : {n}")

    # index grossier des marqueurs par case de 50 um
    P = 50.0
    idx = collections.defaultdict(list)
    for k, b in enumerate(boites):
        for i in range(int(b[0] // P), int(b[2] // P) + 1):
            for j in range(int(b[1] // P), int(b[3] // P) + 1):
                idx[(i, j)].append(k)

    def touche(x0, y0, x1, y1):
        for i in range(int(x0 // P), int(x1 // P) + 1):
            for j in range(int(y0 // P), int(y1 // P) + 1):
                for k in idx.get((i, j), ()):
                    b = boites[k]
                    if x0 <= b[2] and b[0] <= x1 and y0 <= b[3] and b[1] <= y1:
                        return True
        return False

    def cote(bt):
        bb = bt.getBBox()
        x, y = (bb.xMin() + bb.xMax()) / 2 / u, (bb.yMin() + bb.yMax()) / 2 / u
        return min((x, "W"), (W - x, "E"), (y, "S"), (H - y, "N"))[1]

    def ports(net):
        return [bt for bt in net.getBTerms()]

    def ports_voisins(net):
        """ports a une cellule pres (pilote et charges directes du net)."""
        res = set()
        for it in net.getITerms():
            inst = it.getInst()
            for it2 in inst.getITerms():
                n2 = it2.getNet()
                if n2 is None or n2 == net:
                    continue
                if n2.getSigType() in ("POWER", "GROUND", "CLOCK"):
                    continue
                for bt in n2.getBTerms():
                    res.add(base(bt.getName()))
        return res

    par_macro = collections.Counter()
    par_bus = collections.Counter()
    cotes_bus = {}
    internes = []
    noms = collections.Counter()
    n_nets = 0
    for net in block.getNets():
        if net.getSigType() in ("POWER", "GROUND"):
            continue
        try:
            gs = net.getGuides()
        except AttributeError:
            sys.exit("dbNet.getGuides() absent : OpenROAD trop ancien, ou guides non gardes dans l'ODB")
        xs = []
        dedans = False
        for g in gs:
            if g.getLayer().getName() != couche:
                continue
            r = g.getBox()
            x0, y0, x1, y1 = r.xMin() / u, r.yMin() / u, r.xMax() / u, r.yMax() / u
            xs += [x0, x1]
            if not dedans and touche(x0, y0, x1, y1):
                dedans = True
        if not dedans:
            continue
        n_nets += 1
        noms[base(net.getName())] += 1
        bts = ports(net)
        if bts:
            for bt in bts:
                b = base(bt.getName())
                par_bus[b] += 1
                cotes_bus[b] = cote(bt)
        else:
            macros = sorted({f"{it.getInst().getName()}:{base(it.getMTerm().getName())}"
                             for it in net.getITerms() if it.getInst().isBlock()})
            if macros:
                par_macro[" -> ".join(macros[:3])] += 1
            else:
                internes.append((max(xs) - min(xs), net))

    print(f"\n{n_nets} nets avec un guide {couche} dans une zone congestionnee")
    print(f"\nrelies a un port ({sum(par_bus.values())} bits) : bus, cote, bits")
    for b, n in par_bus.most_common(25):
        print(f"   {b:40s} {cotes_bus[b]}  {n}")

    if par_macro:
        print(f"\nrelies a une macro ({sum(par_macro.values())} nets) : broches de macros, nets")
        for b, n in par_macro.most_common(30):
            print(f"   {b:70s} {n}")

    internes.sort(key=lambda t: -t[0])
    tranches = collections.Counter()
    for dx, _ in internes:
        tranches[min(int(dx // 250) * 250, 1000)] += 1
    print(f"\ninternes ({len(internes)}) par etendue en x de leurs guides {couche} (um) :")
    for t in sorted(tranches):
        print(f"   {t:5d}{'+' if t == 1000 else ' a %d' % (t + 250):>8s} : {tranches[t]}")
    voisins = collections.Counter()
    for dx, net in internes:
        if dx < 250:
            continue
        for p in ports_voisins(net):
            voisins[p] += 1
    print("\ninternes de plus de 250 um : ports a une cellule pres (bus : nets)")
    for p, n in voisins.most_common(25):
        print(f"   {p:40s} {n}")
    print("\nnoms de nets les plus frequents (indices retires) :")
    for nom, n in noms.most_common(30):
        print(f"   {nom:50s} {n}")


main()
