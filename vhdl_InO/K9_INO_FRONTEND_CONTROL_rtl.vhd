library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.TAHX_1_ISA_TABLE.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.IN_ORDER_TYPES.all;

                                ---
architecture                    RTL
of INO_FRONTEND_CONTROL is      ---

   signal committed_ghist_s    : ghist_t := ( others => '0' );
   signal committed_ras_s      : ras_ptr_t := ( others => '0' );
   signal boundary_s           : std_logic := '0';
   signal recovery_s           : recovery_t := NO_RECOVERY;

   function IS_CONDITIONAL( op : opcode_t ) return boolean is
   begin
      return unsigned( op ) >= 16#E4# and unsigned( op ) <= 16#EB#;
   end function;

   function IS_CALL( op : opcode_t ) return boolean is
   begin
      return op = OP_CALL or op = x"33";                    -- CALLI
   end function;

   function IS_RTD( op : opcode_t ) return boolean is
   begin
      return op = OP_RTD_0 or op = OP_RTD_N;
   end function;

   function AFTER_GHIST( c : ino_commit_t ) return ghist_t is
      variable g : ghist_t := c.slot.pred.ghist;
   begin
      if IS_CONDITIONAL( c.slot.canon.op ) then
         g := g( g'high - 1 downto 0 ) & c.taken;
      end if;
      return g;
   end function;

   function AFTER_RAS( c : ino_commit_t ) return ras_ptr_t is
      variable p : ras_ptr_t := c.slot.pred.ras_ptr;
   begin
      if IS_CALL( c.slot.canon.op ) then
         p := p + 1;
      elsif IS_RTD( c.slot.canon.op ) then
         p := p - 1;
      end if;
      return p;
   end function;

   function MISPREDICTED( c : ino_commit_t ) return boolean is
      variable idx : natural;
   begin
      idx := to_integer( unsigned( c.slot.canon.op ) );
      if not ISA_TABLE( idx ).control then
         return false;
      end if;
      if c.slot.pred.taken /= c.taken then
         return true;
      end if;
      return c.taken = '1' and c.slot.pred.target /= c.target;
   end function;

begin

   RECOVERY_o <= recovery_s;

   BOUNDARY_VALID_o <= '1' when boundary_s = '1'
                                    and STACK_IDLE_i = '1'
                                    and DECODE_COUNT_i /= 0
                                    and DECODE_BLOCK_i( 0 ).valid = '1'
                                    and recovery_s.valid = '0'
                       else '0';
   BOUNDARY_PC_o <= DECODE_BLOCK_i( 0 ).pc when DECODE_COUNT_i /= 0
                    else ( others => '0' );

   -----------------------------------------------------------------------------
   -- Reprise du frontal. Le deroutement systeme est prioritaire ; il annule tout
   -- ce qui a ete precharge/decode et restaure l'etat predicteur retire.
   -----------------------------------------------------------------------------

   RECOVERY_COMB : process( COMMIT_i, SYSTEM_REDIRECT_VALID_i, SYSTEM_REDIRECT_PC_i,
                            committed_ghist_s, committed_ras_s )
      variable r : recovery_t;
   begin
      r := NO_RECOVERY;
      if SYSTEM_REDIRECT_VALID_i = '1' then
         r.valid   := '1';
         r.kind    := RECOVER_COMMITTED;
         r.new_pc  := SYSTEM_REDIRECT_PC_i;
         r.ghist   := committed_ghist_s;
         r.ras_ptr := committed_ras_s;
      elsif COMMIT_i.valid = '1' and COMMIT_i.fault.valid = '0'
            and MISPREDICTED( COMMIT_i ) then
         r.valid   := '1';
         r.kind    := RECOVER_CHECKPOINT;
         r.new_pc  := COMMIT_i.target;
         r.ghist   := AFTER_GHIST( COMMIT_i );
         r.ras_ptr := AFTER_RAS( COMMIT_i );
      end if;
      recovery_s <= r;
   end process;

   -----------------------------------------------------------------------------
   -- Compatibilite avec BRANCH_PREDICT : une seule instruction peut etre retiree
   -- par cycle dans le coeur InO. Les champs ROB n'ont plus de signification.
   -----------------------------------------------------------------------------

   RETIRE_COMB : process( COMMIT_i )
      variable b : retire_block_t;
      variable e : isa_entry_t;
   begin
      for i in b'range loop
         b( i ) := ( valid => '0', rob_index => ( others => '0' ), pc => ( others => '0' ),
                     is_store => '0', is_control => '0', conditional => '0', taken => '0',
                     target => ( others => '0' ), ghist => ( others => '0' ) );
      end loop;

      if COMMIT_i.valid = '1' and COMMIT_i.fault.valid = '0' then
         e := ISA_TABLE( to_integer( unsigned( COMMIT_i.slot.canon.op ) ) );
         b( 0 ).valid       := '1';
         b( 0 ).pc          := COMMIT_i.slot.pc;
         if e.control then b( 0 ).is_control := '1'; end if;
         if IS_CONDITIONAL( COMMIT_i.slot.canon.op ) then b( 0 ).conditional := '1'; end if;
         b( 0 ).taken       := COMMIT_i.taken;
         b( 0 ).target      := COMMIT_i.target;
         b( 0 ).ghist       := COMMIT_i.slot.pred.ghist;
      end if;
      RETIRE_o <= b;
   end process;

   -----------------------------------------------------------------------------
   -- Etat retire du predicteur et frontiere HX.
   -----------------------------------------------------------------------------

   STATE : process( CLK_i )
      variable e : isa_entry_t;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            committed_ghist_s <= ( others => '0' );
            committed_ras_s   <= ( others => '0' );
            boundary_s        <= '0';
         else
            if SYSTEM_REDIRECT_VALID_i = '1' then
               -- Le PC redirige pointe toujours au debut d'une instruction HX.
               boundary_s <= '1';
            elsif COMMIT_i.valid = '1' and COMMIT_i.fault.valid = '0' then
               if COMMIT_i.slot.canon.len = 0 then boundary_s <= '0'; else boundary_s <= '1'; end if;

               e := ISA_TABLE( to_integer( unsigned( COMMIT_i.slot.canon.op ) ) );
               if e.control then
                  committed_ghist_s <= AFTER_GHIST( COMMIT_i );
                  committed_ras_s   <= AFTER_RAS( COMMIT_i );
               end if;
            end if;
         end if;
      end if;
   end process;

                                ---
end architecture                RTL;
                                ---
------------------------------------------------------------------------------------------------------------------------
