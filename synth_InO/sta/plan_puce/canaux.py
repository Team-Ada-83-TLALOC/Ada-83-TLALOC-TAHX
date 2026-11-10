#!/usr/bin/env python3
"""Demande de pistes dans les canaux d'un plan de puce TAHX, avec les LEF abstraits.

Usage : canaux.py [--pas 20] [--iter 6] [--png canaux.png]
Lit :
  - les LEF abstraits des macros (pnr_InO/macros/<m>/vues/<m>.lef) : boites et
    position reelle de chaque broche ;
  - liens.json (liaisons champ a champ, connexions_macros.py) ;
  - le plan retenu (plan_retenu.R) et les points des blocs SoC et peripheriques.
Modele :
  - grille de pas `--pas` um sur la boite des macros, plus une marge ; une case dont
    le centre tombe dans une macro est bloquee (LEF a couches occupees obstruees :
    rien ne passe au-dessus des macros) ;
  - capacite d'une case : pistes horizontales (Metal3 0,48 um, TopMetal1 3,28 um a
    moitie pris par l'alimentation) et verticales (Metal2 et Metal4, 0,48 um), avec
    un taux d'utilisation `--util` (0,7) ;
  - chaque bit est une liaison a deux points, broche a broche (les bits d'un champ
    sont apparies dans l'ordre de leurs noms) ; les bits voisins sont groupes en
    faisceaux (meme case de depart et d'arrivee) ;
  - routage de chaque faisceau par Dijkstra sur la grille, en plusieurs passes ou le
    cout d'une case surchargee augmente (negociation a la PathFinder, simplifiee) ;
  - une liaison a plusieurs destinations est comptee comme plusieurs liaisons a
    deux points (sur-estimation : le routeur partage le tronc).
Sortie : cases les plus chargees, charge par canal nomme, carte PNG.
"""
import argparse, heapq, json, math, os, re, sys
from collections import defaultdict

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
RACINE = os.path.abspath(os.path.join(ICI, "..", "..", ".."))
MACROS = os.path.join(RACINE, "pnr_InO", "macros")
DOSSIER = {"ino_decode_queue": "decode_queue"}          # module -> dossier de pnr_InO/macros

