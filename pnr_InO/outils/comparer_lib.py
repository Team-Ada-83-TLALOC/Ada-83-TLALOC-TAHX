#!/usr/bin/env python3
"""Comparer les arcs de deux .lib d'une meme macro (deux runs LibreLane).

  comparer_lib.py A.lib B.lib [--charge 0.05] [--n 25] [--arc DE>VERS ...]
                              [--motif REGEX] [--tous]

Arcs relus :
  combinatoires   entree -> sortie (cell_rise / cell_fall)
  horloge->sortie clk_i -> sortie (rising_edge)
  setup           contrainte d'une entree (setup_rising, rise/fall_constraint)
Les bits d'un bus sont regroupes (nom sans [n]) : on garde le pire bit.
Retards : tables 1D en fonction de la charge, interpolees a --charge (pF) ;
contraintes : pire valeur de la table. Resultat en ns, B - A.

Sorties : les arcs presents dans un seul fichier, les --n plus fortes hausses
et baisses, et les arcs demandes par --arc (motifs DE>VERS, sous-chaines des
noms groupes, ex. 'limits_i>mem_req_o.valid'). Sans --arc, une liste par
defaut : les traversees d'exec_entier qui fixaient la periode de l'assemblage
v11h (17 novembre 2026).
Python seul.
"""
import argparse
import re
import sys
from collections import defaultdict

ARCS_DEFAUT = [
    "limits_i.lim_csp>mem_req_o.valid",
    "mem_ready_i>issue_ready_o",
    "mem_rsp_i.rdata>complete_o.result",
    "issue_i.operand>mem_req_o.address",
    "issue_i.operand>complete_o.result",
    "reset_i>complete_o.result",
]


def groupe(nom):
    return re.sub(r"\[\d+\]", "", nom)


def interp(index, valeurs, x):
    if len(index) != len(valeurs) or not index:
        return max(valeurs)
    if x <= index[0]:
        i = 0
    elif x >= index[-1]:
        i = len(index) - 2
    else:
        i = max(k for k in range(len(index) - 1) if index[k] <= x)
    if len(index) == 1:
        return valeurs[0]
    x0, x1, y0, y1 = index[i], index[i + 1], valeurs[i], valeurs[i + 1]
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0)


def nombres(texte):
    return [float(v) for v in re.findall(r"-?\d+(?:\.\d*)?(?:[eE][-+]?\d+)?", texte)]


def lire(chemin, charge):
    """{(type, de, vers): valeur max sur les bits}"""
    arcs = defaultdict(lambda: float("-inf"))
    pin = None
    timing = None
    table = None
    tampon = ""
    with open(chemin, encoding="utf-8", errors="replace") as f:
        for ligne in f:
            s = ligne.strip()
            m = re.match(r'pin\s*\(\s*"?([^")]+?)"?\s*\)\s*\{', s)
            if m and timing is None:
                pin = m.group(1)
                continue
            if s.startswith("timing()") or s.startswith("timing ()"):
                timing = {"related": None, "type": "combinational", "val": []}
                continue
            if timing is None:
                continue
            m = re.match(r'related_pin\s*:\s*"?([^";]+)"?\s*;', s)
            if m:
                timing["related"] = m.group(1)
                continue
            m = re.match(r"timing_type\s*:\s*\"?(\w+)\"?\s*;", s)
            if m:
                timing["type"] = m.group(1)
                continue
            m = re.match(r"(cell_rise|cell_fall|rise_constraint|fall_constraint)\s*\(", s)
            if m:
                table = {"index": [], "values": [], "kind": m.group(1)}
                continue
            if table is not None:
                if s.startswith("index_1"):
                    table["index"] = nombres(s.split("(", 1)[1])
                    continue
                if s.startswith("index_2"):
                    table["index2"] = True
                    continue
                if s.startswith("values") or tampon:
                    tampon += s
                    if ");" in s:
                        table["values"] = nombres(tampon.split("(", 1)[1])
                        tampon = ""
                    continue
                if s.startswith("}"):
                    v = table["values"]
                    if v:
                        if table["kind"].startswith("cell") and not table.get("index2"):
                            timing["val"].append(interp(table["index"], v, charge))
                        else:
                            timing["val"].append(max(v))
                    table = None
                    continue
            if s.startswith("}") and table is None:
                t = timing
                timing = None
                if not t["val"] or t["related"] is None or pin is None:
                    continue
                typ = t["type"]
                if typ == "combinational":
                    cle = ("comb", groupe(t["related"]), groupe(pin))
                elif typ in ("rising_edge", "falling_edge"):
                    cle = ("clk", groupe(t["related"]), groupe(pin))
                elif typ.startswith("setup"):
                    cle = ("setup", groupe(t["related"]), groupe(pin))
                elif typ.startswith("hold"):
                    cle = ("hold", groupe(t["related"]), groupe(pin))
                else:
                    continue
                arcs[cle] = max(arcs[cle], max(t["val"]))
    return dict(arcs)


