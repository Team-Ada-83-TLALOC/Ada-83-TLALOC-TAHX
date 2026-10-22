library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
use work.TAHX_1_ISA.all;
use work.TAHX_1_ISA_TABLE.all;
use work.FETCH_DECODE_TYPES.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- T_K1e_STACK_CHAIN_tb : prise sur le cycle du commit (V2, étude de vitesse).
        --
        -- Les bancs K1* présentent une instruction à la fois : l'instruction suivante
        -- n'est jamais offerte au cycle d'un commit. Ce banc offre un flux continu
        -- (DECODE_QUEUE presque toujours non vide) d'un programme tiré au hasard,
        -- exécuté auparavant sur un modèle de référence (pile en mémoire, DSP) :
        --
        --   LI, ADD, SUB, OUX, CGT, NEG, INC, MUL, DUP, DROP, OVER, BRA, BT, BF,
        --   LQ / SQ directs [B16] lvl 0 vers une zone de données ou vers une
        --   cellule vivante de la pile (cohérence du cache de pile).
        --
        -- Cache de pile de 16 mots (configuration TAHX) et profondeur jusqu'à 40 :
        -- SPILL/FILL et collisions fréquents. ISSUE_READY, latence de COMPLETE,
        -- offre de DECODE et acceptation mémoire sont tirés au hasard. Les mauvaises
        -- prédictions (BT/BF) sont volontaires : elles interdisent l'enchaînement.
        --
        -- Vérifications : opérandes de chaque ISSUE (ordre du programme), opcode et
        -- PC de chaque COMMIT, absence de faute, puis après WRITEBACK_ALL : DSP final
        -- et mémoire (cellules vivantes de la pile et zone de données). Le banc
        -- compte aussi les prises enchaînées (chain_s, nom externe) : il en exige.
        --------------------------------------------------------------------------------


                                -------------------
entity                          T_K1e_STACK_CHAIN_tb
is                              -------------------
end entity                      T_K1e_STACK_CHAIN_tb;
                                -------------------


                                ----
