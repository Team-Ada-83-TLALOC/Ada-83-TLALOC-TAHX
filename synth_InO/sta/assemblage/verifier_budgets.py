#!/usr/bin/env python3
"""Coherence des SDC rebudgetes avec le releve : chaque segment interne d'une macro
relancee doit recevoir au moins g_M * d - biais (d : duree du segment dans le releve).

Usage : verifier_budgets.py <chemins.txt> <dossier des SDC> [--periode-releve 25]
Budget lu dans le SDC (valeur du bus, remplacee par celle du bit s'il en a une) :
  horloge -> sortie v : periode - incertitude - output_delay(v) - L (insertion interne) ;
  entree u -> bascule  : periode - incertitude - input_delay(u) + L ;
  entree u -> sortie v : max_delay(bus u, bus v) - input_delay(u) - output_delay(v).
Affiche, par macro et par sorte de segment, le pire rapport budget / (g d) et les
segments sous g d - biais.
"""
import argparse, os, re, sys
from collections import defaultdict

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import rebudgeter as R


def lire_sdc(f):
    per = unc = None
    g = None
    vin, vout, md = {}, {}, {}
    for l in open(f):
        m = re.search(r"g = ([\d.]+) pour cette macro", l)
        if m:
            g = float(m.group(1))
        m = re.match(r"create_clock .*-period (\S+)", l)
        if m:
            per = float(m.group(1))
        m = re.match(r"set_clock_uncertainty -setup (\S+)", l)
        if m:
            unc = float(m.group(1))
        m = re.match(r"set_(input|output)_delay\s+(?:-max\s+)?(-?[\d.]+) -clock clk \[get_ports \{(.+?)\}\]", l)
        if m and "-min" not in l:
            (vin if m.group(1) == "input" else vout)[m.group(3)] = float(m.group(2))
        m = re.match(r"set_max_delay\s+(-?[\d.]+) -from \[get_ports \{(.+?)\}\] -to \[get_ports \{(.+?)\}\]", l)
        if m:
            k = (m.group(2), m.group(3))
            md[k] = min(md.get(k, 1e30), float(m.group(1)))
    return per, unc, g, vin, vout, md


def bus(p):
    return re.sub(r"\[\d+\]$", "[*]", p)


def val(d, port):
    return d.get(port, d.get(bus(port)))


def mdp(md, pu, pv):
    """set_max_delay effectif d'une paire de bits : le plus serre (OpenSTA, priorite egale)."""
    v = [x for x in (md.get((pu, pv)), md.get((bus(pu), bus(pv)))) if x is not None]
    return min(v) if v else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("chemins"); ap.add_argument("dossier")
    ap.add_argument("--periode-releve", type=float, default=25.0)
    ap.add_argument("--incert", type=float, default=0.5)
    ap.add_argument("--biais", type=float, default=0.3)
    a = ap.parse_args()
    chemins, broches = R.lire(a.chemins)
    direction = {p: v[0] for p, v in broches.items()}
    chs = [R.segments(c, direction, a.periode_releve, a.incert) for c in chemins]
    sdc = {}
    for f in os.listdir(a.dossier):
        if f.endswith(".sdc"):
            m = f.rsplit("_", 1)[0]
            sdc[m] = lire_sdc(os.path.join(a.dossier, f))
    releves = {(m, R.macro_de(u)[1], R.macro_de(v)[1]) for s in chs for m, d, u, v in s if m and u and v}
    pire = defaultdict(lambda: (9.0, None))
    sous = defaultdict(int)
    for s in chs:
        for m, d, u, v in s:
            if m not in sdc or d < 0.3:
                continue
            per, unc, g, vin, vout, md = sdc[m]
            pu = R.macro_de(u)[1] if u else None
            pv = R.macro_de(v)[1] if v else None
            if u is None:
                sorte, b = "horloge->sortie", per - unc - val(vout, pv) - R.LAT.get(m, 0.0)
            elif v is None:
                sorte, b = "entree->bascule", per - unc - val(vin, pu) + R.LAT.get(m, 0.0)
            else:
                k = mdp(md, pu, pv)
                if k is None:
                    continue
                sorte, b = "entree->sortie", k - val(vin, pu) - val(vout, pv)
            r = b / (g * d)
            if r < pire[(m, sorte)][0]:
                pire[(m, sorte)] = (r, f"{pu or 'clk'} -> {pv or 'bascule'} : d {d:.2f}, g d {g * d:.2f}, "
                                       f"budget {b:.2f}")
            if b < g * d - a.biais - 0.01:
                sous[(m, sorte)] += 1
    # Arcs combinatoires des .lib absents du releve (les releves sont verifies ci-dessus,
    # avec leur charge reelle) : chaque arc doit avoir au moins g d.
    for m, (per, unc, g, vin, vout, md) in sdc.items():
        for (pu, pv), d in R.arcs_lib(m).items():
            if d < 0.3 or pu in ("clk_i", "CLK_i") or (m, pu, pv) in releves:
                continue
            k = mdp(md, pu, pv)
            if k is None or val(vin, pu) is None or val(vout, pv) is None:
                continue
            b = k - val(vin, pu) - val(vout, pv)
            r = b / (g * d)
            if r < pire[(m, "arc .lib")][0]:
                pire[(m, "arc .lib")] = (r, f"{pu} -> {pv} : d {d:.2f}, g d {g * d:.2f}, budget {b:.2f}")
            if b < g * d - a.biais - 0.01:
                sous[(m, "arc .lib")] += 1
    for (m, sorte), (r, ex) in sorted(pire.items()):
        print(f"{m:18s} {sorte:16s} pire budget/(g d) {r:5.2f}  sous g d - biais : "
              f"{sous[(m, sorte)]:4d}   ({ex})")


if __name__ == "__main__":
    main()
