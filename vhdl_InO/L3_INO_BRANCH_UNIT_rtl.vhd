library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

        --------------------------------------------------------------------------------
        -- INO_BRANCH_UNIT, architecture RTL.
        --
        -- Même sémantique de résolution que L3_BRANCH_UNIT du backend OoO, réduite aux
        -- branches ordinaires déjà compatibles avec STACK_UNIT :
        --
        --   BRA E0..E3 : toujours prise
        --   BT  E4..E7 : prise si operand(0) /= 0
        --   BF  E8..EB : prise si operand(0) = 0
        --
        -- cible relative = pc + len + sign_extend(val)
        -- target rendu = cible si pris, pc + len sinon.
        --
        -- Un cycle, comme INO_INTEGER_UNIT.
        --------------------------------------------------------------------------------

                                ---
architecture                    RTL
of INO_BRANCH_UNIT is           ---

   constant NO_COMPLETE : ino_complete_t := (
      valid        => '0',
      result_valid => '0',
      result       => ( others => '0' ),
      fault        => NO_FAULT,
      taken        => '0',
      target       => ( others => '0' ) );

   signal computed_s            : ino_complete_t := NO_COMPLETE;
   signal complete_s            : ino_complete_t := NO_COMPLETE;

   function IS_ORDINARY_BRANCH( op : opcode_t ) return boolean is
   begin
      return unsigned( op ) >= 16#E0# and unsigned( op ) <= 16#EB#;
   end function;

   function EXECUTE( ins : ino_issue_t ) return ino_complete_t is
      constant op       : opcode_t := ins.slot.canon.op;
      constant pc       : address_t := ins.slot.pc;
      variable fall     : address_t;
      variable tgt      : address_t;
      variable taken_v  : boolean := true;
      variable r        : ino_complete_t := NO_COMPLETE;
   begin
      fall := pc + resize( ins.slot.canon.len, 64 );
      tgt  := fall + unsigned( resize( ins.slot.canon.val, 64 ) );

      if unsigned( op ) >= 16#E4# and unsigned( op ) <= 16#E7# then
         taken_v := unsigned( ins.operand( 0 ) ) /= 0;       -- BT
      elsif unsigned( op ) >= 16#E8# and unsigned( op ) <= 16#EB# then
         taken_v := unsigned( ins.operand( 0 ) ) = 0;        -- BF
      end if;

      r.valid        := '1';
      r.result_valid := '0';
      r.result       := ( others => '0' );
      r.fault        := NO_FAULT;
      if taken_v then
         r.taken  := '1';
         r.target := tgt;
      else
         r.taken  := '0';
         r.target := fall;
      end if;
      return r;
   end function;

begin

   ISSUE_READY_o <= '1';
   COMPLETE_o    <= complete_s;

   computed_s <= EXECUTE( ISSUE_i );

   -- pragma translate_off
   -- Contrôle au front d'horloge : ISSUE_i est un bus commun aux unités du
   -- backend et ISSUE_VALID_i est un valid dérivé du routage de classe.  Un
   -- contrôle combinatoire peut observer un delta-cycle transitoire où le bus
   -- a déjà changé mais pas encore le valid (ou inversement).  Seul l'état
   -- présent au front montant constitue une émission réelle.
   CHECK_OPCODE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ISSUE_VALID_i = '1' then
            assert ISSUE_i.issue_class = ISSUE_BRANCH
               report "INO_BRANCH_UNIT : classe d'emission incorrecte"
               severity failure;
            assert IS_ORDINARY_BRANCH( ISSUE_i.slot.canon.op )
               report "INO_BRANCH_UNIT : transfert non encore implante"
               severity failure;
         end if;
      end if;
   end process CHECK_OPCODE;
   -- pragma translate_on

   PIPE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            complete_s <= NO_COMPLETE;
         elsif ISSUE_VALID_i = '1' then
            complete_s <= computed_s;
         else
            complete_s <= NO_COMPLETE;
         end if;
      end if;
   end process PIPE;

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
