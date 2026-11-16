#!/usr/bin/env python3
"""Cellules d'un chemin d'un rapport report_checks : retard par famille, et position.

Usage :
  python3 pnr_InO/outils/cellules_chemin.py <max.rpt> [--chemin N]
      retard du N-ieme chemin du rapport (defaut 1) par famille de cellules, d'apres le
      prefixe que leur donne OpenROAD : hold (tampons de hold, repair_timing -hold),
      rebuffer et place (repair_timing / placement), wire et max_length (fils longs,
      repair_design), fanout, input / output (tampons des ports), logique (_NNN_).
  openroad -python -exit pnr_InO/outils/cellules_chemin.py -- <max.rpt> <run>.odb [--chemin N]
      en plus, position de chaque cellule (centre, um) et distance de Manhattan a la
      precedente : un chapelet de tampons proches est un retard ajoute, un chapelet
      espace un long fil. --svg chemin.svg : dessin du trajet dans la macro (a ouvrir
      dans un navigateur) : bord de la macro, trajet, cellules de hold, depart, arrivee,
      et le retard des segments de plus de 200 um.
Retard d'un etage = fil jusqu'a l'entree + cellule.
"""
import collections, re, sys

LIGNE = re.compile(r"^\s*((?:-?\d+(?:\.\d+)?\s+)+)([\^v])\s+(\S+)\s+\((\S+)\)\s*$")


def chemin_n(rpt, n):
    """[(instance ou port, cellule, retard de l'etage, instant)] du n-ieme chemin."""
    k, cur, out = 0, None, []
    for l in open(rpt):
        if l.startswith("Startpoint:"):
            k += 1
            cur = (k == n)
            continue
        if not cur:
            continue
        if "data arrival time" in l:
            break
        m = LIGNE.match(l)
        if not m:
            continue
        nb = [float(x) for x in m.group(1).split()]
        nom, cell = m.group(3), m.group(4)
        if cell in ("in", "out"):
            out.append([nom, "port " + cell, nb[-2], nb[-1], 0.0])
            continue
        inst, pin = nom.rsplit("/", 1)
        if len(nb) >= 4:                      # sortie : fanout cap slew retard instant
            if out and out[-1][0] == inst:
                out[-1][2] += nb[-2]; out[-1][3] = nb[-1]; out[-1][4] = nb[-4]
            else:
                out.append([inst, cell, nb[-2], nb[-1], nb[-4]])
        else:                                 # entree : slew retard(fil) instant
            out.append([inst, cell, nb[-2], nb[-1], 0.0])
    if not out:
        sys.exit(f"chemin {n} introuvable dans {rpt}")
    return out


def famille(inst, cell):
    if cell.startswith("port"):
        return "port"
    feuille = inst.split("/")[-1]             # instances hierarchiques (u_backend/.../_0805_)
    m = re.match(r"([a-z_]+?)\d+$", feuille)
    if m:
        return m.group(1).rstrip("_")
    return "logique" if re.match(r"_\d+_$", feuille) else feuille


def main():
    a = [x for x in sys.argv[1:] if x != "--"]
    n, svg = 1, None
    if "--svg" in a:
        i = a.index("--svg"); svg = a[i + 1]; del a[i:i + 2]
    if "--chemin" in a:
        i = a.index("--chemin"); n = int(a[i + 1]); del a[i:i + 2]
    if not a:
        sys.exit(__doc__)
    rpt, odbf = a[0], (a[1] if len(a) > 1 else None)
    etages = chemin_n(rpt, n)
    tot = collections.defaultdict(float)
    nb = collections.Counter()
    for inst, cell, d, t, cap in etages:
        f = famille(inst, cell)
        tot[f] += d; nb[f] += 1
    duree = etages[-1][3] - etages[0][3] + etages[0][2]
    print(f"chemin {n} de {rpt} : {etages[0][0]} -> {etages[-1][0]}, "
          f"{len(etages)} etages, {duree:.3f} ns depuis le port ou la bascule de depart")
    for f, d in sorted(tot.items(), key=lambda e: -e[1]):
        print(f"   {f:12s} {nb[f]:4d} etages  {d:7.3f} ns")

    if not odbf:
        return
    import os
    if not os.path.exists(odbf):
        sys.exit(f"ODB introuvable : {odbf}")
    try:
        import odb
    except ImportError:
        sys.exit("positions : le module odb n'existe que dans OpenROAD ; lancer\n"
                 "  openroad -python -exit pnr_InO/outils/cellules_chemin.py -- <max.rpt> <run>.odb")
    db = odb.dbDatabase.create()
    odb.read_db(db, odbf)
    block = db.getChip().getBlock()
    u = block.getDbUnitsPerMicron()

    def pos(nom, cell):
        if cell.startswith("port"):
            bt = block.findBTerm(nom)
            if bt is None or not bt.getBPins():
                return None
            bb = bt.getBPins()[0].getBBox()
        else:
            inst = block.findInst(nom)
            if inst is None:
                return None
            bb = inst.getBBox()
        return (bb.xMin() + bb.xMax()) / 2 / u, (bb.yMin() + bb.yMax()) / 2 / u

    print(f"\n{'cellule':22s} {'type':28s} {'retard':>7s} {'charge':>7s} {'x':>8s} {'y':>8s} {'dist':>7s}")
    prec, long_tot, trace = None, 0.0, []
    for inst, cell, d, t, cap in etages:
        p = pos(inst, cell)
        if p:
            trace.append((inst, cell, d, p))
        dist = ""
        if p and prec:
            dd = abs(p[0] - prec[0]) + abs(p[1] - prec[1])
            long_tot += dd
            dist = f"{dd:7.1f}"
        xy = f"{p[0]:8.1f} {p[1]:8.1f}" if p else f"{'?':>8s} {'?':>8s}"
        print(f"{inst:22s} {cell:28s} {d:7.3f} {cap:7.4f} {xy} {dist}")
        prec = p or prec
    print(f"longueur de Manhattan parcourue : {long_tot:.0f} um")
    if svg:
        ecrire_svg(svg, block, u, trace, etages, long_tot, rpt, n)


