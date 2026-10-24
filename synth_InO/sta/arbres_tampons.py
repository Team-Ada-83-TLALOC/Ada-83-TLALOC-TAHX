#!/usr/bin/env python3
# Remplace les echelles de tampons d'ABC par des arbres equilibres.
#
# Avec -constr, ABC limite la sortance a 10 en chainant des tampons : un net de
# sortance 200 devient une echelle de 20 buf_1 en serie, et la derniere charge voit
# 20 retards de tampon (8 a 9 ns au coin typ sur le chemin de chainage). ABC
# synthetise chaque macro seule, sans les temps d'arrivee entre macros : il ne sait
# pas quelle charge est critique. Un flot place-route (repair_design d'OpenROAD)
# reconstruit ces reseaux en arbres. Ce script fait de meme sur la netlist, pour que
# l'estimation d'OpenSTA ne compte pas ce defaut de synthese.
#
# Usage : arbres_tampons.py tahx_1_sg13.v tahx_1_sg13_arbres.v [sortance]
#   Chaque grappe de tampons (tampons dont la sortie, net interne _N_, n'alimente
#   que des broches simples) est supprimee ; ses charges finales sont reparties en
#   un arbre de buf_4 (feuilles) et buf_8 (niveaux superieurs) de sortance donnee
#   (defaut 8), attache au net d'entree de la grappe.
import re, sys, math

ENTREE, SORTIE = sys.argv[ 1 ], sys.argv[ 2 ]
SORTANCE = int( sys.argv[ 3 ] ) if len( sys.argv ) > 3 else 8
BUF = re.compile( r'^sg13cmos5l_buf_\d+$' )
AUTO = re.compile( r'^_\d+_$' )
TETE = re.compile( r'^  (\S+) (\S+ ?) \($' )
def ex( e ):
   # Un identificateur echappe (\a.b[3]) se termine par une espace.
   return e + ' ' if re.search( r'\\\S+$', e ) else e
BROCHE = re.compile( r'^    \.(\\\S+ |\w+)\((.*)\),?$' )

