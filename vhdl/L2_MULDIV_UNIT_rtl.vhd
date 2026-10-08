library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  MULDIV_UNIT, architecture RTL : multiplieur pipeliné, diviseur itératif.
		--
		--  Une instruction prise par cycle (voie 0), lue au cycle qui suit (étiquettes
		--  vers le fichier, contournement d'abord) :
		--    MUL      lecture et quatre produits partiels de 32 x 32 bits sur les valeurs
		--             absolues ; puis leur somme (128 bits), le signe, le débordement ;
		--             résultat au troisième cycle après la prise. Une MUL par cycle.
		--    CVTIX, CVTXI  le produit des deux premières sources par le même chemin,
		--             puis le diviseur (dividende de 128 bits).
		--    DIV, REMI, MODI  le diviseur (dividende de 64 bits).
		--    autre    faute 137, par le chemin de MUL.
		--  Diviseur : division avec restauration, sur les valeurs
		--  absolues, DIV_BITS bits de quotient par cycle, à partir du premier bit utile
		--  du dividende (les petits dividendes sont rapides) ; puis un cycle pour les
		--  signes, l'arrondi de CVTXI et le débordement. Une seule division à la fois ;
		--  les MUL passent pendant qu'elle travaille. Diviseur nul : faute 128 sans
		--  itération.
		--  Sortie : un résultat par cycle ; celui de MUL d'abord ; une division finie
		--  attend, et aucune MUL n'est prise tant qu'elle attend (au plus deux cycles).
		--  ISSUE_READY_o dépend de l'instruction offerte : une instruction du diviseur
		--  n'entre que diviseur libre et aucune autre en route vers lui.
		--  Reprise : chaque étage oublie son instruction abandonnée au front ; la sortie
		--  est aussi masquée en combinatoire, comme dans INTEGER_UNIT.
		--------------------------------------------------------------------------------
				---
architecture			RTL of MULDIV_UNIT
is				---
   constant OP_MUL		: opcode_t := x"14";
   constant OP_DIV		: opcode_t := x"15";
   constant OP_REMI		: opcode_t := x"16";
   constant OP_MODI		: opcode_t := x"17";
   constant OP_CVTIX	: opcode_t := x"1C";
   constant OP_CVTXI	: opcode_t := x"1D";
   constant DIV_BITS	: positive := 2;					-- bits de quotient par cycle
   constant LIM_POS		: unsigned( 127 downto 0 ) := ( 63 => '1', others => '0' );	-- 2^63

   function IS_DIV( op : opcode_t ) return boolean is				-- par le diviseur seul
   begin
      return op = OP_DIV or op = OP_REMI or op = OP_MODI;
   end function;
   function IS_CVT( op : opcode_t ) return boolean is
   begin
      return op = OP_CVTIX or op = OP_CVTXI;
   end function;
   function NEEDS_DIVIDER( op : opcode_t ) return boolean is
   begin
      return IS_DIV( op ) or IS_CVT( op );
   end function;
   function MAG( x : std_logic_vector( 63 downto 0 ) ) return unsigned is		-- |x|, 64 bits
   begin
      if x( 63 ) = '1' then return unsigned( - signed( x ) ); else return unsigned( x ); end if;
   end function;
   function RESULT_OF( ins : renamed_instruction_t; v : std_logic_vector( 63 downto 0 ); fault : trap_code_t;
                       faulty : boolean ) return exec_result_t is
      variable r : exec_result_t;
   begin
      r.valid := '1';
      r.value := v;
      r.destination := ins.destination;
      r.completion := ( valid => '1', rob_index => ins.rob_index, fault => NO_FAULT,
                        taken => '0', target => ( others => '0' ), mispredicted => '0' );
      if faulty then
         r.destination_valid := '0';
         r.completion.fault := ( valid => '1', code => fault );
      else
         r.destination_valid := ins.destination_valid;
      end if;
      return r;
   end function;

   -- étage de lecture
   signal rd_valid		: boolean;
   signal instr		: renamed_instruction_t;
   signal opd_r		: operand_array_t;				-- opérandes lus (combinatoire)
   -- chemin de MUL (et du produit de CVT) : étage 2, puis sortie
   type pp_t			is array( 0 to 3 ) of unsigned( 63 downto 0 );
   signal m2_valid		: boolean;
   signal m2_instr		: renamed_instruction_t;
   signal m2_pp		: pp_t;
   signal m2_neg		: boolean;					-- signe du produit
   signal m2_c		: std_logic_vector( 63 downto 0 );		-- CVT : le diviseur
   signal m2_fault		: trap_code_t;					-- faute connue à la lecture
   signal m2_faulty		: boolean;
   signal mo		: exec_result_t;				-- sortie de MUL
   -- diviseur
   type dv_state_t		is ( DV_LIBRE, DV_CALCUL, DV_FIN, DV_FAIT );
   signal dv_state		: dv_state_t;
   signal dv_instr		: renamed_instruction_t;
   signal dv_x		: unsigned( 127 downto 0 );			-- dividende, bits de tête en haut
   signal dv_d		: unsigned( 63 downto 0 );			-- |diviseur|
   signal dv_r		: unsigned( 64 downto 0 );			-- reste partiel
   signal dv_q		: unsigned( 127 downto 0 );			-- quotient
   signal dv_left		: natural range 0 to 128;			-- cycles restants
   signal dv_negq		: boolean;					-- signe du quotient
   signal dv_nega		: boolean;					-- signe du dividende
   signal dv_negb		: boolean;					-- signe du diviseur
   signal dv_res		: exec_result_t;				-- division finie
   signal out_r		: exec_result_t;				-- sortie du cycle
   signal take_ok		: boolean;					-- l'instruction offerte entre

begin
		--------------------------------------------------------------------------------
		-- Prise : MUL (et autres) sauf division finie en attente ; instruction du
		-- diviseur : diviseur libre, aucune en route vers lui
		--------------------------------------------------------------------------------
   take_ok <= ( dv_state /= DV_FAIT ) when not NEEDS_DIVIDER( ISSUE_BLOCK_i( 0 ).slot.canon.op )
              else ( dv_state = DV_LIBRE and not ( rd_valid and NEEDS_DIVIDER( instr.slot.canon.op ) )
                     and not ( m2_valid and IS_CVT( m2_instr.slot.canon.op ) ) );
   ISSUE_READY_o <= '1' when take_ok else '0';

		--------------------------------------------------------------------------------
		-- Lecture : étiquettes, opérandes (contournement d'abord)
		--------------------------------------------------------------------------------
   READ_TAGS_o( 0 ) <= instr.source;

   LECTURE : process( instr, READ_DATA_i, BYPASS_i )
      variable opd : operand_array_t;
   begin
      for s in 0 to MAX_SOURCE_COUNT - 1 loop
         opd( s ) := READ_DATA_i( 0 )( s );
         for p in BYPASS_i'range loop
            if BYPASS_i( p ).valid = '1' and BYPASS_i( p ).destination_valid = '1'
               and BYPASS_i( p ).destination = instr.source( s ) then
               opd( s ) := BYPASS_i( p ).value;
            end if;
         end loop;
      end loop;
      opd_r <= opd;
   end process;

		--------------------------------------------------------------------------------
		-- Sortie : MUL d'abord, puis une division finie ; masquée pour une abandonnée
		--------------------------------------------------------------------------------
   out_r <= mo when mo.valid = '1' else dv_res when dv_state = DV_FAIT
            else ( valid => '0', destination_valid => '0', destination => ( others => '0' ), value => ( others => '0' ),
                   completion => ( valid => '0', rob_index => ( others => '0' ), fault => NO_FAULT,
                                   taken => '0', target => ( others => '0' ), mispredicted => '0' ) );

   SORTIE : process( out_r, RECOVERY_i, ROB_HEAD_i )
   begin
      RESULT_o( 0 ) <= out_r;
      if out_r.valid = '0' or ABANDONED( out_r.completion.rob_index, RECOVERY_i, ROB_HEAD_i ) then
         RESULT_o( 0 ).valid <= '0';
      end if;
   end process;

   AUTRES_VOIES : for l in 1 to LANES_G - 1 generate
      READ_TAGS_o( l ) <= ( others => ( others => '0' ) );
      RESULT_o( l ).valid <= '0';
   end generate;

		--------------------------------------------------------------------------------
		-- Étages
		--------------------------------------------------------------------------------
   ETAGES : process( CLK_i )
      variable ua, ub		: unsigned( 63 downto 0 );
      variable sum		: unsigned( 127 downto 0 );
      variable p			: signed( 127 downto 0 );
      variable x		: unsigned( 127 downto 0 );
      variable r		: unsigned( 64 downto 0 );
      variable q		: unsigned( 127 downto 0 );
      variable msb		: integer;
      variable steps		: natural;
      variable rs		: signed( 64 downto 0 );
      variable bs		: signed( 64 downto 0 );
      variable v		: std_logic_vector( 63 downto 0 );
      variable fits		: boolean;
      variable dv_from_mul	: boolean;
      variable mo_used		: boolean;

      -- charge le diviseur : dividende xx (bits utiles comptés), |diviseur| dd
      procedure DV_LOAD( ins : renamed_instruction_t; xx : unsigned( 127 downto 0 ); dd : unsigned( 63 downto 0 );
                         negq, nega, negb : boolean ) is
         variable m : integer := -1;
         variable t : natural;
      begin
         for i in 0 to 127 loop
            if xx( i ) = '1' then m := i; end if;
         end loop;
         t := ( ( m + 1 + DIV_BITS - 1 ) / DIV_BITS ) * DIV_BITS;			-- pas, multiple de DIV_BITS
         dv_instr <= ins; dv_d <= dd; dv_r <= ( others => '0' ); dv_q <= ( others => '0' );
         dv_x <= shift_left( xx, 128 - t ); dv_left <= t / DIV_BITS;
         dv_negq <= negq; dv_nega <= nega; dv_negb <= negb;
         if t = 0 then dv_state <= DV_FIN; else dv_state <= DV_CALCUL; end if;
      end procedure;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            rd_valid <= false; m2_valid <= false; mo.valid <= '0'; dv_state <= DV_LIBRE;
         else
            mo_used := mo.valid = '1';						-- la sortie de ce cycle

            -- étage 2 -> sortie de MUL, ou chargement du diviseur (CVT)
            mo.valid <= '0';
            if m2_valid and not ABANDONED( m2_instr.rob_index, RECOVERY_i, ROB_HEAD_i ) then
               sum := shift_left( resize( m2_pp( 0 ), 128 ), 64 ) + shift_left( resize( m2_pp( 1 ), 128 ), 32 )
                      + shift_left( resize( m2_pp( 2 ), 128 ), 32 ) + resize( m2_pp( 3 ), 128 );
               if m2_faulty then
                  mo <= RESULT_OF( m2_instr, ( others => '0' ), m2_fault, true );
               elsif IS_CVT( m2_instr.slot.canon.op ) then
                  DV_LOAD( m2_instr, sum, MAG( m2_c ), m2_neg /= ( m2_c( 63 ) = '1' ), m2_neg, m2_c( 63 ) = '1' );
               else						-- MUL : signé, sur 64 bits ?
                  if m2_neg then fits := sum <= LIM_POS; p := - signed( sum ); else fits := sum < LIM_POS; p := signed( sum ); end if;
                  if fits then mo <= RESULT_OF( m2_instr, std_logic_vector( p( 63 downto 0 ) ), FAULT_OVERFLOW, false );
                  else mo <= RESULT_OF( m2_instr, ( others => '0' ), FAULT_OVERFLOW, true ); end if;
               end if;
            end if;

            -- lecture -> étage 2 (MUL, CVT, autres) ou diviseur (DIV, REMI, MODI)
            m2_valid <= false;
            if rd_valid and not ABANDONED( instr.rob_index, RECOVERY_i, ROB_HEAD_i ) then
               if IS_DIV( instr.slot.canon.op ) then
                  if unsigned( opd_r( 1 ) ) = 0 then			-- diviseur nul : faute, sans itération
                     dv_instr <= instr; dv_res <= RESULT_OF( instr, ( others => '0' ), FAULT_DIV_ZERO, true );
                     dv_state <= DV_FAIT;
                  else
                     DV_LOAD( instr, resize( MAG( opd_r( 0 ) ), 128 ), MAG( opd_r( 1 ) ),
                              ( opd_r( 0 )( 63 ) = '1' ) /= ( opd_r( 1 )( 63 ) = '1' ),
                              opd_r( 0 )( 63 ) = '1', opd_r( 1 )( 63 ) = '1' );
                  end if;
               else
                  ua := MAG( opd_r( 0 ) ); ub := MAG( opd_r( 1 ) );
                  m2_pp( 0 ) <= ua( 63 downto 32 ) * ub( 63 downto 32 );
                  m2_pp( 1 ) <= ua( 63 downto 32 ) * ub( 31 downto 0 );
                  m2_pp( 2 ) <= ua( 31 downto 0 ) * ub( 63 downto 32 );
                  m2_pp( 3 ) <= ua( 31 downto 0 ) * ub( 31 downto 0 );
                  m2_neg <= ( opd_r( 0 )( 63 ) = '1' ) /= ( opd_r( 1 )( 63 ) = '1' );
                  m2_c <= opd_r( 2 );
                  m2_instr <= instr; m2_valid <= true; m2_faulty <= false; m2_fault <= FAULT_UNDEFINED;
                  if IS_CVT( instr.slot.canon.op ) and unsigned( opd_r( 2 ) ) = 0 then
                     m2_faulty <= true; m2_fault <= FAULT_DIV_ZERO;
                  elsif instr.slot.canon.op /= OP_MUL and not IS_CVT( instr.slot.canon.op ) then
                     m2_faulty <= true; m2_fault <= FAULT_UNDEFINED;		-- pas pour cette unité
                  end if;
               end if;
            end if;

            -- prise -> lecture
            rd_valid <= false;
            if ISSUE_VALID_i = '1' and ISSUE_COUNT_i >= 1 and take_ok
               and not ABANDONED( ISSUE_BLOCK_i( 0 ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
               instr <= ISSUE_BLOCK_i( 0 ); rd_valid <= true;
            end if;

            -- diviseur
            case dv_state is
               when DV_CALCUL =>					-- DIV_BITS pas de restauration
                  x := dv_x; r := dv_r; q := dv_q;
                  for k in 1 to DIV_BITS loop
                     r := r( 63 downto 0 ) & x( 127 ); x := shift_left( x, 1 );
                     if r >= resize( dv_d, 65 ) then r := r - resize( dv_d, 65 ); q := q( 126 downto 0 ) & '1';
                     else q := q( 126 downto 0 ) & '0'; end if;
                  end loop;
                  dv_x <= x; dv_r <= r; dv_q <= q;
                  if dv_left = 1 then dv_state <= DV_FIN; end if;
                  dv_left <= dv_left - 1;
               when DV_FIN =>						-- signes, arrondi, débordement
                  q := dv_q; fits := true; v := ( others => '0' );
                  if dv_instr.slot.canon.op = OP_CVTXI and resize( dv_r, 66 ) + resize( dv_r, 66 ) >= resize( dv_d, 66 ) then
                     q := q + 1;					-- au plus proche, à l'écart de zéro
                  end if;
                  if dv_instr.slot.canon.op = OP_REMI or dv_instr.slot.canon.op = OP_MODI then
                     rs := signed( dv_r ); if dv_nega then rs := - rs; end if;		-- signe du dividende
                     if dv_instr.slot.canon.op = OP_MODI and rs /= 0 and ( rs < 0 ) /= dv_negb then
                        bs := signed( '0' & dv_d ); if dv_negb then bs := - bs; end if;
                        rs := rs + bs;					-- signe du diviseur
                     end if;
                     v := std_logic_vector( rs( 63 downto 0 ) );
                  else
                     if dv_negq then fits := q <= LIM_POS; p := - signed( q ); else fits := q < LIM_POS; p := signed( q ); end if;
                     v := std_logic_vector( p( 63 downto 0 ) );
                  end if;
                  if fits then dv_res <= RESULT_OF( dv_instr, v, FAULT_OVERFLOW, false );
                  else dv_res <= RESULT_OF( dv_instr, ( others => '0' ), FAULT_OVERFLOW, true ); end if;
                  dv_state <= DV_FAIT;
               when DV_FAIT =>						-- sorti si MUL n'avait pas la sortie
                  if not mo_used then dv_state <= DV_LIBRE; end if;
               when DV_LIBRE =>
                  null;
            end case;

            -- reprise : les abandonnées quittent chaque étage (lecture, étage 2 : plus haut ;
            -- la sortie de ce cycle est masquée et remplacée au front ; le diviseur, chargé
            -- seulement libre, oublie la sienne)
            if RECOVERY_i.valid = '1' then
               if dv_state /= DV_LIBRE and ABANDONED( dv_instr.rob_index, RECOVERY_i, ROB_HEAD_i ) then
                  dv_state <= DV_LIBRE;
               end if;
            end if;
         end if;
      end if;
   end process;
		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
