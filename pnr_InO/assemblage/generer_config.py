#!/usr/bin/env python3
"""Configuration LibreLane de l'assemblage de TAHX_1 d'apres un plan de canaux.py.

Usage : pnr_InO/assemblage/generer_config.py [plan] [--marge 150] [--marge-haut M]
                                            [--lef v2] [--gds auto|vues] [--periode 26]
Ecrit pnr_InO/assemblage/config_<plan>.yaml :
  - DIE_AREA : boite des macros plus une marge de chaque cote (ports de TAHX_1 et
    fils autour des macros) ;
  - MACROS : LEF, modeles .lib (3 coins) et declaration (src/bb) de chaque macro, GDS,
    position (coin bas-gauche, y vers le haut), orientation N ;
  - LEF : version du plan (cle LEF de canaux.PLANS ; v11h -> <m>_v2.lef) ou --lef ;
    --lef vues : vues/<m>.lef, ecrit par vues_macros.sh depuis le run retenu (meme run
    que le GDS, .lib et netlist) ; les broches sont alors comparees a celles de
    <m>_v2.lef (positions de reference du plan) : un ecart est signale ;
  - positions : x au pas de 0,48 um (pistes Metal2, broches N/S des macros), y au pas
    de 0,42 um (pistes Metal3, broches E/O) ; les marges sont arrondies a ces pas et
    les positions relatives du plan sont gardees telles quelles (elles y sont deja
    pour v11h : bus droits au bit pres) ; une position hors grille est signalee ;
  - marge du haut : --marge-haut, sinon cle MARGE_HAUT du plan (v11h : zone du bloc
    frontend_control du modele Logisim, logique de liaison placee librement) ;
  - GDS (--gds) :
      auto (defaut) : pour des LEF v2, le run complet le plus recent de
        pnr_InO/macros/<m>/runs/ (final/klayout_gds/*.gds present, resolved.json avec
        IO_PIN_ORDER_CFG = pin_order_v2.cfg et DIE_AREA a la taille du LEF v2) ; a
        defaut, le GDS fantome (gds_fantomes.py, ecrit au besoin) ;
      fantome : GDS fantomes pour toutes les macros ;
      vues : GDS de vues/PROVENANCE_VUES.txt (runs v1, chemins absolus de la machine
        des runs) ;
    LibreLane verifie que les GDS existent mais ne les lit qu'a l'ecriture du GDS de
    la puce : les fantomes suffisent a un essai arrete au routage global ;
  - obstructions (--obs) : pleine (defaut) ecrit lef_obs/<m>.lef, copie du LEF dont
    l'OBS est remplace par un rectangle plein (0 0 L H) sur Metal1 a TopMetal1, comme
    les LEF de vues/ (v1) : les fils du sommet ne passent pas sur les macros. Les LEF
    v2 tires d'ODB arretes au routage global n'obstruent que les rails et sangles
    d'alimentation (7 % de Metal2 a Metal4) ; --obs lef les garde tels quels ;
  - .lib : vues/lib/ (runs v1 tant que vues_macros.sh n'a pas ete passe sur les runs
    v2 ; memes ports en v1 et v2) ;
  - premier essai : flux arrete au routage global, sans grille d'alimentation (les
    macros ont leur grille jusqu'a TopMetal1, la couche du haut ; le raccordement
    au sommet demandera des macros en PDN_MULTILAYER: false, Metal4 seul).
"""
import argparse, os, re, sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.abspath(os.path.join(ICI, "..", ".."))
sys.path.insert(0, os.path.join(RACINE, "synth_InO", "sta", "plan_puce"))
sys.path.insert(0, ICI)
import canaux as C
import glob, json
import gds_fantomes as F

INST = {"ino_fetch": "u_instruction.u_fetch", "ino_decode_predict": "u_instruction.u_decode_predict",
        "ino_decode_queue": "u_decode_queue", "stack_unit_16_8": "u_core.u_stack",
        "ino_exec_entier": "u_core.u_backend.u_entier", "ino_exec_arith": "u_core.u_backend.u_arith",
        "ino_system": "u_core.u_system", "ino_data_cache": "u_data_cache"}
