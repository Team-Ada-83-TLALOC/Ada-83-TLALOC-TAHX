#!/usr/bin/env python3
"""Broches de SRAM reliees a un reseau mais non atteintes par le routage (DEF).

Les runs de pnr_InO desactivent le LVS (RUN_LVS: false). Une broche de SRAM sans
point d'acces pour le routeur detaille (avertissement DRT-0418) peut alors rester
non raccordee sans aucune erreur : ni DRC, ni Checker.DisconnectedPins (qui ne lit
que la netlist). Ce script relit le DEF routé et, pour chaque broche de signal
d'une SRAM reliee a un reseau, cherche un fil ou un via de ce reseau qui touche
la broche sur sa couche.

Usage :
  python3 pnr_InO/verifier_broches_sram.py <macro>.def <sram>.lef [<sram>.lef ...]
    <macro>.def : DEF du routage detaille ou final
                  (<run>/*-openroad-detailedrouting/<macro>.def, ou final/def/)
    <sram>.lef  : LEF des SRAM ($PDK_ROOT/ihp-sg13g2/libs.ref/sg13g2_sram/lef/...)
Sortie : par instance de SRAM, broches reliees et broches non atteintes ; code de
retour 1 s'il y a au moins une broche non atteinte. Une broche seule sur son reseau
(sortie de SRAM inutilisee, reseau sans autre terminal) n'a rien a router : elle est
comptee a part (« seules sur leur reseau »), pas comme non atteinte.

Approximation : un segment de fil est un rectangle de demi-largeur 0,1 um autour
de son axe (0,82 um en TopMetal1), prolonge d'autant aux extremites ; un via est
un carre de 0,2 um centre sur son point, sur les deux couches qu'il relie (le
numero de son nom : Via1 relie Metal1 et Metal2, Via2 Metal2 et Metal3...). Les
formes RECT d'un ROUTED sont prises telles quelles.
"""
import re
import sys
from collections import defaultdict

MI_LARGEUR = {"TopMetal1": 0.82, "TopMetal2": 1.0}
MI_LARGEUR_DEFAUT = 0.10
COUCHES = ["Metal1", "Metal2", "Metal3", "Metal4", "Metal5", "TopMetal1", "TopMetal2"]


def lire_lef(chemins):
    """{macro: (largeur, hauteur, {broche: [(couche, x1, y1, x2, y2)]})}"""
    macros = {}
    for chemin in chemins:
        macro = None
        broche = None
        couche = None
        dans_port = False
        for ligne in open(chemin, errors="replace"):
            mots = ligne.split()
            if not mots:
                continue
            if mots[0] == "MACRO":
                macro = mots[1]
                macros[macro] = [0.0, 0.0, {}]
            elif macro is None:
                continue
            elif mots[0] == "SIZE" and broche is None:
                macros[macro][0] = float(mots[1])
                macros[macro][1] = float(mots[3])
            elif mots[0] == "PIN":
                broche = mots[1]
                macros[macro][2][broche] = []
            elif mots[0] == "USE" and broche is not None and mots[1] in ("POWER", "GROUND"):
                del macros[macro][2][broche]
                broche = None
            elif mots[0] == "PORT":
                dans_port = True
            elif mots[0] == "LAYER" and dans_port:
                couche = mots[1]
            elif mots[0] == "RECT" and dans_port and broche is not None:
                x1, y1, x2, y2 = map(float, mots[1:5])
                macros[macro][2][broche].append((couche, x1, y1, x2, y2))
            elif mots[0] == "END":
                if len(mots) == 1 and dans_port:
                    dans_port = False
                elif broche is not None and len(mots) > 1 and mots[1] == broche:
                    broche = None
                elif len(mots) > 1 and mots[1] == macro:
                    macro = None
    return {m: (v[0], v[1], v[2]) for m, v in macros.items()}


def transformer(rect, x, y, l, h, orient):
    """Rectangle de broche (repere de la macro) -> repere du DEF, en um."""
    c, x1, y1, x2, y2 = rect
    if orient == "N":
        return (c, x + x1, y + y1, x + x2, y + y2)
    if orient == "FS":                       # miroir vertical
        return (c, x + x1, y + h - y2, x + x2, y + h - y1)
    if orient == "S":                        # rotation de 180 degres
        return (c, x + l - x2, y + h - y2, x + l - x1, y + h - y1)
    if orient == "FN":                       # miroir horizontal
        return (c, x + l - x2, y + y1, x + l - x1, y + y2)
    raise ValueError("orientation non traitee : %s" % orient)


def nom(n):
    return n.replace("\\", "")


def couches_via(v):
    m = re.match(r"(?i)topvia(\d)", v)
    if m:
        return ["Metal5", "TopMetal1"] if m.group(1) == "1" else ["TopMetal1", "TopMetal2"]
    m = re.match(r"(?i)via(\d)", v)
    if m:
        n = int(m.group(1))
        return ["Metal%d" % n, "Metal%d" % (n + 1)]
    return []


