library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.TAHX_1_ISA_TABLE.all;
use work.FETCH_DECODE_TYPES.all;
use work.MEMORY_TYPES.all;
use work.EXEC_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.ROB_TYPES.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- N3_INO_PLATEFORME
        --
        -- Premier banc de la machine InO complete. Il reutilise l'image N3 de
        -- DIS_BONJOUR et les modeles memoire de la plateforme OoO, mais ne depend
        -- d'aucun signal interne propre au ROB/renommage/LSQ.
        --
        -- Verifications de ce premier jalon : boot, execution du programme et de ses
        -- handlers, sortie console, TRAP 0 et code de sortie.
        --------------------------------------------------------------------------------

                                -----------------
entity                          N3_INO_PLATEFORME
is                              -----------------
   generic (
      NOM_G        : string;
      MAX_CYCLES_G : positive := 1000000;
      PERF_G       : boolean := false
   );
end entity                      N3_INO_PLATEFORME;
                                -----------------

                                ----
architecture                    TEST of N3_INO_PLATEFORME
is                              ----

   constant PERIOD       : time := 10 ns;
   constant BASE         : natural := 16#400000#;
   constant MEM_END      : natural := 16#4E0000#;
   constant WORDS        : positive := ( MEM_END - BASE ) / 8;
   constant BOOT         : natural := 16#420000#;
   constant CONSOLE      : natural := 16#421A00#;
   constant COP0         : natural := 16#450000#;

   signal clk            : std_logic := '0';
   signal running        : boolean := true;
   signal reset          : std_logic := '1';

   signal i_req          : std_logic;
   signal i_addr         : address_t;
   signal i_ready        : std_logic;
   signal i_rvalid       : std_logic;
   signal i_rdata        : word64_t;
   signal i_fault        : std_logic;

   signal d_req          : std_logic;
   signal d_write        : std_logic;
   signal d_addr         : address_t;
   signal d_size         : unsigned( 1 downto 0 );
   signal d_wdata        : word64_t;
   signal d_wstrb        : std_logic_vector( 7 downto 0 );
   signal d_ready        : std_logic := '0';
   signal d_rvalid       : std_logic := '0';
   signal d_rdata        : word64_t := ( others => '0' );
   signal d_fault        : std_logic := '0';

   signal irq_ack        : std_logic;
   signal irq_code       : trap_code_t;
   signal halted         : std_logic;
   signal halt_cause     : halt_cause_t;
   signal exit_code      : word64_t;
   signal fpc            : address_t;
   signal fcode          : trap_code_t;

   -- Instrumentation de performance InO (simulation seulement).
   -- Ces types ne modifient aucun signal du DUT.
   type perf_class_t is ( PERF_NONE, PERF_INTEGER, PERF_MULDIV, PERF_MEMORY,
                          PERF_BRANCH, PERF_FLOAT, PERF_COMPLEX, PERF_SYSTEM );
   type natural_by_class_t is array( perf_class_t ) of natural;
   type natural_by_opcode_t is array( 0 to 255 ) of natural;

   -- Etats des unites observees (V0) : 0 STACK_UNIT, 1 INO_MEMORY_UNIT (M2),
   -- 2 INO_DCACHE_CORE. Chacune expose hors synthese l'indice de son etat
   -- (state_t'pos) et la liste des noms de ses etats (OBS_STATE_NAMES).
   constant OBS_UNITS    : positive := 3;
   constant OBS_STATES   : positive := 32;            -- etats par unite, au plus
   type obs_by_unit_t is array( 0 to OBS_UNITS - 1 ) of natural;
   type natural_by_port_t is array( 0 to 1 ) of natural;
   type obs_by_state_t is array( 0 to OBS_UNITS - 1, 0 to OBS_STATES - 1 ) of natural;
   type obs_by_op_state_t is array( 0 to 255, 0 to OBS_UNITS - 1, 0 to OBS_STATES - 1 ) of natural;
   -- Famine du frontal, selon le dernier evenement avant elle.
   type famine_t is ( FAM_AUTRE, FAM_REPRISE, FAM_TRANSFERT );
   type natural_by_famine_t is array( famine_t ) of natural;

   signal mem_ready      : boolean := false;

begin

   DUT : entity work.TAHX_1(IN_ORDER)
      port map (
         CLK_i => clk, RESET_i => reset, BOOT_BLOCK_i => to_unsigned( BOOT, 64 ),
         I_REQ_o => i_req, I_ADDR_o => i_addr, I_READY_i => i_ready,
         I_RVALID_i => i_rvalid, I_RDATA_i => i_rdata, I_FAULT_i => i_fault,
         D_REQ_o => d_req, D_WRITE_o => d_write, D_ADDR_o => d_addr, D_SIZE_o => d_size,
         D_WDATA_o => d_wdata, D_WSTRB_o => d_wstrb,
         D_READY_i => d_ready, D_RVALID_i => d_rvalid, D_RDATA_i => d_rdata, D_FAULT_i => d_fault,
         IRQ_PENDING_i => ( others => '0' ), IRQ_ACK_o => irq_ack, IRQ_ACK_CODE_o => irq_code,
         HALT_REQ_i => '0', HALTED_o => halted, HALT_CAUSE_o => halt_cause,
         EXIT_CODE_o => exit_code, FPC_o => fpc, FCODE_o => fcode );

   INSTRUCTIONS : entity work.MEMOIRE_INSTRUCTIONS
      generic map (
         LATENCY_MIN_G => 2, LATENCY_MAX_G => 6, READY_PROB_G => 0.9,
         IMAGE_G => "n3_image.bin", IMAGE_BASE_G => BASE,
         SEED_1_G => 3, SEED_2_G => 4 )
      port map (
         CLK_i => clk,
         I_REQ_i => i_req, I_ADDR_i => i_addr, I_READY_o => i_ready,
         I_RVALID_o => i_rvalid, I_RDATA_o => i_rdata, I_FAULT_o => i_fault,
         ACCEPTED_o => open );

   clk <= not clk after PERIOD / 2 when running;

   -----------------------------------------------------------------------------
   -- Memoire de donnees : meme image que le frontal, plus le premier cadre de
   -- co-pile. Les lectures ont une latence ordonnee ; les ecritures sont postees.
   -----------------------------------------------------------------------------

   DONNEES : process
      type char_file_t is file of character;
      file f : char_file_t;
      variable status : file_open_status;
      variable ch : character;
      type mem_t is array( 0 to WORDS - 1 ) of word64_t;
      variable m : mem_t := ( others => ( others => '0' ) );
      variable n : natural := 0;
      constant CAP : positive := 64;

      type pend_t is record
         data  : word64_t;
         fault : std_logic;
         due   : natural;
      end record;
      type pend_array_t is array( 0 to CAP - 1 ) of pend_t;
      variable q : pend_array_t;
      variable head, cnt, now, last_due : natural := 0;
      variable o : integer;
      variable w : word64_t;
      variable rdy : std_logic;
   begin
      file_open( status, f, "n3_image.bin", read_mode );
      assert status = open_ok report "n3_image.bin introuvable" severity failure;
      while not endfile( f ) loop
         read( f, ch );
         w := m( n / 8 );
         w( 8 * ( n mod 8 ) + 7 downto 8 * ( n mod 8 ) ) :=
            std_logic_vector( to_unsigned( character'pos( ch ), 8 ) );
         m( n / 8 ) := w;
         n := n + 1;
      end loop;
      file_close( f );
      m( ( COP0 - BASE ) / 8 ) := std_logic_vector( to_unsigned( COP0, 64 ) );
      mem_ready <= true;

      loop
         wait until falling_edge( clk );
         now := now + 1;
         if cnt > 0 and q( head ).due <= now then
            d_rvalid <= '1'; d_rdata <= q( head ).data; d_fault <= q( head ).fault;
            head := ( head + 1 ) mod CAP; cnt := cnt - 1;
         else
            d_rvalid <= '0'; d_fault <= '0';
         end if;

         if cnt < CAP - 2 then rdy := '1'; else rdy := '0'; end if;
         d_ready <= rdy;

         wait until rising_edge( clk );
         if d_req = '1' and rdy = '1' then
            o := ( to_integer( d_addr( 30 downto 0 ) ) - BASE ) / 8;
            if d_addr( 63 downto 31 ) /= 0
               or to_integer( d_addr( 30 downto 0 ) ) < BASE or o >= WORDS then
               if d_write = '0' then
                  q( ( head + cnt ) mod CAP ) :=
                     ( data => ( others => '0' ), fault => '1', due => now + 2 );
                  cnt := cnt + 1;
               end if;
               report "memoire : acces hors zone a " & HEX( d_addr ) severity warning;
            elsif d_write = '1' then
               w := m( o );
               for b in 0 to 7 loop
                  if d_wstrb( b ) = '1' then
                     w( 8*b+7 downto 8*b ) := d_wdata( 8*b+7 downto 8*b );
                  end if;
               end loop;
               m( o ) := w;
            else
               last_due := maximum( last_due + 1, now + 3 );
               q( ( head + cnt ) mod CAP ) := ( data => m( o ), fault => '0', due => last_due );
               cnt := cnt + 1;
            end if;
         end if;
      end loop;
   end process DONNEES;


   -----------------------------------------------------------------------------
   -- Observation fonctionnelle. La console est observee a l'entree de DATA_CACHE,
   -- avant l'ecriture differee vers la memoire externe.
   -----------------------------------------------------------------------------

   STIMULI : process
      alias dc_req   is << signal DUT.dc_req : mem_request_bus_t >>;
      alias dc_ready is << signal DUT.dc_ready : std_logic_vector >>;
      alias commit        is << signal DUT.commit : ino_commit_t >>;
      alias dq_take       is << signal DUT.dq_take : decode_count_t >>;
      alias dq_count      is << signal DUT.dq_count : decode_count_t >>;
      -- Occupation de la file : etat interne de INO_DECODE_QUEUE (pas de port) ;
      -- 8 = DQ_DEPTH de J1b_INO_DECODE_QUEUE_rtl.vhd.
      alias dq_occupancy  is << signal DUT.U_DECODE_QUEUE.count : natural range 0 to 8 >>;
      alias stack_idle    is << signal DUT.stack_idle : std_logic >>;
      alias recovery      is << signal DUT.recovery : recovery_t >>;
      alias system_hold   is << signal DUT.system_hold : std_logic >>;
      alias stack_mem_req is << signal DUT.stack_mem_req : mem_request_t >>;
      alias exec_mem_req  is << signal DUT.exec_mem_req : mem_request_t >>;
      -- Etats observes (V0), hors synthese dans le RTL (pragma translate_off).
      alias st_stack is << signal DUT.U_CORE.U_STACK.obs_state_s : natural >>;
      alias st_m2    is << signal
         DUT.U_CORE.U_BACKEND.U_BACKEND.U_BASE.U_BASE.U_BASE.U_BASE.U_MEMORY.obs_state_s : natural >>;
      alias st_cache is << signal DUT.U_DATA_CACHE.U_CORE.obs_state : natural >>;
      alias noms_stack is << constant DUT.U_CORE.U_STACK.OBS_STATE_NAMES : string >>;
      alias noms_m2    is << constant
         DUT.U_CORE.U_BACKEND.U_BACKEND.U_BASE.U_BASE.U_BASE.U_BASE.U_MEMORY.OBS_STATE_NAMES : string >>;
      alias noms_cache is << constant DUT.U_DATA_CACHE.U_CORE.OBS_STATE_NAMES : string >>;

      file fa : text;
      file fp : text;
      variable status : file_open_status;
      variable l, v : line;
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable exp_exit : integer;
      variable exp_out, got_out, old : line;
      variable now, commits : natural := 0;
      variable takes : natural := 0;
      variable cyc_system, cyc_front_starve, cyc_idle_work, cyc_busy : natural := 0;
      variable cyc_stack_mem, cyc_exec_mem : natural := 0;
      variable dq_occ_sum, dq_occ_max : natural := 0;
      variable recoveries : natural := 0;
      variable inflight : boolean := false;
      variable take_cycle : natural := 0;
      variable lat : natural := 0;
      variable cls : perf_class_t := PERF_NONE;
      variable class_count, class_lat_sum, class_lat_max : natural_by_class_t := ( others => 0 );
      variable op_count, op_lat_sum, op_lat_max : natural_by_opcode_t := ( others => 0 );
      variable opi : natural := 0;
      variable ch : character;
      variable good : boolean;

      -- V0 : etats des unites (cycles, entrees ; par opcode, cycles de l'instruction
      -- en vol, de sa prise a son commit exclu, comme lat).
      variable stv          : obs_by_unit_t := ( others => 0 );
      variable st_prev      : obs_by_unit_t := ( others => natural'high );
      variable st_cycles    : obs_by_state_t := ( others => ( others => 0 ) );
      variable st_entries   : obs_by_state_t := ( others => ( others => 0 ) );
      variable st_cur       : obs_by_state_t := ( others => ( others => 0 ) );
      variable st_op        : obs_by_op_state_t := ( others => ( others => ( others => 0 ) ) );
      -- V0 : requetes acceptees par le cache (port 0 STACK, 1 EXEC).
      variable acc_read, acc_write, acc_probe : natural_by_port_t := ( others => 0 );
      -- V0 : famine du frontal.
      variable famine       : famine_t := FAM_AUTRE;
      variable fam_cycles, fam_episodes : natural_by_famine_t := ( others => 0 );
      variable starving, starving_prev : boolean := false;
      variable transfers_ok : natural := 0;

      procedure READ_FIELD( prefix : string; value : out line ) is
      begin
         readline( fa, l );
         value := new string'( l( prefix'length + 2 to l'length ) );
      end procedure;

      function F2( x : real ) return string is
         variable n : integer := integer( x * 100.0 );
         variable f : string( 1 to 2 );
      begin
         f( 1 ) := character'val( 48 + ( abs( n ) mod 100 ) / 10 );
         f( 2 ) := character'val( 48 + abs( n ) mod 10 );
         return integer'image( n / 100 ) & "," & f;
      end function;

      procedure PERF_LINE( texte : string ) is
         variable ll : line;
      begin
         report texte severity note;
         ll := new string'( texte );
         writeline( fp, ll );
      end procedure;

      function UPPER( x : string ) return string is
         variable r : string( x'range ) := x;
      begin
         for i in x'range loop
            if x( i ) >= 'a' and x( i ) <= 'z' then
               r( i ) := character'val( character'pos( x( i ) ) - 32 );
            end if;
         end loop;
         return r;
      end function;

      -- Mot k (depuis 0) d'une liste de noms separes par une espace.
      function MOT( s : string; k : natural ) return string is
         variable debut : integer := s'low;
         variable n     : natural := 0;
      begin
         for i in s'range loop
            if s( i ) = ' ' then
               if n = k then
                  return s( debut to i - 1 );
               end if;
               n := n + 1;
               debut := i + 1;
            end if;
         end loop;
         if n = k then
            return s( debut to s'high );
         end if;
         return "?";
      end function;

      function NB_MOTS( s : string ) return natural is
         variable n : natural := 1;
      begin
         for i in s'range loop
            if s( i ) = ' ' then
               n := n + 1;
            end if;
         end loop;
         return n;
      end function;

      -- Indice du nom x dans la liste s (casse ignoree), -1 s'il n'y est pas.
      function INDICE( s : string; x : string ) return integer is
      begin
         for k in 0 to NB_MOTS( s ) - 1 loop
            if UPPER( MOT( s, k ) ) = UPPER( x ) then
               return k;
            end if;
         end loop;
         return -1;
      end function;

      function PERF_CLASS( op : opcode_t ) return perf_class_t is
         variable e : isa_entry_t;
      begin
         if op = OP_TRAP or op = OP_EXC_RAISE or op = OP_RTX then
            return PERF_SYSTEM;
         end if;
         e := ISA_TABLE( to_integer( unsigned( op ) ) );
         case e.issue_class is
            when ISSUE_NONE    => return PERF_NONE;
            when ISSUE_INTEGER => return PERF_INTEGER;
            when ISSUE_MUL_DIV => return PERF_MULDIV;
            when ISSUE_MEMORY  => return PERF_MEMORY;
            when ISSUE_BRANCH  => return PERF_BRANCH;
            when ISSUE_FLOAT   => return PERF_FLOAT;
            when ISSUE_COMPLEX => return PERF_COMPLEX;
         end case;
      end function;

      function CLASS_NAME( k : perf_class_t ) return string is
      begin
         case k is
            when PERF_NONE    => return "NONE";
            when PERF_INTEGER => return "INTEGER";
            when PERF_MULDIV  => return "MULDIV";
            when PERF_MEMORY  => return "MEMORY";
            when PERF_BRANCH  => return "BRANCH";
            when PERF_FLOAT   => return "FLOAT";
            when PERF_COMPLEX => return "COMPLEX";
            when PERF_SYSTEM  => return "SYSTEM";
         end case;
      end function;

      impure function NOMS_ETATS( u : natural ) return string is
      begin
         case u is
            when 0      => return noms_stack;
            when 1      => return noms_m2;
            when others => return noms_cache;
         end case;
      end function;

      function NOM_UNITE( u : natural ) return string is
      begin
         case u is
            when 0      => return "STACK";
            when 1      => return "M2";
            when others => return "CACHE";
         end case;
      end function;

      function IMG( n : natural ) return string is
      begin
         return integer'image( n );
      end function;

      -- Compteurs de V0 (etude de vitesse) :
      --   PERF SPILL / FILL           requetes STACK acceptees (ecritures /lectures)
      --   PERF CACHE ...              requetes acceptees par port, defauts, reecritures
      --   PERF famine ...             famine du frontal selon l'evenement qui la precede
      --   PERF ETAT <u> <etat>        cycles passes dans l'etat, entrees dans l'etat
      --   PERF OPETAT <op> <u> e=n    cycles de l'etat e pendant les instructions <op>
      --                               (de la prise au commit exclu : la somme sur les
      --                               etats d'une unite vaut lat_sum)
      procedure PERF_LINES_V0 is
         variable ll : line;
         variable i_fill, i_wb : integer;
         variable any : boolean;
      begin
         PERF_LINE( "PERF SPILL / FILL (requetes STACK acceptees)        "
                    & IMG( acc_write( 0 ) ) & " /" & IMG( acc_read( 0 ) ) );
         PERF_LINE( "PERF CACHE requetes STACK (lect / ecr / sondes)     "
                    & IMG( acc_read( 0 ) ) & " / " & IMG( acc_write( 0 ) ) & " / " & IMG( acc_probe( 0 ) ) );
         PERF_LINE( "PERF CACHE requetes EXEC (lect / ecr / sondes)      "
                    & IMG( acc_read( 1 ) ) & " / " & IMG( acc_write( 1 ) ) & " / " & IMG( acc_probe( 1 ) ) );
         i_fill := INDICE( noms_cache, "REMPLISSAGE" );
         i_wb   := INDICE( noms_cache, "RECRITURE" );
         if i_fill >= 0 then
            PERF_LINE( "PERF CACHE remplissages de lignes (defauts)         " & IMG( st_entries( 2, i_fill ) ) );
         end if;
         if i_wb >= 0 then
            PERF_LINE( "PERF CACHE reecritures de victimes                  " & IMG( st_entries( 2, i_wb ) ) );
         end if;
         PERF_LINE( "PERF famine apres reprise (cycles / episodes)       "
                    & IMG( fam_cycles( FAM_REPRISE ) ) & " / " & IMG( fam_episodes( FAM_REPRISE ) ) );
         PERF_LINE( "PERF famine apres transfert pris bien predit        "
                    & IMG( fam_cycles( FAM_TRANSFERT ) ) & " / " & IMG( fam_episodes( FAM_TRANSFERT ) )
                    & " (transferts " & IMG( transfers_ok ) & ")" );
         PERF_LINE( "PERF famine autre (cycles / episodes)               "
                    & IMG( fam_cycles( FAM_AUTRE ) ) & " / " & IMG( fam_episodes( FAM_AUTRE ) ) );

         for u in 0 to OBS_UNITS - 1 loop
            for s in 0 to NB_MOTS( NOMS_ETATS( u ) ) - 1 loop
               PERF_LINE( "PERF ETAT " & NOM_UNITE( u ) & " " & UPPER( MOT( NOMS_ETATS( u ), s ) )
                          & " cycles " & IMG( st_cycles( u, s ) ) & " entrees " & IMG( st_entries( u, s ) ) );
            end loop;
         end loop;

         for op in 0 to 255 loop
            if op_count( op ) /= 0 then
               for u in 0 to OBS_UNITS - 1 loop
                  any := false;
                  write( ll, "PERF OPETAT " & to_hstring( std_logic_vector( to_unsigned( op, 8 ) ) )
                             & " " & NOM_UNITE( u ) );
                  for s in 0 to NB_MOTS( NOMS_ETATS( u ) ) - 1 loop
                     if st_op( op, u, s ) /= 0 then
                        any := true;
                        write( ll, " " & UPPER( MOT( NOMS_ETATS( u ), s ) ) & "=" & IMG( st_op( op, u, s ) ) );
                     end if;
                  end loop;
                  if any then
                     PERF_LINE( ll.all );
                  end if;
                  deallocate( ll );
               end loop;
            end if;
         end loop;
      end procedure;

   begin
      file_open( status, fa, "attendu.txt", read_mode );
      CHECK( c, status = open_ok, "ouverture de attendu.txt" );
      READ_FIELD( "EXIT", v ); exp_exit := integer'value( v.all );
      READ_FIELD( "INSTRUCTIONS", v );                         -- conserve pour les futurs compteurs
      READ_FIELD( "SORTIE", exp_out );
      file_close( fa );

      CHECK( c, NB_MOTS( noms_stack ) <= OBS_STATES and NB_MOTS( noms_m2 ) <= OBS_STATES
                and NB_MOTS( noms_cache ) <= OBS_STATES, "etats observes : au plus OBS_STATES par unite" );

      wait until mem_ready;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';
      got_out := new string'( "" );

      loop
         wait until rising_edge( clk );
         wait for 1 ns;
         now := now + 1;

         -- Evenement qui precede une famine du frontal (V0), vu avant la partition :
         -- le cycle du commit est deja un cycle de famine si la file est vide.
         -- Transfert pris (BRA, BT/BF pris, CALL, RTD...) bien predit : la famine
         -- qui suit vient de la redirection du frontal, pas d'une reprise.
         if commit.valid = '1' and commit.taken = '1' and commit.slot.pred.taken = '1'
            and commit.slot.pred.target = commit.target and commit.fault.valid = '0' then
            transfers_ok := transfers_ok + 1;
            famine := FAM_TRANSFERT;
         end if;
         if recovery.valid = '1' then
            famine := FAM_REPRISE;
         end if;

         -- Partition exclusive des cycles hors reset.
         starving := false;
         if system_hold = '1' then
            cyc_system := cyc_system + 1;
         elsif stack_idle = '1' and dq_count = 0 then
            cyc_front_starve := cyc_front_starve + 1;
            -- Famine attribuee au dernier evenement depuis la derniere prise.
            starving := true;
            fam_cycles( famine ) := fam_cycles( famine ) + 1;
            if not starving_prev then
               fam_episodes( famine ) := fam_episodes( famine ) + 1;
            end if;
         elsif stack_idle = '1' then
            cyc_idle_work := cyc_idle_work + 1;
         else
            cyc_busy := cyc_busy + 1;
         end if;

         if stack_mem_req.valid = '1' then cyc_stack_mem := cyc_stack_mem + 1; end if;
         if exec_mem_req.valid  = '1' then cyc_exec_mem  := cyc_exec_mem  + 1; end if;
         if recovery.valid = '1' then recoveries := recoveries + 1; end if;
         dq_occ_sum := dq_occ_sum + dq_occupancy;
         dq_occ_max := maximum( dq_occ_max, dq_occupancy );

         -- V0 : etats des unites (cycles, entrees) ; requetes acceptees par le cache.
         stv := ( st_stack, st_m2, st_cache );
         for u in 0 to OBS_UNITS - 1 loop
            st_cycles( u, stv( u ) ) := st_cycles( u, stv( u ) ) + 1;
            if stv( u ) /= st_prev( u ) then
               st_entries( u, stv( u ) ) := st_entries( u, stv( u ) ) + 1;
            end if;
            st_prev( u ) := stv( u );
         end loop;
         for p in 0 to 1 loop
            if dc_req( p ).valid = '1' and dc_ready( p ) = '1' then
               if dc_req( p ).probe = '1' then
                  acc_probe( p ) := acc_probe( p ) + 1;
               elsif dc_req( p ).write = '1' then
                  acc_write( p ) := acc_write( p ) + 1;
               else
                  acc_read( p ) := acc_read( p ) + 1;
               end if;
            end if;
         end loop;

         -- Fermer d'abord l'instruction qui se retire.  COMMIT et la prise de
         -- l'instruction suivante peuvent se produire sur le meme front ; traiter
         -- DECODE_TAKE en premier associerait alors le COMMIT precedent au nouveau
         -- chronometre et produirait artificiellement une latence nulle.
         if commit.valid = '1' then
            commits := commits + 1;
            opi := to_integer( unsigned( commit.slot.canon.op ) );
            cls := PERF_CLASS( commit.slot.canon.op );
            if inflight then
               lat := now - take_cycle;
               inflight := false;
               for u in 0 to OBS_UNITS - 1 loop
                  for s in 0 to OBS_STATES - 1 loop
                     st_op( opi, u, s ) := st_op( opi, u, s ) + st_cur( u, s );
                     st_cur( u, s ) := 0;
                  end loop;
               end loop;
            else
               -- Un commit sans DECODE_TAKE ne devrait pas arriver pour une instruction HX.
               lat := 0;
            end if;
            class_count( cls ) := class_count( cls ) + 1;
            class_lat_sum( cls ) := class_lat_sum( cls ) + lat;
            class_lat_max( cls ) := maximum( class_lat_max( cls ), lat );
            op_count( opi ) := op_count( opi ) + 1;
            op_lat_sum( opi ) := op_lat_sum( opi ) + lat;
            op_lat_max( opi ) := maximum( op_lat_max( opi ), lat );
         end if;

         -- Ouvrir ensuite le chronometre de l'instruction nouvellement prise.
         if dq_take /= 0 then
            takes := takes + to_integer( dq_take );
            famine := FAM_AUTRE;
            -- STACK_UNIT ne prend actuellement qu'une instruction a la fois.
            if not inflight then
               inflight := true;
               take_cycle := now;
            end if;
         end if;

         -- Cycles de l'instruction en vol, de sa prise (comprise) a son commit (exclu).
         if inflight then
            for u in 0 to OBS_UNITS - 1 loop
               st_cur( u, stv( u ) ) := st_cur( u, stv( u ) ) + 1;
            end loop;
         end if;
         starving_prev := starving;

         for p in dc_req'range loop
            if dc_req( p ).valid = '1' and dc_ready( p ) = '1'
               and dc_req( p ).write = '1'
               and dc_req( p ).address = to_unsigned( CONSOLE, 64 ) then
               old := got_out;
               got_out := new string'( old.all & to_hstring( dc_req( p ).wdata( 7 downto 0 ) ) );
               ch := character'val( to_integer( unsigned( dc_req( p ).wdata( 7 downto 0 ) ) ) );
               report "console InO : '" & ch & "' (" & to_hstring( dc_req( p ).wdata( 7 downto 0 ) ) & ")" severity note;
            end if;
         end loop;

         exit when halted = '1';
         if now mod 10000 = 0 then
            report "InO cycle " & integer'image( now ) & ", commits " & integer'image( commits ) severity note;
         end if;
         if now >= MAX_CYCLES_G then
            CHECK( c, false, "budget de cycles epuise" );
            exit;
         end if;
      end loop;

      report "InO : arret cycle " & integer'image( now ) & ", commits " & integer'image( commits )
         & ", cause " & integer'image( to_integer( halt_cause ) )
         & ", EXIT " & integer'image( to_integer( signed( exit_code ) ) )
         & ", FPC " & HEX( fpc ) & ", FCODE " & integer'image( to_integer( fcode ) ) severity note;

      CHECK( c, commits > 0, "au moins une instruction commise" );
      CHECK( c, halted = '1' and halt_cause = HALT_EXIT, "arret par EXIT" );
      CHECK( c, to_integer( signed( exit_code ) ) = exp_exit, "code de sortie",
             integer'image( exp_exit ), integer'image( to_integer( signed( exit_code ) ) ) );
      good := UPPER( got_out.all ) = UPPER( exp_out.all );
      CHECK( c, good, "sortie du programme", exp_out.all, got_out.all );

      if PERF_G then
         file_open( fp, "perf.txt", write_mode );
         PERF_LINE( "PERF " & NOM_G & " : " & integer'image( now ) & " cycles, "
                    & integer'image( commits ) & " retraits" );
         PERF_LINE( "PERF IPC (retraits par cycle)                       "
                    & F2( real( commits ) / real( maximum( now, 1 ) ) ) );
         PERF_LINE( "PERF prises DECODE_QUEUE                            " & integer'image( takes ) );
         PERF_LINE( "PERF partition SYSTEM_HOLD                          " & integer'image( cyc_system ) );
         PERF_LINE( "PERF partition FRONTEND_STARVE                      " & integer'image( cyc_front_starve ) );
         PERF_LINE( "PERF partition IDLE_AVEC_TRAVAIL                    " & integer'image( cyc_idle_work ) );
         PERF_LINE( "PERF partition INSTRUCTION_BUSY                     " & integer'image( cyc_busy ) );
         PERF_LINE( "PERF cycles requete memoire STACK                   " & integer'image( cyc_stack_mem ) );
         PERF_LINE( "PERF cycles requete memoire EXEC                    " & integer'image( cyc_exec_mem ) );
         PERF_LINE( "PERF occupation moyenne DECODE_QUEUE                "
                    & F2( real( dq_occ_sum ) / real( maximum( now, 1 ) ) ) );
         PERF_LINE( "PERF occupation max DECODE_QUEUE                    " & integer'image( dq_occ_max ) );
         PERF_LINE( "PERF reprises du frontal (RECOVERY)                 " & integer'image( recoveries ) );

         for k in perf_class_t loop
            if class_count( k ) /= 0 then
               PERF_LINE( "PERF CLASS " & CLASS_NAME( k )
                          & " count " & integer'image( class_count( k ) )
                          & " lat_sum " & integer'image( class_lat_sum( k ) )
                          & " lat_avg " & F2( real( class_lat_sum( k ) ) / real( class_count( k ) ) )
                          & " lat_max " & integer'image( class_lat_max( k ) ) );
            end if;
         end loop;

         for op in 0 to 255 loop
            if op_count( op ) /= 0 then
               PERF_LINE( "PERF OP " & to_hstring( std_logic_vector( to_unsigned( op, 8 ) ) )
                          & " count " & integer'image( op_count( op ) )
                          & " lat_sum " & integer'image( op_lat_sum( op ) )
                          & " lat_avg " & F2( real( op_lat_sum( op ) ) / real( op_count( op ) ) )
                          & " lat_max " & integer'image( op_lat_max( op ) ) );
            end if;
         end loop;

         PERF_LINES_V0;
         file_close( fp );
      end if;

      running <= false;
      FINISH( c, NOM_G );
   end process STIMULI;

                                ----
end architecture                TEST;
                                ----
------------------------------------------------------------------------------------------------------------------------
