#!/usr/bin/env python3
"""Placement des SRAM de ino_fetch pour LibreLane.

Usage : python3 placer_sram.py <netlist.v> > instances.yaml

Lit le netlist synthetise (par exemple runs/RUN_.../06-yosys-synthesis/ino_fetch.nl.v),
y trouve les instances de RM_IHPSG13_2P_512x32_c2_bm_bist et ecrit le bloc
'instances' a coller sous MACROS.RM_IHPSG13_2P_512x32_c2_bm_bist dans config.yaml.

Disposition (die 1700 x 2050 um) : deux colonnes (x = 50 et 900), trois paires de
rangees face a face, broches de la SRAM du bas (FS) vers le haut, de celle du haut
(N) vers le bas, canal partage de 130 um entre elles ; rangees dos a dos a 30 um.
  paire 1 : bancs 1 (FS) et 2 (N)
  paire 2 : bancs 3 (FS) et 4 (N)
  paire 3 : u_tag_nx (FS, 2 macros) et u_tag (N, colonne de gauche)
La bande du bas (0 .. 250 um) recoit la file d'octets, pres des broches window_*.

Regle de grille (IHP sg13 : pistes Metal2 et Metal3 au pas de 0,48 um depuis
l'origine du die) : les 376 broches de signal d'une SRAM sont des carres de
0,26 um alignes sur une seule bande au bord sud de la macro (au bord nord en FS).
Une piste Metal3 doit passer dans cette bande, sinon les broches sans piste Metal2
(environ 160 par SRAM, quel que soit x) sont inaccessibles (DRT-0418, puis des
milliers d'erreurs DRC). Le y de chaque macro est donc ajuste pour que la piste
la plus proche passe au milieu de la bande :
  N  : bande y .. y + 0,26             -> y = k * 0,48 - 0,13
  FS : bande y + 219,51 .. y + 219,77  -> y = k * 0,48 - 219,64
"""
import re, sys

MACRO = "RM_IHPSG13_2P_512x32_c2_bm_bist"
H = 219.77                      # hauteur de la macro (LEF)
PITCH = 0.48                    # pas des pistes Metal2 / Metal3
PIN_MID = 0.13                  # milieu de la bande de broches (carres de 0,26)
COLS = [50, 900]

# (y approximatif, orientation, cles des instances par colonne)
ROWS = [
    (250,  "FS", ["gen_banks:1.u_ram.u_w0", "gen_banks:1.u_ram.u_w1"]),
    (600,  "N",  ["gen_banks:2.u_ram.u_w0", "gen_banks:2.u_ram.u_w1"]),
    (850,  "FS", ["gen_banks:3.u_ram.u_w0", "gen_banks:3.u_ram.u_w1"]),
    (1200, "N",  ["gen_banks:4.u_ram.u_w0", "gen_banks:4.u_ram.u_w1"]),
    (1450, "FS", ["u_tag_nx.u_r0", "u_tag_nx.u_r1"]),
    (1800, "N",  ["u_tag.u_w0"]),
]

def on_grid(y, orient):
    """y le plus proche tel qu'une piste passe au milieu de la bande de broches."""
    off = PIN_MID if orient == "N" else H - PIN_MID
    k = round((y + off) / PITCH)
    return round(k * PITCH - off, 3)

def main():
    text = open(sys.argv[1]).read()
    names = sorted(set(re.findall(r"^\s*%s\s+\\?(\S+)\s*\(" % MACRO, text, re.M)))
    used = set()
    print("    instances:")
    for y, orient, keys in ROWS:
        yy = on_grid(y, orient)
        for col, k in enumerate(keys):
            match = [n for n in names if n.endswith(k)]
            if len(match) != 1:
                sys.exit("instance %s : %d correspondances dans le netlist" % (k, len(match)))
            n = match[0]
            used.add(n)
            print("      \"%s\":" % n)
            print("        location: [%d, %.2f]" % (COLS[col], yy))
            print("        orientation: %s" % orient)
    rest = set(names) - used
    if rest:
        sys.exit("SRAM non placees : %s" % ", ".join(sorted(rest)))
    sys.stderr.write("%d SRAM placees\n" % len(used))

main()
