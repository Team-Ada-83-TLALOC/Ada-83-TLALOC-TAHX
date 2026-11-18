# SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
# SPDX-License-Identifier: GPL-3.0-or-later
"""Grille factice d'essai du peigne : DEF de trois macros et d'une grille PDK coupee au halo.
Usage : grille_essai.py <decalage y de la grille, um> <sortie.def>"""
import sys
off = float(sys.argv[1]); sortie = sys.argv[2]
U = 1000
DIE = (2200, 3700); CORE = (20, 20, 2180, 3680)
macros = [("u_a", "ino_decode_queue", 150, 200, 800, 1100, "N"),
          ("u_b", "ino_decode_queue", 1050, 200, 800, 1100, "FN"),
          ("u_f", "ino_fetch", 150, 1310, 1900, 2200, "N")]
H = 10
trous = [(x - H, y - H, x + w + H, y + h + H) for _, _, x, y, w, h, _ in macros]
def couper(a, b, fixe, horiz, larg):
    """segments [a,b] le long de l'axe, coupes par les trous ; fixe : coordonnee de l'axe du fil"""
    segs = [(a, b)]
    for tx1, ty1, tx2, ty2 in trous:
        lo, hi, c1, c2 = (tx1, tx2, ty1, ty2) if horiz else (ty1, ty2, tx1, tx2)
        if fixe + larg / 2 <= c1 or fixe - larg / 2 >= c2:
            continue
        n = []
        for s, e in segs:
            if e <= lo or s >= hi: n.append((s, e))
            else:
                if s < lo: n.append((s, lo))
                if e > hi: n.append((hi, e))
        segs = n
    return segs
fils = {"VPWR": [], "VGND": []}
x0, y0, x1, y1 = CORE
k = 0
while x0 + 10 + 50 * k + 3 < x1:
    for net, dx in (("VPWR", 0), ("VGND", 3)):
        x = x0 + 10 + 50 * k + dx
        for s, e in couper(y0, y1, x, False, 1):
            fils[net].append(f"Metal4 {int(1*U)} + SHAPE STRIPE ( {int(x*U)} {int(s*U)} ) ( * {int(e*U)} )")
    k += 1
k = 0
while y0 + off + 50 * k + 6 < y1:
    for net, dy in (("VPWR", 0), ("VGND", 6)):
        y = y0 + off + 50 * k + dy + 1
        for s, e in couper(x0, x1, y, True, 2):
            fils[net].append(f"TopMetal1 {int(2*U)} + SHAPE STRIPE ( {int(s*U)} {int(y*U)} ) ( {int(e*U)} * )")
    k += 1
L = ["VERSION 5.8 ;", 'DIVIDERCHAR "/" ;', 'BUSBITCHARS "[]" ;', "DESIGN essai ;",
     "UNITS DISTANCE MICRONS 1000 ;", f"DIEAREA ( 0 0 ) ( {DIE[0]*U} {DIE[1]*U} ) ;",
     f"COMPONENTS {len(macros)} ;"]
for n, m, x, y, w, h, o in macros:
    L.append(f"- {n} {m} + FIXED ( {x*U} {y*U} ) {o} ;")
L += ["END COMPONENTS", "SPECIALNETS 2 ;"]
for net, use in (("VPWR", "POWER"), ("VGND", "GROUND")):
    conn = " ".join(f"( {n} {net} )" for n, *_ in macros)
    L.append(f"- {net} {conn} + USE {use}")
    L.append("  + ROUTED " + "\n    NEW ".join(fils[net]) + " ;")
L += ["END SPECIALNETS", "END DESIGN"]
open(sortie, "w").write("\n".join(L) + "\n")
