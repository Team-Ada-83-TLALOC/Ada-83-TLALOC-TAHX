#!/usr/bin/env python3
"""Recherche d'un plan de puce par recuit simule.

Macros a broches figees (runs valides) : position et orientation libres (N, FN, FS, S :
un miroir ne demande pas de nouveau run). Macros a broches libres (exec_entier,
exec_arith, system) : chaque champ est place au point du bord le plus proche de son
partenaire (estimation optimiste de ce qu'un nouvel ordre de broches donnerait).
Blocs SoC (matrice xSPI) et peripheriques : rectangles souples.
Cout : bits x mm de toutes les liaisons, liaisons critiques ponderees, surface,
largeur maximale.
"""
import json, math, os, random, re, sys
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plan_puce as P
from plans import B, ORIG, P67

liens = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "liens.json")))
FIXES = {"ino_fetch": P67["ino_fetch"], "ino_decode_predict": P67["ino_decode_predict"],
         "ino_decode_queue": ORIG["ino_decode_queue"], "stack_unit_16_8": ORIG["stack_unit_16_8"],
         "ino_data_cache": ORIG["ino_data_cache"]}
LIBRES = ["ino_exec_entier", "ino_exec_arith", "ino_system"]
BLOCS = {"SOC": (1700, 1300), "PERIPH": (1100, 1000)}
DIM = dict(B); DIM.update(BLOCS)
CRIT = [("stack_unit_16_8", "issue_o", "ino_exec_entier"), ("ino_exec_entier", "complete_o", "stack_unit_16_8"),
        ("ino_exec_entier", "mem_req_o", "ino_data_cache"), ("ino_data_cache", "exec_rsp_o", "ino_exec_entier"),
        ("ino_data_cache", "exec_ready_o", "ino_exec_entier"),
        ("ino_exec_arith", "complete", "ino_exec_entier"), ("ino_exec_arith", "ready_o", "ino_exec_entier"),
        ("ino_fetch", "window", "ino_decode_predict"), ("ino_decode_predict", "out_", "ino_decode_queue"),
        ("ino_decode_queue", "pop_slot_o", "stack_unit_16_8")]
def critique(s, sf, d):
    return any(s == a and sf.startswith(b) and d == c for a, b, c in CRIT)

# positions locales des champs des macros figees (orientation N)
LOC = {}
for m, c in FIXES.items():
    w, h = B[m]
    pp = P.pin_positions(m, c, w, h)
    acc = defaultdict(lambda: [0, 0, 0])
    for n, (x, y) in pp.items():
        a = acc[P.champ(n)]; a[0] += x; a[1] += y; a[2] += 1
    LOC[m] = {k: (v[0] / v[2], v[1] / v[2]) for k, v in acc.items()}

def chip_bloc(f):
    return "SOC" if re.match(r"(I_|D_|dc_d_addr)", f) else "PERIPH"

L = []
for s, sf, d, df, n in liens:
    s2 = chip_bloc(sf) if s == "chip" else s
    d2 = chip_bloc(df) if d == "chip" else d
    L.append((s2, sf, d2, df, n, critique(s, sf, d)))

def champ_local(m, f):
    loc = LOC[m]
    if f in loc:
        return loc[f]
    ks = [v for k, v in loc.items() if k.startswith(f + ".") or k == f]
    return (sum(v[0] for v in ks) / len(ks), sum(v[1] for v in ks) / len(ks)) if ks else (B[m][0] / 2, B[m][1] / 2)

def point(etat, m, f):
    x, y, o = etat[m]
    w, h = DIM[m]
    if m in FIXES:
        lx, ly = P.orient(champ_local(m, f), w, h, o)
        return (x + lx, y + (h - ly))
    return None   # libre : calcule par rapport au partenaire

def rect_proche(etat, m, q):
    x, y, o = etat[m]; w, h = DIM[m]
    px = min(max(q[0], x), x + w); py = min(max(q[1], y), y + h)
    if x < q[0] < x + w and y < q[1] < y + h:    # partenaire au-dessus : bord le plus proche
        d = [(q[0] - x, (x, q[1])), (x + w - q[0], (x + w, q[1])), (q[1] - y, (q[0], y)), (y + h - q[1], (q[0], y + h))]
        return min(d)[1]
    # sur le bord : projection, collee au bord le plus proche
    if x < px < x + w and y < py < y + h:
        pass
    return (px, py)

def centre(etat, m):
    x, y, o = etat[m]; w, h = DIM[m]
    return (x + w / 2, y + h / 2)

