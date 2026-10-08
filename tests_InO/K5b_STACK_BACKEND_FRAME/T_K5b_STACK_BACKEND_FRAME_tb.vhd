library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

                                ------------------------------
entity                          T_K5b_STACK_BACKEND_FRAME_tb
is                              ------------------------------
end entity                      T_K5b_STACK_BACKEND_FRAME_tb;
                                ------------------------------

                                ----
architecture                    TEST
of T_K5b_STACK_BACKEND_FRAME_tb is

   constant PERIOD              : time := 10 ns;
   constant S0                  : natural := 16#100000#;
   constant OLD_D2              : natural := 16#8800#;
   constant OP_LINK16_T         : opcode_t := x"44";
   constant OP_LINK24_T         : opcode_t := x"48";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   signal clk                   : std_logic := '0';
   signal running               : boolean := true;
   signal reset                 : std_logic := '1';

   signal decode_block          : decoded_block_t := ( others => NO_SLOT );
   signal decode_count          : decode_count_t := ( others => '0' );
   signal decode_take           : decode_count_t;

   signal issue_valid           : std_logic;
   signal issue                 : ino_issue_t;
   signal issue_ready           : std_logic;
   signal complete              : ino_complete_t;
   signal commit                : ino_commit_t;

   signal frame                 : frame_state_t;
   signal limits                : limits_t := (
      lim_dsp => to_unsigned( S0 + 16#1000#, 64 ), lim_rsp => ( others => '0' ),
      lim_csp => to_unsigned( 16#4100#, 64 ), lim_hp => ( others => '0' ) );

   signal sync_valid            : std_logic := '0';
   signal sync_frame            : frame_state_t := (
      dsp => ( others => '0' ), rsp => ( others => '0' ),
      display => ( others => ( others => '0' ) ) );
   signal sync_copile           : copile_state_t := (
      cfp => ( others => '0' ), csp => ( others => '0' ),
      hp => ( others => '0' ), hp_valid => '0' );
   signal copile                : copile_state_t;

   signal maint                 : stack_maint_t := (
      valid => '0', kind => MAINT_WRITEBACK_ALL,
      base => ( others => '0' ), length => ( others => '0' ) );
   signal maint_done            : std_logic;
   signal idle                  : std_logic;

   signal stack_mem_req         : mem_request_t;
   signal stack_mem_rsp         : mem_response_t := NO_MEM_RESPONSE;
   signal back_mem_req          : mem_request_t;
   signal back_mem_rsp          : mem_response_t := NO_MEM_RESPONSE;

   signal mem_4000              : word64_t := ( others => '0' );
   signal mem_4008              : word64_t := ( others => '0' );

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function SLOT_FRAME( op : opcode_t; lvl : natural; val : natural; pc : natural ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid := '1'; r.canon.op := op;
      r.canon.lvl := to_unsigned( lvl, r.canon.lvl'length );
      r.canon.ofs := ( others => '0' );
      r.canon.val := to_signed( val, r.canon.val'length );
      if op = OP_LINK24_T then
         r.canon.len := to_unsigned( 4, r.canon.len'length );
      elsif op = OP_LINK16_T then
         r.canon.len := to_unsigned( 3, r.canon.len'length );
      else
         r.canon.len := to_unsigned( 2, r.canon.len'length );
      end if;
      r.pc := A64( pc ); r.pred := NO_PREDICTION;
      return r;
   end function;

begin

   U_STACK : entity work.STACK_UNIT
      port map (
         CLK_i => clk, RESET_i => reset,
         DECODE_BLOCK_i => decode_block, DECODE_COUNT_i => decode_count, DECODE_TAKE_o => decode_take,
         ISSUE_VALID_o => issue_valid, ISSUE_o => issue, ISSUE_READY_i => issue_ready,
         COMPLETE_i => complete, COMMIT_o => commit,
         FRAME_o => frame, LIMITS_i => limits,
         SYNC_VALID_i => sync_valid, SYNC_FRAME_i => sync_frame,
         MAINT_i => maint, MAINT_DONE_o => maint_done,
         MEM_REQ_o => stack_mem_req, MEM_READY_i => '1', MEM_RSP_i => stack_mem_rsp,
         IDLE_o => idle );

   U_BACKEND : entity work.INO_BACKEND_COMPLEX
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         LIMITS_i => limits,
         SYNC_VALID_i => sync_valid, SYNC_COPILE_i => sync_copile, COPILE_o => copile,
         MEM_REQ_o => back_mem_req, MEM_READY_i => '1', MEM_RSP_i => back_mem_rsp,
         COMPLETE_o => complete );

   clk <= not clk after PERIOD / 2 when running;

   MEMORY : process( clk )
   begin
      if rising_edge( clk ) then
         stack_mem_rsp <= NO_MEM_RESPONSE;
         back_mem_rsp <= NO_MEM_RESPONSE;

         -- Ce scénario garde les FP sauvegardés dans le cache de pile : aucun FILL/SPILL
         -- de STACK_UNIT n'est attendu. Toute transaction vient donc du groupe frame COMPLEX.
         assert stack_mem_req.valid = '0'
            report "STACK_BACKEND_FRAME : acces memoire STACK inattendu" severity failure;

         if back_mem_req.valid = '1' then
            back_mem_rsp.valid <= '1';
            if back_mem_req.write = '1' then
               if back_mem_req.address = A64( 16#4000# ) then
                  mem_4000 <= back_mem_req.wdata;
               elsif back_mem_req.address = A64( 16#4008# ) then
                  mem_4008 <= back_mem_req.wdata;
               else
                  back_mem_rsp.fault <= '1';
               end if;
            else
               if back_mem_req.address = A64( 16#4000# ) then
                  back_mem_rsp.rdata <= mem_4000;
               elsif back_mem_req.address = A64( 16#4008# ) then
                  back_mem_rsp.rdata <= mem_4008;
               else
                  back_mem_rsp.fault <= '1';
               end if;
            end if;
         end if;
      end if;
   end process MEMORY;

   STIMULI : process
      variable c       : tb_counter_t := TB_COUNTER_INIT;
      variable pc_next : natural := 16#1000#;

      procedure DO_SYNC is
      begin
         sync_frame.dsp <= A64( S0 );
         sync_frame.rsp <= A64( 16#200000# );
         sync_frame.display <= ( others => ( others => '0' ) );
         sync_frame.display( 2 ) <= A64( OLD_D2 );
         sync_copile <= ( cfp => A64( 16#3000# ), csp => A64( 16#4000# ),
                          hp => ( others => '0' ), hp_valid => '0' );
         sync_valid <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait for 1 ns;
      end procedure DO_SYNC;

      procedure PRESENT( constant s : in decoded_slot_t ) is
      begin
         decode_block <= ( others => NO_SLOT );
         decode_block( 0 ) <= s;
         decode_count <= to_unsigned( 1, decode_count'length );
         loop
            wait until rising_edge( clk );
            exit when decode_take /= 0;
         end loop;
         decode_count <= ( others => '0' );
         decode_block <= ( others => NO_SLOT );
      end procedure PRESENT;

      procedure RUN( constant s : in decoded_slot_t ) is
         variable cycles : natural := 0;
      begin
         PRESENT( s );
         loop
            wait until rising_edge( clk );
            wait for 1 ns;
            exit when commit.valid = '1';
            cycles := cycles + 1;
            CHECK( c, cycles < 60, "latence bornee LINK/UNLINK integre" );
         end loop;
         CHECK( c, commit.slot.canon.op = s.canon.op, "opcode commit frame" );
         CHECK( c, commit.fault.valid = '0', "frame sans faute" );
      end procedure RUN;

      variable s : decoded_slot_t;
   begin
      wait for 20 ns;
      wait until rising_edge( clk ); reset <= '0';
      wait until rising_edge( clk );
      DO_SYNC;

      CHECK( c, frame.dsp = A64( S0 ), "DSP initial" );
      CHECK( c, frame.display( 2 ) = A64( OLD_D2 ), "DISPLAY2 initial" );

      -- Premier frame : cellule FP à S0+8, puis 24 octets de variables locales.
      s := SLOT_FRAME( OP_LINK16_T, 2, 24, pc_next ); pc_next := pc_next + 3;
      RUN( s );
      CHECK( c, frame.display( 2 ) = A64( S0 + 8 ), "LINK DISPLAY2 := cellule FP" );
      CHECK( c, frame.dsp = A64( S0 + 32 ), "LINK DSP push FP + alloc24" );
      CHECK( c, mem_4000 = x"0000000000003000", "LINK sauve CFP en co-pile" );
      CHECK( c, copile.cfp = A64( 16#4000# ), "LINK CFP" );
      CHECK( c, copile.csp = A64( 16#4008# ), "LINK CSP" );

      -- Frame imbriqué au même niveau : vérifie la chaîne DISPLAY et co-pile.
      s := SLOT_FRAME( OP_LINK24_T, 2, 8, pc_next ); pc_next := pc_next + 4;
      RUN( s );
      CHECK( c, frame.display( 2 ) = A64( S0 + 40 ), "LINK imbrique DISPLAY2" );
      CHECK( c, frame.dsp = A64( S0 + 48 ), "LINK imbrique DSP" );
      CHECK( c, mem_4008 = x"0000000000004000", "LINK imbrique sauve CFP" );
      CHECK( c, copile.cfp = A64( 16#4008# ), "LINK imbrique CFP" );
      CHECK( c, copile.csp = A64( 16#4010# ), "LINK imbrique CSP" );

      -- UNLINK restaure le frame data mais conserve CSP.
      s := SLOT_FRAME( OP_UNLINK, 2, 0, pc_next ); pc_next := pc_next + 2;
      RUN( s );
      CHECK( c, frame.display( 2 ) = A64( S0 + 8 ), "UNLINK restaure DISPLAY2" );
      CHECK( c, frame.dsp = A64( S0 + 32 ), "UNLINK restaure DSP precedent" );
      CHECK( c, copile.cfp = A64( 16#4000# ), "UNLINK restaure CFP" );
      CHECK( c, copile.csp = A64( 16#4010# ), "UNLINK conserve CSP" );

      -- UNLINKR restaure le frame extérieur et rabat CSP sur l'ancien CFP.
      s := SLOT_FRAME( OP_UNLINKR, 2, 0, pc_next ); pc_next := pc_next + 2;
      RUN( s );
      CHECK( c, frame.display( 2 ) = A64( OLD_D2 ), "UNLINKR restaure ancien DISPLAY2" );
      CHECK( c, frame.dsp = A64( S0 ), "UNLINKR restaure DSP exterieur" );
      CHECK( c, copile.cfp = A64( 16#3000# ), "UNLINKR restaure CFP exterieur" );
      CHECK( c, copile.csp = A64( 16#4000# ), "UNLINKR libere co-pile" );

      running <= false;
      FINISH( c, "T_K5b_STACK_BACKEND_FRAME_tb" );
      wait;
   end process STIMULI;

end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
