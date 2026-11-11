#!/usr/bin/env python3
"""Compacte les traversees (set_max_delay -from port -to port) d'un SDC de macro.

Pourquoi : OpenSTA porte, sur chaque sommet, une etiquette (tag) par etat d'exception
distinct venu de l'amont. Une exception -from sur une broche d'entree cree un etat ; deux
broches qui ne sont pas dans exactement les memes -from ont des etiquettes distinctes
partout ou leurs cones se rejoignent. Les surcharges bit a bit de rebudgeter.py donnent a
presque chaque broche d'entree sa propre signature (574 sur 682 pour ino_exec_entier) :
la STA complete et chaque pas de repair_timing sont multiplies dans les cones de
convergence (ALU, complete_o, mem_req_o). Les -to ne creent pas d'etat.

Ce que fait le script :
 1. borne effective de chaque paire de bits (a, b) = la plus serree des exceptions qui la
    couvrent (OpenSTA, a priorite egale) ;
 2. seules comptent les paires reliees par un chemin combinatoire (fichier d'atteignabilite
    ecrit par atteint.tcl) : les autres sont libres ;
 3. dans chaque bus d'entree, les bits sont regroupes en classes compatibles : pour toute
    sortie atteinte par deux bits, meme nature (exception ou contrainte d'horloge) et bornes
    a moins de TAU ; chaque classe devient un -from commun, avec pour chaque sortie la
    borne la plus serree de la classe.
Resultat : jamais plus large que l'original sur un chemin reel, au plus TAU plus serre.

Usage : compacter_traversees.py <sdc> <lef ou netlist> <atteint.txt> [TAU ns, defaut 0.25]
        > <sdc compact>        (resume sur stderr)
"""
import re
import sys
from collections import defaultdict

RX_MD = re.compile(r"set_max_delay\s+(\S+)\s+-from \[get_ports \{(.*?)\}\] -to \[get_ports \{(.*?)\}\]")


def broches(fichier):
    t = open(fichier).read()
    if fichier.endswith(".lef"):
        noms = re.findall(r"^\s*PIN\s+(\S+)", t, re.M)
    else:                                   # netlist Verilog : declarations input / output
        noms = []
        for _, larg, nom in re.findall(r"^\s*(input|output)\s+(\[\d+:\d+\])?\s*(\S+?)\s*[;,]", t, re.M):
            nom = nom.lstrip("\\")
            if larg:
                hi, lo = map(int, larg[1:-1].split(":"))
                noms += [f"{nom}[{i}]" for i in range(min(hi, lo), max(hi, lo) + 1)]
            else:
                noms.append(nom)
    return [n.replace("\\", "") for n in noms if n not in ("VPWR", "VGND")]


def motif(p):
    return re.compile("^" + re.escape(p).replace(r"\[\*\]", r"\[\d+\]").replace(r"\*", ".*") + "$")


def bus(p):
    return re.sub(r"\[\d+\]$", "[*]", p)


def main():
    sdc, ref, fatt = sys.argv[1:4]
    tau = float(sys.argv[4]) if len(sys.argv) > 4 else 0.25
    tout = broches(ref)
    cache = {}

    def dev(p):
        if p not in cache:
            r = motif(p)
            cache[p] = [x for x in tout if r.match(x)]
        return cache[p]

    att = {}
    for l in open(fatt):
        ch = l.split()
        if ch:
            att[ch[0]] = set(ch[1:])

    lignes, exc = [], []
    for l in open(sdc):
        m = RX_MD.match(l)
        if m:
            exc.append((float(m.group(1)), m.group(2), m.group(3)))
        else:
            lignes.append(l.rstrip("\n"))

    eff = {}
    for md, u, v in exc:
        for a in dev(u):
            for b in dev(v):
                if md < eff.get((a, b), 1e30):
                    eff[(a, b)] = md
    # vecteur d'un bit : sortie atteinte -> borne (None = contrainte d'horloge seule)
    vec = {a: {b: eff.get((a, b)) for b in att.get(a, ())} for a in {a for a, _ in eff}}
    hors = sum(1 for (a, b) in eff if b not in att.get(a, ()))
    parbus = defaultdict(list)
    for a in vec:
        parbus[bus(a)].append(a)

    classes = []
    for bu in sorted(parbus):
        cls = []
        for a in sorted(parbus[bu], key=lambda x: (len(x), x)):
            v = vec[a]

            def compatible(c):
                for b, x in v.items():
                    if b in c["lo"]:
                        y = c["lo"][b]
                        if (x is None) != (y is None):
                            return False
                        if x is not None and max(c["hi"][b], x) - min(y, x) > tau:
                            return False
                return True
            for c in cls:
                if compatible(c):
                    for b, x in v.items():
                        if b in c["lo"]:
                            if x is not None:
                                c["hi"][b] = max(c["hi"][b], x)
                                c["lo"][b] = min(c["lo"][b], x)
                        else:
                            c["hi"][b] = c["lo"][b] = x
                    c["bits"].append(a)
                    break
            else:
                cls.append({"hi": dict(v), "lo": dict(v), "bits": [a]})
        classes += cls

    serre = [eff[(a, b)] - c["lo"][b] for c in classes for a in c["bits"]
             for b in vec[a] if vec[a][b] is not None]
    sig0 = defaultdict(set)
    for i, (md, u, v) in enumerate(exc):
        for a in dev(u):
            sig0[a].add(i)
    groupes = defaultdict(list)                      # (classe, borne) -> bits de sortie
    for k, c in enumerate(classes):
        for b, md in c["lo"].items():
            if md is not None:
                groupes[(k, round(md, 3))].append(b)

    def ecrire(ps):                                  # bus complet -> motif
        res = []
        for vb in sorted({bus(x) for x in ps}):
            membres = sorted(x for x in ps if bus(x) == vb)
            if vb != membres[0] and len(membres) == len(dev(vb)):
                res.append(vb)
            else:
                res += membres
        return " ".join(res)

    out = [l for l in lignes if not l.startswith("# Traversees") and not l.startswith("# alloue au chemin")]
    out.append(f"# Traversees compactees (compacter_traversees.py, TAU {tau} ns) : classes de bits")
    out.append("# d'entree, paires sans chemin combinatoire omises ; jamais plus large que la source.")
    for (k, md), bs in sorted(groupes.items()):
        out.append(f"set_max_delay {md:7.3f} -from [get_ports {{{ecrire(classes[k]['bits'])}}}]"
                   f" -to [get_ports {{{ecrire(set(bs))}}}]")
    print("\n".join(out))

    n1 = len({frozenset(s) for s in sig0.values()})
    print(f"{len(exc)} set_max_delay -> {len(groupes)} ; signatures d'entree {n1} -> {len(classes)} "
          f"(TAU {tau} ns) ; paires de bits {len(eff)}, dont {hors} sans chemin", file=sys.stderr)
    s = sorted(serre) or [0.0]
    q = lambda f: s[min(len(s) - 1, int(f * len(s)))]
    print(f"resserrement des paires reelles (ns) : 90 % {q(0.9):.2f}, 99 % {q(0.99):.2f}, "
          f"max {s[-1]:.2f}", file=sys.stderr)


if __name__ == "__main__":
    main()