def nom_arc(c):
    typ, de, vers = c
    return f"{typ:5s} {de} > {vers}"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--charge", type=float, default=0.05, help="pF (defaut 0,05)")
    ap.add_argument("--n", type=int, default=25)
    ap.add_argument("--arc", action="append", help="DE>VERS (sous-chaines)")
    ap.add_argument("--motif", help="ne garder que les arcs dont le nom contient REGEX")
    ap.add_argument("--tous", action="store_true", help="lister tous les arcs communs")
    a = ap.parse_args()

    A, B = lire(a.a, a.charge), lire(a.b, a.charge)
    if not A or not B:
        sys.exit(f"aucun arc lu ({len(A)} / {len(B)})")
    filtre = re.compile(a.motif) if a.motif else None
    garder = lambda c: not filtre or filtre.search(nom_arc(c))
    communs = sorted(c for c in A.keys() & B.keys() if garder(c))
    print(f"# A = {a.a}\n# B = {a.b}\n# charge {a.charge} pF ; {len(A)} / {len(B)} arcs "
          f"groupes, {len(communs)} communs ; delta = B - A (ns)")
    seulA = sorted(c for c in A.keys() - B.keys() if garder(c))
    seulB = sorted(c for c in B.keys() - A.keys() if garder(c))
    for titre, l, d in (("seulement dans A", seulA, A), ("seulement dans B", seulB, B)):
        if l:
            print(f"\n## {titre} ({len(l)})")
            for c in l[: a.n]:
                print(f"  {d[c]:8.3f}  {nom_arc(c)}")
            if len(l) > a.n:
                print(f"  ... {len(l) - a.n} de plus")

    deltas = [(B[c] - A[c], c) for c in communs if c[0] in ("comb", "clk", "setup")]
    deltas.sort()
    print(f"\n## plus fortes hausses (retard ou setup plus grand dans B)")
    for d, c in reversed(deltas[-a.n:]):
        print(f"  {d:+8.3f}  {A[c]:8.3f} -> {B[c]:8.3f}  {nom_arc(c)}")
    print(f"\n## plus fortes baisses")
    for d, c in deltas[: a.n]:
        print(f"  {d:+8.3f}  {A[c]:8.3f} -> {B[c]:8.3f}  {nom_arc(c)}")

    demandes = a.arc or ARCS_DEFAUT
    print(f"\n## arcs suivis")
    for dem in demandes:
        de, _, vers = dem.partition(">")
        trouves = [c for c in A.keys() | B.keys()
                   if de in c[1] and vers in c[2] and c[0] in ("comb", "clk")]
        if not trouves:
            print(f"  {'':8s}  {'-':>8s}    {'-':>8s}  {dem} : aucun arc")
        for c in sorted(trouves):
            va, vb = A.get(c), B.get(c)
            sa = f"{va:8.3f}" if va is not None else f"{'absent':>8s}"
            sb = f"{vb:8.3f}" if vb is not None else f"{'absent':>8s}"
            sd = f"{vb - va:+8.3f}" if va is not None and vb is not None else f"{'':8s}"
            print(f"  {sd}  {sa} -> {sb}  {nom_arc(c)}")

    if a.tous:
        print(f"\n## tous les arcs communs")
        for c in communs:
            print(f"  {B[c] - A[c]:+8.3f}  {A[c]:8.3f} -> {B[c]:8.3f}  {nom_arc(c)}")


if __name__ == "__main__":
    main()
