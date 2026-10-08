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
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;

		--------------------------------------------------------------------------------
		--  ROB, architecture RTL : modèle de référence.
		--
		--  File circulaire de ROB_SIZE entrées, indices entiers modulo ROB_SIZE. L'état
		--  est réparti comme en matériel : le contenu alloué (rob_alloc_t) n'est écrit
		--  qu'à l'allocation ; done, fault, taken et target changent aux fins
		--  d'exécution. Le retrait est un préfixe calculé dans le cycle ; RECOVERY_o
		--  est un registre ; l'état retiré du prédicteur avance au retrait.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of ROB is			---

   constant OP_CALLI		: opcode_t := x"33";

   subtype index_t		is natural range 0 to ROB_SIZE - 1;
   type alloc_array_t		is array( 0 to ROB_SIZE - 1 ) of rob_alloc_t;
   type fault_array_t		is array( 0 to ROB_SIZE - 1 ) of fault_t;
   type addr_array_t		is array( 0 to ROB_SIZE - 1 ) of address_t;

   signal alloc		: alloc_array_t;
   signal done			: std_logic_vector( 0 to ROB_SIZE - 1 );
   signal faults		: fault_array_t;
   signal taken		: std_logic_vector( 0 to ROB_SIZE - 1 );
   signal target		: addr_array_t;

   signal head, tail		: index_t;
   signal count		: natural range 0 to ROB_SIZE;
   signal boundary		: std_logic;
   signal cghist		: ghist_t;					-- état retiré du prédicteur
   signal cras			: natural range 0 to RAS_DEPTH - 1;
   signal rec			: recovery_t;					-- RECOVERY_o
   signal rec_rh		: std_logic;					-- retire_head (COMMITTED)
   signal k_ret		: natural range 0 to RETIRE_WIDTH;

   function IS_COND( op : opcode_t ) return boolean is
   begin
      return unsigned( op ) >= 16#E4# and unsigned( op ) <= 16#EB#;
   end function;

   function RAS_STEP( op : opcode_t ) return integer is
   begin
      if op = OP_CALL or op = OP_CALLI then
         return 1;
      elsif op = OP_RTD_0 or op = OP_RTD_N then
         return -1;
      else
         return 0;
      end if;
   end function;

