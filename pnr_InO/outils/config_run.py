#!/usr/bin/env python3
"""Retrouver la configuration d'un run LibreLane.

  config_run.py RUN
      Pour chaque cle du config_v2.yaml actuel, la valeur de RUN/resolved.json ;
      les cles dont la valeur a change depuis le run sont marquees '<>'.
  config_run.py RUN --contre RUN2
      Toutes les cles de resolved.json qui different entre les deux runs
      (cles du yaml, valeurs par defaut et PDK compris).
  config_run.py RUN --yaml config_RUN.yaml
      Ecrit une copie du config_v2.yaml actuel, commentaires gardes, ou les
      cles d'une ligne prennent la valeur du run (l'ancienne en commentaire).
      Les cles sur plusieurs lignes (listes, LAYERS_RC...) sont signalees.

Les config.json des etapes (RUN/NN-*/config.json) sont aussi lus : si une cle
a pris plusieurs valeurs selon les etapes (reprise avec --from apres une
modification du yaml), les etapes sont listees ; c'est la valeur de l'etape
qui a servi, pas forcement celle de resolved.json.

Option --config : yaml de reference (par defaut DESIGN_DIR/config_v2.yaml).
Python seul, sans yaml ni LibreLane.
"""
import argparse
import glob
import json
import os
import re
import sys
from decimal import Decimal, InvalidOperation

CLE = re.compile(r"^([A-Z][A-Z0-9_]*)\s*:(.*)$")


def charger(run):
    f = os.path.join(run, "resolved.json")
    if not os.path.exists(f):
        sys.exit(f"pas de resolved.json dans {run}")
    with open(f) as fd:
        return json.load(fd)


def configs_etapes(run):
    """{dossier d'etape: config.json}, dans l'ordre des etapes."""
    r = {}
    for f in sorted(glob.glob(os.path.join(run, "*", "config.json"))):
        try:
            with open(f) as fd:
                r[os.path.basename(os.path.dirname(f))] = json.load(fd)
        except (OSError, ValueError):
            pass
    return r


def cles_yaml(chemin):
    """[(cle, numero de ligne, valeur sur la ligne, nb de lignes)] du niveau 0."""
    lignes = open(chemin).read().split("\n")
    r = []
    for i, l in enumerate(lignes):
        m = CLE.match(l)
        if not m:
            continue
        j = i + 1
        while j < len(lignes) and (lignes[j].startswith((" ", "\t", "-"))
                                   or lignes[j].strip() == ""):
            j += 1
        while j > i + 1 and lignes[j - 1].strip() == "":
            j -= 1
        r.append((m.group(1), i, m.group(2), j - i))
    return lignes, r


def norm(v, rel=()):
    """Valeur comparable : nombres en Decimal, chemins relatifs."""
    if isinstance(v, bool) or v is None:
        return v
    if isinstance(v, (int, float)):
        return Decimal(str(v)).normalize()
    if isinstance(v, str):
        try:
            return Decimal(v).normalize()
        except InvalidOperation:
            pass
        for avant, apres in rel:
            if avant and v.startswith(avant):
                return apres + v[len(avant):]
        return v
    if isinstance(v, list):
        return [norm(x, rel) for x in v]
    if isinstance(v, dict):
        return {k: norm(x, rel) for k, x in v.items()}
    return v


def texte(v, dd=None):
    """Valeur en yaml d'une ligne (JSON est du yaml) ; chemins en dir::."""
    if isinstance(v, str) and dd and v.startswith(dd + "/"):
        return "dir::" + v[len(dd) + 1:]
    if isinstance(v, list) and dd:
        return "[" + ", ".join(texte(x, dd) for x in v) + "]"
    if isinstance(v, str) and re.fullmatch(r"[\w.:/+-]+", v) and not \
            re.fullmatch(r"(true|false|null|yes|no|on|off|~)", v, re.I):
        return v
    return json.dumps(v)


