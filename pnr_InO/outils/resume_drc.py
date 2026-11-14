#!/usr/bin/env python3
"""Resume d'un rapport DRC de TritonRoute (detailed_route -output_drc).

Usage : resume_drc.py rapport.drc [--largeur 700 --hauteur 1750] [--bande 20]

Compte les violations par type et par couche, puis les situe dans la macro :
dans une bande de --bande um le long de chaque bord (N, S, E, O), ou au coeur,
avec une carte grossiere (cases de 50 um) des zones les plus chargees.
Sans --largeur/--hauteur, l'emprise est prise sur les violations elles-memes.
"""
import argparse, collections, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("rapport")
ap.add_argument("--largeur", type=float)
ap.add_argument("--hauteur", type=float)
ap.add_argument("--bande", type=float, default=20.0)
ap.add_argument("--case", type=float, default=50.0)
a = ap.parse_args()

viol, cur = [], None
re_type = re.compile(r"violation type:\s*(.+)", re.I)
re_bbox = re.compile(r"bbox\s*=\s*\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)\s*-\s*\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)\s*on Layer\s*(\S+)", re.I)
re_srcs = re.compile(r"srcs:\s*(.*)", re.I)
for l in open(a.rapport, errors="replace"):
    m = re_type.search(l)
    if m:
        cur = {"type": m.group(1).strip(), "srcs": ""}
        continue
    m = re_srcs.search(l)
    if m and cur is not None:
        cur["srcs"] = m.group(1).strip()
        continue
    m = re_bbox.search(l)
    if m and cur is not None:
        x1, y1, x2, y2 = map(float, m.group(1, 2, 3, 4))
        cur.update(x=(x1 + x2) / 2, y=(y1 + y2) / 2, couche=m.group(5))
        viol.append(cur)
        cur = None
if not viol:
    sys.exit("aucune violation lue (format inattendu ?)")

W = a.largeur or max(v["x"] for v in viol)
H = a.hauteur or max(v["y"] for v in viol)
print(f"{len(viol)} violations ; emprise {W:.0f} x {H:.0f} um\n")

print("par type et couche :")
for (t, c), n in collections.Counter((v["type"], v["couche"]) for v in viol).most_common():
    print(f"  {n:6d}  {t:30s} {c}")

def zone(v):
    b = a.bande
    z = []
    if v["y"] > H - b: z.append("N")
    if v["y"] < b: z.append("S")
    if v["x"] > W - b: z.append("E")
    if v["x"] < b: z.append("O")
    return "+".join(z) or "coeur"

print(f"\npar zone (bande de {a.bande:.0f} um le long des bords) :")
for z, n in collections.Counter(zone(v) for v in viol).most_common():
    print(f"  {n:6d}  {z}")

print(f"\ncases de {a.case:.0f} um les plus chargees (x, y du coin bas-gauche) :")
cases = collections.Counter((int(v["x"] // a.case), int(v["y"] // a.case)) for v in viol)
for (i, j), n in cases.most_common(15):
    print(f"  {n:6d}  x {i * a.case:6.0f}  y {j * a.case:6.0f}")

print("\nnets les plus cites :")
nets = collections.Counter()
for v in viol:
    for s in v["srcs"].split():
        if s.startswith("net:"):
            nets[s[4:]] += 1
for s, n in nets.most_common(15):
    print(f"  {n:6d}  {s}")
