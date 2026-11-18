#!/usr/bin/env python3
"""Raccord des bandes d'alimentation d'une macro par ses bords (option B).

Usage (OpenROAD) :
  openroad -python -exit pnr_InO/outils/bords_alim.py -- <m>.odb [autre.odb ...] \\
      [--couche TopMetal1] [--n 5]
  (OpenROAD ancien : openroad -python bords_alim.py -- ...)

Les macros retenues au 17 novembre ont leur grille jusqu'a TopMetal1, la couche du
haut, et routent aussi des signaux sur TopMetal1 (couches_macro.py) : la grille du
sommet ne peut ni passer au-dessus, ni etre retiree de la macro. Reste a la raccorder
par les bords : au sommet, une amorce TopMetal1 a la hauteur exacte de chaque bande
de la macro, du canal jusqu'a l'extremite de la bande (meme net : fusion).

Pour chaque bande d'alimentation horizontale de la couche (formes des nets speciaux,
plus longues que larges), et pour chacune de ses deux extremites, l'outil examine la
zone entre l'extremite et le bord de la macro, elargie de l'espacement minimal de la
couche au-dessus et au-dessous de la bande. Une extremite est libre si aucune forme
d'un autre net n'y touche sur la couche : fils et vias de signal (dbWireDecoder),
formes des autres nets speciaux, broches et obstructions des instances (SRAM).
Il ecrit, par macro et par net : nombre de bandes, extremites libres a gauche et a
droite, distance au bord ; puis les --n premieres extremites bloquees et ce qui les
bloque. Toutes libres d'un cote au moins : l'option B est faisable sans relancer la
macro.
"""
import collections
import sys

import odb


def args():
    a = [x for x in sys.argv[1:] if x != "--"]
    if not a or a[0] in ("-h", "--help"):
        sys.exit(__doc__)
    opt = {"--couche": "TopMetal1", "--n": "5"}
    pos = []
    i = 0
    while i < len(a):
        if a[i] in opt:
            opt[a[i]] = a[i + 1]
            i += 2
        else:
            pos.append(a[i])
            i += 1
    return pos, opt["--couche"], int(opt["--n"])


def touche(r, z):
    return r[0] < z[2] and z[0] < r[2] and r[1] < z[3] and z[1] < r[3]


def formes_signal(block, couche, layer):
    """[(x0, y0, x1, y1, net)] des fils et vias de signal sur la couche."""
    demi = layer.getWidth() // 2
    res = []
    for net in block.getNets():
        if net.isSpecial() or net.getSigType() in ("POWER", "GROUND"):
            continue
        wire = net.getWire()
        if wire is None:
            continue
        nom = net.getName()
        dec = odb.dbWireDecoder()
        dec.begin(wire)
        cour = None
        prec = None
        while True:
            op = dec.next()
            if op == odb.dbWireDecoder.END_DECODE:
                break
            if op in (odb.dbWireDecoder.PATH, odb.dbWireDecoder.JUNCTION,
                      odb.dbWireDecoder.SHORT, odb.dbWireDecoder.VWIRE):
                ly = dec.getLayer()
                cour = ly.getName() if ly is not None else None
                prec = None
            elif op in (odb.dbWireDecoder.POINT, odb.dbWireDecoder.POINT_EXT):
                p = dec.getPoint()
                p = (int(p[0]), int(p[1]))
                if prec is not None and cour == couche:
                    res.append((min(p[0], prec[0]) - demi, min(p[1], prec[1]) - demi,
                                max(p[0], prec[0]) + demi, max(p[1], prec[1]) + demi, nom))
                prec = p
            elif op in (odb.dbWireDecoder.VIA, odb.dbWireDecoder.TECH_VIA):
                via = dec.getTechVia() if op == odb.dbWireDecoder.TECH_VIA else dec.getVia()
                if prec is not None and via is not None:
                    for b in via.getBoxes():
                        ly = b.getTechLayer()
                        if ly is not None and ly.getName() == couche:
                            res.append((prec[0] + b.xMin(), prec[1] + b.yMin(),
                                        prec[0] + b.xMax(), prec[1] + b.yMax(), nom))
                ly = dec.getLayer()
                if ly is not None:
                    cour = ly.getName()
    return res


def formes_instances(block, couche):
    """[(x0, y0, x1, y1, origine)] des broches et obstructions des instances."""
    res = []
    for inst in block.getInsts():
        master = inst.getMaster()
        t = inst.getTransform()
        boites = []
        for b in master.getObstructions():
            ly = b.getTechLayer()
            if ly is not None and ly.getName() == couche:
                boites.append((b, f"OBS {inst.getName()}"))
        for mt in master.getMTerms():
            for mp in mt.getMPins():
                for b in mp.getGeometry():
                    ly = b.getTechLayer()
                    if ly is not None and ly.getName() == couche:
                        boites.append((b, f"broche {inst.getName()}/{mt.getName()}"))
        for b, origine in boites:
            r = odb.Rect(b.xMin(), b.yMin(), b.xMax(), b.yMax())
            t.apply(r)
            res.append((r.xMin(), r.yMin(), r.xMax(), r.yMax(), origine))
    return res


