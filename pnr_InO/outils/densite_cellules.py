#!/usr/bin/env python3
"""Cartes de densite d'une macro placee : surface de cellules, broches de cellules, et
position des groupes de registres, pour comparer deux runs (v1 / v2).

Usage (OpenROAD) :
  openroad -python -exit pnr_InO/outils/densite_cellules.py -- <run>/<etape>/<macro>.odb \
      [--pas 100] [--groupes cells_s,source_address_s,frame_s,return_cells_s]

Ecrit, sur une grille de `--pas` um (y vers le haut, ligne du haut = haut de la macro) :
  - utilisation (surface des cellules standard, hors remplissage, / surface de la case), % ;
  - broches de cellules (ITerms de signal) par case, en centaines ;
  - pour chaque groupe (prefixe de nom de net, indices retires) : nombre de pilotes,
    barycentre et etendue (x min..max, y min..max) des cellules qui pilotent ces nets ;
  - pilotes de chaque groupe par colonne de la grille.
Les noms de nets des registres viennent du RTL (cells_s, source_address_s...) ; les
cellules elles-memes ont des noms generes (_12345_).
"""
import collections, re, sys

import odb


def args():
    a = [x for x in sys.argv[1:] if x != "--"]
    if not a:
        sys.exit(__doc__)
    opt = {"--pas": "100", "--groupes": "cells_s,source_address_s,frame_s,return_cells_s,new_dsp_s,"
                                          "old_dsp_s,new_rsp_s,maint_s,destination_address_s"}
    pos, i = [], 0
    while i < len(a):
        if a[i] in opt:
            opt[a[i]] = a[i + 1]; i += 2
        else:
            pos.append(a[i]); i += 1
    return pos[0], float(opt["--pas"]), [g for g in opt["--groupes"].split(",") if g]


def base(n):
    return re.sub(r"\[\d+\]", "", n.replace("\\", ""))


def main():
    chemin, P, groupes = args()
    db = odb.dbDatabase.create()
    odb.read_db(db, chemin)
    block = db.getChip().getBlock()
    u = block.getDbUnitsPerMicron()
    die = block.getDieArea()
    W, H = die.xMax() / u, die.yMax() / u
    NX, NY = int(-(-W // P)), int(-(-H // P))
    surf = [[0.0] * NY for _ in range(NX)]
    pins = [[0] * NY for _ in range(NX)]
    pos = {}
    for inst in block.getInsts():
        m = inst.getMaster()
        nom = m.getName()
        if re.search(r"(fill|decap|tap|endcap|antenna)", nom, re.I):
            continue
        bb = inst.getBBox()
        x, y = (bb.xMin() + bb.xMax()) / 2 / u, (bb.yMin() + bb.yMax()) / 2 / u
        i, j = min(NX - 1, int(x // P)), min(NY - 1, int(y // P))
        surf[i][j] += m.getWidth() * m.getHeight() / u / u
        pins[i][j] += sum(1 for it in inst.getITerms() if it.getNet() is not None
                          and it.getNet().getSigType() not in ("POWER", "GROUND"))
        pos[inst.getName()] = (x, y)

    def carte(titre, val, fmt):
        print(f"\n{titre} (cases de {P:g} um, x de gauche a droite, haut de la macro en haut)")
        print("        " + "".join(f"{int(i * P):>5d}" for i in range(NX)))
        for j in reversed(range(NY)):
            print(f"{int(j * P):>6d}  " + "".join(fmt(val(i, j)) for i in range(NX)))

    print(f"{chemin}\nboite {W:g} x {H:g} um")
    carte("utilisation des cases (%)", lambda i, j: 100 * surf[i][j] / (P * P), lambda v: f"{v:5.0f}")
    carte("broches de cellules par case (centaines)", lambda i, j: pins[i][j] / 100, lambda v: f"{v:5.1f}")

    pil = collections.defaultdict(list)
    for net in block.getNets():
        b = base(net.getName())
        if b not in groupes:
            continue
        for it in net.getITerms():
            if it.isOutputSignal():
                p = pos.get(it.getInst().getName())
                if p:
                    pil[b].append(p)
    print("\ngroupes de registres : pilotes, barycentre, etendue (um)")
    for g in groupes:
        L = pil.get(g, [])
        if not L:
            print(f"   {g:24s} absent")
            continue
        xs, ys = [p[0] for p in L], [p[1] for p in L]
        print(f"   {g:24s} {len(L):5d}  ({sum(xs) / len(L):6.0f}, {sum(ys) / len(L):6.0f})  "
              f"x {min(xs):5.0f}..{max(xs):5.0f}  y {min(ys):5.0f}..{max(ys):5.0f}")
    print("\npilotes par colonne :")
    print(f"   {'':24s}" + "".join(f"{int(i * P):>5d}" for i in range(NX)))
    for g in groupes:
        c = collections.Counter(min(NX - 1, int(p[0] // P)) for p in pil.get(g, []))
        if c:
            print(f"   {g:24s}" + "".join(f"{c.get(i, 0):5d}" for i in range(NX)))


main()
