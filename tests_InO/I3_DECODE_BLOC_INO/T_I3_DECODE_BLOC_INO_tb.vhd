library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_I3_DECODE_BLOC_INO_tb : DECODE_BLOC contre les vecteurs de gen_vecteurs_decode
		--  (champs extraits par Decodeur_HX de tx_run, logique de bloc selon l'en-tête
		--  de I3_DECODE_BLOC.vhd, contre-vérifiés par un décodeur indépendant écrit
		--  d'après la spécification).
		--
		--    vecteurs_image.txt    fenêtres pleines dans l'image HX de TLALOC
		--    vecteurs_hasard.txt   flot d'instructions tiré au hasard : opcodes réservés,
		--                          champs illégaux, fenêtres partielles, fautes de lecture
		--
		--  Pour chaque fenêtre : nombre de formes, DECODE_VALID_o, CONSUMED_BYTES_o,
		--  NEED_MORE_BYTES_o, STOP_o ; chaque forme (op, lvl, ofs, val, len, pc, pred
		--  nulle) ; cases au-delà invalides ; CONSUME_o avec DECODE_READY_i à '1' puis
		--  à '0'.
		--------------------------------------------------------------------------------


				------------------
entity				T_I3_DECODE_BLOC_INO_tb
is				------------------
end entity			T_I3_DECODE_BLOC_INO_tb;
				------------------


architecture			TEST
of T_I3_DECODE_BLOC_INO_tb is

   signal window		: decode_window_t := ( others => x"00" );
   signal window_count		: window_count_t := ( others => '0' );
   signal window_pc		: address_t := ( others => '0' );
   signal window_fault		: window_flags_t := ( others => '0' );
   signal decoded		: decoded_block_t;
   signal decoded_count		: decode_count_t;
   signal decode_valid		: std_logic;
   signal decode_ready		: std_logic := '0';
   signal consume		: std_logic;
   signal consumed_bytes	: window_count_t;
   signal need_more		: std_logic;
   signal stop			: std_logic;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

   function S( v : std_logic ) return string is
   begin
      return std_logic'image( v );
   end function;

begin

   DUT : entity work.DECODE_BLOC(IN_ORDER)
      port map (
         WINDOW_i => window, WINDOW_COUNT_i => window_count, WINDOW_PC_i => window_pc,
         WINDOW_FAULT_i => window_fault,
         DECODED_o => decoded, DECODED_COUNT_o => decoded_count, DECODE_VALID_o => decode_valid,
         DECODE_READY_i => decode_ready,
         CONSUME_o => consume, CONSUMED_BYTES_o => consumed_bytes,
         NEED_MORE_BYTES_o => need_more, STOP_o => stop );

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;

      procedure FICHIER( nom : string ) is
         file f		: text;
         variable status	: file_open_status;
         variable l		: line;
         variable tag		: character;
         variable pc		: std_logic_vector( 63 downto 0 );
         variable nb, k	: integer;
         variable bytes	: std_logic_vector( 255 downto 0 );
         variable flags	: std_logic_vector( 0 to DECODE_WINDOW_SIZE - 1 );
         variable consumed, need, stp : integer;
         variable op		: std_logic_vector( 7 downto 0 );
         variable lvl		: std_logic_vector( 3 downto 0 );
         variable ofs		: std_logic_vector( 7 downto 0 );
         variable val		: std_logic_vector( 31 downto 0 );
         variable len		: std_logic_vector( 3 downto 0 );
         variable pos		: integer;
         -- formes d'une fenêtre (vecteurs de la largeur 8)
         type v8_t		is array( 0 to 7 ) of std_logic_vector( 7 downto 0 );
         type v4_t		is array( 0 to 7 ) of std_logic_vector( 3 downto 0 );
         type v32_t		is array( 0 to 7 ) of std_logic_vector( 31 downto 0 );
         type int8_t		is array( 0 to 7 ) of integer;
         variable fop, fofs	: v8_t;
         variable flvl, flen	: v4_t;
         variable fval		: v32_t;
         variable fpos		: int8_t;
         variable where	: line;
         variable windows	: natural := 0;
      begin
         file_open( status, f, nom, read_mode );
         CHECK( c, status = open_ok, "ouverture de " & nom );
         if status /= open_ok then
            return;
         end if;
         while not endfile( f ) loop
            readline( f, l );
            next when l'length = 0 or l( l'left ) = '#';

            -- W pc nb octets drapeaux
            read( l, tag );
            CHECK( c, tag = 'W', nom & " : ligne W attendue" );
            hread( l, pc );
            read( l, nb );
            hread( l, bytes );
            read( l, flags );
            for i in 0 to DECODE_WINDOW_SIZE - 1 loop
               window( i ) <= bytes( 255 - 8 * i downto 248 - 8 * i );
            end loop;
            window_count <= to_unsigned( nb, window_count'length );
            window_pc <= unsigned( pc );
            window_fault <= flags;
            decode_ready <= '1';

            -- R formes consommés need_more stop
            readline( f, l );
            read( l, tag );
            CHECK( c, tag = 'R', nom & " : ligne R attendue" );
            read( l, k ); read( l, consumed ); read( l, need ); read( l, stp );

            -- F op lvl ofs val len position (vecteurs de la largeur 8 : jusqu'à 8 formes)
            for i in 0 to k - 1 loop
               readline( f, l );
               read( l, tag );
               CHECK( c, tag = 'F', nom & " : ligne F attendue" );
               hread( l, op ); hread( l, lvl ); hread( l, ofs ); hread( l, val ); hread( l, len ); read( l, pos );
               fop( i ) := op; flvl( i ) := lvl; fofs( i ) := ofs; fval( i ) := val; flen( i ) := len; fpos( i ) := pos;
            end loop;
            -- largeur DECODE_WIDTH : au plus DECODE_WIDTH formes, coupées à une frontière
            -- d'instruction (une forme de longueur non nulle termine son instruction ; une
            -- instruction peut donner deux formes à la même position) ; la suite n'est pas
            -- consommée (ni besoin d'octets, ni arrêt : la forme qui les donnait n'est pas atteinte)
            if k > DECODE_WIDTH then
               k := DECODE_WIDTH;
               while k > 0 and to_integer( unsigned( flen( k - 1 ) ) ) = 0 loop k := k - 1; end loop;
               consumed := fpos( k ); need := 0; stp := 0;
            elsif k = DECODE_WIDTH then					-- bloc plein : pas de besoin d'octets
               need := 0;
            end if;

            wait for 1 ns;
            deallocate( where );
            write( where, nom & ", fenêtre " & to_hstring( pc ) & " (" & integer'image( nb ) & " octets)" );

            CHECK( c, decoded_count = to_unsigned( k, decoded_count'length ), where.all & " : nombre de formes",
                   integer'image( k ), integer'image( to_integer( decoded_count ) ) );
            CHECK( c, decode_valid = B( k > 0 ), where.all & " : DECODE_VALID_o", S( B( k > 0 ) ), S( decode_valid ) );
            CHECK( c, consumed_bytes = to_unsigned( consumed, consumed_bytes'length ), where.all & " : CONSUMED_BYTES_o",
                   integer'image( consumed ), integer'image( to_integer( consumed_bytes ) ) );
            CHECK( c, need_more = B( need = 1 ), where.all & " : NEED_MORE_BYTES_o", S( B( need = 1 ) ), S( need_more ) );
            CHECK( c, stop = B( stp = 1 ), where.all & " : STOP_o", S( B( stp = 1 ) ), S( stop ) );
            CHECK( c, consume = B( k > 0 ), where.all & " : CONSUME_o (prêt)", S( B( k > 0 ) ), S( consume ) );

            for i in 0 to k - 1 loop
               op := fop( i ); lvl := flvl( i ); ofs := fofs( i ); val := fval( i ); len := flen( i ); pos := fpos( i );
               CHECK( c, decoded( i ).valid = '1', where.all & ", forme " & integer'image( i ) & " : valid" );
               CHECK( c, decoded( i ).canon.op = op and decoded( i ).canon.lvl = unsigned( lvl )
                         and decoded( i ).canon.ofs = unsigned( ofs ) and decoded( i ).canon.val = signed( val )
                         and decoded( i ).canon.len = unsigned( len ),
                      where.all & ", forme " & integer'image( i ) & " : op lvl ofs val len",
                      to_hstring( op ) & " " & to_hstring( lvl ) & " " & to_hstring( ofs ) & " "
                         & to_hstring( val ) & " " & to_hstring( len ),
                      to_hstring( decoded( i ).canon.op ) & " " & to_hstring( decoded( i ).canon.lvl ) & " "
                         & to_hstring( decoded( i ).canon.ofs ) & " " & to_hstring( decoded( i ).canon.val ) & " "
                         & to_hstring( decoded( i ).canon.len ) );
               CHECK( c, decoded( i ).pc = unsigned( pc ) + pos,
                      where.all & ", forme " & integer'image( i ) & " : pc",
                      to_hstring( unsigned( pc ) + pos ), to_hstring( decoded( i ).pc ) );
               CHECK( c, decoded( i ).pred = NO_PREDICTION,
                      where.all & ", forme " & integer'image( i ) & " : pred nulle" );
            end loop;
            for i in k to DECODE_WIDTH - 1 loop
               CHECK( c, decoded( i ).valid = '0', where.all & ", case " & integer'image( i ) & " : invalide" );
            end loop;

            decode_ready <= '0';
            wait for 1 ns;
            CHECK( c, consume = '0', where.all & " : CONSUME_o (pas prêt)", "'0'", S( consume ) );
            windows := windows + 1;
         end loop;
         file_close( f );
         report nom & " : " & integer'image( windows ) & " fenêtres" severity note;
      end procedure;

   begin
      FICHIER( "vecteurs_image.txt" );
      FICHIER( "vecteurs_hasard.txt" );
      FINISH( c, "T_I3_DECODE_BLOC_INO_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
