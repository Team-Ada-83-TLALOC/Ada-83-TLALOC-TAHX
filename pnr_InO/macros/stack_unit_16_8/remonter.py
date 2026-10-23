#!/usr/bin/env python3
# Remonte l'origine d'un net dans un netlist Verilog a plat (sortie OpenROAD/Yosys).
#
# Usage : python3 remonter_net.py <netlist.nl.v> <net> [profondeur]
#   ex.   python3 remonter_net.py runs/.../stack_unit_16_8.nl.v _004845_ 4
#
# Pour le net, puis pour chaque entree de la cellule qui le produit (jusqu'a la
# profondeur donnee) : cellule, sortance, et arret sur un port ou une bascule.
import re, sys
from collections import defaultdict

SORTIES = { "Y", "X", "Q", "Q_N", "QN", "Z", "ZN", "CO", "S" }

def lire( fichier ):
    texte = open( fichier ).read()
    ports = set( re.findall( r"^\s*(?:input|output|inout)\s+(?:\[[^\]]*\]\s*)?(\\\S+|\w+)", texte, re.M ) )
    pilote, charges = {}, defaultdict( int )
    # instance : <cellule> <nom> ( .PIN(net), ... );
    for m in re.finditer( r"^\s*(sg13\w+)\s+(\\\S+|\S+)\s*\((.*?)\);", texte, re.M | re.S ):
        cellule, nom, corps = m.group( 1 ), m.group( 2 ), m.group( 3 )
        broches = re.findall( r"\.(\w+)\s*\(\s*([^()]*?)\s*\)", corps )
        entrees = [ ( b, n ) for b, n in broches if b not in SORTIES and n ]
        for b, n in broches:
            if not n:
                continue
            if b in SORTIES:
                pilote[ n ] = ( cellule, nom, entrees )
            else:
                charges[ n ] += 1
    return ports, pilote, charges

def remonter( net, ports, pilote, charges, prof, ind = "" ):
    nom_port = net.split( "[" )[ 0 ].strip()
    if nom_port in ports or nom_port.lstrip( "\\" ) in { p.lstrip( "\\" ) for p in ports }:
        print( f"{ind}{net}  <- PORT  (sortance {charges[ net ]})" )
        return
    if net not in pilote:
        print( f"{ind}{net}  <- ? (pilote introuvable)  (sortance {charges[ net ]})" )
        return
    cellule, nom, entrees = pilote[ net ]
    print( f"{ind}{net}  <- {cellule} {nom}  (sortance {charges[ net ]})" )
    if "df" in cellule or "dl" in cellule:
        print( f"{ind}   (bascule : arret)" )
        return
    if prof > 0:
        for b, n in entrees:
            print( f"{ind}   .{b}:" )
            remonter( n, ports, pilote, charges, prof - 1, ind + "      " )

if __name__ == "__main__":
    fichier, net = sys.argv[ 1 ], sys.argv[ 2 ]
    prof = int( sys.argv[ 3 ] ) if len( sys.argv ) > 3 else 4
    ports, pilote, charges = lire( fichier )
    remonter( net, ports, pilote, charges, prof )
