#!/usr/bin/env python3
"""Fils du sommet de TAHX_1 pour la STA d'assemblage, d'apres un plan de puce.

Usage : fils.py <connexions.txt> <plan> <sortie.tcl> [--detour 1.3]
  connexions.txt : sortie de connexions.tcl (net, pilotes, charges) ;
  plan           : nom d'un plan de canaux.py (retenu, elargi, aligne_dc, v11h) ;
  --lef v1|v2    : LEF des macros (defaut : celle du plan ; v11h -> <m>_v2.lef) ;
Ecrit un Tcl pour OpenSTA :
  - set_load <C fil> sur chaque net (capacite du fil, vue par le pilote) ;
  - set_annotated_delay -net du pilote a chaque charge (Elmore d'une etoile :
    R du segment x (C du segment / 2 + C de la broche de charge)) ;
Positions : broches des macros d'apres leur LEF et le plan ; cellules de liaison au
barycentre de leurs voisins (iterations) ; ports I_* / D_* au bloc SoC, les autres au
bloc des peripheriques ; horloge ignoree (ideale au sommet).
Fil : Manhattan x detour ; 1,55 ohm/um (Metal3 1,54 ; Metal2 2,54 et Metal4 0,63 en
vertical), 0,20 fF/um (LAYERS_RC des macros, 0,18 fF/um, plus le couplage d'un bus),
sans repeteurs (borne pessimiste pour les fils de plus de ~1,5 mm).
"""
import argparse, math, os, re, sys
from collections import defaultdict

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.environ.get("PLAN_PUCE", ICI))
import canaux as C

R_UM, C_UM, C_BROCHE = 1.55e-3, 0.20e-3, 0.005     # kohm/um, pF/um, pF (broche de charge type)
# Repeteurs (comme repair_design) : un tampon tous les LSEG um au-dela ; retard d'un
# tampon chargeant un segment, par coin (estimation buf_4, sg13cmos5l).
LSEG = 500.0
D_BUF = {"slow": 0.16, "typ": 0.09, "fast": 0.06}
# Charge maximale laissee a un pilote : au-dela, repair_design insere un tampon fort
# derriere lui (le pilote ne voit plus que ce tampon ; un retard de tampon par charge).
CMAX = 0.06