# Plans : coin haut-gauche des macros (y vers le bas, orientation N), points des blocs
# SoC et peripheriques, canaux nommes (x0, y0, x1, y1).
PLANS = {
 # Plan retenu (plan_retenu.py, P69).
 "retenu": dict(
   R={"ino_fetch": (0, 0), "ino_decode_predict": (1960, 0), "ino_decode_queue": (2920, 0),
      "stack_unit_16_8": (3380, 0), "ino_exec_arith": (1960, 1160), "ino_exec_entier": (3270, 1560),
      "ino_system": (4320, 1560), "ino_data_cache": (1895, 2620)},
   SOC=(870, 2970), PERIPH=(4870, 3150),
   CANAUX={"fetch | predict": (1900, 0, 1960, 2200), "predict | dq": (2860, 0, 2920, 1100),
           "dq | stack": (3320, 0, 3380, 1100), "predict / arith": (1960, 1100, 2920, 1160),
           "stack / entier+system": (3270, 1500, 4880, 1560), "arith | entier": (3110, 1160, 3270, 2560),
           "entier | system": (4170, 1560, 4320, 2560), "est de stack": (4880, 0, 5420, 1560),
           "sous fetch": (0, 2200, 1895, 2620), "entier / dcache": (1895, 2560, 4170, 2620),
           "arith / dcache": (1960, 2310, 3110, 2620)}),
 # Plan aligne (6 novembre, P76) : exec_entier decale de +328 um (ses broches d'emission
 # et de retour en face de celles du sud de stack_unit), canal stack / entier+system a
 # 460 um, entier | system a 300 um. Routage global du plan elargi : congestion aux
 # memes endroits que l'estimation (carrefour stack / entier / system).
 "aligne": dict(
   R={"ino_fetch": (0, 0), "ino_decode_predict": (2000, 0), "ino_decode_queue": (2960, 0),
      "stack_unit_16_8": (3460, 0), "ino_exec_arith": (2000, 1160), "ino_exec_entier": (3678, 1960),
      "ino_system": (4878, 1960), "ino_data_cache": (1935, 3060)},
   SOC=(870, 3410), PERIPH=(5440, 3590),
   CANAUX={"fetch | predict": (1900, 0, 2000, 2200), "predict | dq": (2900, 0, 2960, 1100),
           "dq | stack": (3360, 0, 3460, 1100), "predict / arith": (2000, 1100, 2900, 1160),
           "stack / entier+system": (3460, 1500, 5978, 1960), "arith | entier": (3150, 1160, 3678, 2960),
           "entier | system": (4578, 1960, 4878, 2960), "est de stack": (4960, 0, 5978, 1960),
           "sous fetch": (0, 2200, 1935, 3060), "entier / dcache": (1935, 2960, 4578, 3060),
           "arith / dcache": (2000, 2310, 3150, 3060)}),
 # Plan aligne_dc (7 novembre, P77) : plan aligne, ino_data_cache decale de +368 um vers
 # l'est : son bord est (broches EXEC et STACK) au pied du canal entier | system, par
 # ou descendent les ports EXEC d'exec_entier et d'ino_system et le port STACK.
 "aligne_dc": dict(
   R={"ino_fetch": (0, 0), "ino_decode_predict": (2000, 0), "ino_decode_queue": (2960, 0),
      "stack_unit_16_8": (3460, 0), "ino_exec_arith": (2000, 1160), "ino_exec_entier": (3678, 1960),
      "ino_system": (4878, 1960), "ino_data_cache": (2303, 3060)},
   SOC=(870, 3410), PERIPH=(5440, 3590),
   CANAUX={"fetch | predict": (1900, 0, 2000, 2200), "predict | dq": (2900, 0, 2960, 1100),
           "dq | stack": (3360, 0, 3460, 1100), "predict / arith": (2000, 1100, 2900, 1160),
           "stack / entier+system": (3460, 1500, 5978, 1960), "arith | entier": (3150, 1160, 3678, 2960),
           "entier | system": (4578, 1960, 4878, 3800), "est de stack": (4960, 0, 5978, 1960),
           "sous fetch": (0, 2200, 2303, 3060), "entier / dcache": (2303, 2960, 4578, 3060),
           "arith / dcache": (2000, 2310, 3150, 3060)}),
 # Plan elargi (6 novembre, P74) : canal stack / entier+system de 60 a 360 um ;
 # fetch | predict, dq | stack et entier / dcache a 100 um, entier | system a 190 um.
 "elargi": dict(
   R={"ino_fetch": (0, 0), "ino_decode_predict": (2000, 0), "ino_decode_queue": (2960, 0),
      "stack_unit_16_8": (3460, 0), "ino_exec_arith": (2000, 1160), "ino_exec_entier": (3350, 1860),
      "ino_system": (4440, 1860), "ino_data_cache": (1935, 2960)},
   SOC=(870, 3310), PERIPH=(5000, 3490),
   CANAUX={"fetch | predict": (1900, 0, 2000, 2200), "predict | dq": (2900, 0, 2960, 1100),
           "dq | stack": (3360, 0, 3460, 1100), "predict / arith": (2000, 1100, 2900, 1160),
           "stack / entier+system": (3350, 1500, 4960, 1860), "arith | entier": (3150, 1160, 3350, 2860),
           "entier | system": (4250, 1860, 4440, 2860), "est de stack": (4960, 0, 5540, 1860),
           "sous fetch": (0, 2200, 1935, 2960), "entier / dcache": (1935, 2860, 4250, 2960),
           "arith / dcache": (2000, 2310, 3150, 2960)}),
}
R, SOC, PERIPH = PLANS["retenu"]["R"], PLANS["retenu"]["SOC"], PLANS["retenu"]["PERIPH"]

# Liaisons critiques (plan_puce.py) : nom, macro source, prefixe du champ, macro destination.
CRIT = [("chainage stack -> entier", "stack_unit_16_8", "issue_o", "ino_exec_entier"),
        ("chainage entier -> stack", "ino_exec_entier", "complete_o", "stack_unit_16_8"),
        ("FAST_PIPE entier -> dcache", "ino_exec_entier", "mem_req_o", "ino_data_cache"),
        ("FAST_PIPE dcache -> entier", "ino_data_cache", "exec_rsp_o", "ino_exec_entier"),
        ("arith -> entier", "ino_exec_arith", "complete_result_o", "ino_exec_entier"),
        ("fetch -> predict", "ino_fetch", "window_o", "ino_decode_predict"),
        ("predict -> dq", "ino_decode_predict", "out_block_o", "ino_decode_queue"),
        ("dq -> stack", "ino_decode_queue", "pop_slot_o", "stack_unit_16_8")]


