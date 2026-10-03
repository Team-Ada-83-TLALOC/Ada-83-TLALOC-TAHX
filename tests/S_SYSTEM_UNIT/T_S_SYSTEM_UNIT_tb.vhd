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
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_S_SYSTEM_UNIT_tb : le contrat de l'en-tête de S_SYSTEM_UNIT.
		--
		--  Le banc joue la tête du ROB (instructions ordinaires, fautes, TRAP de tous
		--  codes, CTX_SAVE, CTX_RESTORE sur des blocs préparés, SET_IMASK, RTX, EXC_RAISE
		--  sur des contextes préparés), les interruptions, COMPLEX_UNIT (SYS_REQ_i au
		--  cycle où la tête paraît, fin de l'instruction après SYS_RSP_o), le renommage
		--  (état retiré, SYNC appliquée), la LSQ (LSQ_DRAINED_i retardé), la maintenance
		--  du cache de pile et la mémoire (MEM_xxx, zone de 16 Kio).
		--  Chaque événement est déterministe (ordre de priorité du contrat) : le banc
		--  calcule son issue au moment où il le présente, d'après la section « Fautes,
		--  déroutements et interruptions » de la V8 (redirection, SYNC, réponse, arrêt),
		--  et tient une mémoire de référence comparée à la vraie à la fin de chaque
		--  séquence. Il contrôle l'ordre des accès (vidange, maintenance). Plusieurs
		--  vies : chaque arrêt est vérifié, puis RESET_i et nouveau démarrage.
		--------------------------------------------------------------------------------


				-----------------
entity				T_S_SYSTEM_UNIT_tb
is				-----------------
end entity			T_S_SYSTEM_UNIT_tb;
				-----------------


architecture			TEST
of T_S_SYSTEM_UNIT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant LIVES		: positive	:= 40;
   constant EVENTS_PER_LIFE	: positive	:= 120;
   constant CYCLE_MAX		: positive	:= 400000;
   constant SEED_1		: positive	:= 1453;
   constant SEED_2		: positive	:= 1515;

   -- disposition de la zone mémoire
   constant ZB			: natural := 16#10000#;
   constant ZS			: natural := 16#4000#;
   constant BOOT_AT		: natural := ZB;
   constant VTB_AT		: natural := ZB + 16#100#;
   constant FSCR_AT		: natural := ZB + 16#900#;
   constant CTXB_AT		: natural := ZB + 16#A00#;				-- 4 blocs de 192 octets
   constant DSTK_AT		: natural := ZB + 16#1000#;			-- DSP0 = DISPLAY[0]
   constant LDSP		: natural := ZB + 16#1E00#;
   constant RSP0		: natural := ZB + 16#3000#;
   constant LRSP		: natural := ZB + 16#2400#;
   constant EXCX_AT		: natural := ZB + 16#3100#;			-- 4 contextes d'exception
   constant LCSP		: natural := ZB + 16#3800#;
   constant OP_RTX		: opcode_t := x"FF";
   constant OP_EXC_RAISE	: opcode_t := x"FE";

   type mem_t			is array( 0 to ZS - 1 ) of byte_t;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal boot_block		: address_t := to_unsigned( BOOT_AT, 64 );
   signal head			: head_status_t := ( valid => '0', rob_index => ( others => '0' ), pc => ( others => '0' ),
					      boundary => '1', done => '0', fault => NO_FAULT, serializing => '0' );
   signal hold			: std_logic;
   signal head_atomic		: std_logic := '0';
   signal redirect		: system_redirect_t;
   signal sys_req		: sys_request_t := ( valid => '0', rob_index => ( others => '0' ), op => x"00",
						 val => ( others => '0' ), operand => ( others => '0' ) );
   signal sys_rsp		: sys_response_t;
   signal c_frame		: frame_state_t;
   signal c_copile		: copile_state_t;
   signal sync_valid		: std_logic;
   signal sync_frame		: frame_state_t;
   signal sync_copile		: copile_state_t;
   signal maint		: stack_maint_t;
   signal maint_done		: std_logic := '0';
   signal drained		: std_logic := '1';
   signal dr			: std_logic;
   signal limits		: limits_t;
   signal mem_req		: mem_request_t;
   signal mem_ready		: std_logic := '0';
   signal mem_rsp		: mem_response_t := NO_MEM_RESPONSE;
   signal irq_pending		: irq_vector_t := ( others => '0' );
   signal irq_ack		: std_logic;
   signal irq_ack_code		: trap_code_t;
   signal halt_req		: std_logic := '0';
   signal halted		: std_logic;
   signal halt_cause		: halt_cause_t;
   signal exit_code		: word64_t;
   signal fpc			: address_t;
   signal fcode		: trap_code_t;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.SYSTEM_UNIT
      port map (
         CLK_i => clk, RESET_i => reset, BOOT_BLOCK_i => boot_block,
         HEAD_STATUS_i => head, HEAD_ATOMIC_i => head_atomic, HOLD_RETIRE_o => hold, REDIRECT_o => redirect,
         SYS_REQ_i => sys_req, SYS_RSP_o => sys_rsp,
         COMMITTED_FRAME_i => c_frame, COMMITTED_COPILE_i => c_copile,
         SYNC_VALID_o => sync_valid, SYNC_FRAME_o => sync_frame, SYNC_COPILE_o => sync_copile,
         STACK_MAINT_o => maint, STACK_MAINT_DONE_i => maint_done, LSQ_DRAINED_i => drained,
         DR_o => dr, LIMITS_o => limits,
         MEM_REQ_o => mem_req, MEM_READY_i => mem_ready, MEM_RSP_i => mem_rsp,
         IRQ_PENDING_i => irq_pending, IRQ_ACK_o => irq_ack, IRQ_ACK_CODE_o => irq_ack_code,
         HALT_REQ_i => halt_req, HALTED_o => halted, HALT_CAUSE_o => halt_cause, EXIT_CODE_o => exit_code,
         FPC_o => fpc, FCODE_o => fcode );

   clk <= not clk after PERIOD / 2 when running;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      -- mémoires : réelle (écrite par l'unité) et de référence (écrite par le modèle)
      variable mem, ref		: mem_t;

      -- modèle architectural
      variable m_dr		: std_logic;
      variable m_fpc		: address_t;
      variable m_fcode		: natural;
      variable m_vtb, m_fscr	: address_t;
      variable m_imask		: std_logic_vector( 31 downto 0 );
      variable m_lim		: limits_t;
      variable m_frame		: frame_state_t;
      variable m_copile		: copile_state_t;

      -- issue attendue de la séquence en cours
      type outcome_t		is ( O_NONE, O_REDIRECT, O_HALT, O_RSP_FAULT );
      variable busy		: boolean := false;			-- une séquence attendue
      variable o_kind		: outcome_t := O_NONE;
      variable o_pc		: address_t;
      variable o_rh		: std_logic;
      variable o_sync		: boolean;
      variable o_frame		: frame_state_t;
      variable o_copile		: copile_state_t;
      variable o_ack		: integer;				-- code acquitté, -1 sinon
      variable o_cause		: halt_cause_t;
      variable o_exit		: word64_t;
      variable o_fault		: natural;
      variable o_rsp		: boolean;				-- réponse SYS_RSP_o attendue
      variable o_rsp_result	: boolean;
      variable o_result		: word64_t;
      variable o_maint		: boolean;				-- maintenance attendue
      variable o_first_maint	: boolean;				-- maintenance avant tout accès
      variable rsp_seen, maint_seen, maint_given : boolean;
      variable drain_left, maint_left : natural;
      variable cool		: natural := 0;				-- cycles avant le repos de l'unité
      variable sync_due		: boolean := false;

      -- tête du ROB
      type kind_t		is ( H_NONE, H_NORMAL, H_FAULT, H_SERIAL );
      variable h_kind		: kind_t := H_NONE;
      variable h_pc		: address_t;
      variable h_op		: opcode_t;
      variable h_val		: integer;
      variable h_operand	: word64_t;
      variable h_code		: natural;
      variable h_wait		: natural := 0;				-- cycles avant la prochaine tête
      variable done_in		: integer := -1;				-- fin de l'instruction (COMPLEX)
      variable done_fault	: natural := 0;
      variable events		: natural := 0;
      variable h_new		: boolean := false;			-- tête apparue ce cycle
      variable h_atomic		: boolean := false;			-- bloc en cours (HEAD_ATOMIC_i)
      variable n_atomic		: natural := 0;
      variable dr_by_fault	: boolean := false;			-- DR = 1 par une faute : EXC_RAISE
      variable next_pc		: address_t;
      type addr_list_t		is array( 0 to 127 ) of address_t;
      variable touched		: addr_list_t;				-- mots écrits pendant la séquence
      variable n_touched	: natural := 0;
      variable deliverable	: integer;
      variable head_fault_now	: boolean;
      variable exp_hold		: std_logic;
      variable rob_seq		: natural := 0;

      -- mémoire : réponses en file
      type pend_t		is record
			  rsp	: mem_response_t;
			  due	: natural;
			end record;
      type pend_array_t		is array( 0 to 15 ) of pend_t;
      variable pq		: pend_array_t;
      variable pq_head, pq_n	: natural := 0;
      variable ready_v		: std_logic;

      variable now		: natural := 0;
      variable life		: natural := 0;
      variable life_over	: boolean;
      variable k, n, x		: integer;
      variable a		: address_t;
      variable w		: word64_t;
      variable ok		: boolean;
      variable n_events, n_faults, n_irq, n_trapv, n_save, n_restore, n_imask, n_rtx, n_exc, n_137, n_132, n_134,
               n_redirects, n_syncs : natural := 0;
      type cause_count_t	is array( 0 to 7 ) of natural;
      variable n_halts		: cause_count_t := ( others => 0 );

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is		-- 0 .. m
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

      impure function RAND_WORD return word64_t is
      begin
         return std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) )
                & std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) );
      end function;

      function ADR( n : natural ) return address_t is
      begin
         return to_unsigned( n, 64 );
      end function;

      function VALID64( a : address_t ) return boolean is
      begin
         return a( 63 downto 31 ) = 0 and to_integer( a( 30 downto 0 ) ) >= ZB and to_integer( a( 30 downto 0 ) ) + 8 <= ZB + ZS;
      end function;

      -- accès de 64 bits à une mémoire du banc (adresse supposée valide)
      procedure WR( variable m : inout mem_t; a : address_t; v : word64_t ) is
         constant o : natural := to_integer( a( 30 downto 0 ) ) - ZB;
      begin
         for i in 0 to 7 loop m( o + i ) := v( 8 * i + 7 downto 8 * i ); end loop;
      end procedure;

      impure function RD( a : address_t ) return word64_t is			-- mémoire de référence
         constant o : natural := to_integer( a( 30 downto 0 ) ) - ZB;
         variable v : word64_t;
      begin
         for i in 0 to 7 loop v( 8 * i + 7 downto 8 * i ) := ref( o + i ); end loop;
         return v;
      end function;

      procedure NOTE( a : address_t ) is
      begin
         if n_touched <= touched'high then touched( n_touched ) := a; n_touched := n_touched + 1; end if;
      end procedure;

      procedure WREF( a : address_t; v : word64_t ) is			-- écriture attendue
      begin
         WR( ref, a, v ); NOTE( a );
      end procedure;

      -- limites effectives selon DR
      impure function EFF_LRSP return address_t is
      begin
         if m_dr = '1' then return m_lim.lim_rsp - RESERVE_RSP; end if;
         return m_lim.lim_rsp;
      end function;

      procedure EXPECT_REDIRECT( pc : address_t; rh : std_logic; sync : boolean ) is
      begin
         o_kind := O_REDIRECT; o_pc := pc; o_rh := rh; o_sync := sync;
      end procedure;

      procedure EXPECT_HALT( cs : halt_cause_t ) is
      begin
         o_kind := O_HALT; o_cause := cs;
      end procedure;

      procedure START( maint_needed : boolean ) is
      begin
         busy := true; o_kind := O_NONE; o_sync := false; o_ack := -1; o_rsp := false; o_rsp_result := false;
         o_maint := maint_needed; o_first_maint := maint_needed; n_touched := 0; rsp_seen := false; maint_seen := false; maint_given := false;
         drain_left := RAND_INT( 5 ); maint_left := 1 + RAND_INT( 5 );
         o_frame := m_frame; o_copile := m_copile; o_copile.hp_valid := '0';
      end procedure;

      ----------------------------------------------------------------------------
      -- Le modèle : issue d'un événement (V8, « Fautes, déroutements et
      -- interruptions »), mémoire de référence comprise
      ----------------------------------------------------------------------------

      procedure MODEL_FAULT( pc : address_t; code : natural ) is
      begin
         START( false );
         if m_dr = '1' then EXPECT_HALT( HALT_DOUBLE_FAULT ); return; end if;
         m_dr := '1'; m_fpc := pc; m_fcode := code; dr_by_fault := true;
         if not VALID64( m_fscr ) or not VALID64( m_fscr + 8 ) then EXPECT_HALT( HALT_DELIVERY ); return; end if;
         WREF( m_fscr, std_logic_vector( pc ) ); WREF( m_fscr + 8, std_logic_vector( to_unsigned( code, 64 ) ) );
         a := m_vtb + 8 * code;
         if not VALID64( a ) then EXPECT_HALT( HALT_DELIVERY ); return; end if;
         if unsigned( RD( a ) ) = 0 then EXPECT_HALT( HALT_NULL_VECTOR ); return; end if;
         EXPECT_REDIRECT( unsigned( RD( a ) ), '0', false );
      end procedure;

      procedure MODEL_IRQ( pc : address_t; code : natural ) is
      begin
         START( true );
         if m_frame.rsp - 8 < m_lim.lim_rsp - RESERVE_RSP then EXPECT_HALT( HALT_DELIVERY ); o_maint := false; return; end if;
         m_dr := '1'; m_fpc := pc; m_fcode := code; dr_by_fault := false;
         a := m_frame.rsp - 8;
         if not VALID64( a ) then EXPECT_HALT( HALT_DELIVERY ); return; end if;
         WREF( a, std_logic_vector( pc ) );
         if not VALID64( m_fscr ) or not VALID64( m_fscr + 8 ) then EXPECT_HALT( HALT_DELIVERY ); return; end if;
         WREF( m_fscr, std_logic_vector( pc ) ); WREF( m_fscr + 8, std_logic_vector( to_unsigned( code, 64 ) ) );
         a := m_vtb + 8 * code;
         if not VALID64( a ) then EXPECT_HALT( HALT_DELIVERY ); return; end if;
         if unsigned( RD( a ) ) = 0 then EXPECT_HALT( HALT_NULL_VECTOR ); return; end if;
         o_frame.rsp := m_frame.rsp - 8;
         o_ack := code;
         EXPECT_REDIRECT( unsigned( RD( a ) ), '0', true );
      end procedure;

      -- SYS_REQ : issue de l'instruction sérialisante de tête
      procedure MODEL_SERIAL( pc : address_t; op : opcode_t; val : integer; operand : word64_t ) is
         variable pcs, blk, vec, ctx, cell : address_t;
         variable nd : natural;
         variable good : boolean;
      begin
         if op = OP_TRAP then pcs := pc + 2; elsif op = OP_EXC_RAISE then pcs := pc + 4; else pcs := pc + 1; end if;
         o_rsp := true;
         if op = OP_TRAP and val <= 14 then
            START( false ); n_trapv := n_trapv + 1;
            o_rsp := true;
            a := m_vtb + 8 * val;
            if not VALID64( a ) then o_kind := O_RSP_FAULT; o_fault := 132; return; end if;
            vec := unsigned( RD( a ) );
            if vec /= 0 then
               if m_dr = '1' then EXPECT_HALT( HALT_DOUBLE_FAULT ); o_rsp := false; return; end if;
               if m_frame.rsp - 8 < m_lim.lim_rsp then o_kind := O_RSP_FAULT; o_fault := 134; return; end if;
               o_maint := true; o_first_maint := false;		-- après la lecture du vecteur
               a := m_frame.rsp - 8;
               if not VALID64( a ) then o_kind := O_RSP_FAULT; o_fault := 132; return; end if;
               WREF( a, std_logic_vector( pcs ) );
               o_frame.rsp := m_frame.rsp - 8;
               EXPECT_REDIRECT( vec, '1', true );
            elsif val = 0 then
               EXPECT_HALT( HALT_EXIT ); o_exit := operand; o_rsp := false;
            else
               o_kind := O_RSP_FAULT; o_fault := 137;
            end if;
         elsif op = OP_TRAP and val = 16 then					-- CTX_SAVE
            START( true ); o_rsp := true; n_save := n_save + 1;
            blk := unsigned( operand );
            good := true;
            for i in 0 to 23 loop good := good and VALID64( blk + 8 * i ); end loop;
            if not good then o_kind := O_RSP_FAULT; o_fault := 132; return; end if;
            WREF( blk, std_logic_vector( pcs ) );
            WREF( blk + 8, std_logic_vector( m_frame.dsp - 8 ) );
            WREF( blk + 16, std_logic_vector( m_frame.rsp ) );
            WREF( blk + 24, std_logic_vector( m_copile.cfp ) );
            WREF( blk + 32, std_logic_vector( m_copile.csp ) );
            WREF( blk + 40, ( 0 => m_dr, others => '0' ) );
            WREF( blk + 48, std_logic_vector( m_lim.lim_dsp ) );
            WREF( blk + 56, std_logic_vector( m_lim.lim_rsp ) );
            WREF( blk + 64, std_logic_vector( m_lim.lim_csp ) );
            for i in 0 to 14 loop WREF( blk + 72 + 8 * i, std_logic_vector( m_frame.display( i ) ) ); end loop;
            o_rsp_result := true; o_result := ( others => '0' );
            EXPECT_REDIRECT( pcs, '1', false );
         elsif op = OP_TRAP and val = 17 then					-- CTX_RESTORE
            START( true ); o_rsp := true; n_restore := n_restore + 1;
            blk := unsigned( operand );
            good := true;
            for i in 0 to 23 loop good := good and VALID64( blk + 8 * i ); end loop;
            if not good then o_kind := O_RSP_FAULT; o_fault := 132; return; end if;
            a := unsigned( RD( blk + 8 ) ) + 8;
            if not VALID64( a ) then o_kind := O_RSP_FAULT; o_fault := 132; return; end if;
            o_frame.dsp := a; o_frame.rsp := unsigned( RD( blk + 16 ) );
            for i in 0 to 14 loop o_frame.display( i ) := unsigned( RD( blk + 72 + 8 * i ) ); end loop;
            o_copile.cfp := unsigned( RD( blk + 24 ) ); o_copile.csp := unsigned( RD( blk + 32 ) );
            m_dr := RD( blk + 40 )( 0 );
            m_lim.lim_dsp := unsigned( RD( blk + 48 ) ); m_lim.lim_rsp := unsigned( RD( blk + 56 ) );
            m_lim.lim_csp := unsigned( RD( blk + 64 ) );
            WREF( a, ( 0 => '1', others => '0' ) );
            EXPECT_REDIRECT( unsigned( RD( blk ) ), '1', true );
         elsif op = OP_TRAP and val = 18 then					-- SET_IMASK
            START( false ); o_rsp := true; n_imask := n_imask + 1;
            o_rsp_result := true; o_result := ( others => '0' ); o_result( 31 downto 0 ) := m_imask;
            m_imask := operand( 31 downto 0 );
            EXPECT_REDIRECT( pcs, '1', false );
         elsif op = OP_TRAP then						-- non attribué
            START( false ); o_rsp := true;
            o_kind := O_RSP_FAULT; o_fault := 137;
         elsif op = OP_RTX then
            START( true ); o_rsp := true; n_rtx := n_rtx + 1;
            if not VALID64( m_frame.rsp ) then o_kind := O_RSP_FAULT; o_fault := 132; return; end if;
            m_dr := '0';
            o_frame.rsp := m_frame.rsp + 8;
            EXPECT_REDIRECT( unsigned( RD( m_frame.rsp ) ), '1', true );
         else								-- EXC_RAISE
            START( true ); o_rsp := true; n_exc := n_exc + 1;
            cell := m_frame.display( 0 ) + to_unsigned( val, 64 );
            if not VALID64( cell ) then o_kind := O_RSP_FAULT; o_fault := 132; return; end if;
            ctx := unsigned( RD( cell ) );
            good := true;
            for i in 0 to 6 loop good := good and VALID64( ctx + 8 * i ); end loop;
            if not good then o_kind := O_RSP_FAULT; o_fault := 132; return; end if;
            if unsigned( RD( ctx + 48 ) ) > 15 then nd := 15; else nd := to_integer( unsigned( RD( ctx + 48 ) ) ); end if;
            for i in 0 to nd - 1 loop good := good and VALID64( ctx + 56 + 8 * i ); end loop;
            if not good then o_kind := O_RSP_FAULT; o_fault := 132; return; end if;
            o_frame.dsp := unsigned( RD( ctx + 16 ) ); o_frame.rsp := unsigned( RD( ctx + 24 ) );
            for i in 0 to nd - 1 loop o_frame.display( i ) := unsigned( RD( ctx + 56 + 8 * i ) ); end loop;
            o_copile.cfp := unsigned( RD( ctx + 32 ) ); o_copile.csp := unsigned( RD( ctx + 40 ) );
            m_dr := '0';
            WREF( cell, RD( ctx ) );
            EXPECT_REDIRECT( unsigned( RD( ctx + 8 ) ), '1', true );
         end if;
      end procedure;

      ----------------------------------------------------------------------------
      -- Préparation d'une vie : mémoire, bloc de démarrage, contextes
      ----------------------------------------------------------------------------

      procedure PREPARE_LIFE is
         variable v : word64_t;
      begin
         for i in mem'range loop mem( i ) := x"00"; end loop;
         -- vecteurs : services 1..7 et interruptions servis, EXIT nul, 8..14 nuls ; fautes servies
         for i in 0 to 255 loop
            v := ( others => '0' );
            if ( i >= 1 and i <= 7 ) or ( i >= 32 and i <= 63 ) or ( i >= 128 and i <= 137 ) then
               v := std_logic_vector( to_unsigned( 16#500000# + 64 * i, 64 ) );
               if RAND < 0.01 then v := ( others => '0' ); end if;		-- vecteur nul : arrêt
            end if;
            WR( mem, ADR( VTB_AT + 8 * i ), v );
         end loop;
         -- bloc de démarrage
         WR( mem, ADR( BOOT_AT + BOOT_PC ), std_logic_vector( ADR( 16#400100# ) ) );
         WR( mem, ADR( BOOT_AT + BOOT_DSP ), std_logic_vector( ADR( DSTK_AT + 64 ) ) );
         WR( mem, ADR( BOOT_AT + BOOT_RSP ), std_logic_vector( ADR( RSP0 ) ) );
         WR( mem, ADR( BOOT_AT + BOOT_CFP ), std_logic_vector( ADR( LCSP - 512 ) ) );
         WR( mem, ADR( BOOT_AT + BOOT_CSP ), std_logic_vector( ADR( LCSP - 256 ) ) );
         WR( mem, ADR( BOOT_AT + BOOT_DR ), ( others => '0' ) );
         WR( mem, ADR( BOOT_AT + BOOT_LIM_DSP ), std_logic_vector( ADR( LDSP ) ) );
         WR( mem, ADR( BOOT_AT + BOOT_LIM_RSP ), std_logic_vector( ADR( LRSP ) ) );
         WR( mem, ADR( BOOT_AT + BOOT_LIM_CSP ), std_logic_vector( ADR( LCSP ) ) );
         WR( mem, ADR( BOOT_AT + BOOT_DISPLAY ), std_logic_vector( ADR( DSTK_AT ) ) );
         for i in 1 to 14 loop WR( mem, ADR( BOOT_AT + BOOT_DISPLAY + 8 * i ), RAND_WORD ); end loop;
         WR( mem, ADR( BOOT_AT + BOOT_HP ), std_logic_vector( ADR( ZB + 16#3F00# ) ) );
         WR( mem, ADR( BOOT_AT + BOOT_LIM_HP ), std_logic_vector( ADR( ZB + 16#3C00# ) ) );
         if RAND < 0.03 then
            WR( mem, ADR( BOOT_AT + BOOT_VTB ), x"0000000000000008" );		-- VTB invalide
         else
            WR( mem, ADR( BOOT_AT + BOOT_VTB ), std_logic_vector( ADR( VTB_AT ) ) );
         end if;
         if RAND < 0.03 then
            WR( mem, ADR( BOOT_AT + BOOT_FSCR ), x"0000000000000010" );		-- FSCR invalide
         else
            WR( mem, ADR( BOOT_AT + BOOT_FSCR ), std_logic_vector( ADR( FSCR_AT ) ) );
         end if;
         if RAND < 0.6 then
            WR( mem, ADR( BOOT_AT + BOOT_IMASK ), ( others => '0' ) );		-- tout démasqué
         else
            WR( mem, ADR( BOOT_AT + BOOT_IMASK ), x"00000000" & std_logic_vector( to_unsigned( RAND_INT( 65535 ), 32 ) ) );
         end if;
         -- blocs de contexte (CTX_RESTORE) : une tâche plausible chacun
         for bk in 0 to 3 loop
            a := ADR( CTXB_AT + 192 * bk );
            WR( mem, a, std_logic_vector( ADR( 16#400800# + 16 * bk ) ) );
            WR( mem, a + 8, std_logic_vector( ADR( DSTK_AT + 256 + 128 * bk ) ) );
            WR( mem, a + 16, std_logic_vector( ADR( RSP0 - 64 * bk ) ) );
            WR( mem, a + 24, std_logic_vector( ADR( LCSP - 1024 ) ) );
            WR( mem, a + 32, std_logic_vector( ADR( LCSP - 768 ) ) );
            WR( mem, a + 40, ( 0 => B( bk = 3 ), others => '0' ) );
            WR( mem, a + 48, std_logic_vector( ADR( LDSP ) ) );
            WR( mem, a + 56, std_logic_vector( ADR( LRSP ) ) );
            WR( mem, a + 64, std_logic_vector( ADR( LCSP ) ) );
            for i in 0 to 14 loop WR( mem, a + 72 + 8 * i, std_logic_vector( ADR( DSTK_AT + 8 * i ) ) ); end loop;
         end loop;
         -- contextes d'exception, désignés par les cellules DISPLAY[0] + 8k, k = 1..4
         for e in 0 to 3 loop
            a := ADR( EXCX_AT + 192 * e );
            WR( mem, ADR( DSTK_AT + 8 * ( e + 1 ) ), std_logic_vector( a ) );
            WR( mem, a, std_logic_vector( ADR( EXCX_AT + 192 * ( ( e + 1 ) mod 4 ) ) ) );	-- PREV : le contexte englobant
            WR( mem, a + 8, std_logic_vector( ADR( 16#400C00# + 16 * e ) ) );	-- DISPATCH
            WR( mem, a + 16, std_logic_vector( ADR( DSTK_AT + 512 + 64 * e ) ) );
            WR( mem, a + 24, std_logic_vector( ADR( RSP0 - 32 * e ) ) );
            WR( mem, a + 32, std_logic_vector( ADR( LCSP - 900 ) ) );
            WR( mem, a + 40, std_logic_vector( ADR( LCSP - 800 ) ) );
            WR( mem, a + 48, std_logic_vector( to_unsigned( 4 * e + RAND_INT( 3 ), 64 ) ) );	-- n : 0 .. 15
            if e = 3 and RAND < 0.5 then WR( mem, a + 48, x"0000000000000020" ); end if;	-- n > 15
            WR( mem, a + 56, std_logic_vector( ADR( DSTK_AT ) ) );		-- le niveau 0 ne change pas
            for i in 1 to 14 loop WR( mem, a + 56 + 8 * i, std_logic_vector( ADR( DSTK_AT + 1024 + 8 * i ) ) ); end loop;
         end loop;
         WR( mem, ADR( DSTK_AT + 8 * 5 ), x"0000000000000008" );			-- contexte invalide
         ref := mem;
      end procedure;

      -- le modèle lit le bloc de démarrage (comme l'unité)
      procedure MODEL_BOOT is
         variable good : boolean := true;
      begin
         START( false );
         for i in 0 to 28 loop good := good and VALID64( boot_block + 8 * i ); end loop;
         if not good then EXPECT_HALT( HALT_DELIVERY ); return; end if;
         a := boot_block;
         m_dr := RD( a + BOOT_DR )( 0 );
         m_lim := ( lim_dsp => unsigned( RD( a + BOOT_LIM_DSP ) ), lim_rsp => unsigned( RD( a + BOOT_LIM_RSP ) ),
                    lim_csp => unsigned( RD( a + BOOT_LIM_CSP ) ), lim_hp => unsigned( RD( a + BOOT_LIM_HP ) ) );
         m_vtb := unsigned( RD( a + BOOT_VTB ) ); m_fscr := unsigned( RD( a + BOOT_FSCR ) );
         m_imask := RD( a + BOOT_IMASK )( 31 downto 0 );
         o_frame.dsp := unsigned( RD( a + BOOT_DSP ) ); o_frame.rsp := unsigned( RD( a + BOOT_RSP ) );
         for i in 0 to 14 loop o_frame.display( i ) := unsigned( RD( a + BOOT_DISPLAY + 8 * i ) ); end loop;
         o_copile := ( cfp => unsigned( RD( a + BOOT_CFP ) ), csp => unsigned( RD( a + BOOT_CSP ) ),
                       hp => unsigned( RD( a + BOOT_HP ) ), hp_valid => '1' );
         EXPECT_REDIRECT( unsigned( RD( a + BOOT_PC ) ), '0', true );
      end procedure;

      -- tête suivante, au pc donné
      procedure NEXT_HEAD( pc : address_t ) is
         variable u : real := RAND;
      begin
         h_pc := pc; h_operand := ( others => '0' ); h_val := 0; h_op := x"10"; h_code := 0;
         events := events + 1;
         if events >= EVENTS_PER_LIFE then					-- fin de vie : EXIT
            h_kind := H_SERIAL; h_op := OP_TRAP; h_val := 0; h_operand := RAND_WORD;
         elsif m_dr = '1' then						-- dans un handler
            if u < 0.40 then
               h_kind := H_NORMAL;
            elsif u < 0.995 then							-- sa fin attendue
               h_kind := H_SERIAL;
               if dr_by_fault then
                  h_op := OP_EXC_RAISE; h_val := 8 * ( 1 + RAND_INT( 3 ) );
                  if RAND < 0.01 then h_val := 40; end if;			-- cellule invalide
               else
                  h_op := OP_RTX;
               end if;
               if RAND < 0.08 then h_op := OP_TRAP; h_val := 18; h_operand := RAND_WORD; end if;
            else
               h_kind := H_FAULT; h_code := 128 + RAND_INT( 9 );		-- double faute
            end if;
         elsif u < 0.45 then
            h_kind := H_NORMAL;
         elsif u < 0.55 then
            h_kind := H_FAULT; h_code := 128 + RAND_INT( 9 );
         elsif u < 0.63 then
            h_kind := H_SERIAL; h_op := OP_TRAP; h_val := 1 + RAND_INT( 13 );	-- 1..14
         elsif u < 0.70 then
            h_kind := H_SERIAL; h_op := OP_TRAP; h_val := 16;
            h_operand := std_logic_vector( ADR( CTXB_AT + 192 * RAND_INT( 3 ) ) );
            if RAND < 0.1 then h_operand := std_logic_vector( ADR( ZB + ZS - 100 ) ); end if;
         elsif u < 0.76 then
            h_kind := H_SERIAL; h_op := OP_TRAP; h_val := 17;
            h_operand := std_logic_vector( ADR( CTXB_AT + 192 * RAND_INT( 3 ) ) );
            if RAND < 0.1 then h_operand := std_logic_vector( ADR( 64 ) ); end if;
         elsif u < 0.82 then
            h_kind := H_SERIAL; h_op := OP_TRAP; h_val := 18; h_operand := RAND_WORD;
            if RAND < 0.6 then h_operand( 31 downto 0 ) := x"FFFF0000"; end if;	-- démasque 32..47
         elsif u < 0.86 then
            h_kind := H_SERIAL; h_op := OP_TRAP;
            if RAND < 0.5 then h_val := 15; else h_val := 19 + RAND_INT( 236 ); end if;
         elsif u < 0.92 then
            h_kind := H_SERIAL; h_op := OP_EXC_RAISE; h_val := 8 * ( 1 + RAND_INT( 4 ) );	-- 8..40 (40 : invalide)
         elsif u < 0.94 then
            h_kind := H_SERIAL; h_op := OP_RTX;					-- hors handler (permis, inutile)
         else
            h_kind := H_NORMAL;
         end if;
      end procedure;

   begin
      s2 := SEED_2;

      for lv in 1 to LIVES loop
         life := lv;
		-- nouvelle vie : mémoire préparée, RESET_i, démarrage attendu
         PREPARE_LIFE;
         if RAND < 0.03 then boot_block <= ADR( ZB + ZS - 64 ); else boot_block <= ADR( BOOT_AT ); end if;
         m_fpc := ( others => '0' ); m_fcode := 0;				-- comme au RESET_i
         m_frame.dsp := ( others => '0' ); m_frame.rsp := ( others => '0' );
         m_frame.display := ( others => ( others => '0' ) );
         m_copile := ( cfp => ( others => '0' ), csp => ( others => '0' ), hp => ( others => '0' ), hp_valid => '0' );
         c_frame <= m_frame; c_copile <= m_copile;
         head.valid <= '0'; h_kind := H_NONE; sys_req.valid <= '0'; irq_pending <= ( others => '0' );
         pq_n := 0; mem_rsp <= NO_MEM_RESPONSE; events := 0; done_in := -1; cool := 0; sync_due := false;
         reset <= '1';
         wait until falling_edge( clk );
         wait until falling_edge( clk );
         reset <= '0';
         wait for 1 ns;
         MODEL_BOOT;
         life_over := false;

         next_pc := ( others => '0' );
         while not life_over loop
            now := now + 1;
            if now > CYCLE_MAX then
               CHECK( c, false, "budget de cycles épuisé" ); exit;
            end if;

		-- mémoire : réponse échue, READY_i
            if pq_n > 0 and pq( pq_head ).due <= now then
               mem_rsp <= pq( pq_head ).rsp; pq_head := ( pq_head + 1 ) mod 16; pq_n := pq_n - 1;
            else
               mem_rsp <= NO_MEM_RESPONSE;
            end if;
            ready_v := B( RAND < 0.7 );
            mem_ready <= ready_v;

		-- LSQ et maintenance
            drained <= B( not busy or drain_left = 0 );
            maint_done <= '0';
            if busy and maint_seen and not maint_given then
               if maint_left = 0 then maint_done <= '1'; maint_given := true; else maint_left := maint_left - 1; end if;
            end if;

		-- tête du ROB : une nouvelle après un délai ; COMPLEX lance SYS_REQ_i quand elle paraît
            sys_req.valid <= '0';
            if h_kind = H_NONE and not busy and cool = 0 and halted = '0' then
               if h_wait > 0 then
                  h_wait := h_wait - 1;
               else
                  NEXT_HEAD( next_pc ); h_new := true; done_in := -1;
                  h_atomic := h_kind = H_NORMAL and RAND < 0.15;		-- un bloc qui écrit en tête
                  rob_seq := rob_seq + 1;
                  if h_kind = H_SERIAL then
                     sys_req <= ( valid => '1', rob_index => to_unsigned( rob_seq mod ROB_SIZE, ROB_INDEX_BITS ),
                                  op => h_op, val => to_signed( h_val, 32 ), operand => h_operand );
                  end if;
               end if;
            end if;
            if done_in > 0 then done_in := done_in - 1; end if;
            head_fault_now := h_kind = H_FAULT or ( h_kind = H_SERIAL and done_in = 0 and done_fault /= 0 );
            head.valid <= B( h_kind /= H_NONE );
            head.pc <= h_pc;
            head.rob_index <= to_unsigned( rob_seq mod ROB_SIZE, ROB_INDEX_BITS );
            head.done <= B( h_kind = H_NORMAL or h_kind = H_FAULT or ( h_kind = H_SERIAL and done_in = 0 ) );
            head.serializing <= B( h_kind = H_SERIAL );
            head.fault <= NO_FAULT;
            if h_kind = H_FAULT then head.fault <= ( valid => '1', code => to_unsigned( h_code, 8 ) ); end if;
            if h_kind = H_SERIAL and done_in = 0 and done_fault /= 0 then
               head.fault <= ( valid => '1', code => to_unsigned( done_fault, 8 ) );
            end if;
            c_frame <= m_frame; c_copile <= m_copile;
            head_atomic <= B( h_atomic and h_kind = H_NORMAL );

		-- interruptions : une requête naît parfois sous une instruction ordinaire
            if not busy and cool = 0 and h_kind = H_NORMAL and m_dr = '0' and RAND < 0.2 then
               irq_pending( RAND_INT( IRQ_COUNT - 1 ) ) <= '1';
            end if;
            wait for 1 ns;
            deliverable := -1;
            for i in 0 to IRQ_COUNT - 1 loop
               if deliverable < 0 and irq_pending( i ) = '1' and m_imask( i ) = '0' then deliverable := i; end if;
            end loop;
            if m_dr = '1' or ( h_atomic and h_kind = H_NORMAL ) then deliverable := -1; end if;

		-- au repos : état visible, retrait tenu
            if not busy and cool = 0 and halted = '0' then
               exp_hold := B( deliverable >= 0 );
               ok := dr = m_dr and hold = exp_hold;
               if m_dr = '1' then
                  ok := ok and limits.lim_dsp = m_lim.lim_dsp + RESERVE_DSP and limits.lim_rsp = m_lim.lim_rsp - RESERVE_RSP
                        and limits.lim_csp = m_lim.lim_csp + RESERVE_CSP;
               else
                  ok := ok and limits.lim_dsp = m_lim.lim_dsp and limits.lim_rsp = m_lim.lim_rsp
                        and limits.lim_csp = m_lim.lim_csp;
               end if;
               ok := ok and limits.lim_hp = m_lim.lim_hp and fpc = m_fpc and fcode = to_unsigned( m_fcode, 8 );
               if ok then CHECK_PASSED( c ); else
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : état au repos",
                         "DR " & std_logic'image( m_dr ) & " HOLD " & std_logic'image( exp_hold ) & " FPC " & HEX( m_fpc )
                            & " FCODE " & integer'image( m_fcode ) & " LIM_RSP " & HEX( m_lim.lim_rsp ),
                         "DR " & std_logic'image( dr ) & " HOLD " & std_logic'image( hold ) & " FPC " & HEX( fpc )
                            & " FCODE " & integer'image( to_integer( fcode ) ) & " LIM_RSP " & HEX( limits.lim_rsp ) );
               end if;
            end if;

		-- l'unité au repos commence-t-elle une séquence ? (ordre de priorité du contrat)
            if not busy and cool = 0 and halted = '0' then
               if head_fault_now then
                  if h_kind = H_FAULT then MODEL_FAULT( h_pc, h_code ); else MODEL_FAULT( h_pc, done_fault ); end if;
                  n_faults := n_faults + 1;
               elsif h_kind = H_SERIAL and h_new then
                  MODEL_SERIAL( h_pc, h_op, h_val, h_operand );
               elsif deliverable >= 0 and h_kind /= H_NONE then
                  MODEL_IRQ( h_pc, IRQ_FIRST + deliverable ); n_irq := n_irq + 1;
               end if;
            end if;
            h_new := false;

		-- sorties de l'unité pendant le cycle
            if maint.valid = '1' and not maint_seen then
               if not ( busy and o_maint ) then
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : STACK_MAINT_o inattendu" );
               end if;
               maint_seen := true;
            end if;
            if sys_rsp.valid = '1' then
               if not ( busy and o_rsp and not rsp_seen ) then
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : SYS_RSP_o inattendu" );
               elsif o_kind = O_RSP_FAULT then
                  if sys_rsp.fault.valid = '1' and sys_rsp.fault.code = o_fault then CHECK_PASSED( c ); else
                     CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : faute de SYS_RSP_o",
                            integer'image( o_fault ), integer'image( to_integer( sys_rsp.fault.code ) ) );
                  end if;
                  if o_fault = 132 then n_132 := n_132 + 1; elsif o_fault = 134 then n_134 := n_134 + 1; else n_137 := n_137 + 1; end if;
                  done_in := 1 + RAND_INT( 2 ); done_fault := o_fault;	-- COMPLEX termine en faute
                  busy := false; cool := 1;
               else
                  ok := sys_rsp.fault.valid = '0' and sys_rsp.result_valid = B( o_rsp_result )
                        and ( not o_rsp_result or sys_rsp.result = o_result );
                  if ok then CHECK_PASSED( c ); else
                     CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : réponse SYS_RSP_o" );
                  end if;
                  done_in := 1 + RAND_INT( 2 ); done_fault := 0;
               end if;
               rsp_seen := true;
            end if;
            if sync_due then						-- cycle de la reprise
               ok := sync_valid = '1' and sync_frame = o_frame and sync_copile.cfp = o_copile.cfp
                     and sync_copile.csp = o_copile.csp and sync_copile.hp_valid = o_copile.hp_valid
                     and ( o_copile.hp_valid = '0' or sync_copile.hp = o_copile.hp );
               if ok then CHECK_PASSED( c ); else
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : SYNC" );
               end if;
               m_frame := o_frame;
               m_copile.cfp := o_copile.cfp; m_copile.csp := o_copile.csp;
               if o_copile.hp_valid = '1' then m_copile.hp := o_copile.hp; end if;
               sync_due := false; n_syncs := n_syncs + 1;
            elsif sync_valid = '1' then
               CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : SYNC inattendue" );
            end if;
            if redirect.valid = '1' then
               ok := busy and o_kind = O_REDIRECT and ( not o_rsp or rsp_seen )
                     and redirect.pc = o_pc and redirect.retire_head = o_rh;
               if o_ack >= 0 then
                  ok := ok and irq_ack = '1' and irq_ack_code = to_unsigned( o_ack, 8 );
               else
                  ok := ok and irq_ack = '0';
               end if;
               if ok then CHECK_PASSED( c ); else
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : redirection",
                         HEX( o_pc ) & " retire_head " & std_logic'image( o_rh ),
                         HEX( redirect.pc ) & " retire_head " & std_logic'image( redirect.retire_head ) );
               end if;
               if o_ack >= 0 then irq_pending( o_ack - IRQ_FIRST ) <= '0'; end if;
               -- les mots écrits pendant la séquence
               ok := true;
               for i in 0 to n_touched - 1 loop
                  if VALID64( touched( i ) ) then
                     for bt in 0 to 7 loop
                        x := to_integer( touched( i )( 30 downto 0 ) ) - ZB + bt;
                        if mem( x ) /= ref( x ) then ok := false; end if;
                     end loop;
                  end if;
               end loop;
               if ok then CHECK_PASSED( c ); else
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : mémoire écrite" );
               end if;
               if o_maint and not maint_given then
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : maintenance oubliée" );
               end if;
               sync_due := o_sync;
               h_kind := H_NONE; h_wait := RAND_INT( 3 ); done_in := -1;
               next_pc := o_pc;
               busy := false; cool := 2; n_redirects := n_redirects + 1; n_events := n_events + 1;
            elsif irq_ack = '1' then
               CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : IRQ_ACK_o hors redirection" );
            end if;
            if halted = '1' then
               ok := busy and o_kind = O_HALT and halt_cause = o_cause and hold = '1'
                     and ( o_cause /= HALT_EXIT or exit_code = o_exit );
               if ok then CHECK_PASSED( c ); else
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : arrêt",
                         "cause " & integer'image( to_integer( o_cause ) ) & " attendu=" & boolean'image( busy and o_kind = O_HALT ),
                         "cause " & integer'image( to_integer( halt_cause ) ) );
               end if;
               ok := true;							-- toute la mémoire, en fin de vie
               for i in mem'range loop
                  if mem( i ) /= ref( i ) then ok := false; end if;
               end loop;
               if ok then CHECK_PASSED( c ); else
                  CHECK( c, false, "vie " & integer'image( life ) & " : mémoire en fin de vie" );
               end if;
               n_halts( to_integer( halt_cause ) ) := n_halts( to_integer( halt_cause ) ) + 1;
               busy := false; life_over := true;
            end if;

		-- front : accès mémoire accepté, retrait d'une instruction ordinaire
            wait until rising_edge( clk );
            if mem_req.valid = '1' and ready_v = '1' then
               if drained = '0' then
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : accès avant LSQ_DRAINED_i" );
               end if;
               if busy and not maint_given and ( o_first_maint or ( o_maint and mem_req.write = '1' ) ) then
                  CHECK( c, false, "vie " & integer'image( life ) & ", cycle " & integer'image( now ) & " : accès avant la maintenance" );
               end if;
               w := ( others => '0' );
               if mem_req.size /= "11" or not VALID64( mem_req.address ) then
                  pq( ( pq_head + pq_n ) mod 16 ) := ( rsp => ( valid => '1', rdata => w, fault => '1' ), due => now + 1 + RAND_INT( 3 ) );
               else
                  if mem_req.write = '1' then
                     WR( mem, mem_req.address, mem_req.wdata ); NOTE( mem_req.address );
                  elsif mem_req.probe = '0' then
                     x := to_integer( mem_req.address( 30 downto 0 ) ) - ZB;
                     for bt in 0 to 7 loop w( 8 * bt + 7 downto 8 * bt ) := mem( x + bt ); end loop;
                  end if;
                  pq( ( pq_head + pq_n ) mod 16 ) := ( rsp => ( valid => '1', rdata => w, fault => '0' ), due => now + 1 + RAND_INT( 3 ) );
               end if;
               pq_n := pq_n + 1;
            end if;
            if h_kind = H_NORMAL and hold = '0' and not busy and cool = 0 then	-- retrait
               if h_atomic and irq_pending /= ( irq_pending'range => '0' ) then n_atomic := n_atomic + 1; end if;
               h_kind := H_NONE; next_pc := h_pc + 4; h_wait := RAND_INT( 1 ); h_atomic := false;
               if RAND < 0.3 and m_frame.dsp + 8 < LDSP then m_frame.dsp := m_frame.dsp + 8; end if;
               if RAND < 0.2 and m_frame.rsp - 8 > LRSP + 256 then m_frame.rsp := m_frame.rsp - 8; end if;
               if RAND < 0.06 then m_frame.rsp := ADR( LRSP + 8 * RAND_INT( 1 ) ); end if;		-- 134 au prochain push
               if RAND < 0.005 then m_frame.rsp := ADR( LRSP - RESERVE_RSP + 8 * RAND_INT( 1 ) ); end if;	-- réserve
               if RAND < 0.05 then m_frame.rsp := ADR( RSP0 - 8 * RAND_INT( 16 ) ); end if;		-- retour au large
            end if;
            if busy and drain_left > 0 then drain_left := drain_left - 1; end if;
            if cool > 0 then cool := cool - 1; end if;
            wait until falling_edge( clk );
         end loop;
      end loop;

      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; " & integer'image( LIVES )
             & " vies, " & integer'image( n_events ) & " redirections ; fautes " & integer'image( n_faults )
             & ", interruptions " & integer'image( n_irq ) & ", TRAP 0..14 " & integer'image( n_trapv ) & ", CTX_SAVE "
             & integer'image( n_save ) & ", CTX_RESTORE " & integer'image( n_restore ) & ", SET_IMASK "
             & integer'image( n_imask ) & ", RTX " & integer'image( n_rtx ) & ", EXC_RAISE " & integer'image( n_exc )
             & " ; réponses en faute 132 " & integer'image( n_132 ) & ", 134 " & integer'image( n_134 ) & ", 137 "
             & integer'image( n_137 ) & " ; SYNC " & integer'image( n_syncs ) & " ; arrêts : EXIT "
             & integer'image( n_halts( 2 ) ) & ", double faute " & integer'image( n_halts( 3 ) ) & ", vecteur nul "
             & integer'image( n_halts( 4 ) ) & ", livraison " & integer'image( n_halts( 5 ) )
             & " ; blocs retirés malgré une interruption pendante " & integer'image( n_atomic ) severity note;
      CHECK( c, n_faults > 100 and n_irq > 50 and n_save > 50 and n_restore > 50 and n_imask > 50 and n_rtx > 20
                and n_exc > 50 and n_132 > 10 and n_134 > 0 and n_137 > 20 and n_halts( 2 ) > 10 and n_halts( 3 ) > 0
                and n_halts( 5 ) > 0 and n_atomic > 20,
             "le tirage a exercé fautes, interruptions, services, réponses en faute et arrêts" );
      running <= false;
      FINISH( c, "T_S_SYSTEM_UNIT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