begin

		--------------------------------------------------------------------------------
		-- 1., 4. état visible
		--------------------------------------------------------------------------------

   TAIL_o		<= to_unsigned( tail, ROB_INDEX_BITS );
   FREE_o		<= to_unsigned( ROB_SIZE - count, FREE_o'length );
   HEAD_o		<= to_unsigned( head, ROB_INDEX_BITS );
   EMPTY_o		<= '1' when count = 0 else '0';
   RECOVERY_o		<= rec;

   TETE : process( head, count, alloc, done, faults, boundary )
   begin
      HEAD_STATUS_o.valid		<= '0';
      if count > 0 then
         HEAD_STATUS_o.valid	<= '1';
      end if;
      HEAD_STATUS_o.rob_index	<= to_unsigned( head, ROB_INDEX_BITS );
      HEAD_STATUS_o.pc		<= alloc( head ).pc;
      HEAD_STATUS_o.boundary	<= boundary;
      HEAD_STATUS_o.done		<= done( head );
      HEAD_STATUS_o.fault		<= faults( head );
      HEAD_STATUS_o.serializing	<= alloc( head ).serializing;
   end process;

		--------------------------------------------------------------------------------
		-- 3. retrait : préfixe de la tête
		--------------------------------------------------------------------------------

   RETRAIT : process( head, count, alloc, done, faults, taken, target, rec, rec_rh, HOLD_RETIRE_i )
      variable k, last_ok	: natural range 0 to RETIRE_WIDTH;
      variable keep_age	: natural;
      variable x		: index_t;
   begin
      last_ok := 0;
      keep_age := ( to_integer( rec.keep_last ) - head ) mod ROB_SIZE;
      for i in 0 to RETIRE_WIDTH - 1 loop
         x := ( head + i ) mod ROB_SIZE;
         exit when i >= count;
         exit when rec.valid = '1' and rec.kind = RECOVER_CHECKPOINT and i > keep_age;
         exit when done( x ) = '0' or faults( x ).valid = '1' or alloc( x ).serializing = '1';
         if alloc( x ).len /= 0 then
            last_ok := i + 1;						-- ne pas finir sur len = 0
         end if;
      end loop;
      k := last_ok;
      if rec.valid = '1' and rec.kind = RECOVER_COMMITTED then		-- SYSTEM_UNIT a décidé
         if rec_rh = '1' then k := 1; else k := 0; end if;
      elsif HOLD_RETIRE_i = '1' then
         k := 0;
      end if;

      for i in 0 to RETIRE_WIDTH - 1 loop
         x := ( head + i ) mod ROB_SIZE;
         RETIRE_o( i ).valid		<= '0';
         if i < k then RETIRE_o( i ).valid <= '1'; end if;
         RETIRE_o( i ).rob_index	<= to_unsigned( x, ROB_INDEX_BITS );
         RETIRE_o( i ).pc		<= alloc( x ).pc;
         RETIRE_o( i ).is_store	<= alloc( x ).is_store;
         RETIRE_o( i ).is_control	<= alloc( x ).is_control;
         RETIRE_o( i ).conditional	<= '0';
         if IS_COND( alloc( x ).op ) then RETIRE_o( i ).conditional <= '1'; end if;
         RETIRE_o( i ).ghist		<= alloc( x ).pred.ghist;
         if alloc( x ).is_control = '1' then
            RETIRE_o( i ).taken	<= taken( x );
            RETIRE_o( i ).target	<= target( x );
         else
            RETIRE_o( i ).taken	<= '0';
            RETIRE_o( i ).target	<= ( others => '0' );
         end if;
      end loop;
      RETIRE_COUNT_o <= to_unsigned( k, RETIRE_COUNT_o'length );
      k_ret <= k;
   end process;

		--------------------------------------------------------------------------------
		-- Au front : retrait, reprise suivante, fins d'exécution, reprise, allocation
		--------------------------------------------------------------------------------

   ETAT : process( CLK_i )
      variable g		: ghist_t;
      variable rp		: natural range 0 to RAS_DEPTH - 1;
      variable bd		: std_logic;
      variable x		: index_t;
      variable h		: index_t;
      variable nr		: recovery_t;
      variable best		: integer;
      variable best_age, age	: natural;
      variable keep_age	: natural;
      variable n		: natural;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            head <= 0; tail <= 0; count <= 0;
            boundary <= '1';
            cghist <= ( others => '0' ); cras <= 0;
            rec <= NO_RECOVERY; rec_rh <= '0';
         else
            -- retrait, état retiré du prédicteur
            g := cghist; rp := cras; bd := boundary;
            for i in 0 to RETIRE_WIDTH - 1 loop
               if i < k_ret then
                  x := ( head + i ) mod ROB_SIZE;
                  if IS_COND( alloc( x ).op ) then
                     g := alloc( x ).pred.ghist( ghist_t'high - 1 downto 0 ) & taken( x );
                  end if;
                  rp := ( rp + RAS_DEPTH + RAS_STEP( alloc( x ).op ) ) mod RAS_DEPTH;
                  if alloc( x ).len /= 0 then bd := '1'; else bd := '0'; end if;
               end if;
            end loop;
            h := ( head + k_ret ) mod ROB_SIZE;
            cghist <= g; cras <= rp;

            -- reprise du cycle suivant
            nr := NO_RECOVERY;
            rec_rh <= '0';
            if SYSTEM_REDIRECT_i.valid = '1' then
               nr.valid := '1'; nr.kind := RECOVER_COMMITTED; nr.new_pc := SYSTEM_REDIRECT_i.pc;
               nr.ghist := g; nr.ras_ptr := to_unsigned( rp, ras_ptr_t'length );
               rec_rh <= SYSTEM_REDIRECT_i.retire_head;
            else
               best := -1; best_age := ROB_SIZE;
               for p in COMPLETION_i'range loop
                  x := to_integer( COMPLETION_i( p ).rob_index );
                  age := ( x - head ) mod ROB_SIZE;
                  if COMPLETION_i( p ).valid = '1' and COMPLETION_i( p ).mispredicted = '1'
                     and COMPLETION_i( p ).fault.valid = '0' and age < count and age < best_age
                     and not ABANDONED( COMPLETION_i( p ).rob_index, rec, to_unsigned( head, ROB_INDEX_BITS ) ) then
                     best := p; best_age := age;
                  end if;
               end loop;
               if best >= 0 then
                  x := to_integer( COMPLETION_i( best ).rob_index );
                  nr.valid := '1'; nr.kind := RECOVER_CHECKPOINT;
                  nr.keep_last := COMPLETION_i( best ).rob_index;
                  nr.checkpoint := alloc( x ).checkpoint;
                  nr.new_pc := COMPLETION_i( best ).target;
                  nr.ghist := alloc( x ).pred.ghist;
                  if IS_COND( alloc( x ).op ) then
                     nr.ghist := alloc( x ).pred.ghist( ghist_t'high - 1 downto 0 ) & COMPLETION_i( best ).taken;
                  end if;
                  nr.ras_ptr := to_unsigned( ( to_integer( alloc( x ).pred.ras_ptr ) + RAS_DEPTH
                                               + RAS_STEP( alloc( x ).op ) ) mod RAS_DEPTH, ras_ptr_t'length );
               end if;
            end if;
            rec <= nr;

            -- fins d'exécution
            for p in COMPLETION_i'range loop
               x := to_integer( COMPLETION_i( p ).rob_index );
               if COMPLETION_i( p ).valid = '1' and ( x - head ) mod ROB_SIZE < count then
                  done( x ) <= '1';
                  if COMPLETION_i( p ).fault.valid = '1' then
                     faults( x ) <= COMPLETION_i( p ).fault;
                  end if;
                  taken( x ) <= COMPLETION_i( p ).taken;
                  target( x ) <= COMPLETION_i( p ).target;
               end if;
            end loop;

            -- reprise de ce cycle, sinon allocation
            if rec.valid = '1' then
               if rec.kind = RECOVER_COMMITTED then
                  count <= 0;
                  tail <= h;
                  bd := '1';
               else
                  keep_age := ( to_integer( rec.keep_last ) - head ) mod ROB_SIZE;
                  count <= keep_age + 1 - k_ret;
                  tail <= ( to_integer( rec.keep_last ) + 1 ) mod ROB_SIZE;
               end if;
            else
               n := 0;
               if ALLOC_VALID_i = '1' then
                  n := to_integer( ALLOC_COUNT_i );

                  -- pragma translate_off
                  assert n <= ROB_SIZE - count report "ROB : allocation au-delà de FREE_o" severity failure;
                  -- pragma translate_on

                  for i in 0 to DECODE_WIDTH - 1 loop
                     if i < n then
                        x := ( tail + i ) mod ROB_SIZE;
                        alloc( x ) <= ALLOC_BLOCK_i( i );
                        done( x ) <= ALLOC_BLOCK_i( i ).done or ALLOC_BLOCK_i( i ).fault.valid;
                        faults( x ) <= ALLOC_BLOCK_i( i ).fault;
                        taken( x ) <= '0';
                        target( x ) <= ( others => '0' );
                     end if;
                  end loop;
               end if;
               tail <= ( tail + n ) mod ROB_SIZE;
               count <= count - k_ret + n;
            end if;
            head <= h;
            boundary <= bd;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