def analyser(chemin, couche, n):
    db = odb.dbDatabase.create()
    odb.read_db(db, chemin)
    block = db.getChip().getBlock()
    u = block.getDbUnitsPerMicron()
    die = block.getDieArea()
    X0, Y0, X1, Y1 = die.xMin(), die.yMin(), die.xMax(), die.yMax()
    layer = db.getTech().findLayer(couche)
    if layer is None:
        sys.exit(f"couche inconnue : {couche}")
    esp = layer.getSpacing()

    bandes = []                                    # (net, x0, y0, x1, y1)
    autres_spe = []                                # formes speciales, par net
    for net in block.getNets():
        if not (net.isSpecial() or net.getSigType() in ("POWER", "GROUND")):
            continue
        for sw in net.getSWires():
            for b in sw.getWires():
                if b.isVia():
                    via = b.getTechVia() or b.getBlockVia()
                    if via is None:
                        continue
                    for vb in via.getBoxes():
                        ly = vb.getTechLayer()
                        if ly is not None and ly.getName() == couche:
                            x, y = b.getViaXY()
                            autres_spe.append((x + vb.xMin(), y + vb.yMin(), x + vb.xMax(),
                                               y + vb.yMax(), net.getName()))
                    continue
                ly = b.getTechLayer()
                if ly is None or ly.getName() != couche:
                    continue
                r = (b.xMin(), b.yMin(), b.xMax(), b.yMax(), net.getName())
                autres_spe.append(r)
                if b.xMax() - b.xMin() > 4 * (b.yMax() - b.yMin()):
                    bandes.append(r)
    sig = formes_signal(block, couche, layer)
    ins = formes_instances(block, couche)

    print(f"\n=== {chemin}")
    print(f"bloc {block.getName()} : {(X1 - X0) / u:g} x {(Y1 - Y0) / u:g} um ; {couche} : "
          f"{len(bandes)} bandes d'alimentation horizontales, {len(sig)} formes de signal, "
          f"{len(ins)} formes d'instances ; espacement {esp / u:g} um")
    bilan = collections.defaultdict(lambda: [0, 0, 0, 0, 0.0, 0.0])
    bloquees = []
    for (x0, y0, x1, y1, net) in bandes:
        b = bilan[net]
        b[0] += 1
        for cote, z in (("gauche", (X0, y0 - esp, x0, y1 + esp)),
                        ("droite", (x1, y0 - esp, X1, y1 + esp))):
            gene = [f[4] for f in sig + ins + [s for s in autres_spe if s[4] != net]
                    if touche(f, z)]
            dist = (z[2] - z[0]) / u
            if cote == "gauche":
                b[4] = max(b[4], dist)
            else:
                b[5] = max(b[5], dist)
            if not gene:
                b[1 if cote == "gauche" else 2] += 1
            else:
                bloquees.append((net, cote, y0 / u, y1 / u, sorted(set(gene))[:3]))
        libres = [k for k in bloquees if k[0] == net and abs(k[2] - y0 / u) < 1e-6]
        if len(libres) == 0:
            b[3] += 1                              # les deux extremites libres
    for net, (k, g, d, deux, dg, dd) in sorted(bilan.items()):
        print(f"   {net:6s} {k:4d} bandes ; extremites libres : gauche {g}, droite {d}, "
              f"les deux {deux} ; distance au bord jusqu'a {dg:.2f} / {dd:.2f} um")
    une = sum(1 for (x0, y0, x1, y1, net) in bandes
              if sum(1 for q in bloquees if q[0] == net and abs(q[2] - y0 / u) < 1e-6) < 2)
    if bloquees:
        print(f"   extremites bloquees : {len(bloquees)} ; premieres :")
        for net, cote, ya, yb, gene in bloquees[:n]:
            print(f"      {net} y {ya:.2f}..{yb:.2f} {cote} : {', '.join(gene)}")
    verdict = "faisable" if une == len(bandes) and bandes else "a voir"
    print(f"   verdict option B : {une} / {len(bandes)} bandes atteignables par un bord au moins ({verdict})")
    return une, len(bandes), len(bloquees)


def main():
    chemins, couche, n = args()
    res = [(c, analyser(c, couche, n)) for c in chemins]
    if len(res) > 1:
        print(f"\n=== bilan {couche} : bandes atteignables par un bord / bandes, extremites bloquees")
        for c, (une, tot, bl) in res:
            print(f"   {une:4d} / {tot:4d}   {bl:4d}   {c}")


if __name__ == "__main__":
    main()
