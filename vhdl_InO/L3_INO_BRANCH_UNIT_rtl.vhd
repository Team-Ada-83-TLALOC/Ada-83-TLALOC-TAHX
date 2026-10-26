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
use work.INO_PADDR.all;
use work.INO_ARITH.all;

        --------------------------------------------------------------------------------
        -- INO_BRANCH_UNIT, architecture RTL.
        --
        -- Même sémantique de résolution que L3_BRANCH_UNIT du backend OoO :
        --
        --   BRA E0..E3 : toujours prise, cible relative
        --   BT  E4..E7 : prise si operand(0) /= 0
        --   BF  E8..EB : prise si operand(0) = 0
        --   CALL       : toujours pris, cible relative
        --   CALLI      : toujours pris, cible = operand(0)
        --   RTD 0/n    : toujours pris, cible = ISSUE_i.address (pile retours)
        --
        -- target rendu = adresse où l'exécution continue.
        --
        -- Espace physique InO (INO_PADDR) : si l'adresse de continuation n'est pas
        -- réalisable (bits 63..PA_BITS non nuls), le transfert faute (132) ; FPC est
        -- alors l'adresse de l'instruction de transfert. CALL / CALLI fautent aussi si
        -- leur adresse de retour (pc + len) n'est pas réalisable : la pile des retours
        -- ne garde que PA_BITS bits.
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

   constant OP_CALLI : opcode_t := x"33";

   function IS_BRANCH_OP( op : opcode_t ) return boolean is
   begin
      return ( unsigned( op ) >= 16#E0# and unsigned( op ) <= 16#EB# )
          or op = OP_CALL or op = OP_CALLI or op = OP_RTD_0 or op = OP_RTD_N;
   end function;

   -- Le pc d'une instruction emise est realisable (< 2**32, TO_VA de INO_EXECUTE) :
   -- fall = pc + len et la cible pc + len + val se calculent sur 34 bits (un etage
   -- de compression 3:2, puis ADD_PFX). La cible est realisable si les deux bits
   -- hauts de la somme sur 34 bits sont nuls ; sinon la cible sur 64 bits ne l'est
   -- pas non plus (somme negative, ou >= 2**32).
   function EXECUTE( ins : ino_issue_t ) return ino_complete_t is
      constant op       : opcode_t := ins.slot.canon.op;
      variable pc34     : unsigned( 33 downto 0 );
      variable ln34     : unsigned( 33 downto 0 );
      variable vl34     : unsigned( 33 downto 0 );
      variable xs, xc   : unsigned( 33 downto 0 );
      variable fall34   : unsigned( 33 downto 0 );
      variable tgt34    : unsigned( 33 downto 0 );
      variable fall     : address_t;
      variable tgt      : address_t;
      variable tgt_ok   : boolean;
      variable fall_ok  : boolean;
      variable taken_v  : boolean := true;
      variable r        : ino_complete_t := NO_COMPLETE;
   begin
      pc34 := "00" & ins.slot.pc( 31 downto 0 );
      ln34 := resize( ins.slot.canon.len, 34 );
      vl34 := unsigned( resize( ins.slot.canon.val, 34 ) );
      xs := pc34 xor ln34 xor vl34;
      xc := ( ( pc34 and ln34 ) or ( pc34 and vl34 ) or ( ln34 and vl34 ) ) sll 1;
      tgt34  := ADD_PFX( xs, xc, '0' );
      fall34 := ADD_PFX( pc34, ln34, '0' );
      fall    := resize( fall34( 32 downto 0 ), 64 );
      fall_ok := fall34( 32 ) = '0';
      tgt     := resize( tgt34( 31 downto 0 ), 64 );
      tgt_ok  := tgt34( 33 downto 32 ) = "00";

      if unsigned( op ) >= 16#E4# and unsigned( op ) <= 16#E7# then
         taken_v := unsigned( ins.operand( 0 ) ) /= 0;       -- BT
      elsif unsigned( op ) >= 16#E8# and unsigned( op ) <= 16#EB# then
         taken_v := unsigned( ins.operand( 0 ) ) = 0;        -- BF
      elsif op = OP_CALLI then
         tgt := unsigned( ins.operand( 0 ) );
         tgt_ok := PA_OK( tgt );
      elsif op = OP_RTD_0 or op = OP_RTD_N then
         tgt := ins.address;
         tgt_ok := PA_OK( tgt );
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
      if ( taken_v and not tgt_ok ) or ( not taken_v and not fall_ok )
         or ( ( op = OP_CALL or op = OP_CALLI ) and not fall_ok ) then
         r.fault  := ( valid => '1', code => FAULT_ACCESS );
         r.taken  := '0';
         r.target := ( others => '0' );
      end if;
      return r;
   end function;

begin

   ISSUE_READY_o <= '1';

   -- Terminaison dans le cycle d'émission (V3) : aucun registre de sortie.
   computed_s <= EXECUTE( ISSUE_i );
   COMPLETE_o <= computed_s when ISSUE_VALID_i = '1' and RESET_i = '0' else NO_COMPLETE;

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
            assert IS_BRANCH_OP( ISSUE_i.slot.canon.op )
               report "INO_BRANCH_UNIT : transfert non implante"
               severity failure;
            if ISSUE_i.slot.canon.op = OP_CALLI then
               assert ISSUE_i.operand_count = 1
                  report "INO_BRANCH_UNIT : CALLI sans cible"
                  severity failure;
            elsif ISSUE_i.slot.canon.op = OP_RTD_0 or ISSUE_i.slot.canon.op = OP_RTD_N then
               assert ISSUE_i.address_known = '1'
                  report "INO_BRANCH_UNIT : RTD sans cible de pile retours"
                  severity failure;
            end if;
         end if;
      end if;
   end process CHECK_OPCODE;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
