library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

--------------------------------------------------------------------------------
-- INO_EXEC_ENTIER, architecture STRUCTURE : INO_BACKEND_EXCM sans les unites
-- arithmetiques longues (WITH_ARITH = false), les conversions des ports
-- d'adresse, et la selection de INO_EXEC_ARITH.
--------------------------------------------------------------------------------

architecture STRUCTURE of INO_EXEC_ENTIER is

   constant OP_FEXP_T       : opcode_t := x"24";

   signal issue             : ino_issue_t;
   signal arith             : std_logic;
   signal backend_valid     : std_logic;
   signal backend_ready     : std_logic;
   signal arith_ready       : std_logic;
   signal mem_req           : mem_request_t;
   signal backend_complete  : ino_complete_t;
   signal complete          : ino_complete_t;

begin

   issue <= TO_VA( ISSUE_i );

   -- Classe faite par INO_EXEC_ARITH (meme decodage que dans celle-ci).
   arith <= '1' when ISSUE_i.issue_class = ISSUE_MUL_DIV
                  or ISSUE_i.issue_class = ISSUE_FLOAT
                  or ( ISSUE_i.issue_class = ISSUE_COMPLEX and ISSUE_i.slot.canon.op = OP_FEXP_T )
            else '0';

   backend_valid <= ISSUE_VALID_i and not arith;

   -- SYNC_VALID bloque l'emission de FEXP, comme dans INO_COMPLEX_UNIT.
   arith_ready <= ARITH_READY_i( 0 ) when ISSUE_i.issue_class = ISSUE_MUL_DIV
                  else ARITH_READY_i( 1 ) when ISSUE_i.issue_class = ISSUE_FLOAT
                  else ARITH_READY_i( 2 ) and not SYNC_VALID_i;

   ISSUE_READY_o <= arith_ready when arith = '1' else backend_ready;

U_BACKEND :
  entity work.INO_BACKEND_EXCM
    generic map ( WITH_ARITH => false )
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      ISSUE_VALID_i => backend_valid, ISSUE_i => issue, ISSUE_READY_o => backend_ready,
      FRAME_DSP_i => TO_VA( FRAME_DSP_i ), FRAME_RSP_i => TO_VA( FRAME_RSP_i ),
      DISP_SEL_o => DISP_SEL_o, DISP_i => TO_VA( DISP_i ), LIMITS_i => LIMITS_i,
      SYNC_VALID_i => SYNC_VALID_i, SYNC_COPILE_i => SYNC_COPILE_i, COPILE_o => COPILE_o,
      STACK_MAINT_o => STACK_MAINT_o, STACK_MAINT_DONE_i => STACK_MAINT_DONE_i,
      MEM_REQ_o => mem_req, MEM_READY_i => MEM_READY_i, MEM_RSP_i => MEM_RSP_i,
      COMPLETE_o => backend_complete
    );

   -- Une seule instruction en vol : les deux retours ne se chevauchent pas.
   RETOUR : process( all )
      variable c : ino_complete_t;
   begin
      c := backend_complete;
      if ARITH_COMPLETE_VALID_i = '1' then
         c.valid        := '1';
         c.result_valid := ARITH_COMPLETE_RESULT_VALID_i;
         c.result       := ARITH_COMPLETE_RESULT_i;
         c.fault        := ARITH_COMPLETE_FAULT_i;
         c.taken        := '0';
         c.target       := ( others => '0' );
      end if;
      complete <= c;
   end process RETOUR;

   MEM_REQ_o  <= TO_PA_EXEC( mem_req );
   COMPLETE_o <= TO_PA( complete );

   -- pragma translate_off
   CHECK : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         assert complete.valid /= '1' or PA_OK( complete.target )
            report "INO_EXEC_ENTIER : cible de COMPLETE non realisable (TO_PA inexact)" severity failure;
         assert not ( ARITH_COMPLETE_VALID_i = '1' and backend_complete.valid = '1' )
            report "INO_EXEC_ENTIER : deux retours dans le meme cycle" severity failure;
      end if;
   end process CHECK;
   -- pragma translate_on

end architecture STRUCTURE;