def formes_routees(texte, dbu):
    """Formes (couche, x1, y1, x2, y2) en um des instructions ROUTED / NEW."""
    formes = []
    for bloc in re.split(r"\+\s*(?:ROUTED|FIXED|COVER|NOSHIELD)\b|\bNEW\b", texte)[1:]:
        jetons = re.findall(r"\(|\)|[^\s()]+", bloc)
        if not jetons:
            continue
        couche = jetons[0]
        i = 1
        if i < len(jetons) and re.fullmatch(r"\d+", jetons[i]):
            i += 1                           # largeur explicite (ignoree)
        points = []
        derniere = None
        while i < len(jetons):
            j = jetons[i]
            if j == "(":
                xs, ys = jetons[i + 1], jetons[i + 2]
                k = i + 3
                if jetons[k] != ")":         # extension eventuelle
                    k += 1
                px = derniere[0] if xs == "*" else int(xs)
                py = derniere[1] if ys == "*" else int(ys)
                derniere = (px, py)
                points.append(derniere)
                i = k + 1
            elif j == "RECT" and derniere is not None:
                dx1, dy1, dx2, dy2 = (int(jetons[i + 2]), int(jetons[i + 3]),
                                      int(jetons[i + 4]), int(jetons[i + 5]))
                px, py = derniere
                formes.append((couche, (px + dx1) / dbu, (py + dy1) / dbu,
                               (px + dx2) / dbu, (py + dy2) / dbu))
                i += 7
            elif j in ("SHAPE", "STYLE", "TAPERRULE", "MASK"):
                i += 2
            elif j in ("+", ";", "TAPER", "VIRTUAL"):
                i += 1
            else:
                if derniere is not None:     # via au dernier point
                    for cv in couches_via(j):
                        x, y = derniere[0] / dbu, derniere[1] / dbu
                        formes.append((cv, x - 0.1, y - 0.1, x + 0.1, y + 0.1))
                i += 1
        mi = MI_LARGEUR.get(couche, MI_LARGEUR_DEFAUT)
        for (ax, ay), (bx, by) in zip(points, points[1:]):
            formes.append((couche, min(ax, bx) / dbu - mi, min(ay, by) / dbu - mi,
                           max(ax, bx) / dbu + mi, max(ay, by) / dbu + mi))
        if len(points) == 1:
            x, y = points[0][0] / dbu, points[0][1] / dbu
            formes.append((couche, x - mi, y - mi, x + mi, y + mi))
    return formes


def touche(a, b):
    return a[0] == b[0] and a[1] <= b[3] and b[1] <= a[3] and a[2] <= b[4] and b[2] <= a[4]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    lef = lire_lef(sys.argv[2:])
    dbu = 1000.0
    instances = {}                           # instance -> (macro, x, y, orient)
    section = None
    net_texte = []
    resultats = defaultdict(lambda: [0, [], []])   # reliees, non atteintes, seules
    for ligne in open(sys.argv[1], errors="replace"):
        s = ligne.strip()
        if s.startswith("UNITS DISTANCE MICRONS"):
            dbu = float(s.split()[3])
        elif s.startswith("COMPONENTS "):
            section = "C"
        elif s.startswith("END COMPONENTS"):
            section = None
        elif s.startswith("NETS ") and not s.startswith("NETS END"):
            section = "N"
        elif s.startswith("END NETS"):
            section = None
        elif section == "C" and s.startswith("-"):
            m = re.match(r"-\s+(\S+)\s+(\S+).*?\+\s*(?:PLACED|FIXED)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*(\S+)", s)
            if m and m.group(2) in lef:
                instances[nom(m.group(1))] = (m.group(2), int(m.group(3)) / dbu,
                                              int(m.group(4)) / dbu, m.group(5))
        elif section == "N":
            net_texte.append(s)
            if s.endswith(";"):
                texte = " ".join(net_texte)
                net_texte = []
                tous = re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", texte.split("+")[0])
                conn = [(nom(i), p) for i, p in tous if nom(i) in instances]
                if not conn:
                    continue
                if len(tous) < 2:
                    # reseau a un seul terminal (sortie de SRAM inutilisee) : rien a router
                    for inst, broche in conn:
                        resultats[inst][2].append(broche)
                    continue
                formes = formes_routees(texte, dbu)
                for inst, broche in conn:
                    macro, x, y, o = instances[inst]
                    l, h, broches = lef[macro]
                    rects = [transformer(r, x, y, l, h, o) for r in broches.get(broche, [])]
                    if not rects:
                        continue
                    resultats[inst][0] += 1
                    if not any(touche(r, f) for r in rects for f in formes):
                        resultats[inst][1].append(broche)
    total = 0
    for inst in sorted(instances):
        n, manquantes, seules = resultats[inst]
        total += len(manquantes)
        print("%-40s %4d broches reliees, %4d non atteintes, %3d seules sur leur reseau%s" % (
            inst, n, len(manquantes), len(seules),
            " : " + " ".join(sorted(manquantes)[:12]) + (" ..." if len(manquantes) > 12 else "") if manquantes else ""))
    print("total : %d broche(s) de SRAM reliee(s) non atteinte(s) par le routage" % total)
    sys.exit(1 if total else 0)


main()
