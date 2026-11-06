#!/usr/bin/env python3
"""Evaluation d'un plan de puce TAHX_SOC : longueur des liaisons entre macros.

Entrees :
  - liaisons bit a bit entre macros (liens.json : [macro_src, champ_src, macro_dst,
    champ_dst, bits]), tirees de la netlist hierarchique (connexions_macros.py) ;
  - ports de chaque macro (src/<module>.v) ;
  - ordre des broches de chaque macro (pin_order_25ns.cfg, semantique de LibreLane :
    entrees reparties a pas constant sur le cote, de bas en haut a l'ouest et a
    l'est, de gauche a droite au nord et au sud ; $n = n emplacements vides) ;
  - plan : position (coin haut-gauche, y vers le bas), orientation (N, FN, FS, S).
Sortie : pour chaque liaison, distance de Manhattan entre les barycentres des
broches des deux champs ; total en bits x mm ; liaisons critiques.
"""
import json, re, sys
from collections import defaultdict

import os
ICI = os.path.dirname(os.path.abspath(__file__))
PORTS = json.load(open(os.path.join(ICI, "ports.json")))
TOP = {"ino_fetch": "ino_fetch", "ino_decode_predict": "ino_decode_predict",
       "ino_decode_queue": "ino_decode_queue", "stack_unit_16_8": "stack_unit_16_8",
       "ino_exec_entier": "ino_exec_entier", "ino_exec_arith": "ino_exec_arith",
       "ino_system": "ino_system", "ino_data_cache": "ino_data_cache"}
COURT = {"ino_fetch": "FETCH", "ino_decode_predict": "PREDICT", "ino_decode_queue": "DQ",
         "stack_unit_16_8": "STACK", "ino_exec_entier": "ENTIER", "ino_exec_arith": "ARITH",
         "ino_system": "SYSTEM", "ino_data_cache": "DCACHE"}

def ports(mod):
    return PORTS[mod]

def ports_netlist(mod, SRC):
    s = open(f"{SRC}/{mod}.v").read()
    a = s.index(f"module {mod}"); body = s[a:s.index("endmodule", a)]
    hdr = body[:body.index(");")]
    declared = set(n.strip().lstrip("\\") for n in hdr[hdr.index("(") + 1:].split(","))
    out = []
    for m in re.finditer(r"^\s*(input|output)\s+(?:wire\s+)?(?:\[(\d+):(\d+)\]\s+)?(\\?\S+)\s*;", body, re.M):
        n = m.group(4).lstrip("\\")
        if n not in declared:
            continue
        if m.group(2):
            out += [f"{n}[{i}]" for i in range(int(m.group(3)), int(m.group(2)) + 1)]
        else:
            out.append(n)
    return out

def parse_cfg(text):
    sides = {}; cur = None
    for tok in text.split():
        if tok in ("#N", "#S", "#E", "#W"):
            cur = tok[1]; sides[cur] = []
        elif tok.startswith("#") or tok.startswith("@"):
            continue
        elif tok.startswith("$"):
            sides[cur].append(int(tok[1:]))
        else:
            sides[cur].append(tok)
    return sides

def pin_positions(mod, cfg_text, w, h):
    """position locale (x, y vers le haut) de chaque broche, macro en orientation N."""
    names = ports(mod)
    sides = parse_cfg(cfg_text)
    pos = {}
    for side, entries in sides.items():
        seq = []
        for e in entries:
            if isinstance(e, int):
                seq += [None] * e
            else:
                rx = re.compile("^" + e + "$")
                hit = [n for n in names if rx.match(n) and n not in pos]
                seq += hit
                for n in hit:
                    pos[n] = None
        L = w if side in "NS" else h
        for i, n in enumerate(seq):
            if n is None:
                continue
            t = (i + 0.5) / len(seq) * L
            pos[n] = {"N": (t, h), "S": (t, 0), "W": (0, t), "E": (w, t)}[side]
    for n in names:
        if pos.get(n) is None:
            pos[n] = (w / 2, h / 2)   # non placee : au centre (signale plus bas)
    return pos

