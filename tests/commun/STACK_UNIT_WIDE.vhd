library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
-- Modele de banc (simulation seulement) : STACK_UNIT vue avec des ports larges.
--
-- STACK_UNIT a des ports reduits pour sa macro (INO_PORTS_PA) : adresses sur
-- PA_BITS bits, DISPLAY lu par un port d'indice et ecrit une entree par cycle
-- avant SYNC. Les bancs unitaires gardent l'interface d'origine : adresses de
-- 64 bits, FRAME_o complet et SYNC d'un frame complet. Ce modele fait le lien :
--
--   - conversions TO_PA / TO_VA ;
--   - FRAME_o : frame interne de STACK_UNIT, observe par un nom externe ;
--   - SYNC : les entrees de DISPLAY qui changent sont ecrites d'abord, une par
--     cycle, l'offre de DECODE etant masquee ; sans changement de DISPLAY, la
--     SYNC passe au meme cycle qu'avant ; SYNC_BUSY_o signale l'attente ;
--   - DISP_SEL_i / DISP_o : port de lecture de DISPLAY, pour un INO_EXCM_UNIT.
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

entity STACK_UNIT_WIDE is
   generic (
      STACK_CACHE_WORDS_G  : positive := 64;
      RETURN_CACHE_WORDS_G : positive := 32
   );
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      DECODE_VALID_i    : in  std_logic;
      DECODE_SLOT_i     : in  decoded_slot_t;
      DECODE_TAKE_o     : out std_logic;

      ISSUE_VALID_o     : out std_logic;
      ISSUE_o           : out ino_issue_t;
      ISSUE_READY_i     : in  std_logic;

      COMPLETE_i        : in  ino_complete_t;
      COMMIT_o          : out ino_commit_t;

      FRAME_o           : out frame_state_t;
      DISP_SEL_i        : in  disp_sel_t := ( others => '0' );
      DISP_o            : out address_t;
      LIM_DSP_i         : in  address_t;
      LIM_RSP_i         : in  address_t;

      SYNC_VALID_i      : in  std_logic;
      SYNC_FRAME_i      : in  frame_state_t;
      SYNC_BUSY_o       : out std_logic;      -- SYNC en cours (ecritures de DISPLAY)

      MAINT_i           : in  stack_maint_t;
      MAINT_DONE_o      : out std_logic;

      MEM_REQ_o         : out mem_request_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      IDLE_o            : out std_logic
   );
end entity STACK_UNIT_WIDE;

architecture MODELE of STACK_UNIT_WIDE is

   type mask_t is array( 0 to 14 ) of boolean;

   signal frame_obs    : frame_state_t;
   signal diff         : mask_t;
   signal busy_s       : std_logic := '0';
   signal go_s         : std_logic := '0';
   signal pend_s       : frame_state_t;
   signal mask_s       : mask_t := ( others => false );

   signal dut_decode   : std_logic;
   signal dut_sync     : std_logic;
   signal dut_dsp      : paddr_t;
   signal dut_rsp      : paddr_t;
   signal dut_we       : std_logic;
   signal dut_wsel     : disp_sel_t;
   signal dut_wdata    : paddr_t;

   signal issue_pa     : issue_pa_t;
   signal commit_pa    : commit_pa_t;
   signal mem_req_pa   : mem_request_pa_t;
   signal disp_pa      : paddr_t;
   signal dsp_pa       : paddr_t;
   signal rsp_pa       : paddr_t;

   function ANY( m : mask_t ) return boolean is
   begin
      for i in m'range loop
         if m( i ) then return true; end if;
      end loop;
      return false;
   end function;

   function FIRST( m : mask_t ) return natural is
   begin
      for i in m'range loop
         if m( i ) then return i; end if;
      end loop;
      return 0;
   end function;