INST = {"u_instruction.u_fetch": "ino_fetch", "u_instruction.u_decode_predict": "ino_decode_predict",
        "u_decode_queue": "ino_decode_queue", "u_core.u_stack": "stack_unit_16_8",
        "u_core.u_backend.u_entier": "ino_exec_entier", "u_core.u_backend.u_arith": "ino_exec_arith",
        "u_core.u_system": "ino_system", "u_data_cache": "ino_data_cache"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("connexions"); ap.add_argument("plan"); ap.add_argument("sortie")
    ap.add_argument("--detour", type=float, default=1.3)
    ap.add_argument("--coin", default="slow", choices=sorted(D_BUF))
    ap.add_argument("--registre-d", action="store_true",
                    help="etage de registres sur D_* dans la matrice, au bord ouest du cache : "
                         "les ports D_* sont pris a ce bord (fils courts)")
    ap.add_argument("--lef", default=None, help="v1, v2 ; defaut : celle du plan")
    a = ap.parse_args()
    plan = C.PLANS[a.plan]
    vlef = C.version_lef(a.plan, a.lef)
    broches = {}
    for m, (x0, y0) in plan["R"].items():
        w, h, pins = C.lire_lef(C.lef_macro(m, vlef))
        broches[m] = {n: (x0 + px, y0 + (h - py)) for n, (px, py) in pins.items()}

    nets = []
    for ligne in open(a.connexions):
        t = ligne.rstrip("\n").split("\t")
        if len(t) < 3:
            continue
        nets.append((t[0], t[1].split(), t[2].split()))

    def separe(p):                      # "inst/broche" -> (inst, broche) ; OpenSTA echappe les '.'
        if p.startswith("PORT:"):
            return None, p[5:]
        i = p.rfind("/")
        return p[:i].replace("\\", ""), p[i + 1:].replace("\\", "")

    fixes, sans = {}, set()
    def pos_fixe(p):
        inst, b = separe(p)
        if inst is None:
            if re.match(r"(CLK_i|RESET_i)$", b):
                return None
            if a.registre_d and b.startswith("D_"):
                x0, y0 = plan["R"]["ino_data_cache"]
                return (x0 - 20, y0 + 1061.84 - 529)  # milieu des broches d_* (bord ouest)
            return plan["SOC"] if re.match(r"(I_|D_)", b) else plan["PERIPH"]
        m = INST.get(inst)
        if m is None:
            return "mobile"
        q = broches[m].get(b)
        if q is None:
            sans.add((m, b))
            x0, y0 = plan["R"][m]
            return (x0, y0)
        return q
    mobiles = defaultdict(list)          # cellule de liaison -> nets
    for n, d, l in nets:
        for p in d + l:
            q = pos_fixe(p)
            if q == "mobile":
                mobiles[separe(p)[0]].append(n)
            elif q is not None:
                fixes[p] = q
    cx = sum(x for x, y in plan["R"].values()) / len(plan["R"])
    cy = sum(y for x, y in plan["R"].values()) / len(plan["R"])
    pos = {c: (cx, cy) for c in mobiles}
    par_net = {n: d + l for n, d, l in nets}
    for _ in range(40):                  # barycentre des voisins, macros et ports fixes
        nouv = {}
        for c, ns in mobiles.items():
            sx = sy = k = 0
            for n in ns:
                for p in par_net[n]:
                    inst = separe(p)[0]
                    q = fixes.get(p) if p in fixes else (pos.get(inst) if inst in pos and inst != c else None)
                    if q is not None:
                        sx += q[0]; sy += q[1]; k += 1
            nouv[c] = (sx / k, sy / k) if k else pos[c]
        pos = nouv

    def ou(p):
        if p in fixes:
            return fixes[p]
        inst = separe(p)[0]
        return pos.get(inst)

    out = open(a.sortie, "w")
    out.write(f"# fils du sommet, plan {a.plan}, LEF {vlef or 'v1'}, detour {a.detour}\n")
    longs = []
    for n, d, l in nets:
        if not d or not l:
            continue
        p0 = ou(d[0])
        if p0 is None:
            continue
        ctot = 0.0; arcs = []
        for p in l:
            q = ou(p)
            if q is None:
                continue
            L = (abs(p0[0] - q[0]) + abs(p0[1] - q[1])) * a.detour
            if L <= LSEG:
                cseg = L * C_UM
                ctot += cseg
                arcs.append((p, L, R_UM * L * (cseg / 2 + C_BROCHE)))
            else:
                # n repeteurs : le pilote ne voit que le premier segment ; retard
                # = (n + 1) segments (Elmore) + n tampons.
                nrep = int(math.ceil(L / LSEG)) - 1
                ls = L / (nrep + 1)
                ctot += ls * C_UM
                seg = R_UM * ls * (ls * C_UM / 2 + C_BROCHE)
                arcs.append((p, ls, (nrep + 1) * seg + nrep * D_BUF[a.coin]))
            longs.append((L, n))
        if ctot <= 0 or not arcs:
            continue
        # Modele en pi du net (comme estimate_parasitics d'OpenROAD) : moitie de la
        # capacite du fil de chaque cote d'une resistance effective (moyenne des
        # segments ponderee par leur capacite), puis un Elmore par charge.
        tampon = ctot > CMAX
        if tampon:
            arcs = [(p, L, dly + D_BUF[a.coin]) for p, L, dly in arcs]
            ctot = CMAX
        reff = sum(R_UM * L * L * C_UM for _, L, _ in arcs) / max(ctot, 1e-6)   # L : premier segment
        if tampon:
            reff = 0.0
        src = d[0][5:] if d[0].startswith("PORT:") else d[0]
        out.write(f"sta::set_pi_model {{{src}}} {ctot / 2:.6f} {max(reff, 1e-4):.6f} {ctot / 2:.6f}\n")
        for p, L, dly in arcs:
            if dly > 0.0005:
                dst = p[5:] if p.startswith("PORT:") else p
                out.write(f"sta::set_elmore {{{src}}} {{{dst}}} {dly:.5f}\n")
    out.close()
    longs.sort(reverse=True)
    print(f"{len(nets)} nets ; {len(mobiles)} cellules de liaison placees ; broches absentes des LEF : {len(sans)}")
    for m, b in sorted(sans)[:8]:
        print("   absente :", m, b)
    print("fils les plus longs (mm, avec detour) : " +
          ", ".join(f"{L / 1000:.2f} {n}" for L, n in longs[:6]))


if __name__ == "__main__":
    main()
