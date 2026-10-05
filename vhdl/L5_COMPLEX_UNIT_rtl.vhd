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
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  COMPLEX_UNIT, architecture RTL : première étape (voir le contrat).
		--
		--  Un automate, une instruction à la fois. Les blocs passent par un moteur
		--  commun : une liste d'au plus trois intervalles (lus, écrits), un sondage par
		--  morceaux (8 octets, puis 1), une maintenance par intervalle, puis une boucle
		--  d'accès (octets ; composants pour LEXCMP). Un seul accès mémoire en vol ;
		--  une instruction abandonnée pendant un accès attend sa réponse (S_FLUSH).
		--------------------------------------------------------------------------------


				---
architecture			RTL
of COMPLEX_UNIT is		---

   constant OP_FEXP		: opcode_t := x"24";
   constant OP_BLKMOV		: opcode_t := x"34";
   constant OP_BLKCMP		: opcode_t := x"35";
   constant OP_CO_VAR		: opcode_t := x"38";
   constant OP_HEAP_ALLOC	: opcode_t := x"39";
   constant OP_BLKAND		: opcode_t := x"3C";
   constant OP_BLKOU		: opcode_t := x"3D";
   constant OP_BLKOUX		: opcode_t := x"3E";
   constant OP_BLKNOT		: opcode_t := x"3F";
   constant OP_LINK16		: opcode_t := x"44";
   constant OP_LINK24		: opcode_t := x"48";
   constant OP_EXCM16		: opcode_t := x"45";
   constant OP_EXCM24		: opcode_t := x"49";
   constant OP_UNLINK		: opcode_t := x"F8";
   constant OP_UNLINKR		: opcode_t := x"F9";
   constant OP_RTX		: opcode_t := x"FF";
   constant OP_EXC_RAISE	: opcode_t := x"FE";

   type state_t		is ( S_IDLE, S_READ, S_SYS, S_SYS_WAIT, S_FEXP_START, S_FEXP, S_FUPD, S_HEAD, S_DRAIN, S_ATOMIC, S_HOLD_WAIT, S_FSTEP, S_FSTEP_WAIT,
				     S_RANGE, S_PROBE, S_PROBE_WAIT, S_MAINT, S_ACC, S_ACC_WAIT, S_INVAL, S_RESULT,
				     S_RETIRE_WAIT, S_FLUSH, S_LEXEC, S_ULOAD, S_UWAIT );
   type range_t		is record
			  base		: address_t;
			  length		: address_t;
			end record;
   type range_array_t		is array( 0 to 2 ) of range_t;

   signal state		: state_t;
   signal instr		: renamed_instruction_t;
   signal opd			: operand_array_t;
   signal res_value		: word64_t;
   signal res_fault		: natural range 0 to 255;
   signal res_dest		: boolean;
   signal at_head		: boolean;					-- attend son retrait

   -- co-pile et tas : exemplaires retiré et spéculatif
   signal cfp_c, cfp_s		: address_t;
   signal frame_c		: frame_state_t;				-- EXC_MACH : DSP, RSP retirés
   signal fin_value		: word64_t;					-- résultat après l'invalidation
   signal fin_dest		: boolean;
   signal fstep		: natural range 0 to 31;			-- accès du groupe frame
   signal csp_c, csp_s		: address_t;
   -- CFP, CSP spéculatifs : valeurs après chaque LINK, UNLINK, UNLINKR en vol
   constant HIST_DEPTH		: positive := 16;
   type hist_entry_t		is record
			  rob		: rob_index_t;
			  cfp, csp	: address_t;
			end record;
   type hist_t			is array( 0 to HIST_DEPTH - 1 ) of hist_entry_t;
   signal hist			: hist_t;
   signal hn			: natural range 0 to HIST_DEPTH;
   signal res_nocomp		: boolean;					-- LINK : la LSQ rend la fin d'exécution
   signal lx_addr		: address_t;				-- LSQ_EXEC_o : adresse, donnée
   signal lx_data		: word64_t;
   signal hp_c, hp_s		: address_t;

   -- blocs
   signal ranges		: range_array_t;
   signal nranges		: natural range 0 to 3;
   signal write_range		: integer range -1 to 2;			-- intervalle écrit
   signal ri			: natural range 0 to 3;			-- intervalle en cours
   signal roff		: address_t;				-- décalage dans l'intervalle
   signal k			: address_t;				-- octet, ou décalage LEXCMP
   signal sub			: natural range 0 to 2;			-- étape de l'octet k
   signal word_a		: word64_t;					-- élément lu ([src] ou [a]) : 1 ou 8 octets
   signal word_mode		: boolean;					-- le bloc avance par mots de 8 octets
   signal wstep		: boolean;					-- l'élément en cours : 8 octets (sinon 1)
   signal comp_g		: word64_t;					-- composant LEXCMP lu à g
   signal lg, ld		: signed( 63 downto 0 );
   signal atomic		: std_logic;
   signal maint_inval		: boolean;					-- maintenance d'invalidation

   signal req			: mem_request_t;
   signal inflight		: boolean;					-- requête acceptée, réponse attendue

   -- FEXP
   signal fexp_start, fexp_abort, fexp_busy, fexp_done : std_logic;
   signal fexp_r		: word64_t;

   function B( x : boolean ) return std_logic is
   begin
      if x then return '1'; else return '0'; end if;
   end function;

   function IS_LINK( op : opcode_t ) return boolean is
   begin
      return op = OP_LINK16 or op = OP_LINK24;
   end function;

   function IS_EXCM( op : opcode_t ) return boolean is
   begin
      return op = OP_EXCM16 or op = OP_EXCM24;
   end function;

   function IS_UNLINK( op : opcode_t ) return boolean is
   begin
      return op = OP_UNLINK or op = OP_UNLINKR;
   end function;

   function IS_FRAME( op : opcode_t ) return boolean is
   begin
      return IS_LINK( op ) or IS_EXCM( op ) or IS_UNLINK( op );
   end function;

   -- écrit la mémoire : HEAD_ATOMIC_o, sondage préalable (LINK, EXC_MACH compris)
   function IS_WRITING_BLOCK( op : opcode_t ) return boolean is
   begin
      return op = OP_BLKMOV or op = OP_BLKAND or op = OP_BLKOU or op = OP_BLKOUX or op = OP_BLKNOT
             or IS_LINK( op ) or IS_EXCM( op );
   end function;

   function IS_BLOCK( op : opcode_t ) return boolean is
   begin
      return IS_WRITING_BLOCK( op ) or op = OP_BLKCMP or ( unsigned( op ) >= 16#C8# and unsigned( op ) <= 16#CE# );
   end function;

   function IS_LEX( op : opcode_t ) return boolean is
   begin
      return unsigned( op ) >= 16#C8# and unsigned( op ) <= 16#CE#;
   end function;

   function SZ_OF( op : opcode_t ) return natural is				-- octets d'un composant
   begin
      return 2 ** to_integer( unsigned( op( 1 downto 0 ) ) );
   end function;

   -- 8 * ceil( n / 8 ), sur 65 bits (dépassement de 2^64 compris)
   function ROUND8( n : unsigned( 63 downto 0 ) ) return unsigned is
      variable r : unsigned( 64 downto 0 );
   begin
      r := resize( n, 65 ) + 7;
      r( 2 downto 0 ) := "000";
      return r;
   end function;

   function EXTEND( w : word64_t; sz : natural; sgn : boolean ) return signed is
      variable r : word64_t := ( others => '0' );
   begin
      r( 8 * sz - 1 downto 0 ) := w( 8 * sz - 1 downto 0 );
      if sgn and sz < 8 and w( 8 * sz - 1 ) = '1' then
         r( 63 downto 8 * sz ) := ( others => '1' );
      end if;
      return signed( r );
   end function;

begin

   FEXP : entity work.FEXP_UNIT
      port map ( CLK_i => CLK_i, RESET_i => RESET_i, START_i => fexp_start, X_i => opd( 0 ), N_i => opd( 1 ),
                 ABORT_i => fexp_abort, BUSY_o => fexp_busy, DONE_o => fexp_done, R_o => fexp_r );

		--------------------------------------------------------------------------------
		-- Sorties
		--------------------------------------------------------------------------------

   ISSUE_READY_o	<= '1' when state = S_IDLE else '0';
   READ_TAGS_o( 0 )	<= instr.source;
   HEAD_ATOMIC_o	<= atomic;
   MEM_REQ_o		<= req;
   COMMITTED_COPILE_o	<= ( cfp => cfp_c, csp => csp_c, hp => hp_c, hp_valid => '0' );
   LSQ_EXEC_o		<= ( valid => B( state = S_LEXEC or state = S_ULOAD ), rob_index => instr.rob_index,
			   address => lx_addr, data => lx_data );			-- LINK, UNLINK, UNLINKR
   FRAME_UPDATE_o	<= ( valid => '1', rob_index => instr.rob_index, lvl => instr.slot.canon.lvl,
			     value => unsigned( opd( 0 ) ) ) when state = S_FUPD		-- UNLINK : FP sauvé
			   else ( valid => '0', rob_index => instr.rob_index, lvl => instr.slot.canon.lvl,
			     value => unsigned( opd( 0 ) ) );
   fexp_start		<= '1' when state = S_FEXP_START else '0';

   SORTIE : process( state, instr, res_value, res_fault, res_dest, res_nocomp, RECOVERY_i, ROB_HEAD_i )
      variable r : exec_result_t;
   begin
      r := ( valid => '0', destination_valid => '0', destination => instr.destination, value => res_value,
             completion => ( valid => '0', rob_index => instr.rob_index, fault => NO_FAULT,
                             taken => '0', target => ( others => '0' ), mispredicted => '0' ) );
      if state = S_RESULT and not ABANDONED( instr.rob_index, RECOVERY_i, ROB_HEAD_i ) then
         r.valid := '1';
         if not res_nocomp or res_fault /= 0 then r.completion.valid := '1'; end if;
         if res_fault /= 0 then
            r.completion.fault := ( valid => '1', code => to_unsigned( res_fault, 8 ) );
         elsif res_dest then
            r.destination_valid := instr.destination_valid;
         end if;
      end if;
      RESULT_o( 0 ) <= r;
   end process;

   DEMANDES : process( state, instr, opd )
   begin
      SYS_REQ_o <= ( valid => '0', rob_index => instr.rob_index, op => instr.slot.canon.op,
                     val => instr.slot.canon.val, operand => opd( 0 ) );
      if state = S_SYS then SYS_REQ_o.valid <= '1'; end if;
   end process;

   INTERVALLES : process( state, instr, ranges, nranges, write_range, ri, maint_inval )
   begin
      RANGE_o <= ( valid => '0', rob_index => instr.rob_index, read_valid => '0', read_base => ranges( 0 ).base,
                   read_length => ranges( 0 ).length, write_valid => '0', write_base => ( others => '0' ),
                   write_length => ( others => '0' ) );
      if state = S_RANGE then
         RANGE_o.valid <= '1';
         RANGE_o.read_valid <= '1';
         if write_range >= 0 then
            RANGE_o.write_valid <= '1';
            RANGE_o.write_base <= ranges( write_range ).base;
            RANGE_o.write_length <= ranges( write_range ).length;
         end if;
      end if;
      STACK_MAINT_o <= ( valid => '0', kind => MAINT_WRITEBACK_RANGE, base => ( others => '0' ),
                         length => ( others => '0' ) );
      if state = S_MAINT and ri < nranges then
         STACK_MAINT_o <= ( valid => '1', kind => MAINT_WRITEBACK_RANGE, base => ranges( ri ).base,
                            length => ranges( ri ).length );
      elsif state = S_INVAL and write_range >= 0 then
         STACK_MAINT_o <= ( valid => '1', kind => MAINT_INVALIDATE_RANGE, base => ranges( write_range ).base,
                            length => ranges( write_range ).length );
      end if;
   end process;

		--------------------------------------------------------------------------------
		-- Automate
		--------------------------------------------------------------------------------

   AUTOMATE : process( CLK_i )
      variable o		: operand_array_t;
      variable op		: opcode_t;
      variable sz65		: unsigned( 64 downto 0 );
      variable nxt		: unsigned( 65 downto 0 );
      variable left		: address_t;
      variable b		: byte_t;
      variable cg, cd		: signed( 63 downto 0 );
      variable sz		: natural;
      variable done_acc	: boolean;
      variable dif		: unsigned( 63 downto 0 );
      variable step8		: boolean;
      variable esz		: natural range 0 to 3;
      variable w		: word64_t;
      variable n		: natural range 0 to 8;

      procedure FINISH( value : word64_t; fault : natural; dest : boolean ) is
      begin
         res_value <= value; res_fault <= fault; res_dest <= dest; res_nocomp <= false; state <= S_RESULT;
      end procedure;

      variable hv		: hist_t;
      variable hnv		: natural range 0 to HIST_DEPTH;
      variable ccfp, ccsp	: address_t;					-- état retiré, après les retraits du cycle
      variable rcfp, rcsp	: address_t;					-- état spéculatif après une reprise
      variable got		: boolean;
      variable nv		: address_t;

      procedure PUSH( c, p : address_t ) is					-- valeurs après l'instruction en cours
      begin
         hv( hnv ) := ( rob => instr.rob_index, cfp => c, csp => p ); hnv := hnv + 1;
         cfp_s <= c; csp_s <= p;
      end procedure;

      -- un accès mémoire (un seul en vol)
      procedure MEM_ACCESS( a : address_t; size : natural; wr : boolean; data : word64_t ) is
      begin
         req <= ( valid => '1', write => '0', probe => '0', address => a, size => to_unsigned( size, 2 ),
                  wdata => data );
         if wr then req.write <= '1'; end if;
      end procedure;

   begin
      if rising_edge( CLK_i ) then
         fexp_abort <= '0';
         if RESET_i = '1' then
            state <= S_IDLE; atomic <= '0'; req <= NO_MEM_REQUEST; inflight <= false;
            cfp_c <= ( others => '0' ); cfp_s <= ( others => '0' );
            csp_c <= ( others => '0' ); csp_s <= ( others => '0' );
            hp_c <= ( others => '0' ); hp_s <= ( others => '0' );
            hn <= 0; res_nocomp <= false;
         else
            -- historique : le retrait consomme sa tête (état retiré) ; une reprise ôte les
            -- entrées abandonnées et rend la dernière qui reste (ou l'état retiré)
            hv := hist; hnv := hn; ccfp := cfp_c; ccsp := csp_c;
            for r in 0 to RETIRE_WIDTH - 1 loop
               if RETIRE_i( r ).valid = '1' and hnv > 0 and hv( 0 ).rob = RETIRE_i( r ).rob_index then
                  ccfp := hv( 0 ).cfp; ccsp := hv( 0 ).csp;
                  for j in 0 to HIST_DEPTH - 2 loop hv( j ) := hv( j + 1 ); end loop;
                  hnv := hnv - 1;
               end if;
            end loop;
            cfp_c <= ccfp; csp_c <= ccsp;
            rcfp := ccfp; rcsp := ccsp;
            if RECOVERY_i.valid = '1' then
               while hnv > 0 and ABANDONED( hv( hnv - 1 ).rob, RECOVERY_i, ROB_HEAD_i ) loop hnv := hnv - 1; end loop;
               if hnv > 0 then rcfp := hv( hnv - 1 ).cfp; rcsp := hv( hnv - 1 ).csp; end if;
               if state = S_IDLE or state = S_FLUSH then cfp_s <= rcfp; csp_s <= rcsp; end if;
            end if;
            -- resynchronisation (SYSTEM_UNIT, au cycle d'une reprise)
            if SYNC_VALID_i = '1' then
               hnv := 0;
               cfp_c <= SYNC_COPILE_i.cfp; cfp_s <= SYNC_COPILE_i.cfp;
               csp_c <= SYNC_COPILE_i.csp; csp_s <= SYNC_COPILE_i.csp;
               if SYNC_COPILE_i.hp_valid = '1' then hp_c <= SYNC_COPILE_i.hp; hp_s <= SYNC_COPILE_i.hp; end if;
            end if;

            -- requête acceptée, réponse reçue
            if req.valid = '1' and MEM_READY_i = '1' then
               req.valid <= '0';
               inflight <= true;
            elsif MEM_RSP_i.valid = '1' then
               inflight <= false;
            end if;

            if state /= S_IDLE and state /= S_FLUSH and ABANDONED( instr.rob_index, RECOVERY_i, ROB_HEAD_i ) then
               -- abandon : oubli, état retiré ; une réponse encore en route est attendue
               csp_s <= rcsp; hp_s <= hp_c; cfp_s <= rcfp; atomic <= '0'; fexp_abort <= '1';
               if req.valid = '1' and MEM_READY_i = '1' then
                  state <= S_FLUSH;						-- acceptée ce cycle
               elsif req.valid = '1' then
                  req.valid <= '0'; state <= S_IDLE;			-- pas encore acceptée : retirée
               elsif inflight and MEM_RSP_i.valid = '0' then
                  state <= S_FLUSH;						-- en route
               else
                  state <= S_IDLE;
               end if;
            else
               case state is

                  when S_IDLE =>
                     if ISSUE_VALID_i = '1' and ISSUE_COUNT_i >= 1
                        and not ABANDONED( ISSUE_BLOCK_i( 0 ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                        instr <= ISSUE_BLOCK_i( 0 );
                        state <= S_READ;
                     end if;

                  when S_READ =>							-- opérandes, puis le genre
                     for s in 0 to MAX_SOURCE_COUNT - 1 loop
                        o( s ) := READ_DATA_i( 0 )( s );
                        for p in BYPASS_i'range loop
                           if BYPASS_i( p ).valid = '1' and BYPASS_i( p ).destination_valid = '1'
                              and BYPASS_i( p ).destination = instr.source( s ) then
                              o( s ) := BYPASS_i( p ).value;
                           end if;
                        end loop;
                     end loop;
                     if instr.source_count = 0 then o( 0 ) := ( others => '0' ); end if;
                     opd <= o;
                     op := instr.slot.canon.op;
                     at_head <= false;
                     if op = OP_TRAP or op = OP_RTX or op = OP_EXC_RAISE then
                        state <= S_SYS;
                     elsif op = OP_FEXP then
                        state <= S_FEXP_START;				-- opérandes rangés au cycle suivant
                     elsif IS_LINK( op ) then					-- LINK : hors de la tête
                        if hnv < HIST_DEPTH then
                           if csp_s + 8 > LIMITS_i.lim_csp then
                              FINISH( ( others => '0' ), 135, false );
                           else
                              lx_addr <= csp_s; lx_data <= std_logic_vector( cfp_s );	-- M64[CSP] := CFP
                              PUSH( csp_s, csp_s + 8 );				-- CFP := CSP ; CSP += 8
                              state <= S_LEXEC;
                           end if;
                        end if;								-- historique plein : attente
                     elsif IS_UNLINK( op ) then					-- UNLINK, UNLINKR : hors de la tête
                        if hnv < HIST_DEPTH then
                           lx_addr <= cfp_s; lx_data <= ( others => '0' );		-- M64[CFP], par la LSQ
                           state <= S_FUPD;
                        end if;
                     elsif op = OP_CO_VAR or op = OP_HEAP_ALLOC or IS_BLOCK( op ) or IS_EXCM( op ) then
                        at_head <= true;
                        state <= S_HEAD;
                     else
                        FINISH( ( others => '0' ), 137, false );
                     end if;

                  when S_FUPD =>							-- FRAME_UPDATE_o
                     state <= S_ULOAD;

                  when S_ULOAD =>							-- LSQ_EXEC_o : adresse du chargement
                     state <= S_UWAIT;

                  when S_UWAIT =>							-- le chargement de la LSQ, sur le bus
                     got := false;
                     for p in BYPASS_i'range loop
                        if BYPASS_i( p ).valid = '1' and BYPASS_i( p ).completion.valid = '1'
                           and BYPASS_i( p ).completion.rob_index = instr.rob_index then
                           got := true;
                           if BYPASS_i( p ).completion.fault.valid = '0' and BYPASS_i( p ).destination_valid = '1' then
                              nv := unsigned( BYPASS_i( p ).value );
                              if instr.slot.canon.op = OP_UNLINKR then
                                 PUSH( nv, cfp_s );					-- CSP := CFP ; CFP := M64[CFP]
                              else
                                 PUSH( nv, csp_s );					-- CFP := M64[CFP]
                              end if;
                           end if;							-- faute : la LSQ l'a rendue
                        end if;
                     end loop;
                     if got then state <= S_IDLE; end if;

                  when S_LEXEC =>							-- LSQ_EXEC_o : adresse et donnée
                     if instr.slot.canon.lvl /= 0 then				-- résultat : l'ancien DISPLAY[lvl]
                        res_value <= std_logic_vector( instr.address ); res_fault <= 0; res_dest <= true;
                        res_nocomp <= true; state <= S_RESULT;
                     else
                        state <= S_IDLE;
                     end if;

                  when S_SYS =>							-- SYS_REQ_o
                     state <= S_SYS_WAIT;

                  when S_SYS_WAIT =>
                     if SYS_RSP_i.valid = '1' then
                        if SYS_RSP_i.fault.valid = '1' then
                           FINISH( ( others => '0' ), to_integer( SYS_RSP_i.fault.code ), false );
                        else
                           FINISH( SYS_RSP_i.result, 0, SYS_RSP_i.result_valid = '1' );
                        end if;
                     end if;

                  when S_FEXP_START =>						-- START de FEXP_UNIT
                     state <= S_FEXP;

                  when S_FEXP =>
                     if fexp_done = '1' then FINISH( fexp_r, 0, true ); end if;

                  when S_HEAD =>
                     if instr.rob_index = ROB_HEAD_i then
                        op := instr.slot.canon.op;
                        if op = OP_CO_VAR then
                           sz65 := ROUND8( unsigned( opd( 0 ) ) );
                           nxt := resize( csp_s, 66 ) + resize( sz65, 66 );
                           if nxt > resize( LIMITS_i.lim_csp, 66 ) then
                              FINISH( ( others => '0' ), 135, false );
                           else
                              csp_s <= nxt( 63 downto 0 );
                              FINISH( std_logic_vector( csp_s ), 0, true );
                           end if;
                        elsif op = OP_HEAP_ALLOC then
                           sz65 := ROUND8( unsigned( opd( 0 ) ) );
                           if sz65 > resize( hp_s, 65 ) or hp_s - sz65( 63 downto 0 ) < LIMITS_i.lim_hp then
                              FINISH( ( others => '0' ), 136, false );
                           else
                              hp_s <= hp_s - sz65( 63 downto 0 );
                              FINISH( std_logic_vector( hp_s - sz65( 63 downto 0 ) ), 0, true );
                           end if;
                        elsif IS_FRAME( op ) then					-- groupe frame : un intervalle
                           nranges <= 1; fin_value <= ( others => '0' ); fin_dest <= false;
                           if IS_EXCM( op ) then
                              frame_c <= COMMITTED_FRAME_i;
                              ranges( 0 ) <= ( base => instr.address + 16,		-- 5 mots, puis DISPLAY[0..lvl]
                                               length => to_unsigned( 48 + 8 * to_integer( instr.slot.canon.lvl ), 64 ) );
                              write_range <= 0;
                              state <= S_DRAIN;
                           end if;
                        else								-- bloc : ses intervalles
                           fin_value <= ( others => '0' ); fin_dest <= false;
                           write_range <= -1;
                           if IS_LEX( op ) then
                              sz := SZ_OF( op );
                              lg <= signed( opd( 1 ) ); ld <= signed( opd( 3 ) );
                              ranges( 0 ) <= ( base => unsigned( opd( 0 ) ), length => unsigned( opd( 1 ) ) + sz );
                              ranges( 1 ) <= ( base => unsigned( opd( 2 ) ), length => unsigned( opd( 3 ) ) + sz );
                              if signed( opd( 1 ) ) <= 0 then ranges( 0 ).length <= ( others => '0' ); end if;
                              if signed( opd( 3 ) ) <= 0 then ranges( 1 ).length <= ( others => '0' ); end if;
                              nranges <= 2;
                           elsif op = OP_BLKNOT then
                              ranges( 0 ) <= ( base => unsigned( opd( 0 ) ), length => unsigned( opd( 1 ) ) );
                              nranges <= 1; write_range <= 0;
                           elsif op = OP_BLKCMP then
                              ranges( 0 ) <= ( base => unsigned( opd( 0 ) ), length => unsigned( opd( 1 ) ) );
                              ranges( 1 ) <= ( base => unsigned( opd( 2 ) ), length => unsigned( opd( 1 ) ) );
                              nranges <= 2;
                           else								-- ( @dst len @src )
                              ranges( 0 ) <= ( base => unsigned( opd( 2 ) ), length => unsigned( opd( 1 ) ) );
                              ranges( 1 ) <= ( base => unsigned( opd( 0 ) ), length => unsigned( opd( 1 ) ) );
                              nranges <= 2; write_range <= 1;
                           end if;
                           state <= S_DRAIN;
                        end if;
                     end if;

                  when S_DRAIN =>
                     if LSQ_DRAINED_i = '1' then
                        if IS_WRITING_BLOCK( instr.slot.canon.op ) then
                           atomic <= '1'; state <= S_ATOMIC;
                        else
                           state <= S_RANGE;
                        end if;
                     end if;

                  when S_ATOMIC =>							-- HEAD_ATOMIC_o = '1' depuis un cycle
                     if SYSTEM_HOLD_i = '0' then
                        state <= S_RANGE;						-- engagé : HEAD_ATOMIC_o reste à '1'
                     else
                        atomic <= '0'; state <= S_HOLD_WAIT;			-- SYSTEM_UNIT déjà en séquence
                     end if;

                  when S_HOLD_WAIT =>
                     if SYSTEM_HOLD_i = '0' then atomic <= '1'; state <= S_ATOMIC; end if;

                  when S_RANGE =>							-- RANGE_o ; sondage
                     ri <= 0; roff <= ( others => '0' );
                     if IS_LEX( instr.slot.canon.op ) then
                        state <= S_MAINT;						-- lectures seules : pas de sondage
                     else
                        state <= S_PROBE;
                     end if;

                  when S_PROBE =>							-- morceaux de 8 octets, puis 1
                     if ri >= nranges then
                        ri <= 0; state <= S_MAINT;
                     elsif roff >= ranges( ri ).length then
                        ri <= ri + 1; roff <= ( others => '0' );
                     else
                        left := ranges( ri ).length - roff;
                        if left >= 8 then
                           req <= ( valid => '1', write => '0', probe => '1', address => ranges( ri ).base + roff,
                                    size => "11", wdata => ( others => '0' ) );
                           roff <= roff + 8;
                        else
                           req <= ( valid => '1', write => '0', probe => '1', address => ranges( ri ).base + roff,
                                    size => "00", wdata => ( others => '0' ) );
                           roff <= roff + 1;
                        end if;
                        state <= S_PROBE_WAIT;
                     end if;

                  when S_PROBE_WAIT =>
                     if MEM_RSP_i.valid = '1' then
                        if MEM_RSP_i.fault = '1' then
                           FINISH( ( others => '0' ), 132, false );
                        else
                           state <= S_PROBE;
                        end if;
                     end if;

                  when S_MAINT =>							-- réécriture de chaque intervalle
                     if ri >= nranges then
                        k <= ( others => '0' ); sub <= 0; fstep <= 0;
                        -- par mots de 8 octets : BLKMOV (sans recouvrement, V8), BLKNOT, BLKCMP ;
                        -- blocs logiques : si [dst] et [src] sont égaux ou distants d'au moins 8
                        dif := unsigned( opd( 0 ) ) - unsigned( opd( 2 ) );
                        word_mode <= instr.slot.canon.op = OP_BLKMOV or instr.slot.canon.op = OP_BLKNOT
                                     or instr.slot.canon.op = OP_BLKCMP
                                     or dif = 0 or ( dif >= 8 and dif <= unsigned'( x"FFFFFFFFFFFFFFF8" ) );
                        if IS_FRAME( instr.slot.canon.op ) then state <= S_FSTEP; else state <= S_ACC; end if;
                     elsif ranges( ri ).length = 0 then
                        ri <= ri + 1;
                     elsif STACK_MAINT_DONE_i = '1' then
                        ri <= ri + 1;
                     end if;

                  when S_ACC =>							-- un accès de la boucle
                     op := instr.slot.canon.op;
                     done_acc := false;
                     if IS_LEX( op ) then
                        sz := SZ_OF( op );
                        if lg > 0 and ld > 0 then
                           if sub = 0 then MEM_ACCESS( unsigned( opd( 0 ) ) + k, to_integer( unsigned( op( 1 downto 0 ) ) ), false, ( others => '0' ) );
                           else MEM_ACCESS( unsigned( opd( 2 ) ) + k, to_integer( unsigned( op( 1 downto 0 ) ) ), false, ( others => '0' ) );
                           end if;
                           state <= S_ACC_WAIT;
                        else								-- préfixe commun : signe( lg - ld )
                           if lg > ld then FINISH( x"0000000000000001", 0, true );
                           elsif lg < ld then FINISH( ( others => '1' ), 0, true );
                           else FINISH( ( others => '0' ), 0, true );
                           end if;
                        end if;
                     elsif k >= unsigned( opd( 1 ) ) then				-- len octets faits
                        if op = OP_BLKCMP then
                           FINISH( x"0000000000000001", 0, true );
                        elsif write_range >= 0 then
                           state <= S_INVAL;
                        else
                           FINISH( ( others => '0' ), 0, false );
                        end if;
                     else
                        -- un élément : 8 octets en mode mot s'il en reste au moins 8, sinon 1
                        if sub = 0 then
                           step8 := word_mode and unsigned( opd( 1 ) ) - k >= 8;
                           wstep <= step8;
                        else
                           step8 := wstep;
                        end if;
                        if step8 then esz := 3; else esz := 0; end if;
                        case sub is
                           when 0 =>							-- [src+k], [a+k], [dst+k] (BLKNOT)
                              if op = OP_BLKNOT or op = OP_BLKCMP then
                                 MEM_ACCESS( unsigned( opd( 0 ) ) + k, esz, false, ( others => '0' ) );
                              else
                                 MEM_ACCESS( unsigned( opd( 2 ) ) + k, esz, false, ( others => '0' ) );
                              end if;
                           when 1 =>							-- [dst+k], [b+k] ; ou écriture
                              if op = OP_BLKCMP then
                                 MEM_ACCESS( unsigned( opd( 2 ) ) + k, esz, false, ( others => '0' ) );
                              elsif op = OP_BLKMOV then
                                 MEM_ACCESS( unsigned( opd( 0 ) ) + k, esz, true, word_a );
                              elsif op = OP_BLKNOT then				-- chaque octet xor= 1
                                 MEM_ACCESS( unsigned( opd( 0 ) ) + k, esz, true, word_a xor x"0101010101010101" );
                              else
                                 MEM_ACCESS( unsigned( opd( 0 ) ) + k, esz, false, ( others => '0' ) );
                              end if;
                           when others =>						-- BLKAND, BLKOU, BLKOUX : écriture
                              MEM_ACCESS( unsigned( opd( 0 ) ) + k, esz, true, word_a );
                        end case;
                        state <= S_ACC_WAIT;
                     end if;

                  when S_ACC_WAIT =>
                     if MEM_RSP_i.valid = '1' then
                        op := instr.slot.canon.op;
                        b := MEM_RSP_i.rdata( 7 downto 0 );
                        if MEM_RSP_i.fault = '1' then
                           FINISH( ( others => '0' ), 132, false );			-- (LEXCMP : rien n'est écrit)
                        elsif IS_LEX( op ) then
                           sz := SZ_OF( op );
                           if sub = 0 then
                              comp_g <= MEM_RSP_i.rdata; sub <= 1; state <= S_ACC;
                           else
                              cg := EXTEND( comp_g, sz, op( 2 ) = '0' );
                              cd := EXTEND( MEM_RSP_i.rdata, sz, op( 2 ) = '0' );
                              -- étendus sur 64 bits, les composants non signés (1, 2, 4 octets ;
                              -- ULEXCMPQ = LEXCMPQ) sont positifs : une comparaison signée suffit
                              if cg /= cd then
                                 if cg < cd then FINISH( ( others => '1' ), 0, true );
                                 else FINISH( x"0000000000000001", 0, true ); end if;
                              else
                                 k <= k + sz; lg <= lg - sz; ld <= ld - sz; sub <= 0; state <= S_ACC;
                              end if;
                           end if;
                        else
                           if wstep then w := MEM_RSP_i.rdata; else w := x"00000000000000" & b; end if;
                           if wstep then n := 8; else n := 1; end if;
                           case sub is
                              when 0 =>
                                 word_a <= w; sub <= 1; state <= S_ACC;
                              when 1 =>
                                 if op = OP_BLKCMP then
                                    if w /= word_a then FINISH( ( others => '0' ), 0, true );
                                    else k <= k + n; sub <= 0; state <= S_ACC; end if;
                                 elsif op = OP_BLKMOV or op = OP_BLKNOT then
                                    k <= k + n; sub <= 0; state <= S_ACC;
                                 else							-- [dst+k] lu : l'opération
                                    if op = OP_BLKAND then word_a <= word_a and w;
                                    elsif op = OP_BLKOU then word_a <= word_a or w;
                                    else word_a <= word_a xor w; end if;
                                    sub <= 2; state <= S_ACC;
                                 end if;
                              when others =>
                                 k <= k + n; sub <= 0; state <= S_ACC;
                           end case;
                        end if;
                     end if;

                  when S_FSTEP =>							-- groupe frame : un mot de 8 octets
                     op := instr.slot.canon.op;
                     if IS_EXCM( op ) then
                        case fstep is
                           when 0 => MEM_ACCESS( ranges( 0 ).base, 3, true, std_logic_vector( frame_c.dsp ) );
                           when 1 => MEM_ACCESS( ranges( 0 ).base + 8, 3, true, std_logic_vector( frame_c.rsp ) );
                           when 2 => MEM_ACCESS( ranges( 0 ).base + 16, 3, true, std_logic_vector( cfp_s ) );
                           when 3 => MEM_ACCESS( ranges( 0 ).base + 24, 3, true, std_logic_vector( csp_s ) );
                           when 5 to 19 => MEM_ACCESS( ranges( 0 ).base + 40 + 8 * ( fstep - 5 ), 3, true,
                                                       std_logic_vector( frame_c.display( fstep - 5 ) ) );
                           when others => MEM_ACCESS( ranges( 0 ).base + 32, 3, true,
                                                      std_logic_vector( resize( instr.slot.canon.lvl, 64 ) + 1 ) );
                        end case;
                     end if;
                     state <= S_FSTEP_WAIT;

                  when S_FSTEP_WAIT =>
                     if MEM_RSP_i.valid = '1' then
                        op := instr.slot.canon.op;
                        if MEM_RSP_i.fault = '1' then
                           FINISH( ( others => '0' ), 132, false );
                        elsif fstep = 5 + to_integer( instr.slot.canon.lvl ) then	-- EXC_MACH : DISPLAY[lvl] écrit
                           state <= S_INVAL;
                        else
                           fstep <= fstep + 1; state <= S_FSTEP;
                        end if;
                     end if;

                  when S_INVAL =>							-- invalidation de l'intervalle écrit
                     if STACK_MAINT_DONE_i = '1' or ranges( write_range ).length = 0 then
                        FINISH( fin_value, 0, fin_dest );
                     end if;

                  when S_RESULT =>
                     if at_head then state <= S_RETIRE_WAIT; else state <= S_IDLE; end if;

                  when S_RETIRE_WAIT =>						-- le retrait retient CSP, HP
                     for r in 0 to RETIRE_WIDTH - 1 loop
                        if RETIRE_i( r ).valid = '1' and RETIRE_i( r ).rob_index = instr.rob_index then
                           csp_c <= csp_s; hp_c <= hp_s; cfp_c <= cfp_s; atomic <= '0'; state <= S_IDLE;
                           -- (historique vide : les instructions plus anciennes sont retirées)
                        end if;
                     end loop;

                  when S_FLUSH =>							-- réponse d'une instruction abandonnée
                     if MEM_RSP_i.valid = '1' then state <= S_IDLE; end if;
               end case;
            end if;
            hist <= hv; hn <= hnv;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
