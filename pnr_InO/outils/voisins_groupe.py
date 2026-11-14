#!/usr/bin/env python3
"""Ports atteints depuis les registres d'un groupe, par zone de la macro.

Usage (OpenROAD) :
  openroad -python -exit pnr_InO/outils/voisins_groupe.py -- <macro>.odb return_cells_s \
      [--coupe 400] [--niveaux 3]

Pour chaque pilote d'un net du groupe (nom du net sans indice), classe en zone ouest
(x < coupe) ou est (x >= coupe), parcourt le graphe des cellules jusqu'a `--niveaux`
cellules dans les deux sens (charges et pilotes, sans traverser les bascules au-dela de
la premiere, ni l'horloge, le reset ou l'alimentation) et compte les ports de la macro
atteints (nom du port sans indice). Sert a savoir quelle broche attire chaque moitie
d'un groupe de registres coupe en deux par le placement.
"""
import collections, re, sys

import odb


def base(n):
    return re.sub(r"\[\d+\]", "", n.replace("\\", ""))


def main():
    a = [x for x in sys.argv[1:] if x != "--"]
    opt = {"--coupe": "400", "--niveaux": "3"}
    pos, i = [], 0
    while i < len(a):
        if a[i] in opt:
            opt[a[i]] = a[i + 1]; i += 2
        else:
            pos.append(a[i]); i += 1
    if len(pos) < 2:
        sys.exit(__doc__)
    chemin, groupe = pos[0], pos[1]
    coupe, niveaux = float(opt["--coupe"]), int(opt["--niveaux"])
    db = odb.dbDatabase.create()
    odb.read_db(db, chemin)
    block = db.getChip().getBlock()
    u = block.getDbUnitsPerMicron()

    def centre(inst):
        bb = inst.getBBox()
        return (bb.xMin() + bb.xMax()) / 2 / u, (bb.yMin() + bb.yMax()) / 2 / u

    def ignore(net):
        if net is None or net.getSigType() in ("POWER", "GROUND", "CLOCK", "RESET"):
            return True
        return re.match(r"(clk|reset|rst)", base(net.getName()), re.I) is not None

    def bascule(inst):
        return re.search(r"(df|dl|latch)", inst.getMaster().getName(), re.I) is not None

    zones = {"ouest": [], "est": []}
    for net in block.getNets():
        if base(net.getName()) != groupe:
            continue
        for it in net.getITerms():
            if it.isOutputSignal():
                inst = it.getInst()
                x, y = centre(inst)
                zones["ouest" if x < coupe else "est"].append((inst, net, x, y))

    print(f"{chemin}\ngroupe {groupe} : coupe x = {coupe:g} um, {niveaux} niveaux de cellules")
    for z, L in zones.items():
        if not L:
            print(f"\n{z} : aucun pilote"); continue
        xs, ys = [t[2] for t in L], [t[3] for t in L]
        print(f"\n{z} : {len(L)} pilotes, x {min(xs):.0f}..{max(xs):.0f}, y {min(ys):.0f}..{max(ys):.0f}")
        ports = collections.Counter()
        for inst0, net0, _, _ in L:
            vus_i, vus_n = {inst0.getName()}, set()
            front = [net0]
            vus_p = set()
            for k in range(niveaux):
                suiv = []
                for net in front:
                    if ignore(net) or net.getName() in vus_n:
                        continue
                    vus_n.add(net.getName())
                    for bt in net.getBTerms():
                        vus_p.add(base(bt.getName()))
                    for it in net.getITerms():
                        inst = it.getInst()
                        if inst.getName() in vus_i:
                            continue
                        vus_i.add(inst.getName())
                        if bascule(inst) and k > 0:
                            continue
                        for it2 in inst.getITerms():
                            n2 = it2.getNet()
                            if n2 is not None and n2.getName() not in vus_n:
                                suiv.append(n2)
                front = suiv
            for p in vus_p:
                ports[p] += 1
        for p, n in ports.most_common(15):
            print(f"   {p:40s} {n}")


main()
