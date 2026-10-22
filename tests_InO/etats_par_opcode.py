#!/usr/bin/env python3
# Resume des compteurs d'etats de V0 (N3_INO_PLATEFORME) sur les bancs mesures.
#
# Usage (depuis tests_InO/) :
#   python3 etats_par_opcode.py                    MESURES/B_*.txt, 25 opcodes
#   python3 etats_par_opcode.py -n 40 MESURES/G10/B_*.txt
#
# Pour chaque fichier : verifie que, pour chaque opcode et chaque unite, la somme
# des cycles par etat (PERF OPETAT) vaut lat_sum (PERF OP). Puis, sur l'ensemble :
#   - famine du frontal selon l'evenement qui la precede ;
#   - cycles par etat de chaque unite (STACK, M2, CACHE) ;
#   - pour les opcodes qui coutent le plus de cycles : nombre, latence moyenne et
#     cycles moyens par etat de la STACK_UNIT, plus les etats occupes de M2 et du
#     cache (hors ST_IDLE / LIBRE).
import collections, glob, os, re, sys

ICI = os.path.dirname( os.path.abspath( __file__ ) )
UNITES = ( 'STACK', 'M2', 'CACHE' )
REPOS = { 'M2': 'ST_IDLE', 'CACHE': 'LIBRE' }

def mnemoniques():
    noms = {}
    table = os.path.join( ICI, '..', 'vhdl', 'A__TAHX_1_isa_table.vhd' )
    for l in open( table, encoding = 'utf-8' ):
        m = re.match( r'\s*16#(\w\w)# => \(\w+, \d, (FMT_\w+),.*--\s*\d+\s+(\S+)', l )
        if m:
            fmt = m.group( 2 )[ 4: ]
            noms[ int( m.group( 1 ), 16 ) ] = m.group( 3 ) + ( '' if fmt == 'NONE' else f' [{fmt}]' )
    return noms

def lire( fichier ):
    r = { 'op': {}, 'opetat': collections.defaultdict( dict ), 'etat': {}, 'famine': {}, 'cycles': 0, 'retraits': 0 }
    for l in open( fichier, encoding = 'utf-8' ):
        m = re.match( r'PERF T_\S+ : (\d+) cycles, (\d+) retraits', l )
        if m:
            r[ 'cycles' ], r[ 'retraits' ] = int( m.group( 1 ) ), int( m.group( 2 ) )
        m = re.match( r'PERF OP (\w\w) count (\d+) lat_sum (\d+)', l )
        if m:
            r[ 'op' ][ int( m.group( 1 ), 16 ) ] = ( int( m.group( 2 ) ), int( m.group( 3 ) ) )
        m = re.match( r'PERF OPETAT (\w\w) (\w+)(.*)', l )
        if m:
            r[ 'opetat' ][ int( m.group( 1 ), 16 ) ][ m.group( 2 ) ] = \
                { e: int( n ) for e, n in re.findall( r'(\w+)=(\d+)', m.group( 3 ) ) }
        m = re.match( r'PERF ETAT (\w+) (\w+) cycles (\d+) entrees (\d+)', l )
        if m:
            r[ 'etat' ][ ( m.group( 1 ), m.group( 2 ) ) ] = ( int( m.group( 3 ) ), int( m.group( 4 ) ) )
        m = re.match( r'PERF famine (apres reprise|apres transfert pris bien predit|autre)\D*(\d+) / (\d+)', l )
        if m:
            r[ 'famine' ][ m.group( 1 ) ] = ( int( m.group( 2 ) ), int( m.group( 3 ) ) )
    return r

def main():
    args = sys.argv[ 1: ]
    top = 25
    if args[ :1 ] == [ '-n' ]:
        top, args = int( args[ 1 ] ), args[ 2: ]
    fichiers = args or sorted( glob.glob( os.path.join( ICI, 'MESURES', 'B_*.txt' ) ) )
    noms = mnemoniques()

    op = collections.Counter(); lat = collections.Counter()
    opetat = collections.defaultdict( collections.Counter )
    etat = collections.Counter(); entrees = collections.Counter()
    famine = collections.defaultdict( lambda: [ 0, 0 ] )
    cycles = retraits = 0
    erreurs = 0
    for f in fichiers:
        r = lire( f )
        if not r[ 'opetat' ]:
            print( f'{f} : pas de compteurs d\'etats (mesure anterieure a V0)' )
            continue
        cycles += r[ 'cycles' ]; retraits += r[ 'retraits' ]
        for o, ( n, s ) in r[ 'op' ].items():
            op[ o ] += n; lat[ o ] += s
            for u in UNITES:
                d = r[ 'opetat' ][ o ].get( u, {} )
                if sum( d.values() ) != s:
                    erreurs += 1
                    print( f'{os.path.basename( f )} : OP {o:02X} {u} : somme des etats {sum( d.values() )} /= lat_sum {s}' )
                for e, c in d.items():
                    opetat[ ( o, u ) ][ e ] += c
        for k, ( c, n ) in r[ 'etat' ].items():
            etat[ k ] += c; entrees[ k ] += n
        for k, ( c, n ) in r[ 'famine' ].items():
            famine[ k ][ 0 ] += c; famine[ k ][ 1 ] += n
    if not cycles:
        return 1

    print( f'{len( fichiers )} banc(s) : {cycles} cycles, {retraits} retraits, IPC {retraits / cycles:.3f}'
           + ( '' if erreurs == 0 else f', {erreurs} INCOHERENCE(S)' ) )
    print( '\nFamine du frontal (cycles / episodes)' )
    for k, ( c, n ) in famine.items():
        print( f'  {k:36s} {c:8d} / {n:6d}' + ( f'  ({c / n:.1f} par episode)' if n else '' ) )

    for u in UNITES:
        print( f'\nEtats de {u} (cycles, part des cycles, entrees, cycles par entree)' )
        for ( uu, e ), c in sorted( etat.items(), key = lambda x: -x[ 1 ] ):
            if uu == u and c:
                n = entrees[ ( uu, e ) ]
                print( f'  {e:24s} {c:9d} {100 * c / cycles:6.1f} % {n:9d} {c / max( n, 1 ):6.2f}' )

    print( f'\nOpcodes les plus couteux ({top}) : cycles moyens par etat de la STACK_UNIT ;'
           ' M2 et CACHE hors repos' )
    for o in sorted( lat, key = lambda o: -lat[ o ] )[ :top ]:
        n = op[ o ]
        print( f'\n  {o:02X} {noms.get( o, "?" ):14s} n={n:7d} lat={lat[ o ] / n:6.2f}'
               f'  {100 * lat[ o ] / cycles:5.1f} % des cycles' )
        for u in UNITES:
            d = { e: c / n for e, c in opetat[ ( o, u ) ].items() if e != REPOS.get( u ) and c / n >= 0.005 }
            if d:
                print( f'     {u:5s} ' + '  '.join( f'{e}={v:.2f}' for e, v in d.items() ) )
    return 1 if erreurs else 0

if __name__ == '__main__':
    sys.exit( main() )
