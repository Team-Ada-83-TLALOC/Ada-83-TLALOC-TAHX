#!/usr/bin/env python3
"""Demande de fil interne d'une macro pour une disposition de broches donnee.

Entrees :
  flux.txt   : liaisons de la netlist (flux.tcl) : entree -> sortie (combinatoire),
               entree -> bascule, bascule -> sortie ;
  <cfg>      : fichier IO_PIN_ORDER_CFG de LibreLane (#N #S #E #W, $n, @bit_major) ;
  <L> <H>    : dimensions de la boite (um) ;
  <lef>      : LEF de la macro (liste des broches).

Modele : chaque bit d'entree a est relie a chaque bit de sortie o qu'il atteint,
directement ou a travers une bascule, avec le poids 1 / (nombre de destinations de a),
et 1 / (destinations de la bascule) en plus a travers une bascule : un signal diffuse
partout (reset, valid, opcode) compte pour environ un fil, un bus de donnees pour un fil
par bit. La demande est la somme poids x distance de Manhattan entre broches, separee
en horizontal (Metal3 dans sg13cmos5l) et vertical (Metal2, Metal4). Ce n'est pas un
routage : c'est un indicateur pour comparer des dispositions en quelques secondes.

Positions (io_place.py de LibreLane) : N et S de gauche a droite, E et W de bas en
haut ; broches et creneaux virtuels ($n) repartis regulierement le long du cote.

Usage : flux_broches.py flux.txt <cfg> <L> <H> <lef> [nombre de paires a lister]
"""
import re
import sys
from collections import defaultdict, Counter


def broches_lef(f):
    return [p.replace("\\", "") for p in re.findall(r"^\s*PIN\s+(\S+)", open(f).read(), re.M)
            if p not in ("VPWR", "VGND")]


def cle(nom, bit_major):
    nums = [int(x) for x in re.findall(r"\d+", nom)]
    ids = re.findall(r"[A-Za-z_][A-Za-z_0-9]*", nom)
    return (nums, ids) if bit_major else (ids, nums)


def positions(cfg, L, H, pins):
    bit_major = False
    cotes = defaultdict(list)
    cote = None
    pris = set()
    for l in open(cfg):
        l = l.strip()
        if not l:
            continue
        if l.startswith("@"):
            bit_major = "bit" in l
            continue
        if l.startswith("#"):
            cote = l[1]
            continue
        if l.startswith("$"):
            cotes[cote] += [None] * int(l[1:])
            continue
        rx = re.compile("^" + l.replace("\\\\?", "\\\\?") + "$")
        m = [p for p in pins if p not in pris and (rx.match(p) or rx.match("\\" + p))]
        m.sort(key=lambda p: cle(p, bit_major))
        pris |= set(m)
        cotes[cote] += m
    pos = {}
    for c, lst in cotes.items():
        n = len(lst)
        for i, p in enumerate(lst):
            if p is None:
                continue
            t = (i + 0.5) / n
            pos[p] = {"N": (t * L, H), "S": (t * L, 0), "E": (L, t * H), "W": (0, t * H)}[c]
    return pos, set(pins) - pris


def grp(p):
    return re.sub(r"\[\d+\]$", "", p)


def main():
    flux, cfg, L, H, lef = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
    nliste = int(sys.argv[6]) if len(sys.argv) > 6 else 15
    pos, oublis = positions(cfg, L, H, broches_lef(lef))
    IF, IO, FO = defaultdict(set), defaultdict(set), defaultdict(set)
    for l in open(flux):
        k, a, t, b = l.split()
        if "ANTENNA" in b:
            continue
        if k == "I":
            (IO if t == "O" else IF)[a].add(b)
        elif t == "O":
            FO[a].add(b)
    liens = Counter()
    for a, os_ in IO.items():
        for o in os_:
            liens[(a, o)] += 1 / len(os_)
    for a, fs in IF.items():
        for f in fs:
            for o in FO.get(f, ()):
                liens[(a, o)] += 1 / len(fs) / len(FO[f])
    dh = dv = 0.0
    par = Counter()
    poids = Counter()
    for (a, o), w in liens.items():
        if a not in pos or o not in pos:
            continue
        (xa, ya), (xo, yo) = pos[a], pos[o]
        dh += w * abs(xa - xo)
        dv += w * abs(ya - yo)
        par[(grp(a), grp(o))] += w * (abs(xa - xo) + abs(ya - yo))
        poids[(grp(a), grp(o))] += w
    print(f"{cfg} ({L:.0f} x {H:.0f} um) : demande horizontale {dh / 1e3:8.1f} mm, "
          f"verticale {dv / 1e3:8.1f} mm, totale {(dh + dv) / 1e3:8.1f} mm"
          + (f" ; {len(oublis)} broches hors du cfg" if oublis else ""))
    for (A, B), d in par.most_common(nliste):
        print(f"   {d / 1e3:7.1f} mm  {poids[(A, B)]:6.1f} fils  {A:28s} -> {B}")


if __name__ == "__main__":
    main()