def ecrire_svg(f, block, u, trace, etages, long_tot, rpt, n):
    bb = block.getDieArea()
    W, H = bb.dx() / u, bb.dy() / u
    k = 600.0 / max(W, H)
    def xy(p):
        return 20 + p[0] * k, 20 + (H - p[1]) * k
    pts = " ".join(f"{xy(p)[0]:.1f},{xy(p)[1]:.1f}" for _, _, _, p in trace)
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W * k + 330:.0f} {H * k + 70:.0f}" '
         f'font-family="sans-serif" font-size="12">',
         f'<rect x="20" y="20" width="{W * k:.1f}" height="{H * k:.1f}" fill="none" stroke="#888"/>']
    (x0, y0), (x1, y1) = xy(trace[0][3]), xy(trace[-1][3])
    o.append(f'<line x1="{x0:.1f}" y1="{y0:.1f}" x2="{x1:.1f}" y2="{y1:.1f}" stroke="#888" stroke-dasharray="4 4"/>')
    o.append(f'<polyline points="{pts}" fill="none" stroke="#D85A30" stroke-width="1.5"/>')
    for (i0, c0, d0, p0), (i1, c1, d1, p1) in zip(trace, trace[1:]):
        dd = abs(p1[0] - p0[0]) + abs(p1[1] - p0[1])
        if dd > 200:
            (a0, b0), (a1, b1) = xy(p0), xy(p1)
            o.append(f'<text x="{(a0 + a1) / 2 + 3:.1f}" y="{(b0 + b1) / 2 - 3:.1f}" fill="#993C1D">{d1:.2f}</text>')
    for inst, cell, d, p in trace:
        x, y = xy(p)
        if inst.split("/")[-1].startswith("hold"):
            o.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="#EF9F27"><title>{inst} {d:.3f} ns</title></circle>')
        else:
            o.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="2" fill="#712B13"><title>{inst} {cell} {d:.3f} ns</title></circle>')
    o.append(f'<rect x="{x0 - 6:.1f}" y="{y0 - 6:.1f}" width="12" height="12" fill="#1D9E75"/>')
    o.append(f'<rect x="{x1 - 6:.1f}" y="{y1 - 6:.1f}" width="12" height="12" fill="#7F77DD"/>')
    L = W * k + 40
    dur = etages[-1][3] - etages[0][3] + etages[0][2]
    for i, txt in enumerate([f"{etages[0][0]}", f"-> {etages[-1][0]}", f"{dur:.2f} ns, {len(etages)} etages",
                             f"trajet {long_tot:.0f} um", "vert : depart, violet : arrivee",
                             "orange : cellules de hold", "nombres : retard (ns) des segments > 200 um",
                             f"macro {W:.0f} x {H:.0f} um, nord en haut",
                             "survoler un point : cellule et retard"]):
        o.append(f'<text x="{L:.0f}" y="{40 + 18 * i}">{txt}</text>')
    o.append("</svg>")
    open(f, "w").write("\n".join(o) + "\n")
    print(f"dessin : {f}")


if __name__ == "__main__":
    main()
