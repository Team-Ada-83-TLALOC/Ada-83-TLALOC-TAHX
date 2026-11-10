#!/usr/bin/env python3
"""Configuration LibreLane de l'assemblage de TAHX_1 d'apres un plan de canaux.py.

Usage : pnr_InO/assemblage/generer_config.py [plan] [--marge 150]
Ecrit pnr_InO/assemblage/config_<plan>.yaml :
  - DIE_AREA : boite des macros plus une marge de chaque cote (ports de TAHX_1 et
    fils autour des macros) ;
  - MACROS : LEF, modeles .lib (3 coins) et declaration (src/bb) de chaque macro, GDS
    du run retenu (chemin de PROVENANCE_VUES.txt, rendu relatif s'il est sous
    pnr_InO/macros), position (coin bas-gauche, y vers le haut, arrondie au pas
    des pistes de 0,48 um pour garder les broches des macros sur les pistes du
    sommet), orientation N ;
  - premier essai : flux arrete au routage global, sans grille d'alimentation (les
    macros ont leur grille jusqu'a TopMetal1, la couche du haut ; le raccordement
    au sommet demandera des macros en PDN_MULTILAYER: false, Metal4 seul).
"""
import argparse, os, re, sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.abspath(os.path.join(ICI, "..", ".."))
sys.path.insert(0, os.path.join(RACINE, "synth_InO", "sta", "plan_puce"))
import canaux as C

INST = {"ino_fetch": "u_instruction.u_fetch", "ino_decode_predict": "u_instruction.u_decode_predict",
        "ino_decode_queue": "u_decode_queue", "stack_unit_16_8": "u_core.u_stack",
        "ino_exec_entier": "u_core.u_backend.u_entier", "ino_exec_arith": "u_core.u_backend.u_arith",
        "ino_system": "u_core.u_system", "ino_data_cache": "u_data_cache"}
PAS = 0.48


def grille(v):
    return round(round(v / PAS) * PAS, 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plan", nargs="?", default="elargi")
    ap.add_argument("--marge", type=float, default=150.0)
    a = ap.parse_args()
    plan = C.PLANS[a.plan]
    tailles = {}
    for m in plan["R"]:
        d = C.DOSSIER.get(m, m)
        w, h, _ = C.lire_lef(os.path.join(C.MACROS, d, "vues", f"{d}.lef"))
        tailles[m] = (w, h)
    W = max(x + tailles[m][0] for m, (x, y) in plan["R"].items())
    H = max(y + tailles[m][1] for m, (x, y) in plan["R"].items())
    M = a.marge
    DW, DH = grille(W + 2 * M), grille(H + 2 * M)

    L = []
    w = L.append
    w("# Assemblage de TAHX_1 (coeur, 8 macros) : genere par generer_config.py, plan "
      f"'{a.plan}' de synth_InO/sta/plan_puce/canaux.py. Ne pas modifier a la main.")
    w("# Premier essai : routage global seulement (librelane ... --to OpenROAD.GlobalRouting),")
    w("# sans grille d'alimentation (voir l'en-tete de generer_config.py).")
    w("PDK: ihp-sg13cmos5l")
    w("DESIGN_NAME: TAHX_1")
    w("VERILOG_FILES:\n  - dir::src/tahx_1_sommet.v")
    w("CLOCK_PORT: CLK_i\nCLOCK_PERIOD: 25")
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
    for m, (x, y) in plan["R"].items():
        d = C.DOSSIER.get(m, m)
        vues = os.path.join(C.MACROS, d, "vues")
        prov = open(os.path.join(vues, "PROVENANCE_VUES.txt")).read()
        g = re.search(r"^GDS\s*:\s*(\S+)", prov, re.M)
        gds = g.group(1) if g else ""
        k = gds.find("/pnr_InO/macros/")
        gds = "dir::../macros/" + gds[k + len("/pnr_InO/macros/"):] if k >= 0 else gds
        lx = grille(M + x)
        ly = grille(M + (H - (y + tailles[m][1])))
        w(f"  {m}:")
        w(f"    lef:\n      - dir::../macros/{d}/vues/{d}.lef")
        w(f"    gds:\n      - {gds}")
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
    print(f"{sortie} : puce {DW} x {DH} um")
    for m, (x, y) in plan["R"].items():
        print(f"   {INST[m]:32s} [{grille(M + x)}, {grille(M + (H - (y + tailles[m][1])))}]")


if __name__ == "__main__":
    main()
