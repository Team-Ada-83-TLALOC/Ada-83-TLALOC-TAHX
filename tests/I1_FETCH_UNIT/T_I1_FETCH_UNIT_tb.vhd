library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.MEMOIRE_PKG.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_I1_FETCH_UNIT_tb : le contrat de l'en-tête de I1_FETCH_UNIT.
		--
		--  Mémoire : MEMOIRE_INSTRUCTIONS (tests/commun), contenu MEMOIRE_PKG, latence
		--  tirée de 1 à 20 cycles. Le banc joue FETCH_BYTE_QUEUE (FETCH_READY_i au
		--  hasard), BRANCH_PREDICT (sauts, souvent vers quelques adresses chaudes pour
		--  que le cache serve), DECODE_BLOC (STOP_i) et le ROB (reprises, dont celle du
		--  démarrage). Chaque cycle :
		--    - FLUSH_o = reprise, ou prédiction, ou STOP_i, et alors FETCH_VALID_o = '0' ;
		--    - pas de bloc avant le démarrage ni après un STOP_i ;
		--    - bloc pris : adresse attendue (consécutifs, redirections), nombre
		--      d'octets, octets et faute selon MEMOIRE_PKG ;
		--    - un bloc attendu arrive en moins de MAX_WAIT cycles où la file accepte.
		--------------------------------------------------------------------------------


				-----------------
entity				T_I1_FETCH_UNIT_tb
is				-----------------
end entity			T_I1_FETCH_UNIT_tb;
				-----------------