begin

   U_DUT : entity work.STACK_UNIT
      generic map (
         STACK_CACHE_WORDS_G  => STACK_CACHE_WORDS_G,
         RETURN_CACHE_WORDS_G => RETURN_CACHE_WORDS_G )
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         DECODE_VALID_i => dut_decode, DECODE_SLOT_i => TO_PA( DECODE_SLOT_i ), DECODE_TAKE_o => DECODE_TAKE_o,
         ISSUE_VALID_o => ISSUE_VALID_o, ISSUE_o => issue_pa, ISSUE_READY_i => ISSUE_READY_i,
         COMPLETE_i => TO_PA( COMPLETE_i ), COMMIT_o => commit_pa,
         FRAME_DSP_o => dsp_pa, FRAME_RSP_o => rsp_pa, DISP_SEL_i => DISP_SEL_i, DISP_o => disp_pa,
         LIM_DSP_i => LIM_DSP_i, LIM_RSP_i => LIM_RSP_i,
         SYNC_VALID_i => dut_sync, SYNC_DSP_i => dut_dsp, SYNC_RSP_i => dut_rsp,
         DISP_WE_i => dut_we, DISP_WSEL_i => dut_wsel, DISP_WDATA_i => dut_wdata,
         MAINT_i => MAINT_i, MAINT_DONE_o => MAINT_DONE_o,
         MEM_REQ_o => mem_req_pa, MEM_READY_i => MEM_READY_i, MEM_RSP_i => MEM_RSP_i,
         IDLE_o => IDLE_o );

   -- Frame interne de STACK_UNIT (simulation seulement).
   OBSERVATION : block
      alias frame_dut is << signal ^.U_DUT.frame_s : frame_state_t >>;
   begin
      frame_obs <= frame_dut;
   end block OBSERVATION;

   FRAME_o   <= frame_obs;
   SYNC_BUSY_o <= busy_s or go_s;
   DISP_o    <= TO_VA( disp_pa );
   ISSUE_o   <= TO_VA( issue_pa );
   COMMIT_o  <= TO_VA( commit_pa );
   MEM_REQ_o <= TO_VA( mem_req_pa );

   DIFFERENCES : for i in 0 to 14 generate
      diff( i ) <= CUT( SYNC_FRAME_i.display( i ) ) /= frame_obs.display( i );
   end generate;

   dut_decode <= DECODE_VALID_i and not busy_s;
   dut_sync   <= '1' when go_s = '1' or ( busy_s = '0' and SYNC_VALID_i = '1' and not ANY( diff ) ) else '0';
   dut_dsp    <= TO_PA( pend_s.dsp ) when go_s = '1' else TO_PA( SYNC_FRAME_i.dsp );
   dut_rsp    <= TO_PA( pend_s.rsp ) when go_s = '1' else TO_PA( SYNC_FRAME_i.rsp );
   dut_we     <= '1' when busy_s = '1' and ANY( mask_s ) else '0';
   dut_wsel   <= to_unsigned( FIRST( mask_s ), 4 );
   dut_wdata  <= TO_PA( pend_s.display( FIRST( mask_s ) ) );

   SEQUENCE_SYNC : process( CLK_i )
      variable m : mask_t;
   begin
      if rising_edge( CLK_i ) then
         go_s <= '0';
         if RESET_i = '1' then
            busy_s <= '0';
            mask_s <= ( others => false );
         elsif busy_s = '0' then
            if SYNC_VALID_i = '1' and ANY( diff ) then
               busy_s <= '1';
               pend_s <= SYNC_FRAME_i;
               mask_s <= diff;
            end if;
         else
            assert SYNC_VALID_i = '0'
               report "STACK_UNIT_WIDE : SYNC pendant l'ecriture de DISPLAY d'une SYNC precedente"
               severity failure;
            m := mask_s;
            m( FIRST( mask_s ) ) := false;
            mask_s <= m;
            if not ANY( m ) then
               busy_s <= '0';
               go_s   <= '1';
            end if;
         end if;
      end if;
   end process SEQUENCE_SYNC;

end architecture MODELE;
------------------------------------------------------------------------------------------------------------------------