def lire_lef(chemin):
    """-> (largeur, hauteur, {broche: (x, y)}) ; y vers le haut, origine en bas a gauche."""
    w = h = None
    pins, cur, rects = {}, None, []
    for ligne in open(chemin):
        t = ligne.split()
        if not t:
            continue
        if t[0] == "SIZE" and w is None and len(t) >= 4 and t[2] == "BY":
            w, h = float(t[1]), float(t[3].rstrip(";"))
        elif t[0] == "PIN":
            cur, rects = t[1], []
        elif t[0] == "RECT" and cur:
            x1, y1, x2, y2 = map(float, t[1:5])
            rects.append(((x1 + x2) / 2, (y1 + y2) / 2))
        elif t[0] == "END" and cur and len(t) > 1 and t[1] == cur:
            if rects:
                pins[cur] = (sum(r[0] for r in rects) / len(rects), sum(r[1] for r in rects) / len(rects))
            cur = None
    return w, h, pins


def cle_bit(n):
    """ordre naturel : champ.sous[3] avant champ.sous[10]."""
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", n)]


def main():
    global R, SOC, PERIPH
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", default=None, choices=sorted(PLANS))
    ap.add_argument("--pas", type=float, default=20.0)
    ap.add_argument("--iter", type=int, default=6)
    ap.add_argument("--util", type=float, default=0.7)
    ap.add_argument("--marge", type=float, default=200.0, help="marge autour des macros (um)")
    ap.add_argument("--png", default=os.path.join(ICI, "canaux.png"))
    a = ap.parse_args()
    if a.plan:
        R, SOC, PERIPH = PLANS[a.plan]["R"], PLANS[a.plan]["SOC"], PLANS[a.plan]["PERIPH"]

    boites, broches = {}, {}
    for m, (x0, y0) in R.items():
        d = DOSSIER.get(m, m)
        w, h, pins = lire_lef(os.path.join(MACROS, d, "vues", f"{d}.lef"))
        boites[m] = (x0, y0, w, h)
        broches[m] = {n: (x0 + px, y0 + (h - py)) for n, (px, py) in pins.items()}   # y vers le bas

    X0 = -a.marge; Y0 = -a.marge
    X1 = max(x + w for x, y, w, h in boites.values()) + a.marge
    Y1 = max(y + h for x, y, w, h in boites.values()) + a.marge
    P = a.pas
    NX, NY = int(math.ceil((X1 - X0) / P)), int(math.ceil((Y1 - Y0) / P))

    def case(x, y):
        return min(NX - 1, max(0, int((x - X0) // P))), min(NY - 1, max(0, int((y - Y0) // P)))

    bloque = [[False] * NY for _ in range(NX)]
    for m, (x, y, w, h) in boites.items():
        for i in range(NX):
            cx = X0 + (i + 0.5) * P
            if not (x < cx < x + w):
                continue
            for j in range(NY):
                cy = Y0 + (j + 0.5) * P
                if y < cy < y + h:
                    bloque[i][j] = True

    # Capacite par case (pistes) : H = Metal3 + moitie de TopMetal1 ; V = Metal2 + Metal4.
    capH = P * (1 / 0.48 + 0.5 / 3.28) * a.util
    capV = P * (2 / 0.48) * a.util

    def sortie(m, n):
        """case libre devant une broche (la broche est sur le bord de la macro)."""
        x, y = broches[m][n]
        bx, by, bw, bh = boites[m]
        d = min((abs(x - bx), "W"), (abs(x - bx - bw), "E"), (abs(y - by), "N"), (abs(y - by - bh), "S"))[1]
        dx, dy = {"W": (-P / 2, 0), "E": (P / 2, 0), "N": (0, -P / 2), "S": (0, P / 2)}[d]
        return case(x + dx, y + dy)

    def champ_broches(m, f):
        ns = [n for n in broches[m] if n == f or re.match(re.escape(f) + r"(\[\d+\]|\..*)$", n)]
        return sorted(ns, key=cle_bit)

    liens = json.load(open(os.path.join(ICI, "liens.json")))
    faisceaux = defaultdict(int)          # (case src, case dst) -> bits
    critiques = defaultdict(set)          # nom critique -> faisceaux
    manquants = []
    for s, sf, d, df, nb in liens:
        if s == d:
            continue
        def bouts(m, f, nbits):
            if m == "chip":
                p = SOC if re.match(r"(I_|D_|dc_d_addr|u_instruction\.i_)", f) else PERIPH
                return [case(*p)] * nbits
            ns = champ_broches(m, f)
            return [sortie(m, n) for n in ns]
        A, B = bouts(s, sf, nb), bouts(d, df, nb)
        if not A or not B:
            manquants.append((s, sf, d, df, nb))
            continue
        for k in range(nb):
            ca = A[min(len(A) - 1, k * len(A) // nb)]
            cb = B[min(len(B) - 1, k * len(B) // nb)]
            faisceaux[(ca, cb)] += 1
            for nom, ms, fs, md in CRIT:
                if s == ms and sf.startswith(fs) and d == md:
                    critiques[nom].add((ca, cb))

    # Routage negocie : cout d'un pas = 1 + penalite de surcharge (historique + presente).
    useH = [[0.0] * NY for _ in range(NX)]
    useV = [[0.0] * NY for _ in range(NX)]
    histH = [[0.0] * NY for _ in range(NX)]
    histV = [[0.0] * NY for _ in range(NX)]
    routes = {}

    def cout(i, j, horiz, nbits, fac):
        if bloque[i][j]:
            return None
        u, c, hst = (useH, capH, histH) if horiz else (useV, capV, histV)
        over = max(0.0, (u[i][j] + nbits) / c - 1.0)
        return 1.0 + hst[i][j] + fac * over * 4.0

    def dijkstra(src, cibles, nbits, fac):
        dist = {src: 0.0}; prev = {}
        pq = [(0.0, src)]; reste = set(cibles)
        while pq and reste:
            dd, (i, j) = heapq.heappop(pq)
            if dd > dist.get((i, j), 1e30):
                continue
            reste.discard((i, j))
            for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ni, nj = i + di, j + dj
                if not (0 <= ni < NX and 0 <= nj < NY):
                    continue
                if bloque[ni][nj] and (ni, nj) not in cibles:
                    continue
                c = cout(ni, nj, di != 0, nbits, fac) if not bloque[ni][nj] else 1.0
                nd = dd + c
                if nd < dist.get((ni, nj), 1e30):
                    dist[(ni, nj)] = nd; prev[(ni, nj)] = (i, j)
                    heapq.heappush(pq, (nd, (ni, nj)))
        return prev

    def chemin(prev, src, dst):
        pts = [dst]
        while pts[-1] != src:
            if pts[-1] not in prev:
                return None
            pts.append(prev[pts[-1]])
        return pts[::-1]

    def poser(pts, nbits, signe):
        for (i, j), (k, l) in zip(pts, pts[1:]):
            if k != i:                         # pas horizontal : piste H dans les deux cases
                useH[i][j] += signe * nbits / 2; useH[k][l] += signe * nbits / 2
            else:
                useV[i][j] += signe * nbits / 2; useV[k][l] += signe * nbits / 2

    par_src = defaultdict(list)
    for (ca, cb), nb in faisceaux.items():
        par_src[ca].append((cb, nb))
    ordre = sorted(par_src, key=lambda c: -sum(nb for _, nb in par_src[c]))
    for it in range(a.iter):
        fac = 0.0 if it == 0 else 1.0 + it
        for src in ordre:
            for cb, nb in par_src[src]:
                if (src, cb) in routes:
                    poser(routes[(src, cb)], nb, -1)
            prev = dijkstra(src, {cb for cb, _ in par_src[src]}, max(nb for _, nb in par_src[src]), fac)
            for cb, nb in par_src[src]:
                pts = chemin(prev, src, cb) if cb != src else [src]
                if pts is None:
                    continue
                routes[(src, cb)] = pts
                poser(pts, nb, +1)
        over_tot = 0.0
        for i in range(NX):
            for j in range(NY):
                for u, c, hst in ((useH, capH, histH), (useV, capV, histV)):
                    o = max(0.0, u[i][j] / c - 1.0)
                    if o > 0:
                        hst[i][j] += 0.5 * o
                        over_tot += u[i][j] - c
        pire = max(max(useH[i][j] / capH, useV[i][j] / capV) for i in range(NX) for j in range(NY))
        print(f"passe {it}: depassement total {over_tot:,.0f} pistes, pire case {pire:.2f} x capacite")

    # Charge par canal nomme : rectangles libres entre macros (y vers le bas).
    CANAUX = PLANS[a.plan or "retenu"]["CANAUX"] if (a.plan or R is PLANS["retenu"]["R"]) else {}
    print(f"\ngrille {NX} x {NY} cases de {P:.0f} um ; capacite par case : H {capH:.0f}, V {capV:.0f} pistes "
          f"(utilisation {a.util:.0%})")
    print(f"{len(faisceaux)} faisceaux, {sum(faisceaux.values())} bits ; champs sans broche : {len(manquants)}")
    for m in manquants[:10]:
        print("   sans broche :", m)
    print("\ncanal                              pire H     pire V   (x capacite, sur une coupe du canal)")
    for nom, (x0, y0, x1, y1) in CANAUX.items():
        i0, j0 = case(x0 + 1, y0 + 1); i1, j1 = case(x1 - 1, y1 - 1)
        cases = [(i, j) for i in range(i0, i1 + 1) for j in range(j0, j1 + 1) if not bloque[i][j]]
        if not cases:
            print(f"{nom:34s}  (aucune case libre : canal plus etroit que la grille)")
            continue
        # coupe : un canal vertical (haut) est traverse par des fils verticaux, on somme
        # sur sa largeur la charge V d'une rangee ; un canal horizontal, la charge H d'une colonne.
        vertical = (y1 - y0) > (x1 - x0)
        if vertical:
            rangs = defaultdict(float); capr = defaultdict(float)
            for i, j in cases:
                rangs[j] += useV[i][j]; capr[j] += capV
            ph = max((sum(useH[i][j] for i, jj in cases if jj == j) / (capH * sum(1 for i, jj in cases if jj == j))
                      for j in rangs), default=0)
            pv = max(rangs[j] / capr[j] for j in rangs)
        else:
            cols = defaultdict(float); capc = defaultdict(float)
            for i, j in cases:
                cols[i] += useH[i][j]; capc[i] += capH
            pv = max((sum(useV[ii][j] for ii, j in cases if ii == i) / (capV * sum(1 for ii, j in cases if ii == i))
                      for i in cols), default=0)
            ph = max(cols[i] / capc[i] for i in cols)
        print(f"{nom:34s}  {ph:6.2f}     {pv:6.2f}")

    def pres_point(i, j):          # blocs SoC et peripheriques reduits a un point : ignores
        cx, cy = X0 + (i + .5) * P, Y0 + (j + .5) * P
        return any(abs(cx - px) + abs(cy - py) < 150 for px, py in (SOC, PERIPH))
    print("\nliaisons critiques : longueur routee (mm), pire bit / moyenne ; Manhattan broche a broche")
    for nom, _, _, _ in CRIT:
        ls = [(len(routes[f]) - 1) * P / 1000 for f in critiques[nom] if f in routes]
        mh = [(abs(f[0][0] - f[1][0]) + abs(f[0][1] - f[1][1])) * P / 1000 for f in critiques[nom]]
        if ls:
            print(f"   {nom:28s} {max(ls):5.2f} / {sum(ls) / len(ls):4.2f}   Manhattan {max(mh):4.2f}")
    lst = sorted(((max(useH[i][j] / capH, useV[i][j] / capV), i, j) for i in range(NX) for j in range(NY)
                  if not bloque[i][j] and not pres_point(i, j)), reverse=True)[:15]
    print("\ncases les plus chargees (x, y du centre en um, y vers le bas) :")
    for r, i, j in lst:
        print(f"   ({X0 + (i + .5) * P:6.0f}, {Y0 + (j + .5) * P:6.0f})  {r:5.2f}  "
              f"H {useH[i][j]:5.0f}/{capH:.0f}  V {useV[i][j]:5.0f}/{capV:.0f}")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
        g = np.zeros((NY, NX))
        for i in range(NX):
            for j in range(NY):
                g[j, i] = np.nan if bloque[i][j] else max(useH[i][j] / capH, useV[i][j] / capV)
        fig, ax = plt.subplots(figsize=(12, 8.5))
        im = ax.imshow(g, origin="upper", extent=(X0, X0 + NX * P, Y0 + NY * P, Y0), cmap="magma_r",
                       vmin=0, vmax=max(2.0, float(np.nanmax(g))))
        for m, (x, y, w, h) in boites.items():
            ax.add_patch(plt.Rectangle((x, y), w, h, fill=True, fc="#dddddd", ec="#555555"))
            ax.text(x + w / 2, y + h / 2, m.replace("ino_", ""), ha="center", va="center", fontsize=8)
        ax.plot(*SOC, "s", color="tab:blue"); ax.plot(*PERIPH, "s", color="tab:green")
        ax.set_title(f"Charge des canaux (x capacite ; >1 = surcharge), grille {P:.0f} um")
        fig.colorbar(im, ax=ax, shrink=0.8)
        fig.tight_layout(); fig.savefig(a.png, dpi=110)
        print(f"\ncarte : {a.png}")
    except ImportError:
        pass


if __name__ == "__main__":
    main()
