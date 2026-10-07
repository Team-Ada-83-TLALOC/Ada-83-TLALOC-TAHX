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

		--------------------------------------------------------------------------------
		--  BRANCH_PREDICT, architecture RTL : modèle de référence.
		--
		--  Dans le cycle : PREDICTION parcourt les cases avec une copie de l'état
		--  (historique, sommet, pile), coupe le bloc et calcule la redirection.
		--  Au front : apprentissage (retraits dans l'ordre ; deux retraits du même
		--  compteur s'enchaînent), puis reprise ou avance de l'état si le bloc passe.
		--  Une réalisation (table à quelques ports, apprentissage différé) devra passer
		--  le même banc (tests/I4_BRANCH_PREDICT).
		--------------------------------------------------------------------------------


				---
architecture			RTL
of BRANCH_PREDICT is		---

   constant GSHARE		: positive := 2 ** ghist_t'length;
   constant OP_CALLI		: opcode_t := x"33";

   type counter_array_t	is array( 0 to GSHARE - 1 ) of natural range 0 to 3;
   type ras_array_t		is array( 0 to RAS_DEPTH - 1 ) of address_t;

   signal counters		: counter_array_t := ( others => 1 );
   signal ghist		: ghist_t;
   signal ras			: ras_array_t := ( others => ( others => '0' ) );
   signal ras_ptr		: natural range 0 to RAS_DEPTH - 1;

   -- état après le bloc (coupé), pour le front
   signal next_ghist		: ghist_t;
   signal next_ras		: ras_array_t;
   signal next_ras_ptr		: natural range 0 to RAS_DEPTH - 1;
   signal out_cnt		: natural range 0 to DECODE_WIDTH;
   -- apprentissage de la table de blocs : point d'entrée, événement du bloc
   signal dentry		: address_t;
   signal next_dentry		: address_t;
   signal tr_valid, tr_taken	: std_logic;
   signal tr_key, tr_fin, tr_target : address_t;
   signal c_valid, c_taken	: std_logic;
   signal c_key, c_fin, c_target : address_t;

   function IS_BRANCH_COND( op : opcode_t ) return boolean is			-- BT, BF : E4 .. EB
   begin
      return unsigned( op ) >= 16#E4# and unsigned( op ) <= 16#EB#;
   end function;

   function IS_BRA( op : opcode_t ) return boolean is				-- E0 .. E3
   begin
      return unsigned( op ) >= 16#E0# and unsigned( op ) <= 16#E3#;
   end function;

   function INDEX( pc : address_t; h : ghist_t ) return natural is
   begin
      return to_integer( unsigned( std_logic_vector( pc( 15 downto 0 ) ) xor h ) );
   end function;

begin

   OUT_VALID_o	<= IN_VALID_i;
   IN_READY_o		<= OUT_READY_i;
   OUT_COUNT_o	<= to_unsigned( out_cnt, OUT_COUNT_o'length );
   TRAIN_VALID_o	<= tr_valid;
   TRAIN_TAKEN_o	<= tr_taken;
   TRAIN_KEY_o		<= tr_key;
   TRAIN_FIN_o		<= tr_fin;
   TRAIN_TARGET_o	<= tr_target;

		--------------------------------------------------------------------------------
		-- 2. prédiction, case par case
		--------------------------------------------------------------------------------

   PREDICTION : process( IN_BLOCK_i, IN_COUNT_i, IN_VALID_i, OUT_READY_i, counters, ghist, ras, ras_ptr, dentry )
      variable g	: ghist_t;
      variable p	: natural range 0 to RAS_DEPTH - 1;
      variable rs	: ras_array_t;
      variable blk	: decoded_block_t;
      variable n	: natural range 0 to DECODE_WIDTH;
      variable taken	: boolean;
      variable target	: address_t;
      variable op	: opcode_t;
      variable redirect : boolean := false;
      variable redirect_pc : address_t;
      variable e, fin	: address_t;					-- point d'entrée, fin d'instruction
      variable cv, ct	: std_logic;
      variable ck, cf, cg : address_t;
   begin
      e := dentry; cv := '0'; ct := '0'; ck := ( others => '0' ); cf := ( others => '0' ); cg := ( others => '0' );
      g := ghist; p := ras_ptr; rs := ras;
      blk := IN_BLOCK_i;
      n := to_integer( IN_COUNT_i );
      if n > DECODE_WIDTH then n := DECODE_WIDTH; end if;
      redirect := false;
      redirect_pc := ( others => '0' );

      for i in 0 to DECODE_WIDTH - 1 loop
         exit when i >= n;
         op := blk( i ).canon.op;
         target := blk( i ).pc + blk( i ).canon.len + unsigned( resize( blk( i ).canon.val, 64 ) );
         fin := blk( i ).pc + blk( i ).canon.len - 1;
         if e( 63 downto 5 ) /= fin( 63 downto 5 ) then e := fin( 63 downto 5 ) & "00000"; end if;
         blk( i ).pred := NO_PREDICTION;
         blk( i ).pred.ghist := g;
         blk( i ).pred.ras_ptr := to_unsigned( p, ras_ptr_t'length );
         taken := false;
         if IS_BRANCH_COND( op ) then
            taken := counters( INDEX( blk( i ).pc, g ) ) >= 2;
            if not taken and cv = '0' then cv := '1'; ct := '0'; ck := e; cf := fin; end if;
            blk( i ).pred.target := target;
            if taken then
               g := g( g'high - 1 downto 0 ) & '1';
            else
               g := g( g'high - 1 downto 0 ) & '0';
            end if;
         elsif IS_BRA( op ) then
            taken := true;
            blk( i ).pred.target := target;
         elsif op = OP_CALL or op = OP_CALLI then
            if op = OP_CALL then
               taken := true;
               blk( i ).pred.target := target;
            end if;
            rs( p ) := blk( i ).pc + blk( i ).canon.len;
            p := ( p + 1 ) mod RAS_DEPTH;
         elsif op = OP_RTD_0 or op = OP_RTD_N then
            p := ( p + RAS_DEPTH - 1 ) mod RAS_DEPTH;
            taken := true;
            blk( i ).pred.target := rs( p );
         end if;
         if taken then
            blk( i ).pred.taken := '1';
            n := i + 1;							-- coupe après la première prise
            redirect := true;
            redirect_pc := blk( i ).pred.target;
            cv := '1'; ct := '1'; ck := e; cf := fin; cg := blk( i ).pred.target;
            e := blk( i ).pred.target;					-- point d'entrée suivant
            exit;
         end if;
      end loop;

      OUT_BLOCK_o	<= blk;
      out_cnt		<= n;
      next_ghist	<= g;
      next_ras		<= rs;
      next_ras_ptr	<= p;
      PREDICT_PC_o	<= redirect_pc;
      next_dentry	<= e;
      c_valid <= cv; c_taken <= ct; c_key <= ck; c_fin <= cf; c_target <= cg;
      if redirect and IN_VALID_i = '1' and OUT_READY_i = '1' then
         PREDICT_VALID_o <= '1';
      else
         PREDICT_VALID_o <= '0';
      end if;
   end process;

		--------------------------------------------------------------------------------
		-- 3., 4. au front
		--------------------------------------------------------------------------------

   ETAT : process( CLK_i )
      type update_t is record
         idx	: natural range 0 to GSHARE - 1;
         val	: natural range 0 to 3;
      end record;
      type update_array_t is array( 0 to RETIRE_WIDTH - 1 ) of update_t;
      variable upd	: update_array_t;
      variable nu	: natural range 0 to RETIRE_WIDTH;
      variable v	: natural range 0 to 3;
      variable idx	: natural range 0 to GSHARE - 1;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            counters <= ( others => 1 );
            ghist <= ( others => '0' );
            ras <= ( others => ( others => '0' ) );
            ras_ptr <= 0;
            dentry <= ( others => '0' );
            tr_valid <= '0';
         else
            -- apprentissage : un retrait voit les précédents du même cycle
            nu := 0;
            for k in 0 to RETIRE_WIDTH - 1 loop
               if RETIRE_i( k ).valid = '1' and RETIRE_i( k ).is_control = '1' and RETIRE_i( k ).conditional = '1' then
                  idx := INDEX( RETIRE_i( k ).pc, RETIRE_i( k ).ghist );
                  v := counters( idx );
                  for j in 0 to RETIRE_WIDTH - 1 loop
                     if j < nu and upd( j ).idx = idx then
                        v := upd( j ).val;
                     end if;
                  end loop;
                  if RETIRE_i( k ).taken = '1' then
                     if v < 3 then v := v + 1; end if;
                  elsif v > 0 then
                     v := v - 1;
                  end if;
                  upd( nu ) := ( idx => idx, val => v );
                  nu := nu + 1;
               end if;
            end loop;
            for j in 0 to RETIRE_WIDTH - 1 loop
               if j < nu then
                  counters( upd( j ).idx ) <= upd( j ).val;
               end if;
            end loop;

            -- reprise, ou avance de l'état si le bloc passe
            tr_valid <= '0';
            if RECOVERY_i.valid = '1' then
               ghist <= RECOVERY_i.ghist;
               ras_ptr <= to_integer( RECOVERY_i.ras_ptr );
               dentry <= RECOVERY_i.new_pc;
            elsif IN_VALID_i = '1' and OUT_READY_i = '1' then
               ghist <= next_ghist;
               ras <= next_ras;
               ras_ptr <= next_ras_ptr;
               dentry <= next_dentry;
               tr_valid <= c_valid; tr_taken <= c_taken; tr_key <= c_key; tr_fin <= c_fin; tr_target <= c_target;
            end if;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
