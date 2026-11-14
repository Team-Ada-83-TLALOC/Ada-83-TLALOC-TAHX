#!/usr/bin/env python3
"""GDS fantomes des macros, tires de leurs LEF, pour un essai d'assemblage sans GDS.

Usage : pnr_InO/assemblage/gds_fantomes.py [plan] [--lef v2] [--couche 189/4]
Ecrit pnr_InO/assemblage/gds_fantomes/<macro>.gds : une cellule du nom de la macro
(MACRO du LEF), reduite a son contour (rectangle de SIZE, couche prBoundary).

LibreLane exige un GDS existant pour chaque macro (cle gds de MACROS, chemins
verifies au chargement de la configuration), mais ne le lit qu'aux etapes qui
ecrivent ou verifient le GDS de la puce (KLayout.StreamOut, XOR, DRC). Un essai
arrete au routage global (--to OpenROAD.GlobalRouting) peut donc tourner avec ces
fantomes. Ils ne conviennent PAS a un GDS final : il faut alors les GDS des runs v2
complets (final/klayout_gds/, generer_config.py --gds auto).

Ecrivain GDSII minimal, sans dependance (unites : 1 nm par unite de base, 1e-3 um).
"""
import argparse, os, struct, sys, time

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.abspath(os.path.join(ICI, "..", ".."))
sys.path.insert(0, os.path.join(RACINE, "synth_InO", "sta", "plan_puce"))
import canaux as C


def reel8(v):
    """Reel GDSII : signe, exposant base 16 en exces 64, mantisse sur 56 bits."""
    if v == 0:
        return b"\0" * 8
    s = 0x80 if v < 0 else 0
    v = abs(v)
    e = 64
    while v >= 1:
        v /= 16; e += 1
    while v < 1 / 16:
        v *= 16; e -= 1
    m = int(round(v * (1 << 56)))
    if m >= (1 << 56):
        m >>= 4; e += 1
    return bytes([s | e]) + m.to_bytes(7, "big")


def rec(typ, dt, data=b""):
    if len(data) % 2:
        data += b"\0"
    return struct.pack(">HBB", 4 + len(data), typ, dt) + data


def chaine(typ, s):
    return rec(typ, 0x06, s.encode("ascii"))


def ecrire_gds(chemin, cellule, w_um, h_um, couche, type_):
    t = time.localtime()
    date = struct.pack(">6h", t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec) * 2
    W, H = int(round(w_um * 1000)), int(round(h_um * 1000))
    xy = struct.pack(">10i", 0, 0, W, 0, W, H, 0, H, 0, 0)
    out = b"".join([
        rec(0x00, 0x02, struct.pack(">h", 600)),                  # HEADER
        rec(0x01, 0x02, date),                                     # BGNLIB
        chaine(0x02, "FANTOMES"),                                  # LIBNAME
        rec(0x03, 0x05, reel8(1e-3) + reel8(1e-9)),                # UNITS
        rec(0x05, 0x02, date),                                     # BGNSTR
        chaine(0x06, cellule),                                     # STRNAME
        rec(0x08, 0x00),                                           # BOUNDARY
        rec(0x0D, 0x02, struct.pack(">h", couche)),                # LAYER
        rec(0x0E, 0x02, struct.pack(">h", type_)),                 # DATATYPE
        rec(0x10, 0x03, xy),                                       # XY
        rec(0x11, 0x00),                                           # ENDEL
        rec(0x07, 0x00),                                           # ENDSTR
        rec(0x04, 0x00),                                           # ENDLIB
    ])
    open(chemin, "wb").write(out)


def nom_macro(lef):
    for l in open(lef):
        t = l.split()
        if len(t) >= 2 and t[0] == "MACRO":
            return t[1]
    sys.exit(f"pas de MACRO dans {lef}")


def chemin_fantome(m):
    return os.path.join(ICI, "gds_fantomes", f"{m}.gds")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plan", nargs="?", default="v11h")
    ap.add_argument("--lef", default=None, help="v1, v2 ; defaut : celle du plan")
    ap.add_argument("--couche", default="189/4", help="couche/type du contour (prBoundary d'IHP)")
    a = ap.parse_args()
    couche, type_ = map(int, a.couche.split("/"))
    vlef = C.version_lef(a.plan, a.lef)
    os.makedirs(os.path.join(ICI, "gds_fantomes"), exist_ok=True)
    for m in C.PLANS[a.plan]["R"]:
        lef = C.lef_macro(m, vlef)
        w, h, _ = C.lire_lef(lef)
        cell = nom_macro(lef)
        ecrire_gds(chemin_fantome(m), cell, w, h, couche, type_)
        print(f"{os.path.relpath(chemin_fantome(m), RACINE)} : cellule {cell}, {w:g} x {h:g} um")


if __name__ == "__main__":
    main()