def valeur_yaml(s):
    """Valeur ecrite dans le yaml (une ligne), sans commentaire."""
    s = re.sub(r"\s+#.*$", "", s).strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        s = s[1:-1]
    if s.lower() in ("true", "false"):
        return s.lower() == "true"
    if s.lower() in ("null", "~", ""):
        return None
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--config")
    ap.add_argument("--contre", metavar="RUN2")
    ap.add_argument("--yaml", metavar="SORTIE")
    a = ap.parse_args()

    run = os.path.abspath(a.run.rstrip("/"))
    res = charger(run)
    dd = (res.get("DESIGN_DIR") or "").rstrip("/")
    rel = [(run + "/", "<RUN>/"), (dd + "/", "dir::")]

    if a.contre:
        run2 = os.path.abspath(a.contre.rstrip("/"))
        res2 = charger(run2)
        dd2 = (res2.get("DESIGN_DIR") or "").rstrip("/")
        rel2 = [(run2 + "/", "<RUN>/"), (dd2 + "/", "dir::")]
        print(f"# {os.path.basename(run)}  |  {os.path.basename(run2)}")
        n = 0
        for k in sorted(set(res) | set(res2)):
            if k == "meta":
                continue
            v1 = norm(res.get(k, "<absent>"), rel)
            v2 = norm(res2.get(k, "<absent>"), rel2)
            if v1 != v2:
                n += 1
                print(f"{k}\n    {texte(res.get(k, '<absent>'), dd)}\n"
                      f"    {texte(res2.get(k, '<absent>'), dd2)}")
        if json.dumps(res.get("meta"), sort_keys=True) != \
                json.dumps(res2.get("meta"), sort_keys=True):
            n += 1
            print(f"meta\n    {json.dumps(res.get('meta'))}\n"
                  f"    {json.dumps(res2.get('meta'))}")
        print(f"# {n} cle(s) differente(s)")
        return

    cfg = a.config or os.path.join(dd, "config_v2.yaml")
    if not os.path.exists(cfg):
        sys.exit(f"pas de {cfg} (option --config)")
    lignes, cles = cles_yaml(cfg)
    etapes = configs_etapes(run)
    print(f"# {os.path.basename(run)} contre {cfg}")
    print(f"# {len(etapes)} config.json d'etapes lus")

    nouvelles = list(lignes)
    for k, i, brut, nl in cles:
        if k == "meta":
            continue
        if k not in res:
            print(f"   {k:40s} (absente de resolved.json)")
            continue
        v = res[k]
        diff = "  "
        if nl == 1:
            actuel = valeur_yaml(brut)
            vr = norm(v, rel)
            va = norm(actuel, [])
            if isinstance(v, list) and isinstance(actuel, str):
                va = actuel.replace(" ", "")
                vr = texte(v, dd).replace(" ", "").replace('"', "")
            if vr != va:
                diff = "<>"
                nouvelles[i] = (f"{k}: {texte(v, dd)}"
                                f"   # yaml actuel : {brut.strip()}")
        else:
            diff = "..."   # plusieurs lignes : a verifier a la main
        print(f"{diff:2s} {k:40s} {texte(v, dd)}")
        # valeurs des etapes
        vus = {}
        for e, c in etapes.items():
            if k in c:
                cle = json.dumps(norm(c[k], rel), default=str, sort_keys=True)
                vus.setdefault(cle, [c[k], []])[1].append(e)
        if len(vus) > 1:
            for val, es in vus.values():
                print(f"       etapes {es[0]} .. {es[-1]} ({len(es)}) : "
                      f"{texte(val, dd)}")

    print("# '<>' : le yaml actuel differe du run ; '...' : cle sur plusieurs "
          "lignes, non comparee")
    sdc = sorted(glob.glob(os.path.join(run, "final", "sdc", "*.sdc")))
    if sdc:
        print(f"# SDC ecrit par OpenROAD a la fin du run : {sdc[0]}")

    if a.yaml:
        with open(a.yaml, "w") as fd:
            fd.write(f"# config_v2.yaml retrouve de {os.path.basename(run)} "
                     f"(pnr_InO/outils/config_run.py)\n")
            fd.write("\n".join(nouvelles))
        print(f"# ecrit {a.yaml}")


if __name__ == "__main__":
    main()