def traite_module( lignes ):
   # Instances : [ type, nom, [ [ broche, expr ], ... ] ] ; autres lignes gardees.
   corps = []
   insts = []
   i = 0
   while i < len( lignes ):
      m = TETE.match( lignes[ i ] )
      if m and not lignes[ i ].startswith( '  module' ):
         broches = []
         j = i + 1
         while lignes[ j ].strip() != ');':
            b = BROCHE.match( lignes[ j ] )
            if not b:
               raise SystemExit( f'ligne inattendue : {lignes[ j ]!r}' )
            broches.append( [ b[ 1 ], b[ 2 ].strip() ] )
            j += 1
         insts.append( [ m[ 1 ], m[ 2 ], broches ] )
         corps.append( ( 'inst', len( insts ) - 1 ) )
         i = j + 1
      else:
         corps.append( ( 'ligne', lignes[ i ] ) )
         i += 1

   # Nets internes _N_ que l'on peut deplacer : references uniquement comme
   # broche simple d'instance (pas dans un assign, une concatenation, un port).
   interdits = set()
   for k, v in corps:
      if k == 'ligne':
         for t in re.findall( r'_\d+_', v ):
            if not v.lstrip().startswith( 'wire' ):
               interdits.add( t )
   charges = {}       # net -> [ ( inst, indice de broche ) ] hors sortie de tampon
   sortie_de = {}     # net -> inst du tampon qui le pilote
   for n, ( typ, nom, broches ) in enumerate( insts ):
      for p, ( broche, e ) in enumerate( broches ):
         if not AUTO.match( e ):
            for t in re.findall( r'_\d+_', e ):
               interdits.add( t )
            continue
         if BUF.match( typ ) and broche == 'X':
            sortie_de[ e ] = n
         else:
            charges.setdefault( e, [] ).append( ( n, p ) )

   def eligible( n ):
      typ, nom, broches = insts[ n ]
      d = dict( broches )
      return BUF.match( typ ) and AUTO.match( d.get( 'X', '' ) ) and d[ 'X' ] not in interdits

   # Grappes : depuis chaque tampon eligible dont l'entree n'est pas la sortie d'un
   # tampon eligible.
   supprimes = set()
   nouveaux_fils = []
   nouvelles_insts = []
   nb = 0
   for n in range( len( insts ) ):
      if not eligible( n ):
         continue
      a = dict( insts[ n ][ 2 ] )[ 'A' ]
      if a in sortie_de and eligible( sortie_de[ a ] ):
         continue
      grappe = []
      finales = []
      pile = [ n ]
      while pile:
         b = pile.pop()
         grappe.append( b )
         x = dict( insts[ b ][ 2 ] )[ 'X' ]
         for ( c, p ) in charges.get( x, [] ):
            if eligible( c ) and insts[ c ][ 2 ][ p ][ 0 ] == 'A':
               pile.append( c )
            else:
               finales.append( ( c, p ) )
      if len( grappe ) < 2 or not finales:
         continue
      # Arbre : feuilles de SORTANCE charges en buf_4, puis niveaux en buf_8.
      for b in grappe:
         supprimes.add( b )
      niveau = finales
      typ = 'sg13cmos5l_buf_4'
      while True:
         groupes = [ niveau[ k:k + SORTANCE ] for k in range( 0, len( niveau ), SORTANCE ) ]
         suivant = []
         for g in groupes:
            nb += 1
            fil = f'_arbre{nb}_'
            nouveaux_fils.append( fil )
            for ( c, p ) in g:
               if c == 'nouvelle':
                  nouvelles_insts[ p ][ 2 ][ 0 ][ 1 ] = fil
               else:
                  insts[ c ][ 2 ][ p ][ 1 ] = fil
            nouvelles_insts.append( [ typ, f'_arbre{nb}_b_', [ [ 'A', None ], [ 'X', fil ] ] ] )
            suivant.append( ( 'nouvelle', len( nouvelles_insts ) - 1 ) )
         typ = 'sg13cmos5l_buf_8'
         if len( suivant ) <= 1:
            break
         niveau = suivant
      for ( c, p ) in suivant:
         nouvelles_insts[ p ][ 2 ][ 0 ][ 1 ] = a

   sortie = []
   for k, v in corps:
      if k == 'ligne':
         if v.startswith( 'endmodule' ):
            for typ, nom, broches in nouvelles_insts:
               sortie.append( f'  {typ} {nom} (' )
               sortie.append( ',\n'.join( f'    .{b}({ex( e )})' for b, e in broches ) )
               sortie.append( '  );' )
         sortie.append( v )
         if re.match( r'^module ', v ) and v.rstrip().endswith( ';' ):
            sortie += [ f'  wire {fil};' for fil in nouveaux_fils ]
      elif v not in supprimes:
         typ, nom, broches = insts[ v ]
         sortie.append( f'  {typ} {nom} (' )
         sortie.append( ',\n'.join( f'    .{b}({ex( e )})' for b, e in broches ) )
         sortie.append( '  );' )
   return sortie, len( supprimes ), len( nouvelles_insts )

lignes = open( ENTREE ).read().split( '\n' )
res = []
module = None
for l in lignes:
   if module is None:
      if l.startswith( 'module ' ):
         module = [ l ]
      else:
         res.append( l )
   else:
      module.append( l )
      if l.startswith( 'endmodule' ):
         # La declaration du module peut tenir sur plusieurs lignes : la ramener a
         # une seule pour placer les nouveaux fils juste apres.
         k = 0
         while not module[ k ].rstrip().endswith( ');' ):
            k += 1
         tete = ' '.join( x.strip() for x in module[ :k + 1 ] )
         nom = tete.split()[ 1 ].split( '(' )[ 0 ]
         s, ns, nn = traite_module( [ tete[ :-1 ] + ';' ] + module[ k + 1: ] )
         print( f'{nom:24s} tampons supprimes {ns:6d}, tampons d arbre {nn:6d}' )
         res += s
         module = None
open( SORTIE, 'w' ).write( '\n'.join( res ) )
