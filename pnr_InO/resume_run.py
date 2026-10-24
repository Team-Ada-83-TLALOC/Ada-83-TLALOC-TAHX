#!/usr/bin/env python3
# Resume d'un run LibreLane d'une macro, a committer (RESULTATS.txt), comme
# tests_InO/MESURES pour l'IPC : les runs/ ne sont pas suivis par git.
#
# Usage :
#   pnr_InO/resume_run.py pnr_InO/macros/stack_unit_16_8            dernier run
#   pnr_InO/resume_run.py pnr_InO/macros/stack_unit_16_8 RUN_2026-…  run nomme
#   pnr_InO/resume_run.py --tout                                     chaque macro
#   option -n : affiche sans ecrire RESULTATS.txt
#
# Source : runs/<run>/final/metrics.json (metriques OpenROAD / LibreLane). Les
# cles retenues sont choisies par motif ; celles par coin (« __corner:<nom> »)
# sont regroupees. Si aucune ne correspond (version de LibreLane differente), le
# script liste les cles disponibles pour ajuster MOTIFS.
import json, os, re, sys, glob, datetime

ICI = os.path.dirname( os.path.abspath( __file__ ) )

# (motif de cle, libelle) ; l'ordre est celui de l'affichage.
MOTIFS = [
   ( r'^timing__setup__ws$',                   'marge setup (WNS, ns)' ),
   ( r'^timing__setup__tns$',                  'setup TNS (ns)' ),
   ( r'^timing__setup_vio__count$',            'chemins setup en violation' ),
   ( r'^timing__hold__ws$',                    'marge hold (WNS, ns)' ),
   ( r'^timing__hold__tns$',                   'hold TNS (ns)' ),
   ( r'^timing__hold_vio__count$',             'chemins hold en violation' ),
   ( r'^clock__skew__worst_setup$',            'skew (setup, ns)' ),
   ( r'^design__max_slew_violation__count$',   'violations de slew' ),
   ( r'^design__max_cap_violation__count$',    'violations de capacite' ),
   ( r'^design__max_fanout_violation__count$', 'violations de fanout' ),
   ( r'^design__die__area$',                   'surface du die (um2)' ),
   ( r'^design__core__area$',                  'surface du coeur (um2)' ),
   ( r'^design__instance__area$',              'surface des cellules (um2)' ),
   ( r'^design__instance__count$',             'instances' ),
   ( r'^design__instance__utilization$',       'utilisation' ),
   ( r'^route__wirelength$',                   'longueur de fil (um)' ),
   ( r'^route__drc_errors$',                   'erreurs DRC du routeur' ),
   ( r'^antenna__violating__nets$',            'nets en violation d antenne' ),
   ( r'^antenna__violating__pins$',            'broches en violation d antenne' ),
   ( r'^klayout__drc_error__count$',           'erreurs DRC KLayout' ),
   ( r'^magic__drc_error__count$',             'erreurs DRC Magic' ),
   ( r'^power__total$',                        'puissance totale (W)' ),
]

def dernier_run( macro ):
   runs = [ r for r in glob.glob( os.path.join( macro, 'runs', '*' ) )
            if os.path.isfile( os.path.join( r, 'final', 'metrics.json' ) ) ]
   return max( runs, key = os.path.getmtime ) if runs else None

def lire( run ):
   with open( os.path.join( run, 'final', 'metrics.json' ) ) as f:
      return json.load( f )

def resume( macro, run, m ):
   lignes = []
   nom = os.path.basename( os.path.normpath( macro ) )
   date = datetime.datetime.fromtimestamp(
      os.path.getmtime( os.path.join( run, 'final', 'metrics.json' ) ) ).strftime( '%Y-%m-%d %H:%M' )
   lignes.append( f'Macro      : {nom}' )
   lignes.append( f'Run        : {os.path.basename( run )} ({date})' )
   prov = os.path.join( macro, 'PROVENANCE.txt' )
   if os.path.isfile( prov ):
      for l in open( prov ):
         if l.startswith( ( 'RTL', 'Empreinte' ) ):
            lignes.append( l.rstrip() )
   else:
      lignes.append( 'RTL        : inconnu (pas de PROVENANCE.txt)' )
   cfg = os.path.join( macro, 'config.yaml' )
   if os.path.isfile( cfg ):
      for l in open( cfg ):
         if re.match( r'\s*CLOCK_PERIOD\s*:', l ):
            lignes.append( f'Periode    : {l.split( ":", 1 )[ 1 ].strip()} ns (config.yaml)' )
   lignes.append( '' )
   vus = 0
   for motif, libelle in MOTIFS:
      for k in sorted( m ):
         base = k.split( '__corner:' )[ 0 ]
         if re.match( motif, base ):
            coin = k.split( '__corner:' )[ 1 ] if '__corner:' in k else 'tous coins'
            v = m[ k ]
            if isinstance( v, float ):
               v = f'{v:.6g}'
            lignes.append( f'{libelle:34s} {coin:28s} {v}' )
            vus += 1
   if vus == 0:
      lignes.append( 'Aucune metrique reconnue ; cles disponibles :' )
      lignes += [ '  ' + k for k in sorted( m ) ]
   return '\n'.join( lignes ) + '\n'

def un( macro, nom_run, ecrire ):
   run = os.path.join( macro, 'runs', nom_run ) if nom_run else dernier_run( macro )
   if not run or not os.path.isfile( os.path.join( run, 'final', 'metrics.json' ) ):
      print( f'{macro} : aucun run termine (runs/*/final/metrics.json)' )
      return
   texte = resume( macro, run, lire( run ) )
   print( texte )
   if ecrire:
      with open( os.path.join( macro, 'RESULTATS.txt' ), 'w' ) as f:
         f.write( texte )

def main():
   args = sys.argv[ 1: ]
   ecrire = '-n' not in args
   args = [ a for a in args if a != '-n' ]
   if args[ :1 ] == [ '--tout' ]:
      for macro in sorted( glob.glob( os.path.join( ICI, 'macros', '*' ) ) ):
         if os.path.isdir( macro ):
            un( macro, None, ecrire )
   elif args:
      un( args[ 0 ], args[ 1 ] if len( args ) > 1 else None, ecrire )
   else:
      print( __doc__ or 'usage : resume_run.py <macro> [run] | --tout [-n]' )
      return 2

if __name__ == '__main__':
   sys.exit( main() )
