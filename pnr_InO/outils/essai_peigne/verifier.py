# SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verification independante d'un vidage d'essai du peigne (essai.tcl) : espacements
TopMetal1 / Metal4 (un ecart du meme net comble par une forme est accepte), formes dans
les macros hors des couloirs, broches TopMetal1 des macros reliees a la grille, VPWR et
VGND separes. Usage : verifier.py <vidage>"""
import sys, math, collections
ESP = {"TopMetal1": 1640, "Metal4": 210}
S, V, P, M, G = [], [], [], {}, []
for l in open(sys.argv[1]):
    t = l.split()
    if t[0] == "S": S.append((t[1], t[2], *map(int, t[3:7]))); G.append(t[7] == "1")
    elif t[0] == "V": V.append((t[1], int(t[2]), int(t[3])))
    elif t[0] == "P": P.append((t[1], t[2], *map(int, t[3:7])))
    elif t[0] == "M": M[t[1]] = tuple(map(int, t[2:6]))
def dist(a, b):
    dx = max(0, b[0] - a[2], a[0] - b[2]); dy = max(0, b[1] - a[3], a[1] - b[3])
    return math.hypot(dx, dy)
def comble(a, b, L):
    """l'ecart entre a et b (meme net) est-il rempli par une forme du meme net ?"""
    (ax1, ay1, ax2, ay2), (bx1, by1, bx2, by2) = a[2], b[2]
    ox1, ox2, oy1, oy2 = max(ax1, bx1), min(ax2, bx2), max(ay1, by1), min(ay2, by2)
    if ox2 > ox1: z = (ox1, min(ay2, by2), ox2, max(ay1, by1))
    elif oy2 > oy1: z = (min(ax2, bx2), oy1, max(ax1, bx1), oy2)
    else: return False
    return any(f[0] == a[0] and f[2][0] <= z[0] and f[2][1] <= z[1] and f[2][2] >= z[2] and f[2][3] >= z[3]
               for f in L)
# espacements (formes speciales + broches TopMetal1 des macros)
formes = [(n, c, (x1, y1, x2, y2)) for n, c, x1, y1, x2, y2 in S] + \
         [(n, "TopMetal1", (x1, y1, x2, y2)) for n, i, x1, y1, x2, y2 in P]
par = collections.defaultdict(list)
for f in formes: par[f[1]].append(f)
viol = collections.Counter(); ex = {}
for c, L in par.items():
    L.sort(key=lambda f: f[2][0])
    for i, a in enumerate(L):
        for b in L[i + 1:]:
            if b[2][0] > a[2][2] + ESP[c]: break
            if b[2][1] > a[2][3] + ESP[c] or a[2][1] > b[2][3] + ESP[c]: continue
            d = dist(a[2], b[2])
            if a[0] != b[0] and d < ESP[c]:
                k = f"{c} court {a[0]}/{b[0]}"; viol[k] += 1; ex.setdefault(k, (a, b))
            elif a[0] == b[0] and 0 < d < ESP[c] and not comble(a, b, L):
                k = f"{c} ecart meme net"; viol[k] += 1; ex.setdefault(k, (a, b))
# formes dans les macros : seulement les stubs dans les couloirs (bout de bande -> bord)
for n, c, x1, y1, x2, y2 in S:
    for nom, (a, b, cc, d) in M.items():
        if x1 < cc and x2 > a and y1 < d and y2 > b:
            ok = c == "TopMetal1" and any(p[0] == n and p[1] == nom and p[3] == y1 and p[5] == y2 and
                                          (p[2] <= x2 or p[4] >= x1) for p in P)
            if not ok: viol["forme dans une macro hors couloir"] += 1
# connexite : noeuds = formes et broches ; vias : Metal4 et TopMetal1 du meme net contenant le centre
N = [(n, c, r) for n, c, r in formes]
pere = list(range(len(N)))
def r_(i):
    while pere[i] != i: pere[i] = pere[pere[i]]; i = pere[i]
    return i
def u_(i, j): pere[r_(i)] = r_(j)
idx = collections.defaultdict(list)
for i, (n, c, r) in enumerate(N): idx[(n, c)].append(i)
for k, L in idx.items():
    L.sort(key=lambda i: N[i][2][0])
    for a_, i in enumerate(L):
        for j in L[a_ + 1:]:
            if N[j][2][0] > N[i][2][2]: break
            if dist(N[i][2], N[j][2]) == 0: u_(i, j)
for n, x, y in V:
    m4 = [i for i in idx[(n, "Metal4")] if N[i][2][0] <= x <= N[i][2][2] and N[i][2][1] <= y <= N[i][2][3]]
    tm = [i for i in idx[(n, "TopMetal1")] if N[i][2][0] <= x <= N[i][2][2] and N[i][2][1] <= y <= N[i][2][3]]
    for i in m4 + tm[1:]: u_(i, (m4 + tm)[0])
# la grille d'origine est reliee par les vias de pdngen (absents de l'essai) : un noeud par net
racines = {}
for n in ("VPWR", "VGND"):
    L = [i for i in range(len(S)) if G[i] and N[i][0] == n]
    for i in L[1:]: u_(i, L[0])
    racines[n] = L[0]
isoles = collections.Counter()
for k, (n, inst, *r) in enumerate(P):
    i = len(S) + k
    if r_(i) != r_(racines[n]): isoles[inst] += 1
if r_(racines["VPWR"]) == r_(racines["VGND"]): viol["VPWR et VGND relies"] += 1
print(f"formes {len(S)}, vias {len(V)}, broches TM1 {len(P)} ; violations {dict(viol)} ; "
      f"broches non reliees a la grille {dict(isoles)}")
for k, (a, b) in ex.items(): print("  ex.", k, a, b)