def orient(p, w, h, o):
    x, y = p
    if o in ("FN", "S"):
        x = w - x
    if o in ("FS", "S"):
        y = h - y
    return x, y

def champ(n):
    return re.sub(r"\[\d+\]$", "", n)

def evaluer(plan, cfgs, boites, points, liens, verbeux=True):
    # plan : macro -> (x, y_haut, orientation) en coordonnees y vers le bas
    H = max(y + boites[m][1] for m, (x, y, o) in plan.items())
    W = max(x + boites[m][0] for m, (x, y, o) in plan.items())
    centres = {}
    for m, (x0, y0, o) in plan.items():
        w, h = boites[m]
        pp = pin_positions(m, cfgs[m], w, h)
        acc = defaultdict(lambda: [0.0, 0.0, 0])
        for n, p in pp.items():
            lx, ly = orient(p, w, h, o)
            gx, gy = x0 + lx, y0 + (h - ly)          # y vers le bas
            c = acc[champ(n)]
            c[0] += gx; c[1] += gy; c[2] += 1
        centres[m] = {k: (v[0] / v[2], v[1] / v[2]) for k, v in acc.items()}
    # chevauchements
    noms = list(plan)
    for i in range(len(noms)):
        for j in range(i + 1, len(noms)):
            a, b = noms[i], noms[j]
            ax, ay, _ = plan[a]; bx, by, _ = plan[b]
            aw, ah = boites[a]; bw, bh = boites[b]
            if ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah:
                print(f"  !! chevauchement {COURT[a]} / {COURT[b]}")
    def lieu(m, f):
        if m == "chip":
            return points["SOC"] if re.match(r"(I_|D_|dc_d_addr)", f) else points["PERIPH"]
        if f in centres[m]:
            return centres[m][f]
        ks = [v for k, v in centres[m].items() if k.startswith(f + ".") or k == f]
        if not ks:
            return None
        return (sum(v[0] for v in ks) / len(ks), sum(v[1] for v in ks) / len(ks))
    total = 0.0; parlien = defaultdict(float); crit = {}
    CRIT = [("chainage", "stack_unit_16_8", "issue_o", "ino_exec_entier"),
            ("chainage", "ino_exec_entier", "complete_o", "stack_unit_16_8"),
            ("FAST_PIPE", "ino_exec_entier", "mem_req_o", "ino_data_cache"),
            ("FAST_PIPE", "ino_data_cache", "exec_rsp_o", "ino_exec_entier"),
            ("arith", "ino_exec_arith", "complete_result_o", "ino_exec_entier"),
            ("decodeur", "ino_fetch", "window_o", "ino_decode_predict"),
            ("decodeur", "ino_decode_predict", "out_block_o", "ino_decode_queue"),
            ("decodeur", "ino_decode_queue", "pop_slot_o", "stack_unit_16_8")]
    for s, sf, d, df, n in liens:
        a = lieu(s, sf); b = lieu(d, df)
        if a is None or b is None:
            continue
        dist = (abs(a[0] - b[0]) + abs(a[1] - b[1])) / 1000.0
        total += n * dist
        parlien[(COURT.get(s, s), COURT.get(d, d))] += n * dist
        for nom, ms, fs, md in CRIT:
            if s == ms and sf.startswith(fs) and d == md:
                crit[nom] = max(crit.get(nom, 0), dist)
    if verbeux:
        print(f"  boite des macros {W/1000:.2f} x {H/1000:.2f} mm ; total {total:,.0f} bits.mm")
        print("  critiques (pire distance, mm) : " + ", ".join(f"{k} {v:.2f}" for k, v in crit.items()))
        print("  plus lourdes : " + ", ".join(f"{a}->{b} {v:,.0f}" for (a, b), v in
                                             sorted(parlien.items(), key=lambda x: -x[1])[:6]))
    return total, crit, (W, H)
