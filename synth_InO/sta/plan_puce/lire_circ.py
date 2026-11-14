#!/usr/bin/env python3
"""Positions des macros d'un modele Logisim a l'echelle, comparees a un plan de canaux.py.

Usage : lire_circ.py [logisim/TAHX_TOP_logisim_echelle_v11h.circ] [--plan v11h]

Dans le modele, chaque macro est un sous-circuit du circuit TAHX_TOP dont l'apparence
est un rectangle en um (largeur x hauteur). Le coin haut-gauche du rectangle vaut
loc + (rect.x - ancre.x, rect.y - ancre.y) ; avec l'ancre en (47, 47) et le rectangle en
(50, 50), loc + (3, 3). Le modele est dessine a la grille de Logisim (10 um) : il donne
la disposition a quelques um pres, le plan (canaux.PLANS) donne les positions exactes.
Sortie : position Logisim et position du plan dans le repere du plan (haut de
decode_predict en y = 0, bord gauche de fetch en x = 0, y vers le bas), et l'ecart.
"""
import argparse, os, sys
import xml.etree.ElementTree as ET

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import canaux as C

NOMS = {"fetch": "ino_fetch", "decode_predict": "ino_decode_predict", "decode_queue": "ino_decode_queue",
        "stack_unit": "stack_unit_16_8", "data_cache": "ino_data_cache", "exec_entier": "ino_exec_entier",
        "exec_arith": "ino_exec_arith", "system": "ino_system"}


def lire(circ):
    """-> {sous-circuit: (x, y, l, h)} : coin haut-gauche et taille, um, y vers le bas."""
    racine = ET.parse(circ).getroot()
    app = {}
    for c in racine.iter("circuit"):
        a = c.find("appear")
        if a is None:
            continue
        r, anc = a.find("rect"), a.find("circ-anchor")
        if r is None or anc is None:
            continue
        app[c.get("name")] = (float(r.get("x")) - float(anc.get("x")), float(r.get("y")) - float(anc.get("y")),
                              float(r.get("width")), float(r.get("height")))
    top = next(c for c in racine.iter("circuit") if c.get("name") == "TAHX_TOP")
    res = {}
    for comp in top.iter("comp"):
        n = comp.get("name")
        if n in app and comp.get("lib") is None:
            x, y = map(float, comp.get("loc").strip("()").split(","))
            dx, dy, w, h = app[n]
            res[n] = (x + dx, y + dy, w, h)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("circ", nargs="?", default=os.path.join(C.RACINE, "logisim",
                                                             "TAHX_TOP_logisim_echelle_v11h.circ"))
    ap.add_argument("--plan", default="v11h", choices=sorted(C.PLANS))
    a = ap.parse_args()
    blocs = lire(a.circ)
    if "decode_predict" not in blocs or "fetch" not in blocs:
        sys.exit("fetch ou decode_predict absent du modele")
    ox, oy = blocs["fetch"][0], blocs["decode_predict"][1]
    plan = C.PLANS[a.plan]["R"]
    print(f"{os.path.basename(a.circ)} : repere du plan, origine Logisim ({ox:g}, {oy:g})")
    print(f"{'bloc':18s} {'Logisim x, y':>18s} {'taille':>16s}   {'plan ' + a.plan + ' x, y':>20s}   ecart")
    for n, (x, y, w, h) in sorted(blocs.items(), key=lambda kv: (kv[1][1], kv[1][0])):
        m = NOMS.get(n)
        lx, ly = x - ox, y - oy
        if m in plan:
            px, py = plan[m]
            print(f"{n:18s} {lx:8.2f}, {ly:8.2f} {w:7g} x {h:<7g}   {px:9.2f}, {py:8.2f}   "
                  f"{lx - px:+6.2f}, {ly - py:+6.2f}")
        else:
            print(f"{n:18s} {lx:8.2f}, {ly:8.2f} {w:7g} x {h:<7g}   (pas une macro)")


if __name__ == "__main__":
    main()
