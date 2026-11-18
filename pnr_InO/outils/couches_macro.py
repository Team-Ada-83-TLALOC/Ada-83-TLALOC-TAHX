#!/usr/bin/env python3
"""Usage des couches de routage dans l'ODB d'une macro (ou de plusieurs).

Usage (OpenROAD) :
  openroad -python -exit pnr_InO/outils/couches_macro.py -- \\
      pnr_InO/macros/<m>/runs/<RUN>/final/odb/<m>.odb [autre.odb ...] [--couche TopMetal1] [--n 10]
  (OpenROAD ancien : openroad -python couches_macro.py -- ...)

Sert a choisir le raccordement des macros a la grille d'alimentation du sommet
(passation du 18 novembre, § 4). Pour chaque ODB :
  - longueur des fils de signal par couche (mm) et nombre de nets qui touchent chaque
    couche ; vias de signal par couche de coupe ;
  - fils d'alimentation (dbSWire : nets speciaux) par couche : nombre de formes,
    longueur, largeurs ; vias d'alimentation par couche de coupe ;
  - pour la couche --couche (TopMetal1 par defaut) : les --n nets de signal qui y ont
    le plus de longueur, et la boite qui contient leurs fils.
Verdict pour la couche --couche :
  - aucun signal : on peut retirer les bandes d'alimentation de cette couche de l'ODB
    final sans toucher au routage (option C), ou faire passer la grille du sommet au-
    dessus apres une relance en PDN_MULTILAYER: false (option A) ;
  - des signaux : option C exclue ; option A demande RT_MAX_LAYER sous cette couche.
Les fils de signal sont lus par dbWireDecoder (present dans les OpenROAD anciens et
recents) ; longueurs en distance de Manhattan entre points successifs d'une meme couche.
"""
import collections
import sys

import odb


def args():
    a = [x for x in sys.argv[1:] if x != "--"]
    if not a or a[0] in ("-h", "--help"):
        sys.exit(__doc__)
    opt = {"--couche": "TopMetal1", "--n": "10"}
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


def nom_couche(layer):
    return layer.getName() if layer is not None else "?"


def couches_via(via):
    """(coupe, bas, haut) d'un dbTechVia ou dbVia."""
    try:
        bas, haut = via.getBottomLayer(), via.getTopLayer()
    except Exception:
        return ("?", None, None)
    coupe = "?"
    try:
        for b in via.getBoxes():
            ly = b.getTechLayer()
            if ly is not None and ly.getType() == "CUT":
                coupe = ly.getName()
                break
    except Exception:
        pass
    if coupe == "?" and bas is not None and haut is not None:
        coupe = f"{bas.getName()}-{haut.getName()}"
    return (coupe, bas, haut)


def point(dec):
    p = dec.getPoint()
    return int(p[0]), int(p[1])


def fils_signal(net):
    """{couche: longueur dbu}, {coupe: nombre de vias}, boite par couche."""
    longueur = collections.Counter()
    vias = collections.Counter()
    boites = {}
    wire = net.getWire()
    if wire is None:
        return longueur, vias, boites
    dec = odb.dbWireDecoder()
    dec.begin(wire)
    couche = None
    prec = None
    while True:
        op = dec.next()
        if op == odb.dbWireDecoder.END_DECODE:
            break
        if op in (odb.dbWireDecoder.PATH, odb.dbWireDecoder.JUNCTION,
                  odb.dbWireDecoder.SHORT, odb.dbWireDecoder.VWIRE):
            couche = nom_couche(dec.getLayer())
            prec = None
        elif op in (odb.dbWireDecoder.POINT, odb.dbWireDecoder.POINT_EXT):
            p = point(dec)
            if prec is not None and couche is not None:
                longueur[couche] += abs(p[0] - prec[0]) + abs(p[1] - prec[1])
                b = boites.get(couche)
                x0, y0 = min(p[0], prec[0]), min(p[1], prec[1])
                x1, y1 = max(p[0], prec[0]), max(p[1], prec[1])
                boites[couche] = (x0, y0, x1, y1) if b is None else \
                    (min(b[0], x0), min(b[1], y0), max(b[2], x1), max(b[3], y1))
            prec = p
        elif op in (odb.dbWireDecoder.VIA, odb.dbWireDecoder.TECH_VIA):
            via = dec.getTechVia() if op == odb.dbWireDecoder.TECH_VIA else dec.getVia()
            coupe, bas, haut = couches_via(via)
            vias[coupe] += 1
            # le decodeur passe sur l'autre couche du via
            nouvelle = dec.getLayer()
            if nouvelle is not None:
                couche = nom_couche(nouvelle)
            elif bas is not None and haut is not None:
                couche = haut.getName() if couche == bas.getName() else bas.getName()
    return longueur, vias, boites