PAS = 0.48


PAS_Y = 0.42


def grille(v, pas=PAS):
    return round(round(v / pas) * pas, 2)


def sur_grille(v, pas):
    return abs(v / pas - round(v / pas)) < 1e-6


def taille_lef(f):
    for l in open(f):
        t = l.split()
        if len(t) >= 4 and t[0] == "SIZE" and t[2] == "BY":
            return float(t[1]), float(t[3].rstrip(";"))
    return None


def run_v2_complet(run, cible, version):
    """Le run a-t-il ecrit son GDS avec le pin_order et la boite de la version ?"""
    g = glob.glob(os.path.join(run, "final", "klayout_gds", "*.gds"))
    try:
        r = json.load(open(os.path.join(run, "resolved.json")))
    except (OSError, ValueError):
        return None
    pin = str(r.get("IO_PIN_ORDER_CFG") or "")
    die = r.get("DIE_AREA") or []
    try:
        taille = (round(float(die[2]) - float(die[0]), 2), round(float(die[3]) - float(die[1]), 2))
    except (IndexError, TypeError, ValueError):
        return None
    if g and pin.endswith(f"pin_order_{version}.cfg") and taille == cible:
        return g[0]
    return None


COUCHES_OBS = ("Metal1", "Metal2", "Metal3", "Metal4", "TopMetal1")


def lef_obs_plein(m, lef):
    """Copie du LEF avec un OBS plein ; -> chemin relatif au dossier de l'assemblage."""
    w, h = taille_lef(lef)
    lignes = open(lef).read().split("\n")
    debut = next(i for i, l in enumerate(lignes) if l.strip() == "OBS")
    fin = next(i for i in range(debut + 1, len(lignes)) if lignes[i].strip() == "END")
    obs = ["  OBS"] + [x for c in COUCHES_OBS for x in (f"    LAYER {c} ;", f"     RECT  0 0 {w:g} {h:g} ;")] + ["  END"]
    os.makedirs(os.path.join(ICI, "lef_obs"), exist_ok=True)
    sortie = os.path.join(ICI, "lef_obs", f"{m}.lef")
    open(sortie, "w").write("\n".join(lignes[:debut] + obs + lignes[fin + 1:]))
    return f"lef_obs/{m}.lef"