architecture                    TEST
of T_K1e_STACK_CHAIN_tb is      ----

   constant PERIOD      : time := 10 ns;
   constant N_INSN      : positive := 6000;
   constant DMAX        : positive := 40;                  -- profondeur maximale de pile
   constant S0          : natural := 16#100000#;           -- DSP initial : pile vide
   constant MBASE       : natural := S0 - 512;             -- DISPLAY(0) : zone de données
   constant DATA_WORDS  : positive := 64;                  -- [ MBASE, S0 )
   constant MEM_WORDS   : positive := DATA_WORDS + DMAX + 8;
   constant P0          : natural := 16#400000#;
   constant SEED_1      : positive := 2026;
   constant SEED_2      : positive := 1022;

   constant OP_OUX_T    : opcode_t := x"02";
   constant OP_NEG_T    : opcode_t := x"08";
   constant OP_CGT_T    : opcode_t := x"09";
   constant OP_ADD_T    : opcode_t := x"10";
   constant OP_INC_T    : opcode_t := x"11";
   constant OP_SUB_T    : opcode_t := x"12";
   constant OP_MUL_T    : opcode_t := x"14";
   constant OP_DROP_T   : opcode_t := x"30";
   constant OP_DUP_T    : opcode_t := x"31";
   constant OP_OVER_T   : opcode_t := x"32";
   constant OP_LQ_T     : opcode_t := x"57";
   constant OP_SQ_T     : opcode_t := x"67";
   constant OP_LI_T     : opcode_t := x"C2";
   constant OP_BRA_T    : opcode_t := x"E1";
   constant OP_BT_T     : opcode_t := x"E5";
   constant OP_BF_T     : opcode_t := x"E9";

   type mem_t           is array( 0 to MEM_WORDS - 1 ) of word64_t;
   type prog_t          is array( 0 to N_INSN - 1 ) of decoded_slot_t;
   type operands_t      is array( 0 to 3 ) of word64_t;
   type exp_t           is record
                           n  : natural range 0 to 4;
                           op : operands_t;
                        end record;
   type exp_array_t     is array( 0 to N_INSN - 1 ) of exp_t;

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   constant NO_COMPLETE : ino_complete_t := (
      valid => '0', result_valid => '0', result => ( others => '0' ),
      fault => NO_FAULT, taken => '0', target => ( others => '0' ) );

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function INIT_WORD( i : natural ) return word64_t is
   begin
      if i < DATA_WORDS then
         return std_logic_vector( to_unsigned( ( i * 7919 + 13 ) mod 65536, 32 ) )
                & std_logic_vector( to_unsigned( ( i * 104729 + 7 ) mod 65536, 32 ) );
      end if;
      return ( others => '0' );
   end function;

   function INIT_MEM return mem_t is
      variable m : mem_t;
   begin
      for i in m'range loop m( i ) := INIT_WORD( i ); end loop;
      return m;
   end function;

   function WIDX( a : address_t ) return natural is
   begin
      return to_integer( ( a - A64( MBASE ) ) / 8 );
   end function;

   -- Résultat d'une opération (référence et exécuteur) ; a : le plus profond.
   function RESULT( op : opcode_t; val : signed; a, b : word64_t ) return word64_t is
      variable p : signed( 127 downto 0 );
   begin
      case op is
         when x"02" => return a xor b;
         when x"08" => return std_logic_vector( - signed( a ) );
         when x"09" => if signed( a ) > signed( b ) then return x"0000000000000001";
                       else return ( others => '0' ); end if;
         when x"10" => return std_logic_vector( signed( a ) + signed( b ) );
         when x"11" => return std_logic_vector( signed( a ) + 1 );
         when x"12" => return std_logic_vector( signed( a ) - signed( b ) );
         when x"14" => p := signed( a ) * signed( b ); return std_logic_vector( p( 63 downto 0 ) );
         when x"C2" => return std_logic_vector( resize( val, 64 ) );
         when others => return ( others => '0' );
      end case;
   end function;

   function TARGET_OF( pc : address_t ) return address_t is
   begin
      return pc + 64;
   end function;

   signal clk           : std_logic := '0';
   signal running       : boolean := true;
   signal reset         : std_logic := '1';

   -- Programme et attentes (écrits par GENERATE avant le départ).
   signal prog          : prog_t := ( others => NO_SLOT );
   signal expect        : exp_array_t;
   signal n_expect      : natural := 0;
   signal final_d       : natural := 0;
   signal final_mem     : mem_t;
   signal gen_done      : boolean := false;
   signal go            : boolean := false;

   -- DECODE_QUEUE du banc.
   signal ptr           : natural := 0;
   signal offer         : std_logic := '0';
   signal decode_valid  : std_logic;
   signal decode_slot   : decoded_slot_t := NO_SLOT;
   signal decode_take   : std_logic;

   signal issue_valid   : std_logic;
   signal issue         : ino_issue_t;
   signal issue_ready   : std_logic := '0';
   signal complete      : ino_complete_t := NO_COMPLETE;
   signal commit        : ino_commit_t;
   signal frame         : frame_state_t;

   signal sync_valid    : std_logic := '0';
   signal sync_frame    : frame_state_t := ( dsp => ( others => '0' ), rsp => ( others => '0' ),
                                             display => ( others => ( others => '0' ) ) );
   signal maint         : stack_maint_t := ( valid => '0', kind => MAINT_WRITEBACK_ALL,
                                             base => ( others => '0' ), length => ( others => '0' ) );
   signal maint_done    : std_logic;
   signal mem_req       : mem_request_t;
   signal mem_ready     : std_logic := '0';
   signal mem_rsp       : mem_response_t := NO_MEM_RESPONSE;
   signal idle          : std_logic;

   -- Mémoire du banc, publiée pour la vérification finale.
   signal mem_copy      : mem_t;
   signal exec_errors   : natural := 0;
   signal exec_checks   : natural := 0;
   signal issued        : natural := 0;
   signal spills, fills : natural := 0;