def fils_alim(net, u):
    """formes par couche : nombre, longueur (um), largeurs (um) ; vias par coupe."""
    formes = collections.defaultdict(lambda: [0, 0.0, set()])
    vias = collections.Counter()
    for sw in net.getSWires():
        for b in sw.getWires():
            if b.isVia():
                via = b.getTechVia() or b.getBlockVia()
                vias[couches_via(via)[0] if via is not None else "?"] += 1
                continue
            ly = nom_couche(b.getTechLayer())
            dx, dy = (b.xMax() - b.xMin()) / u, (b.yMax() - b.yMin()) / u
            f = formes[ly]
            f[0] += 1
            f[1] += max(dx, dy)
            f[2].add(round(min(dx, dy), 3))
    return formes, vias


def analyser(chemin, couche_cible, n):
    db = odb.dbDatabase.create()
    odb.read_db(db, chemin)
    block = db.getChip().getBlock()
    u = block.getDbUnitsPerMicron()
    die = block.getDieArea()
    W, H = (die.xMax() - die.xMin()) / u, (die.yMax() - die.yMin()) / u
    ordre = [ly.getName() for ly in db.getTech().getLayers() if ly.getType() == "ROUTING"]

    lg = collections.Counter()
    nnets = collections.Counter()
    vias_sig = collections.Counter()
    par_net = []
    alim = collections.defaultdict(lambda: [0, 0.0, set()])
    vias_alim = collections.Counter()
    boite_cible = None
    n_sig = n_spe = 0
    for net in block.getNets():
        if net.isSpecial() or net.getSigType() in ("POWER", "GROUND"):
            n_spe += 1
            f, v = fils_alim(net, u)
            for ly, (k, l, w) in f.items():
                a = alim[ly]
                a[0] += k
                a[1] += l
                a[2] |= w
            vias_alim.update(v)
            # un net special peut aussi avoir des fils ordinaires
        l, v, bx = fils_signal(net)
        if not l and not v:
            continue
        if not (net.isSpecial() or net.getSigType() in ("POWER", "GROUND")):
            n_sig += 1
        lg.update(l)
        vias_sig.update(v)
        for ly in l:
            nnets[ly] += 1
        if l.get(couche_cible):
            par_net.append((l[couche_cible], net.getName()))
            b = bx[couche_cible]
            boite_cible = b if boite_cible is None else (
                min(boite_cible[0], b[0]), min(boite_cible[1], b[1]),
                max(boite_cible[2], b[2]), max(boite_cible[3], b[3]))

    print(f"\n=== {chemin}")
    print(f"bloc {block.getName()} : {W:g} x {H:g} um ; {n_sig} nets de signal routes, "
          f"{n_spe} nets speciaux")
    tot = sum(lg.values()) or 1
    print("fils de signal par couche :")
    for ly in ordre:
        if lg.get(ly) or nnets.get(ly):
            print(f"   {ly:10s} {lg[ly] / u / 1000:10.3f} mm  {100 * lg[ly] / tot:5.1f} %  "
                  f"{nnets[ly]:7d} nets")
    for ly in lg:
        if ly not in ordre:
            print(f"   {ly:10s} {lg[ly] / u / 1000:10.2f} mm  (couche hors liste)")
    if vias_sig:
        print("vias de signal : " + ", ".join(f"{c} {k}" for c, k in sorted(vias_sig.items())))
    print("alimentation (nets speciaux) par couche :")
    for ly in ordre + [x for x in alim if x not in ordre]:
        if ly in alim:
            k, l, w = alim[ly]
            ws = ", ".join(f"{x:g}" for x in sorted(w)[:4]) + (" ..." if len(w) > 4 else "")
            print(f"   {ly:10s} {k:7d} formes  {l / 1000:9.2f} mm  largeurs {ws} um")
    if vias_alim:
        print("vias d'alimentation : " + ", ".join(f"{c} {k}" for c, k in sorted(vias_alim.items())))

    lc = lg.get(couche_cible, 0)
    print(f"--- {couche_cible} : {lc / u / 1000:.3f} mm de signal sur {len(par_net)} nets")
    if par_net:
        b = boite_cible
        print(f"    boite des fils : x {b[0] / u:.1f}..{b[2] / u:.1f}, y {b[1] / u:.1f}..{b[3] / u:.1f} um")
        for l, nom in sorted(par_net, reverse=True)[:n]:
            print(f"    {l / u:9.1f} um  {nom}")
        print(f"    verdict : des signaux sur {couche_cible} : option C exclue ; une relance "
              f"(option A) demande RT_MAX_LAYER sous {couche_cible}")
    else:
        print(f"    verdict : aucun signal sur {couche_cible} : options A et C ouvertes")
    return lc / u / 1000, len(par_net)


def main():
    chemins, couche, n = args()
    bilan = []
    for c in chemins:
        bilan.append((c, analyser(c, couche, n)))
    if len(bilan) > 1:
        print(f"\n=== bilan {couche} : signal (mm, nets)")
        for c, (l, k) in bilan:
            print(f"   {l:10.3f} mm {k:6d}  {c}")


if __name__ == "__main__":
    main()
