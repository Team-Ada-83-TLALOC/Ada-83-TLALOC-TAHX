#!/usr/bin/env python3
"""Conversion des rapports report_checks (releve_chemins.tcl sans Path arrivals()) au
format de chemins.txt lu par rebudgeter.py.

Usage : texte_vers_chemins.py <rapports.rpt> <chemins.txt>
  <rapports.rpt> : sortie de report_checks -digits 6 (champs par defaut : Delay, Time,
                   Description), en ns ;
  <chemins.txt>  : ecrit par releve_chemins.tcl avec ses lignes B ; les lignes P et
                   les points sont ajoutes en tete (en secondes, comme Path arrivals()).
Pour chaque chemin : depart (sortie de la macro qui lance, ou port d'entree), puis les
broches des macros (u_*/...) et les ports, avec leur instant d'arrivee ; extremite,
requis et marge. Les chemins en double (meme extremite, memes points) sont ecartes.
"""
import re, sys

# ligne de point : nombres (champs eventuels Fanout, Cap, Slew, puis Delay, Time), sens, broche
LIGNE = re.compile(r"^\s*((?:-?\d+(?:\.\d+)?(?:e-?\d+)?\s+)+)([\^v])\s+(\S+)(?:\s+\((\S+)\))?\s*$")
HORLOGE = ("CLK_i", "clk_i")


def chemins(rpt):
    cur = None
    for l in open(rpt):
        if l.startswith("Startpoint:"):
            cur = dict(pts=[], horloge=True, fin_port="output port" in l, req=None, slack=None,
                       donnee=True)
            continue
        if cur is None:
            continue
        if l.startswith("Endpoint:"):
            cur["fin_port"] = "output port" in l
            continue
        if "data arrival time" in l:
            cur["donnee"] = False
            continue
        m = re.match(r"^\s*(-?\d+(?:\.\d+)?)\s+data required time", l)
        if m and cur["req"] is None:
            cur["req"] = float(m.group(1))
            continue
        m = re.match(r"^\s*(-?\d+(?:\.\d+)?)\s+slack", l)
        if m:
            cur["slack"] = float(m.group(1))
            yield cur
            cur = None
            continue
        if not cur["donnee"]:
            continue
        m = LIGNE.match(l)
        if m:
            cur["pts"].append((m.group(3), float(m.group(1).split()[-1])))


def garder(n):
    return "/" not in n or re.match(r"^u_[^/]*/", n) is not None


def main():
    rpt, sortie = sys.argv[1], sys.argv[2]
    bl = [l for l in open(sortie) if l.startswith("B ")]
    vus, out, n = set(), [], 0
    for c in chemins(rpt):
        pts = c["pts"]
        if not pts or c["req"] is None:
            continue
        fin = pts[-1][0]
        # arbre d'horloge (horloge propagee) : ignore jusqu'a la broche d'horloge
        while len(pts) > 1 and (pts[0][0] in HORLOGE or not garder(pts[0][0])):
            pts = pts[1:]
        # depart : premier point de la partie donnee ; si c'est l'horloge d'une macro
        # (clk_i), le point suivant (sa sortie) devient le depart, comme Path arrivals()
        i0 = 0
        if len(pts) > 1 and pts[0][0].split("/")[-1].startswith("clk") and \
                pts[0][0].split("/")[0] == pts[1][0].split("/")[0]:
            i0 = 1
        garde = [pts[i0]] + [p for p in pts[i0 + 1:] if garder(p[0])]
        if garde[-1][0] != fin:
            garde.append(pts[-1])
        cle = (fin, tuple(p[0] for p in garde))
        if cle in vus:
            continue
        vus.add(cle)
        n += 1
        out.append(f"P {c['slack'] * 1e-9:.6e} {c['req'] * 1e-9:.6e} {fin} {'port' if c['fin_port'] else 'macro'}")
        prec = None
        for nom, t in garde:
            if nom == prec:
                continue
            prec = nom
            out.append(f"{nom} {t * 1e-9:.6e}")
    open(sortie, "w").write("\n".join(out) + "\n" + "".join(bl))
    print(f"{n} chemins convertis depuis {rpt} -> {sortie} ({len(bl)} broches)")
    # controle : broches d'entree de macros au milieu des chemins (traversees). Sans
    # -fields input_pins dans report_checks, il n'y en a aucune.
    # Chemin par chemin, extremite exclue (c'est toujours une entree de macro ou un port).
    direction = {l.split()[1]: l.split()[2] for l in bl if len(l.split()) > 2}
    n_trav = n_ent = 0
    par_chemin, cur = [], None
    for l in out:
        if l.startswith("P "):
            cur = []
            par_chemin.append(cur)
        else:
            cur.append(l.split()[0])
    for pts in par_chemin:
        for u, v in zip(pts[:-1], pts[1:]):
            if direction.get(u) == "input":
                n_ent += 1
                if direction.get(v) == "output" and u.rsplit("/", 1)[0] == v.rsplit("/", 1)[0]:
                    n_trav += 1
    print(f"{n_ent} passages par une entree de macro avant l'extremite, dont {n_trav} "
          f"traversees entree -> sortie")
    if n_ent == 0:
        print("ATTENTION : aucune broche d'entree de macro dans les chemins : rapport sans "
              "-fields input_pins ? Les traversees seraient comptees comme fixes.")


if __name__ == "__main__":
    main()
