#!/usr/bin/env python3
"""Placement des SRAM de ino_data_cache (INO_DATA_CACHE) pour LibreLane, plan 2.

Usage : python3 placer_sram.py <netlist a plat> > instances.txt
(par exemple runs/RUN_.../06-yosys-synthesis/ino_data_cache.nl.v ; les noms
d'instance sont u_core.gen_data:1..4.u_data.u_sram et u_core.gen_tag:1..2.u_tag.u_sram).

Plan 2 (die 2275 x 1334 um) : une seule bande de logique horizontale au milieu
(y 355 .. 976, 620 um ; avec 420 um, debordement de 44 000 au routage global), toutes les SRAM ont leurs broches face a elle :
  rangee du bas (FS, broches en haut)  : donnees voies 0, 1 et tags 0-1 ;
  rangee du haut (N, broches en bas)   : donnees voies 2, 3 et tags 2-3.
Les tags (118,78 um de haut) sont colles au bord du die : la place entre eux et
la bande la prolonge (poche ouverte sur la bande, pas de canal ferme).
Colonnes a 15 um les unes des autres et SRAM a ~10 um des bords : les halos de
10 um se recouvrent, aucune rangee de cellules dans ces fentes (sinon PDN-0179).
Les broches de la macro sont aux deux bouts de la bande (bords W et E).

Colonne libre a droite des tags du bas (x 2216 .. 2275), du bas du die a la bande.
Elle laisse des rangs de cellules jusqu'en bas du coeur : DPL compte ses rangs a
partir du plus bas rang existant, et une SRAM placee entierement ou en partie sous
ce rang echoue au controle de padding (DPL-0011 puis DPL-0033), sans voisin reel.
Sans cette colonne, les rangs sous la rangee FS sont tous coupes (SRAM + halos sur
toute la largeur) et le premier rang est a y = 147,42.

Rails des cellules : un rail tous les 3,78 um depuis y = 15,12 (bas du coeur). Le
bord de la grille Metal4 coupee par une SRAM (bord + halo de 10 um) ne doit pas
tomber juste sous un rail, sinon la pile de vias Metal1-Metal4 de ce rail est
retiree (PDN-0195). Donnees du bas a y = 18,39 : bord + halo = 364,85, a mi-chemin
des rails 362,88 et 366,66 (a 15,99, il tombait 0,43 um sous le rail 362,88).
Rangee du haut : bord bas - halo a ~1,8 um des rails (donnees 975,71, tags 1191,23).

Plan 1 (abandonne) : bandes de logique en haut et en bas, canal de 140 um entre
les rangees de donnees ; tout le trafic passait par trois couloirs etroits ou
au-dessus des SRAM en TopMetal1 (plus de 130 000 violations au routage detaille).

Regle de grille (pistes Metal2/Metal3 au pas de 0,48 um depuis l'origine du die) :
  N  : y = k * 0,48 - 0,13        FS : y = k * 0,48 - (H - 0,13)
"""
import re, sys

PITCH, PIN_MID = 0.48, 0.13
DATA, TAG = "RM_IHPSG13_1P_1024x64_c2_bm_bist", "RM_IHPSG13_1P_256x48_c2_bm_bist"
H = {DATA: 336.46, TAG: 118.78}
X = [10, 810, 1610]

# (macro, cle de l'instance, x, y approximatif, orientation)
PLACES = [
    (DATA, "gen_data:1.u_data.u_sram", X[0], 18.4,   "FS"),
    (DATA, "gen_data:2.u_data.u_sram", X[1], 18.4,   "FS"),
    (TAG,  "gen_tag:1.u_tag.u_sram",   X[2], 16,     "FS"),
    (DATA, "gen_data:3.u_data.u_sram", X[0], 975.7,  "N"),
    (DATA, "gen_data:4.u_data.u_sram", X[1], 975.7,  "N"),
    (TAG,  "gen_tag:2.u_tag.u_sram",   X[2], 1191.2, "N"),
]

def on_grid(y, orient, h):
    off = PIN_MID if orient == "N" else h - PIN_MID
    k = round((y + off) / PITCH)
    return round(k * PITCH - off, 3)

def main():
    text = open(sys.argv[1]).read()
    for macro in (DATA, TAG):
        names = sorted(set(re.findall(r"^\s*%s\s+\\?(\S+)\s*\(" % macro, text, re.M)))
        used = set()
        print("  %s:" % macro)
        print("    instances:")
        for m, k, x, y, orient in PLACES:
            if m != macro:
                continue
            match = [n for n in names if n.endswith(k)]
            if len(match) != 1:
                sys.exit("instance %s : %d correspondances dans le netlist" % (k, len(match)))
            used.add(match[0])
            print("      \"%s\":" % match[0])
            print("        location: [%d, %.2f]" % (x, on_grid(y, orient, H[m])))
            print("        orientation: %s" % orient)
        if set(names) - used:
            sys.exit("SRAM non placees : %s" % ", ".join(sorted(set(names) - used)))
        sys.stderr.write("%s : %d SRAM placees\n" % (macro, len(used)))

main()