def gds_macro(m, d, vlef, mode):
    """(chemin du GDS, origine) ; voir l'en-tete."""
    if mode == "auto" and vlef and vlef != "v1":
        cible = taille_lef(C.lef_macro(m, vlef))
        cible = (round(cible[0], 2), round(cible[1], 2))
        for run in sorted(glob.glob(os.path.join(C.MACROS, d, "runs", "RUN_*")), reverse=True):
            g = run_v2_complet(run, cible, vlef)
            if g:
                return "dir::../macros/" + os.path.relpath(g, C.MACROS), os.path.basename(run)
    if mode in ("auto", "fantome"):
        f = F.chemin_fantome(m)
        lef = C.lef_macro(m, vlef)
        w, h, _ = C.lire_lef(lef)
        os.makedirs(os.path.dirname(f), exist_ok=True)
        F.ecrire_gds(f, F.nom_macro(lef), w, h, 189, 4)
        return f"dir::gds_fantomes/{m}.gds", "FANTOME (contour du LEF) : pas de run v2 complet"
    prov = open(os.path.join(C.MACROS, d, "vues", "PROVENANCE_VUES.txt")).read()
    g = re.search(r"^GDS\s*:\s*(\S+)", prov, re.M)
    gds = g.group(1) if g else ""
    k = gds.find("/pnr_InO/macros/")
    gds = "dir::../macros/" + gds[k + len("/pnr_InO/macros/"):] if k >= 0 else gds
    return gds, "vues (runs v1)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plan", nargs="?", default="elargi")
    ap.add_argument("--marge", type=float, default=150.0)
    ap.add_argument("--marge-haut", type=float, default=None)
    ap.add_argument("--lef", default=None, help="v1, v2 ; defaut : celle du plan")
    ap.add_argument("--gds", default="auto", choices=["auto", "fantome", "vues"])
    ap.add_argument("--obs", default="pleine", choices=["pleine", "lef"])
    ap.add_argument("--periode", type=float, default=26.0, help="ns (SDC rebudgetes P78 : 26)")
    a = ap.parse_args()
    plan = C.PLANS[a.plan]
    vlef = C.version_lef(a.plan, a.lef)
    tailles = {}
    for m in plan["R"]:
        w, h, _ = C.lire_lef(C.lef_macro(m, vlef))
        tailles[m] = (w, h)
    X0 = min(x for x, y in plan["R"].values())
    Y0 = min(y for x, y in plan["R"].values())
    W = max(x + tailles[m][0] for m, (x, y) in plan["R"].items()) - X0
    H = max(y + tailles[m][1] for m, (x, y) in plan["R"].items()) - Y0
    MX, MY = grille(a.marge, PAS), grille(a.marge, PAS_Y)
    MH = a.marge_haut if a.marge_haut is not None else plan.get("MARGE_HAUT", a.marge)
    MH = grille(MH, PAS_Y)
    DW, DH = grille(W + 2 * MX, PAS), grille(H + MY + MH, PAS_Y)

    def position(m):
        x, y = plan["R"][m]
        return round(MX + x - X0, 2), round(MY + (H - (y - Y0 + tailles[m][1])), 2)
    ecarts = {}
    if vlef == "vues":
        for m in plan["R"]:
            _, _, p1 = C.lire_lef(C.lef_macro(m, "vues"))
            _, _, p2 = C.lire_lef(C.lef_macro(m, plan.get("LEF") or "v2"))
            diff = [n for n in set(p1) | set(p2)
                    if n not in p1 or n not in p2
                    or abs(p1[n][0] - p2[n][0]) > 0.005 or abs(p1[n][1] - p2[n][1]) > 0.005]
            if diff:
                ecarts[m] = sorted(diff)
    hors = [m for m in plan["R"] if not (sur_grille(position(m)[0], PAS) and sur_grille(position(m)[1], PAS_Y))]

    L = []
    w = L.append
    w("# Assemblage de TAHX_1 (coeur, 8 macros) : genere par generer_config.py, plan "
      f"'{a.plan}' de synth_InO/sta/plan_puce/canaux.py. Ne pas modifier a la main.")
    w("# Premier essai : routage global seulement (librelane ... --to OpenROAD.GlobalRouting),")
    w("# sans grille d'alimentation (voir l'en-tete de generer_config.py).")
    w("PDK: ihp-sg13cmos5l")
    w("DESIGN_NAME: TAHX_1")
    w("VERILOG_FILES:\n  - dir::src/tahx_1_sommet.v")
    w(f"# LEF {vlef or 'v1'} ; .lib et netlists des macros : vues/ (voir PROVENANCE_VUES.txt).")
    if ecarts:
        w(f"# ATTENTION : broches de vues/ differentes du LEF du plan : {', '.join(ecarts)}")
    if hors:
        w(f"# ATTENTION : positions hors des pistes (x 0,48 / y 0,42) : {', '.join(hors)}")
    w(f"CLOCK_PORT: CLK_i\nCLOCK_PERIOD: {a.periode:g}")
    w("SYNTH_STRATEGY: \"DELAY 1\"\nSYNTH_CORNER: nom_slow_1p08V_125C")
    w("PNR_CORNERS: [nom_slow_1p08V_125C, nom_fast_1p32V_m40C]")
    w("PL_TIMING_DRIVEN: true\nPL_ROUTABILITY_DRIVEN: true\nPL_TARGET_DENSITY_PCT: 60")
    w("GRT_ALLOW_CONGESTION: true")
    w("LAYERS_RC:\n  \"*\":\n"
      "    Metal1: { res: 8.54576E-03, cap: 1.0E-10 }\n"
      "    Metal2: { res: 2.53519E-03, cap: 1.69121E-04 }\n"
      "    Metal3: { res: 1.54329E-03, cap: 1.82832E-04 }\n"
      "    Metal4: { res: 6.31424E-04, cap: 1.66454E-04 }")
    w("DESIGN_REPAIR_MAX_WIRE_LENGTH: 500\nGRT_DESIGN_REPAIR_MAX_WIRE_LENGTH: 500")
    w("DESIGN_REPAIR_MAX_SLEW_PCT: 25\nGRT_DESIGN_REPAIR_MAX_SLEW_PCT: 25")
    w("CTS_CLK_MAX_WIRE_LENGTH: 300\nCTS_DISTANCE_BETWEEN_BUFFERS: 300")
    w(f"FP_SIZING: absolute\nDIE_AREA: [0, 0, {DW}, {DH}]")
    w("FP_MACRO_HORIZONTAL_HALO: 10\nFP_MACRO_VERTICAL_HALO: 10")
    w("DIODE_ON_PORTS: in\nDIODE_CELL: sg13cmos5l_antennanp/A")
    w("MACROS:")
    origines = {}
    for m in plan["R"]:
        d = C.DOSSIER.get(m, m)
        gds, origines[m] = gds_macro(m, d, vlef, a.gds)
        lx, ly = position(m)
        w(f"  {m}:")
        lef = C.lef_macro(m, vlef)
        if a.obs == "pleine":
            w(f"    lef:          # OBS plein, d'apres {os.path.relpath(lef, C.MACROS)}\n"
              f"      - dir::{lef_obs_plein(m, lef)}")
        else:
            w(f"    lef:\n      - dir::../macros/{os.path.relpath(lef, C.MACROS)}")
        w(f"    gds:          # {origines[m]}\n      - {gds}")
        w(f"    vh:\n      - dir::src/bb/{m}.v")
        w("    lib:")
        for coin, nom in (("slow", "nom_slow_1p08V_125C"), ("typ", "nom_typ_1p20V_25C"),
                          ("fast", "nom_fast_1p32V_m40C")):
            w(f"      \"*_{coin}_*\":\n        - dir::../macros/{d}/vues/lib/{nom}.lib")
        w("    instances:")
        w(f"      \"{INST[m]}\":\n        location: [{lx}, {ly}]\n        orientation: N")
    w("RUN_LVS: false\nRUN_KLAYOUT_DRC: false\nRUN_MAGIC_STREAMOUT: false\nRUN_MAGIC_WRITE_LEF: false")
    w("RUN_MAGIC_DRC: false\nRUN_KLAYOUT_XOR: false")
    w("meta:\n  version: 2\n  flow: Classic\n  substituting_steps:")
    for s in ("OpenROAD.GeneratePDN", "Odb.CheckDesignAntennaProperties", "Magic.SpiceExtraction",
              "Checker.IllegalOverlap", "Netgen.LVS", "Checker.LVS"):
        w(f"    {s}: null")
    sortie = os.path.join(ICI, f"config_{a.plan}.yaml")
    open(sortie, "w").write("\n".join(L) + "\n")
    print(f"{sortie} : puce {DW} x {DH} um (macros {W:.2f} x {H:.2f}, LEF {vlef or 'v1'}, "
          f"marges {MX} / {MY} / haut {MH}, OBS {a.obs})")
    for m in plan["R"]:
        print(f"   {INST[m]:32s} {str(list(position(m))):22s} GDS : {origines[m]}")
    for m in hors:
        print(f"   ATTENTION, hors des pistes : {m} {position(m)}")
    for m, d in ecarts.items():
        print(f"   ATTENTION, broches de vues/ differentes du LEF du plan : {m}, {len(d)} broche(s), "
              f"ex. {', '.join(d[:4])}")
    if vlef == "vues" and not ecarts:
        print("   broches de vues/ identiques a celles du LEF du plan (8 macros)")


if __name__ == "__main__":
    main()