def cout(etat, detail=False):
    tot = 0.0; crit = defaultdict(float)
    for s, sf, d, df, n, c in L:
        a = point(etat, s, sf) if s in FIXES else None
        b = point(etat, d, df) if d in FIXES else None
        if a is None and b is None:
            a = rect_proche(etat, s, centre(etat, d)); b = rect_proche(etat, d, a)
        elif a is None:
            a = rect_proche(etat, s, b)
        elif b is None:
            b = rect_proche(etat, d, a)
        dist = (abs(a[0] - b[0]) + abs(a[1] - b[1])) / 1000
        tot += n * dist * (25 if c else 1)
        if c:
            crit[(s, d)] = max(crit[(s, d)], dist)
    # chevauchements (canal de 60 um)
    ms = list(etat); pen = 0.0
    for i in range(len(ms)):
        for j in range(i + 1, len(ms)):
            ax, ay, _ = etat[ms[i]]; bx, by, _ = etat[ms[j]]
            aw, ah = DIM[ms[i]]; bw, bh = DIM[ms[j]]
            ox = min(ax + aw + 60, bx + bw + 60) - max(ax, bx)
            oy = min(ay + ah + 60, by + bh + 60) - max(ay, by)
            if ox > 0 and oy > 0:
                pen += ox * oy
    W = max(etat[m][0] + DIM[m][0] for m in etat) - min(etat[m][0] for m in etat)
    H = max(etat[m][1] + DIM[m][1] for m in etat) - min(etat[m][1] for m in etat)
    surf = W * H / 1e6
    larg = max(0, W - 5900) + max(0, H - 5900)
    c = tot + 2000 * surf + 50 * pen / 1e4 + 50 * larg
    if detail:
        return c, tot, dict(crit), W, H, pen
    return c

def recuit(etat, n=60000, t0=3000.0, graine=1):
    rnd = random.Random(graine)
    cur = dict(etat); cc = cout(cur); best = dict(cur); bc = cc
    ms = list(cur)
    for k in range(n):
        t = t0 * (1 - k / n) + 1
        nv = dict(cur)
        r = rnd.random()
        m = rnd.choice(ms)
        x, y, o = nv[m]
        if r < 0.6:
            s = 600 * (1 - k / n) + 30
            nv[m] = (round(x + rnd.uniform(-s, s)), round(y + rnd.uniform(-s, s)), o)
        elif r < 0.85:
            m2 = rnd.choice(ms)
            x2, y2, o2 = nv[m2]
            nv[m] = (x2, y2, o); nv[m2] = (x, y, o2)
        else:
            if m in FIXES:
                nv[m] = (x, y, rnd.choice(["N", "FN", "FS", "S"]))
        nc = cout(nv)
        if nc < cc or rnd.random() < math.exp((cc - nc) / t):
            cur, cc = nv, nc
            if cc < bc:
                best, bc = dict(cur), cc
    return best, bc

def dessin(etat, ech=100):
    x0 = min(etat[m][0] for m in etat); y0 = min(etat[m][1] for m in etat)
    W = max(etat[m][0] + DIM[m][0] for m in etat) - x0
    H = max(etat[m][1] + DIM[m][1] for m in etat) - y0
    g = [[" "] * (int(W / ech) + 2) for _ in range(int(H / ech) + 2)]
    noms = {"ino_fetch": "F", "ino_decode_predict": "P", "ino_decode_queue": "Q", "stack_unit_16_8": "S",
            "ino_exec_entier": "E", "ino_exec_arith": "A", "ino_system": "Y", "ino_data_cache": "D",
            "SOC": "x", "PERIPH": "p"}
    for m, (x, y, o) in etat.items():
        w, h = DIM[m]
        for i in range(int((y - y0) / ech), int((y - y0 + h) / ech)):
            for j in range(int((x - x0) / ech), int((x - x0 + w) / ech)):
                g[i][j] = noms[m]
    return "\n".join("".join(r) for r in g)

if __name__ == "__main__":
    init = {"ino_fetch": (0, 0, "N"), "ino_decode_predict": (1960, 0, "N"), "ino_decode_queue": (2920, 0, "N"),
            "stack_unit_16_8": (3380, 0, "N"), "ino_exec_entier": (4940, 0, "N"), "ino_exec_arith": (1960, 1160, "N"),
            "ino_system": (3380, 1560, "N"), "ino_data_cache": (3380, 2620, "N"), "SOC": (0, 2260, "N"),
            "PERIPH": (4540, 1560, "N")}
    res = []
    for g in range(int(sys.argv[1]) if len(sys.argv) > 1 else 4):
        b, c = recuit(init, graine=g)
        res.append((c, b))
    res.sort(key=lambda r: r[0])
    for c, b in res[:3]:
        cc, tot, crit, W, H, pen = cout(b, True)
        print(f"cout {cc:,.0f}  liaisons {tot:,.0f}  boite {W/1000:.2f} x {H/1000:.2f} mm  chevauchement {pen:.0f}")
        print("  critiques (mm) : " + ", ".join(f"{P.COURT.get(a,a)}->{P.COURT.get(d,d)} {v:.2f}" for (a, d), v in crit.items()))
        print("  " + ", ".join(f"{P.COURT.get(m,m)}@({x},{y},{o})" for m, (x, y, o) in b.items()))
        print(dessin(b))
