#!/usr/bin/env python3
"""Resume du rapport DRC du routeur detaille (OpenROAD TritonRoute).

Usage :
  python3 analyser_drc.py runs/RUN_.../NN-openroad-detailedrouting/<macro>.drc [config.yaml] [pas_um]

Donne :
  - le nombre de violations par type et par couche ;
  - les nets les plus souvent en cause ;
  - une carte grossiere (cases de pas_um, 50 um par defaut) des zones touchees ;
  - si config.yaml est donne, la place de chaque violation par rapport aux SRAM :
    sous la bande de broches d'une SRAM (0..20 um), dans un canal, ou ailleurs.
"""
import re, sys, collections

# Tailles (LEF) des SRAM IHP utilisees : largeur, hauteur.
SIZES = {
    "RM_IHPSG13_2P_512x32_c2_bm_bist": (685.49, 219.77),
    "RM_IHPSG13_1P_1024x64_c2_bm_bist": (784.48, 336.46),
    "RM_IHPSG13_1P_256x48_c2_bm_bist": (596.48, 118.78),
}

def lire_drc(path):
    viol = []
    cur = None
    for line in open(path):
        line = line.strip()
        m = re.match(r"violation type:\s*(.*)", line)
        if m:
            cur = {"type": m.group(1).strip(), "srcs": [], "layer": "?"}
            viol.append(cur)
            continue
        if cur is None:
            continue
        if line.startswith("srcs:"):
            cur["srcs"] = line[5:].split()
        m = re.match(r"bbox\s*=\s*\(\s*([-\d.]+),\s*([-\d.]+)\s*\)\s*-\s*\(\s*([-\d.]+),\s*([-\d.]+)\s*\)\s*on Layer\s*(\S+)", line)
        if m:
            x1, y1, x2, y2 = map(float, m.group(1, 2, 3, 4))
            cur["bbox"] = (x1, y1, x2, y2)
            cur["layer"] = m.group(5)
    return [v for v in viol if "bbox" in v]

def lire_sram(cfg):
    """(nom, x, y, orientation, largeur, hauteur) de chaque SRAM du config.yaml."""
    srams = []
    macro = None
    lines = open(cfg).read().split("\n")
    for i, l in enumerate(lines):
        m = re.match(r"^  (RM_IHPSG13\S+):\s*$", l)
        if m:
            macro = m.group(1)
            continue
        m = re.match(r'^\s+"([^"]+)":\s*$', l)
        if m and macro and i + 2 < len(lines):
            p = re.search(r"location:\s*\[\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\]", lines[i + 1])
            o = re.search(r"orientation:\s*(\w+)", lines[i + 2])
            if p and o:
                w, h = SIZES[macro]
                srams.append((m.group(1), float(p.group(1)), float(p.group(2)), o.group(1), w, h))
    return srams

def zone(x, y, srams):
    for name, sx, sy, o, w, h in srams:
        if sx <= x <= sx + w:
            # bande de broches : bord sud en N, bord nord en FS
            edge = sy if o in ("N", "FN") else sy + h
            court = ".".join(name.split(".")[-3:-1])
            if abs(y - edge) <= 20:
                return "broches de " + court
            if sy <= y <= sy + h:
                return "sur la SRAM " + court
    return "logique / canaux"

def main():
    v = lire_drc(sys.argv[1])
    srams = lire_sram(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].endswith(".yaml") else []
    pas = float(sys.argv[3]) if len(sys.argv) > 3 else 50.0
    print("%d violations\n" % len(v))
    print("Par type et couche :")
    for (t, l), n in collections.Counter((x["type"], x["layer"]) for x in v).most_common():
        print("  %5d  %-28s %s" % (n, t, l))
    print("\nNets les plus en cause :")
    nets = collections.Counter(s for x in v for s in x["srcs"] if s.startswith("net:"))
    for s, n in nets.most_common(15):
        print("  %5d  %s" % (n, s[4:]))
    print("\nCases de %g um les plus touchees (coin bas gauche) :" % pas)
    cells = collections.Counter()
    for x in v:
        x1, y1, x2, y2 = x["bbox"]
        cells[(int((x1 + x2) / 2 // pas) * pas, int((y1 + y2) / 2 // pas) * pas)] += 1
    for (cx, cy), n in cells.most_common(20):
        print("  %5d  x %6.0f .. %6.0f   y %6.0f .. %6.0f" % (n, cx, cx + pas, cy, cy + pas))
    if srams:
        print("\nPar zone :")
        zc = collections.Counter()
        for x in v:
            x1, y1, x2, y2 = x["bbox"]
            zc[zone((x1 + x2) / 2, (y1 + y2) / 2, srams)] += 1
        for z, n in zc.most_common():
            print("  %5d  %s" % (n, z))
    if len(v) <= 150:
        print("\nDetail :")
        for x in sorted(v, key=lambda t: (t["bbox"][1], t["bbox"][0])):
            x1, y1, x2, y2 = x["bbox"]
            z = zone((x1 + x2) / 2, (y1 + y2) / 2, srams) if srams else ""
            nets = " ".join(s[4:] for s in x["srcs"] if s.startswith("net:"))
            print("  %-22s %-9s (%8.2f, %8.2f)  %-28s %s" % (x["type"][:22], x["layer"], (x1 + x2) / 2, (y1 + y2) / 2, z, nets))

main()