begin

   decode_valid <= offer when ptr < N_INSN and go else '0';
   decode_slot  <= prog( ptr ) when ptr < N_INSN else NO_SLOT;

   DUT : entity work.STACK_UNIT_WIDE
      generic map ( STACK_CACHE_WORDS_G => 16, RETURN_CACHE_WORDS_G => 8 )
      port map (
         CLK_i => clk, RESET_i => reset,
         DECODE_VALID_i => decode_valid, DECODE_SLOT_i => decode_slot, DECODE_TAKE_o => decode_take,
         ISSUE_VALID_o => issue_valid, ISSUE_o => issue, ISSUE_READY_i => issue_ready,
         COMPLETE_i => complete, COMMIT_o => commit,
         FRAME_o => frame, LIM_DSP_i => ( others => '1' ), LIM_RSP_i => ( others => '0' ),
         SYNC_VALID_i => sync_valid, SYNC_FRAME_i => sync_frame, SYNC_BUSY_o => open,
         MAINT_i => maint, MAINT_DONE_o => maint_done,
         MEM_REQ_o => mem_req, MEM_READY_i => mem_ready, MEM_RSP_i => mem_rsp,
         IDLE_o => idle );

   clk <= not clk after PERIOD / 2 when running;

        --------------------------------------------------------------------------------
        -- Programme tiré au hasard, exécuté sur la référence : pile = mémoire aux
        -- adresses ( S0, S0 + 8 d ], DSP = S0 + 8 d.
        --------------------------------------------------------------------------------

   GENERATE_PROG : process
      variable s1, s2 : positive := SEED_1;
      variable r      : real;
      variable m      : mem_t := INIT_MEM;
      variable d      : natural := 0;
      variable p      : prog_t;
      variable x      : exp_array_t;
      variable nx     : natural := 0;
      variable sl     : decoded_slot_t;
      variable op     : opcode_t;
      variable k, a, v : integer;
      variable va, vb : word64_t;
      variable tk     : std_logic;
      variable dmaxv  : natural := 0;
      variable force_inc, top_store : boolean := false;

      impure function RAND_INT( n : natural ) return natural is   -- 0 .. n - 1
      begin
         uniform( s1, s2, r );
         return integer( trunc( r * real( n ) ) ) mod n;
      end function;

      impure function TOP( j : natural ) return word64_t is       -- j = 0 : sommet
      begin
         return m( WIDX( A64( S0 + 8 * ( d - j ) ) ) );
      end function;

      procedure PUSH( w : word64_t ) is
      begin
         d := d + 1;
         m( WIDX( A64( S0 + 8 * d ) ) ) := w;
      end procedure;

      procedure EXPECT_OPS( n : natural ) is              -- n sources, la plus profonde d'abord
      begin
         x( nx ).n := n;
         x( nx ).op := ( others => ( others => '0' ) );
         for j in 0 to 3 loop
            if j < n then x( nx ).op( j ) := TOP( n - 1 - j ); end if;
         end loop;
         nx := nx + 1;
      end procedure;

   begin
      s2 := SEED_2;
      for i in 0 to N_INSN - 1 loop
         -- Tirage d'une opération possible à la profondeur d. Par phases de 150
         -- instructions, la pile monte (empilements favorisés) ou descend : les
         -- excursions jusqu'à DMAX font déborder le cache de pile de 16 mots.
         loop
            k := RAND_INT( 20 );
            top_store := false;
            if force_inc and d >= 1 then
               -- Consommateur immédiat de la cellule rangée par le SQ précédent.
               op := OP_INC_T;
               exit;
            elsif ( i / 150 ) mod 2 = 1 and d >= 2 and RAND_INT( 8 ) = 0 then
               -- SQ vers la cellule qui devient le sommet (souvent propre après un
               -- FILL dans une phase de descente), puis INC : l'invalidation de la
               -- copie du cache de pile doit être vue par la prise enchaînée.
               op := OP_SQ_T;
               top_store := true;
               exit;
            elsif ( i / 150 ) mod 2 = 0 and RAND_INT( 3 ) = 0 then
               k := 0;                                    -- LI
            elsif ( i / 150 ) mod 2 = 1 and RAND_INT( 3 ) = 0 then
               k := 12;                                   -- DROP
            end if;
            case k is
               when 0 | 1 | 2 => op := OP_LI_T;   exit when d < DMAX;
               when 3      => op := OP_ADD_T;  exit when d >= 2;
               when 4      => op := OP_SUB_T;  exit when d >= 2;
               when 5      => op := OP_OUX_T;  exit when d >= 2;
               when 6      => op := OP_CGT_T;  exit when d >= 2;
               when 7      => op := OP_NEG_T;  exit when d >= 1;
               when 8      => op := OP_INC_T;  exit when d >= 1;
               when 9      => op := OP_MUL_T;  exit when d >= 2;
               when 10     => op := OP_DUP_T;  exit when d >= 1 and d < DMAX;
               when 11     => op := OP_OVER_T; exit when d >= 2 and d < DMAX;
               when 12 | 13 => op := OP_DROP_T; exit when d >= 1;
               when 14     => op := OP_BRA_T;  exit;
               when 15     => op := OP_BT_T;   exit when d >= 1;
               when 16     => op := OP_BF_T;   exit when d >= 1;
               when 17 | 18 => op := OP_LQ_T;  exit when d < DMAX;
               when others => op := OP_SQ_T;   exit when d >= 1;
            end case;
         end loop;

         sl := NO_SLOT;
         sl.valid := '1';
         sl.canon.op := op;
         sl.canon.lvl := ( others => '0' );
         sl.canon.len := to_unsigned( ISA_TABLE( to_integer( unsigned( op ) ) ).length, sl.canon.len'length );
         sl.pc := A64( P0 + 16 * i );
         sl.pred := NO_PREDICTION;
         sl.pred.target := TARGET_OF( sl.pc );

         case op is
            when OP_LI_T =>
               v := RAND_INT( 2001 ) - 1000;
               sl.canon.val := to_signed( v, sl.canon.val'length );
               EXPECT_OPS( 0 );
               PUSH( RESULT( op, sl.canon.val, ( others => '0' ), ( others => '0' ) ) );

            when OP_ADD_T | OP_SUB_T | OP_OUX_T | OP_CGT_T | OP_MUL_T =>
               EXPECT_OPS( 2 );
               va := TOP( 1 ); vb := TOP( 0 );
               d := d - 2;
               PUSH( RESULT( op, sl.canon.val, va, vb ) );

            when OP_NEG_T | OP_INC_T =>
               EXPECT_OPS( 1 );
               va := TOP( 0 );
               d := d - 1;
               PUSH( RESULT( op, sl.canon.val, va, va ) );

            when OP_DUP_T =>
               PUSH( TOP( 0 ) );
            when OP_OVER_T =>
               PUSH( TOP( 1 ) );
            when OP_DROP_T =>
               d := d - 1;

            when OP_BRA_T =>
               sl.pred.taken := '1';
               EXPECT_OPS( 0 );

            when OP_BT_T | OP_BF_T =>
               EXPECT_OPS( 1 );
               tk := '0';
               if ( op = OP_BT_T and TOP( 0 ) /= x"0000000000000000" )
                  or ( op = OP_BF_T and TOP( 0 ) = x"0000000000000000" ) then
                  tk := '1';
               end if;
               -- Prédiction juste 4 fois sur 5.
               if RAND_INT( 5 ) = 0 then sl.pred.taken := not tk; else sl.pred.taken := tk; end if;
               d := d - 1;

            when OP_LQ_T =>
               -- Zone de données, ou cellule vivante de la pile (1 .. d).
               if d >= 1 and RAND_INT( 2 ) = 0 then
                  a := S0 + 8 * ( 1 + RAND_INT( d ) );
               else
                  a := MBASE + 8 * RAND_INT( DATA_WORDS );
               end if;
               sl.canon.val := to_signed( a - MBASE, sl.canon.val'length );
               EXPECT_OPS( 0 );
               PUSH( m( WIDX( A64( a ) ) ) );

            when others =>                                -- OP_SQ_T
               if top_store then
                  a := S0 + 8 * ( d - 1 );
               elsif RAND_INT( 2 ) = 0 then
                  a := S0 + 8 * ( 1 + RAND_INT( d ) );    -- cellule vivante, sommet compris
               else
                  a := MBASE + 8 * RAND_INT( DATA_WORDS );
               end if;
               sl.canon.val := to_signed( a - MBASE, sl.canon.val'length );
               EXPECT_OPS( 1 );
               va := TOP( 0 );
               d := d - 1;
               m( WIDX( A64( a ) ) ) := va;
         end case;
         p( i ) := sl;
         force_inc := top_store;
         if d > dmaxv then dmaxv := d; end if;
      end loop;

      prog      <= p;
      expect    <= x;
      n_expect  <= nx;
      final_d   <= d;
      final_mem <= m;
      gen_done  <= true;
      report "programme : " & integer'image( N_INSN ) & " instructions, " & integer'image( nx )
             & " émissions, profondeur finale " & integer'image( d ) & ", maximale "
             & integer'image( dmaxv ) severity note;
      wait;
   end process GENERATE_PROG;

        --------------------------------------------------------------------------------
        -- DECODE_QUEUE : flux continu, avec des trous tirés au hasard.
        --------------------------------------------------------------------------------

   FEED : process( clk )
      variable s1, s2 : positive := 31;
      variable r      : real;
   begin
      if rising_edge( clk ) then
         if decode_take = '1' then
            ptr <= ptr + 1;
         end if;
         uniform( s1, s2, r );
         if r < 0.9 then offer <= '1'; else offer <= '0'; end if;
      end if;
   end process FEED;

        --------------------------------------------------------------------------------
        -- Mémoire (FILL/SPILL de STACK_UNIT) et exécuteur (LI, entier, MUL, branches,
        -- LQ/SQ directs dans la même mémoire).
        --------------------------------------------------------------------------------

   MACHINE : process( clk )
      variable s1, s2   : positive := 77;
      variable r        : real;
      variable m        : mem_t := INIT_MEM;
      variable ne       : natural := 0;
      variable nerr, nchk : natural := 0;
      variable busy     : boolean := false;
      variable wait_n   : natural := 0;
      variable pend     : ino_complete_t := NO_COMPLETE;
      variable e        : exp_t;
      variable op       : opcode_t;
      variable va, vb   : word64_t;
      variable w        : word64_t;
      variable addr     : address_t;
      variable tk       : std_logic;
      variable nrd, nwr : natural := 0;
   begin
      if rising_edge( clk ) then
         mem_rsp  <= NO_MEM_RESPONSE;
         complete <= NO_COMPLETE;

         if reset = '0' then
            -- Port mémoire de STACK_UNIT : réponse au cycle suivant l'acceptation.
            if mem_req.valid = '1' and mem_ready = '1' then
               assert mem_req.size = "11" and mem_req.probe = '0'
                  report "K1e : requete STACK inattendue" severity failure;
               if mem_req.write = '1' then
                  nwr := nwr + 1;
                  m( WIDX( mem_req.address ) ) := mem_req.wdata;
                  mem_rsp <= ( valid => '1', rdata => ( others => '0' ), fault => '0' );
               else
                  nrd := nrd + 1;
                  mem_rsp <= ( valid => '1', rdata => m( WIDX( mem_req.address ) ), fault => '0' );
               end if;
            end if;

            -- Terminaison en attente.
            if busy then
               if wait_n = 0 then
                  complete <= pend;
                  busy := false;
               else
                  wait_n := wait_n - 1;
               end if;
            end if;

            -- Émission acceptée à ce front.
            if issue_valid = '1' and issue_ready = '1' then
               assert not busy report "K1e : emission pendant une execution" severity failure;
               op := issue.slot.canon.op;
               if ne < n_expect then
                  e := expect( ne );
               else
                  e := ( n => 0, op => ( others => ( others => '0' ) ) );
               end if;
               nchk := nchk + 1;
               if issue.operand_count /= e.n then
                  nerr := nerr + 1;
                  report "K1e : emission " & integer'image( ne ) & " (" & HEX( op ) & ") : "
                         & integer'image( issue.operand_count ) & " operandes, attendu "
                         & integer'image( e.n ) severity error;
               else
                  for j in 0 to 3 loop
                     if j < e.n and issue.operand( j ) /= e.op( j ) then
                        nerr := nerr + 1;
                        report "K1e : emission " & integer'image( ne ) & " (" & HEX( op ) & ", pc "
                               & HEX( issue.slot.pc ) & ") : operande " & integer'image( j ) & " "
                               & HEX( issue.operand( j ) ) & ", attendu " & HEX( e.op( j ) )
                               severity error;
                     end if;
                  end loop;
               end if;
               ne := ne + 1;

               va := issue.operand( 0 );
               vb := issue.operand( 1 );
               pend := NO_COMPLETE;
               pend.valid := '1';
               case op is
                  when OP_BRA_T | OP_BT_T | OP_BF_T =>
                     tk := '1';
                     if ( op = OP_BT_T and va = x"0000000000000000" )
                        or ( op = OP_BF_T and va /= x"0000000000000000" ) then
                        tk := '0';
                     end if;
                     pend.taken := tk;
                     if tk = '1' then
                        pend.target := TARGET_OF( issue.slot.pc );
                     else
                        pend.target := issue.slot.pc + resize( issue.slot.canon.len, 64 );
                     end if;
                  when OP_LQ_T =>
                     assert issue.address_known = '1' report "K1e : LQ sans adresse" severity failure;
                     pend.result_valid := '1';
                     pend.result := m( WIDX( issue.address ) );
                  when OP_SQ_T =>
                     assert issue.address_known = '1' report "K1e : SQ sans adresse" severity failure;
                     m( WIDX( issue.address ) ) := va;
                  when others =>
                     pend.result_valid := '1';
                     pend.result := RESULT( op, issue.slot.canon.val, va, vb );
               end case;

               -- Latence : 0 (60 %), 1 ou 2 cycles de plus.
               uniform( s1, s2, r );
               if r < 0.6 then wait_n := 0; elsif r < 0.85 then wait_n := 1; else wait_n := 2; end if;
               busy := true;
            end if;

            uniform( s1, s2, r );
            if r < 0.8 then issue_ready <= '1'; else issue_ready <= '0'; end if;
            uniform( s1, s2, r );
            if r < 0.75 then mem_ready <= '1'; else mem_ready <= '0'; end if;
         end if;

         mem_copy    <= m;
         spills      <= nwr;
         fills       <= nrd;
         exec_errors <= nerr;
         exec_checks <= nchk;
         issued      <= ne;
      end if;
   end process MACHINE;

        --------------------------------------------------------------------------------
        -- Commits, enchaînements, bilan.
        --------------------------------------------------------------------------------

   STIMULI : process
      alias chain is << signal .T_K1e_STACK_CHAIN_tb.DUT.U_DUT.chain_s : std_logic >>;
      variable c        : tb_counter_t := TB_COUNTER_INIT;
      variable ncommit  : natural := 0;
      variable nchain   : natural := 0;
      variable nmispred : natural := 0;
      variable cycles   : natural := 0;
      variable bad      : natural := 0;
      variable w        : word64_t;
   begin
      wait until gen_done;
      wait for 3 * PERIOD;
      wait until rising_edge( clk );
      reset <= '0';

      sync_frame.dsp          <= A64( S0 );
      sync_frame.rsp          <= A64( 16#200000# );
      sync_frame.display      <= ( others => ( others => '0' ) );
      sync_frame.display( 0 ) <= A64( MBASE );
      sync_valid              <= '1';
      wait until rising_edge( clk );
      sync_valid <= '0';
      loop
         wait until rising_edge( clk );
         exit when frame.dsp = A64( S0 ) and frame.display( 0 ) = A64( MBASE );
      end loop;
      wait until rising_edge( clk );
      go <= true;

      while ncommit < N_INSN loop
         wait until rising_edge( clk );
         cycles := cycles + 1;
         if chain = '1' and decode_take = '1' then
            nchain := nchain + 1;
         end if;
         if commit.valid = '1' then
            if commit.fault.valid = '1' then
               CHECK( c, false, "commit " & integer'image( ncommit ) & " sans faute",
                      "aucune", HEX( commit.fault.code ) );
            elsif commit.slot.pc /= prog( ncommit ).pc
                  or commit.slot.canon.op /= prog( ncommit ).canon.op then
               CHECK( c, false, "commit " & integer'image( ncommit ) & " dans l'ordre du programme",
                      HEX( prog( ncommit ).pc ), HEX( commit.slot.pc ) );
            else
               CHECK_PASSED( c );
            end if;
            if commit.slot.pred.taken /= commit.taken then
               nmispred := nmispred + 1;
            end if;
            ncommit := ncommit + 1;
         end if;
         if cycles > 40 * N_INSN then
            CHECK( c, false, "programme termine dans le budget de cycles" );
            exit;
         end if;
      end loop;

      -- Repos, puis écriture de tout le cache de pile.
      loop
         wait until rising_edge( clk );
         exit when idle = '1';
      end loop;
      maint <= ( valid => '1', kind => MAINT_WRITEBACK_ALL, base => ( others => '0' ), length => ( others => '0' ) );
      wait until rising_edge( clk );
      maint.valid <= '0';
      loop
         wait until rising_edge( clk );
         exit when maint_done = '1';
      end loop;
      wait until rising_edge( clk );
      wait until rising_edge( clk );

      CHECK( c, issued = n_expect, "nombre d'emissions", integer'image( n_expect ), integer'image( issued ) );
      CHECK( c, exec_errors = 0, "operandes des emissions (" & integer'image( exec_checks ) & " emissions)",
             "0 erreur", integer'image( exec_errors ) & " erreur(s)" );
      CHECK( c, frame.dsp = A64( S0 + 8 * final_d ), "DSP final",
             HEX( A64( S0 + 8 * final_d ) ), HEX( frame.dsp ) );
      for i in 0 to DATA_WORDS + final_d loop
         if mem_copy( i ) /= final_mem( i ) then
            bad := bad + 1;
            if bad <= 5 then
               report "K1e : memoire " & HEX( A64( MBASE + 8 * i ) ) & " : " & HEX( mem_copy( i ) )
                      & ", attendu " & HEX( final_mem( i ) ) severity error;
            end if;
         end if;
      end loop;
      CHECK( c, bad = 0, "memoire finale (donnees et pile vivante)", "0", integer'image( bad ) );
      CHECK( c, nchain > N_INSN / 5, "prises au cycle du commit",
             "> " & integer'image( N_INSN / 5 ), integer'image( nchain ) );
      CHECK( c, nmispred > 50, "mauvaises predictions exercees", "> 50", integer'image( nmispred ) );
      CHECK( c, spills > 200 and fills > 200, "SPILL et FILL exerces", "> 200",
             integer'image( spills ) & " / " & integer'image( fills ) );

      report "K1e : " & integer'image( ncommit ) & " commits en " & integer'image( cycles ) & " cycles, "
             & integer'image( nchain ) & " prises enchainees, " & integer'image( nmispred )
             & " mauvaises predictions, SPILL " & integer'image( spills ) & ", FILL "
             & integer'image( fills ) severity note;
      running <= false;
      FINISH( c, "T_K1e_STACK_CHAIN_tb" );
      wait;
   end process STIMULI;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
