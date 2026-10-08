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
use work.FETCH_DECODE_TYPES.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- Intégration STACK_UNIT -> INO_BACKEND_MEMORY.
        --
        -- Le scénario force successivement :
        --   1. LVA direct d'une cellule de calcul sale : writeback avant exposition ;
        --   2. ADD qui rend cette cellule sale à nouveau ;
        --   3. SB direct dans cette cellule : writeback avant rangement partiel, puis
        --      invalidation de la copie cache après succès ;
        --   4. DUP : FILL obligatoire de la valeur modifiée par SB ;
        --   5. LQ direct d'une autre cellule sale : writeback avant lecture mémoire.
        --
        -- Le port mémoire interne de STACK_UNIT et celui du backend partagent ici un
        -- modèle mémoire par un arbitre minimal à une requête en vol.
        --------------------------------------------------------------------------------

                                ------------------------------
entity                          T_K2e_STACK_BACKEND_MEMORY_tb
is                              ------------------------------
end entity                      T_K2e_STACK_BACKEND_MEMORY_tb;
                                ------------------------------

                                ----
architecture                    TEST
of T_K2e_STACK_BACKEND_MEMORY_tb is

   constant PERIOD : time := 10 ns;
   constant BASE   : natural := 16#1000#;
   constant R0     : natural := 16#3000#;

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   type memory_t is array( 0 to 63 ) of word64_t;
   type owner_t is ( OWNER_NONE, OWNER_STACK, OWNER_BACKEND );

   signal clk              : std_logic := '0';
   signal running          : boolean := true;
   signal reset            : std_logic := '1';

   signal decode_block     : decoded_block_t := ( others => NO_SLOT );
   signal decode_count     : decode_count_t := ( others => '0' );
   signal decode_take      : decode_count_t;

   signal issue_valid      : std_logic;
   signal issue            : ino_issue_t;
   signal issue_ready      : std_logic;
   signal complete         : ino_complete_t;
   signal commit           : ino_commit_t;

   signal frame            : frame_state_t;
   signal limits           : limits_t := (
      lim_dsp => ( others => '1' ), lim_rsp => ( others => '0' ),
      lim_csp => ( others => '1' ), lim_hp  => ( others => '1' ) );

   signal sync_valid       : std_logic := '0';
   signal sync_frame       : frame_state_t := (
      dsp => ( others => '0' ), rsp => ( others => '0' ),
      display => ( others => ( others => '0' ) ) );

   signal maint            : stack_maint_t := (
      valid => '0', kind => MAINT_WRITEBACK_ALL,
      base => ( others => '0' ), length => ( others => '0' ) );
   signal maint_done       : std_logic;
   signal idle             : std_logic;

   signal stack_mem_req    : mem_request_t;
   signal stack_mem_ready  : std_logic;
   signal stack_mem_rsp    : mem_response_t;

   signal back_mem_req     : mem_request_t;
   signal back_mem_ready   : std_logic;
   signal back_mem_rsp     : mem_response_t;

   signal ext_mem_req      : mem_request_t;
   signal ext_mem_ready    : std_logic;
   signal raw_mem_rsp      : mem_response_t := NO_MEM_RESPONSE;
   signal owner_s          : owner_t := OWNER_NONE;

   signal memory_s         : memory_t := ( others => ( others => '0' ) );
   signal pending_s        : std_logic := '0';
   signal pending_rdata_s  : word64_t := ( others => '0' );
   signal pending_fault_s  : std_logic := '0';

   signal stack_reads      : natural := 0;
   signal stack_writes     : natural := 0;
   signal back_reads       : natural := 0;
   signal back_writes      : natural := 0;

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function IDX( a : address_t ) return natural is
   begin
      return ( to_integer( a ) - BASE ) / 8;
   end function;

   function SLOT(
      op  : opcode_t;
      lvl : natural := 0;
      val : integer := 0;
      len : natural := 1 ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid     := '1';
      r.canon.op  := op;
      r.canon.lvl := to_unsigned( lvl, r.canon.lvl'length );
      r.canon.ofs := ( others => '0' );
      r.canon.val := to_signed( val, r.canon.val'length );
      r.canon.len := to_unsigned( len, r.canon.len'length );
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
         MEM_REQ_o => stack_mem_req, MEM_READY_i => stack_mem_ready, MEM_RSP_i => stack_mem_rsp,
         IDLE_o => idle );

   U_BACKEND : entity work.INO_BACKEND_MEMORY
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         MEM_REQ_o => back_mem_req, MEM_READY_i => back_mem_ready, MEM_RSP_i => back_mem_rsp,
         COMPLETE_o => complete );

   clk <= not clk after PERIOD / 2 when running;

        --------------------------------------------------------------------------------
        -- Arbitre mémoire : STACK_UNIT a priorité. L'architecture InO garantit qu'il
        -- ne devrait jamais y avoir de concurrence réelle entre prémaintenance et accès
        -- du backend ; l'assertion ci-dessous le vérifie.
        --------------------------------------------------------------------------------

   ext_mem_req <= stack_mem_req when stack_mem_req.valid = '1' else back_mem_req;
   ext_mem_ready <= '1' when owner_s = OWNER_NONE else '0';

   stack_mem_ready <= ext_mem_ready when stack_mem_req.valid = '1' else '0';
   back_mem_ready  <= ext_mem_ready when stack_mem_req.valid = '0' and back_mem_req.valid = '1' else '0';

   stack_mem_rsp <= raw_mem_rsp when owner_s = OWNER_STACK else NO_MEM_RESPONSE;
   back_mem_rsp  <= raw_mem_rsp when owner_s = OWNER_BACKEND else NO_MEM_RESPONSE;

   MEMORY_MODEL : process( clk )
      variable i : natural;
      variable w : word64_t;
   begin
      if rising_edge( clk ) then
         raw_mem_rsp <= NO_MEM_RESPONSE;

         if pending_s = '1' then
            raw_mem_rsp <= ( valid => '1', rdata => pending_rdata_s, fault => pending_fault_s );
            pending_s <= '0';
         end if;

         if reset = '1' then
            owner_s <= OWNER_NONE;
            pending_s <= '0';
            memory_s <= ( others => ( others => '0' ) );
            stack_reads <= 0; stack_writes <= 0;
            back_reads <= 0; back_writes <= 0;
         else
            if raw_mem_rsp.valid = '1' then
               owner_s <= OWNER_NONE;
            end if;

            assert not ( stack_mem_req.valid = '1' and back_mem_req.valid = '1' )
               report "STACK/BACKEND MEMORY TB : deux maitres memoire simultanes"
               severity failure;

            if ext_mem_req.valid = '1' and ext_mem_ready = '1' then
               assert ext_mem_req.address >= A64( BASE )
                  and ext_mem_req.address < A64( BASE + 64 * 8 )
                  report "STACK/BACKEND MEMORY TB : adresse hors memoire de test"
                  severity failure;

               i := IDX( ext_mem_req.address );
               w := memory_s( i );

               if stack_mem_req.valid = '1' then
                  owner_s <= OWNER_STACK;
                  if ext_mem_req.write = '1' then stack_writes <= stack_writes + 1;
                  else stack_reads <= stack_reads + 1; end if;
               else
                  owner_s <= OWNER_BACKEND;
                  if ext_mem_req.write = '1' then back_writes <= back_writes + 1;
                  else back_reads <= back_reads + 1; end if;
               end if;

               if ext_mem_req.write = '1' then
                  case ext_mem_req.size is
                     when "00" => w( 7 downto 0 )   := ext_mem_req.wdata( 7 downto 0 );
                     when "01" => w( 15 downto 0 )  := ext_mem_req.wdata( 15 downto 0 );
                     when "10" => w( 31 downto 0 )  := ext_mem_req.wdata( 31 downto 0 );
                     when others => w := ext_mem_req.wdata;
                  end case;
                  memory_s( i ) <= w;
                  pending_rdata_s <= ( others => '0' );
               else
                  pending_rdata_s <= w;
               end if;
               pending_fault_s <= '0';
               pending_s <= '1';
            end if;
         end if;
      end if;
   end process MEMORY_MODEL;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable f : frame_state_t;
      variable sw0, sr0, bw0, br0 : natural;

      procedure DO_SYNC is
      begin
         f.dsp := A64( BASE );
         f.rsp := A64( R0 );
         f.display := ( others => ( others => '0' ) );
         f.display( 0 ) := A64( BASE );
         sync_frame <= f;
         sync_valid <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait for 1 ns;
         CHECK( c, frame.dsp = A64( BASE ), "DSP apres SYNC" );
         CHECK( c, frame.display( 0 ) = A64( BASE ), "DISPLAY0 apres SYNC" );
      end procedure;

      procedure PRESENT( constant s : in decoded_slot_t ) is
      begin
         decode_block      <= ( others => NO_SLOT );
         decode_block( 0 ) <= s;
         decode_count      <= to_unsigned( 1, decode_count'length );
         loop
            wait until rising_edge( clk );
            exit when decode_take /= 0;
         end loop;
         decode_count <= ( others => '0' );
         decode_block <= ( others => NO_SLOT );
      end procedure;

      procedure RUN_OK( constant s : in decoded_slot_t; constant expected_dsp : in natural ) is
         variable cycles : natural := 0;
      begin
         PRESENT( s );
         loop
            wait until rising_edge( clk );
            wait for 1 ns;
            exit when commit.valid = '1';
            cycles := cycles + 1;
            assert cycles < 120 report "timeout COMMIT" severity failure;
         end loop;
         CHECK( c, commit.fault.valid = '0', "instruction sans faute" );
         CHECK( c, frame.dsp = A64( expected_dsp ), "DSP au COMMIT" );
      end procedure;

      procedure MAINT_ALL is
      begin
         maint <= ( valid => '1', kind => MAINT_WRITEBACK_ALL,
                    base => ( others => '0' ), length => ( others => '0' ) );
         wait until rising_edge( clk );
         maint.valid <= '0';
         loop
            wait until rising_edge( clk );
            wait for 1 ns;
            exit when maint_done = '1';
         end loop;
      end procedure;

   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      DO_SYNC;

      ------------------------------------------------------------------
      -- 1. Cellule sale, puis LVA connu : elle doit être rangée avant que
      --    son adresse soit rendue au programme.
      ------------------------------------------------------------------
      RUN_OK( SLOT( OP_LI_D32, 0, 16#12345678#, 5 ), BASE + 8 );
      sw0 := stack_writes;
      RUN_OK( SLOT( x"47", 0, 8, 3 ), BASE + 16 );                 -- LVA 0,8
      CHECK( c, stack_writes = sw0 + 1, "LVA provoque un writeback" );
      CHECK( c, memory_s( 1 ) = x"0000000012345678",
               "valeur exposee par LVA en memoire",
               HEX( word64_t'(x"0000000012345678") ), HEX( memory_s( 1 ) ) );

      RUN_OK( SLOT( x"30" ), BASE + 8 );                           -- DROP adresse

      ------------------------------------------------------------------
      -- 2. Rendre la cellule 1008 sale à nouveau par ADD.
      ------------------------------------------------------------------
      RUN_OK( SLOT( x"D1", 0, 1, 1 ), BASE + 16 );                 -- LI 1 (imm4)
      RUN_OK( SLOT( x"10" ), BASE + 8 );                           -- ADD -> 12345679

      ------------------------------------------------------------------
      -- 3. Store direct partiel dans la cellule sale : writeback de
      --    l'ancien mot avant SB, puis invalidation de la copie cache.
      ------------------------------------------------------------------
      RUN_OK( SLOT( OP_LI_D32, 0, 16#AA#, 5 ), BASE + 16 );
      sw0 := stack_writes; bw0 := back_writes;
      RUN_OK( SLOT( x"64", 0, 8, 3 ), BASE + 8 );                  -- SB 0,8
      CHECK( c, stack_writes = sw0 + 1, "SB direct : writeback avant store partiel" );
      CHECK( c, back_writes = bw0 + 1, "SB direct : rangement backend" );
      CHECK( c, memory_s( 1 ) = x"00000000123456AA",
               "SB direct conserve les octets non ecrits",
               HEX( word64_t'(x"00000000123456AA") ), HEX( memory_s( 1 ) ) );

      ------------------------------------------------------------------
      -- 4. DUP de la cellule invalidée : elle doit être relue en mémoire,
      --    prouvant que le store direct a bien invalidé la copie cache.
      ------------------------------------------------------------------
      sr0 := stack_reads;
      RUN_OK( SLOT( x"31" ), BASE + 16 );                           -- DUP
      CHECK( c, stack_reads = sr0 + 1, "DUP apres store direct : FILL" );

      ------------------------------------------------------------------
      -- 5. La cellule dupliquée à 1010 est sale. Un LQ direct de 1010 doit
      --    la réécrire avant que le backend ne lise la mémoire.
      ------------------------------------------------------------------
      sw0 := stack_writes; br0 := back_reads;
      RUN_OK( SLOT( x"57", 0, 16, 3 ), BASE + 24 );                 -- LQ 0,16
      CHECK( c, stack_writes = sw0 + 1, "LQ direct : writeback cellule sale" );
      CHECK( c, back_reads = br0 + 1, "LQ direct : lecture backend" );
      CHECK( c, memory_s( 2 ) = x"00000000123456AA",
               "writeback de la cellule dupliquee",
               HEX( word64_t'(x"00000000123456AA") ), HEX( memory_s( 2 ) ) );

      -- Le résultat du LQ est à 1018 et sale ; WRITEBACK_ALL permet de
      -- vérifier sa valeur sans dépendre de l'organisation interne du cache.
      MAINT_ALL;
      CHECK( c, memory_s( 3 ) = x"00000000123456AA",
               "resultat LQ remis en memoire",
               HEX( word64_t'(x"00000000123456AA") ), HEX( memory_s( 3 ) ) );

      CHECK( c, frame.dsp = A64( BASE + 24 ), "DSP final" );
      FINISH( c, "T_K2e_STACK_BACKEND_MEMORY_tb" );
      running <= false;
      wait;
   end process STIMULI;

end architecture TEST;

------------------------------------------------------------------------------------------------------------------------