architecture			TEST
of T_I1_FETCH_UNIT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant CYCLES		: positive	:= 60000;
   constant MAX_WAIT		: positive	:= 400;
   constant SEED_1		: positive	:= 1665;
   constant SEED_2		: positive	:= 1789;
   constant REGION		: natural	:= 16#400000#;
   constant REGION_SIZE	: natural	:= 65536;				-- plus grand que le cache
   constant HOT		: positive	:= 24;				-- cibles chaudes

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal i_req, i_ready, i_rvalid, i_fault : std_logic;
   signal i_addr		: address_t;
   signal i_rdata		: word64_t;
   signal accepted		: natural;
   signal fetch_valid		: std_logic;
   signal fetch_pc		: address_t;
   signal fetch_block		: fetch_block_t;
   signal fetch_count		: fetch_count_t;
   signal fetch_ready		: std_logic := '0';
   signal fetch_fault		: std_logic;
   signal recovery		: recovery_t := NO_RECOVERY;
   signal predict_valid	: std_logic := '0';
   signal predict_pc		: address_t := ( others => '0' );
   signal stop			: std_logic := '0';
   signal flush		: std_logic;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.FETCH_UNIT
      port map (
         CLK_i => clk, RESET_i => reset,
         I_REQ_o => i_req, I_ADDR_o => i_addr, I_READY_i => i_ready,
         I_RVALID_i => i_rvalid, I_RDATA_i => i_rdata, I_FAULT_i => i_fault,
         FETCH_VALID_o => fetch_valid, FETCH_PC_o => fetch_pc, FETCH_BLOCK_o => fetch_block,
         FETCH_COUNT_o => fetch_count, FETCH_READY_i => fetch_ready, FETCH_FAULT_o => fetch_fault,
         RECOVERY_i => recovery, PREDICT_VALID_i => predict_valid, PREDICT_PC_i => predict_pc,
         STOP_i => stop, FLUSH_o => flush );

   MEMOIRE : entity work.MEMOIRE_INSTRUCTIONS
      generic map ( LATENCY_MIN_G => 1, LATENCY_MAX_G => 20, READY_PROB_G => 0.8, SEED_1_G => 11, SEED_2_G => 12 )
      port map ( CLK_i => clk, I_REQ_i => i_req, I_ADDR_i => i_addr, I_READY_o => i_ready,
                 I_RVALID_o => i_rvalid, I_RDATA_o => i_rdata, I_FAULT_o => i_fault, ACCEPTED_o => accepted );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + 100 );
      if running then
         report "TEST T_I1_FETCH_UNIT_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      variable active		: boolean := false;			-- chargement en cours (modèle)
      variable expected		: address_t := ( others => '0' );	-- adresse du prochain bloc
      variable waited		: natural := 0;				-- cycles d'attente, file prête
      variable do_rec, do_pred, do_stop, take : boolean;
      variable target, pred_target : address_t;
      variable n_both		: natural := 0;				-- reprise et autre redirection
      variable cnt		: natural;
      variable got, exp		: std_logic_vector( 8 * FETCH_BLOCK_SIZE - 1 downto 0 );
      variable rec		: recovery_t;
      variable ok		: boolean;
      variable n_blocks, n_faulty, n_rec, n_pred, n_stop, longest_wait : natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is		-- 0 .. m
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

      impure function NEW_TARGET return address_t is
      begin
         if RAND < 0.7 then							-- cible chaude
            return to_unsigned( REGION + 997 * RAND_INT( HOT - 1 ), 64 );
         else
            return to_unsigned( REGION + RAND_INT( REGION_SIZE - 1 ), 64 );
         end if;
      end function;

   begin
      s2 := SEED_2;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES loop

		-- redirections du cycle
		-- tirées indépendamment : reprise, prédiction et arrêt peuvent coïncider ;
		-- le contrat dit lequel l'emporte
         do_rec := ( not active and RAND < 0.05 ) or RAND < 0.004;
         do_pred := active and RAND < 0.03;
         do_stop := active and RAND < 0.002;
         if do_rec and active and RAND < 0.3 then				-- prédiction du mauvais chemin
            do_pred := true;						-- au cycle de la reprise
         end if;
         target := NEW_TARGET;
         pred_target := NEW_TARGET;
         rec := NO_RECOVERY;
         if do_rec then
            rec.valid := '1';
            rec.kind := RECOVER_CHECKPOINT;
            rec.new_pc := target;
         end if;
         recovery <= rec;
         predict_valid <= B( do_pred );
         predict_pc <= pred_target;
         if do_rec and ( do_pred or do_stop ) then n_both := n_both + 1; end if;
         stop <= B( do_stop );
         fetch_ready <= B( RAND < 0.75 );
         wait for 1 ns;

		-- vérifications
         if flush = B( do_rec or do_pred or do_stop ) then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : FLUSH_o",
                   std_logic'image( B( do_rec or do_pred or do_stop ) ), std_logic'image( flush ) );
         end if;
         if fetch_valid = '1' then
            if flush = '1' or not active then
               CHECK( c, false, "cycle " & integer'image( cycle ) & " : bloc présenté pendant un vidage ou à l'arrêt" );
            else
               cnt := FETCH_BLOCK_SIZE - to_integer( expected( 4 downto 0 ) );
               got := ( others => '0' ); exp := ( others => '0' );
               if fetch_fault = '0' then
                  for i in 0 to FETCH_BLOCK_SIZE - 1 loop
                     if i < cnt then
                        got( 8 * i + 7 downto 8 * i ) := fetch_block( i );
                        exp( 8 * i + 7 downto 8 * i ) := MEM_BYTE( expected + i );
                     end if;
                  end loop;
               end if;
               ok := fetch_pc = expected and fetch_count = to_unsigned( cnt, fetch_count'length )
                     and fetch_fault = MEM_FAULT( expected ) and got = exp;
               if ok then CHECK_PASSED( c ); else
                  CHECK( c, false, "cycle " & integer'image( cycle ) & " : bloc",
                         HEX( expected ) & " (" & integer'image( cnt ) & " octets, faute "
                            & std_logic'image( MEM_FAULT( expected ) ) & ")",
                         HEX( fetch_pc ) & " (" & integer'image( to_integer( fetch_count ) ) & " octets, faute "
                            & std_logic'image( fetch_fault ) & ")" );
               end if;
            end if;
         end if;
         take := fetch_valid = '1' and fetch_ready = '1';

		-- front : le modèle suit le contrat
         wait until rising_edge( clk );
         if active and fetch_ready = '1' and not take and not ( do_rec or do_pred or do_stop ) then
            waited := waited + 1;
         end if;
         if take then
            if waited > longest_wait then longest_wait := waited; end if;
            waited := 0;
            n_blocks := n_blocks + 1;
            if MEM_FAULT( expected ) = '1' then n_faulty := n_faulty + 1; end if;
            expected := expected + ( FETCH_BLOCK_SIZE - to_integer( expected( 4 downto 0 ) ) );
         end if;
         if do_rec then
            active := true; expected := target; waited := 0; n_rec := n_rec + 1;
         elsif do_pred then
            expected := pred_target; waited := 0; n_pred := n_pred + 1;
         elsif do_stop then
            active := false; waited := 0; n_stop := n_stop + 1;
         end if;
         if waited > MAX_WAIT then
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : aucun bloc depuis "
                             & integer'image( MAX_WAIT ) & " cycles où la file acceptait" );
            waited := 0;
         end if;
         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; blocs pris "
             & integer'image( n_blocks ) & " (en faute " & integer'image( n_faulty ) & "), mots demandés "
             & integer'image( accepted ) & ", reprises " & integer'image( n_rec ) & ", prédictions "
             & integer'image( n_pred ) & ", arrêts " & integer'image( n_stop ) & ", attente maximale "
             & integer'image( longest_wait ) & " cycles" severity note;
      report "reprises coïncidant avec une prédiction ou un arrêt : " & integer'image( n_both ) severity note;
      CHECK( c, n_blocks > 10000 and n_faulty > 50 and n_stop > 20 and n_both > 10 and accepted < 4 * n_blocks,
             "le tirage a exercé blocs, fautes, arrêts, et le cache sert" );
      FINISH( c, "T_I1_FETCH_UNIT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
