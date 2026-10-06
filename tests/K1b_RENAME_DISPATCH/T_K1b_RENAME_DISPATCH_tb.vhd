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
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_K1b_RENAME_DISPATCH_tb : le contrat R1 de K1b_RENAME_DISPATCH.
		--
		--  Référence : l'exécution séquentielle de la machine à pile. Ce qui compte pour
		--  le renommage, ce sont les valeurs des cellules : le banc tient la pile data,
		--  la pile des retours et l'état de frame ; les valeurs produites par les unités
		--  sont choisies par lui. Pour chaque instruction il sait, à sa génération, ce
		--  que ses sources doivent lire, les cellules qu'elle empile et lit, son adresse
		--  connue, l'état de frame après elle et sa faute.
		--  Il joue la file de décodage, le ROB (allocation, retrait, reprises sur
		--  mauvaise prédiction et sur faute en tête, SYNC), les unités (lecture des
		--  sources prêtes, contrôle des valeurs, écriture et réveil de la destination ;
		--  FRAME_UPDATE pour UNLINK) et la LSQ (FILL servis à la valeur de la cellule au
		--  point de leur instruction, invalidations des rangements par pointeur).
		--  Un registre réattribué trop tôt donnerait une valeur fausse en source ; à la
		--  fin, après une reprise, tous les registres doivent être libres.
		--------------------------------------------------------------------------------


				-------------------------
entity				T_K1b_RENAME_DISPATCH_tb
is				-------------------------
end entity			T_K1b_RENAME_DISPATCH_tb;
				-------------------------


architecture			TEST
of T_K1b_RENAME_DISPATCH_tb is

   constant PERIOD		: time		:= 10 ns;
   constant INSTRUCTIONS	: positive	:= 12000;
   constant SEED_1		: positive	:= 1515;
   constant SEED_2		: positive	:= 1610;
   constant DEFERRED		: boolean	:= true;				-- R2b : écriture différée
   constant WIN		: positive	:= 1024;				-- instructions suivies, modulo WIN
   constant NTAGS		: positive	:= 2 ** PHYSICAL_TAG_BITS;
   constant S0		: natural	:= 16#100000#;				-- pile data : DSP0
   constant SWORDS		: positive	:= 4096;				-- mots suivis de la pile data
   constant SLOW		: natural	:= S0 - 8 * 512;			-- premier mot suivi
   constant R0		: natural	:= 16#200000#;				-- pile des retours : RSP0
   constant RWORDS		: positive	:= 256;
   constant LIM_DSP		: natural	:= S0 + 8 * 3000;
   constant LIM_RSP		: natural	:= R0 - 8 * 100;

   type word_array_t		is array( natural range <> ) of word64_t;
   type kind_t			is ( K_LIN, K_LI, K_DROP, K_DUP, K_OVER, K_LOAD, K_STORE, K_PSTORE, K_CHK, K_LEX, K_CALL,
				     K_CALLI, K_RTD, K_BRA, K_BT, K_LINK, K_UNLINK, K_EXCM, K_TRAP16, K_ILLEGAL,
				     K_LVA, K_PLOAD, K_CLOAD );
   type vals_t			is array( 0 to 3 ) of word64_t;
   type addrs_t		is array( 0 to 9 ) of natural;

   type ins_t			is record
			  kind		: kind_t;
			  slot		: decoded_slot_t;
			  nsrc		: natural range 0 to 4;
			  src		: vals_t;			-- valeurs attendues des sources
			  nread		: natural range 0 to 5;	-- cellules lues (FILL possibles) : adresse, valeur
			  raddr		: addrs_t;
			  rval		: word_array_t( 0 to 4 );
			  npush		: natural range 0 to 2;	-- cellules empilées (SPILL)
			  paddr		: addrs_t;
			  dest		: boolean;
			  dval		: word64_t;
			  conv_old	: word64_t;		-- accès direct étroit converti : la cellule avant
			  conv_new	: word64_t;		--  (écriture) la cellule après
			  conv_cell	: natural;		--  son adresse
			  addr_known	: boolean;
			  addr		: address_t;
			  fault		: natural;
			  control		: boolean;
			  mispredict	: boolean;
			  is_store	: boolean;
			  ptr_ea		: integer;			-- rangement par pointeur : adresse (−1 : hors pile)
			  frame_before	: frame_state_t;
			  frame_after	: frame_state_t;
			  nundo		: natural range 0 to 10;	-- écritures à défaire : adresse, ancienne valeur
			  uaddr		: addrs_t;
			  uval		: word_array_t( 0 to 9 );
			  ustack		: std_logic_vector( 0 to 9 );	-- '1' pile data, '0' pile des retours
			  -- lectures en mémoire (mémoire physique jouée) : adresse, taille, valeur attendue
			  nmr		: natural range 0 to 2;
			  mra		: addrs_t;
			  mrn		: addrs_t;
			  mrv		: word_array_t( 0 to 1 );
			  mrp		: std_logic_vector( 0 to 1 );	-- '1' : valeur indéfinie (locale non écrite)
			  wb_lo, wb_n	: natural;			-- LEXCMP : intervalle réécrit en tête
			  wb_state	: natural range 0 to 2;	-- 0 : à réécrire, 1 : réécrit, 2 : vérifié
			  -- après le renommage
			  renamed		: boolean;
			  rob		: rob_index_t;
			  tags		: physical_source_array_t;
			  dtag		: physical_tag_t;
			  ckpt		: checkpoint_id_t;
			  exec_need	: boolean;
			  exec_at		: integer;			-- −1 : pas encore prête
			  done		: boolean;
			  spills_seen	: natural;
			end record;
   type ins_array_t		is array( 0 to WIN - 1 ) of ins_t;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal dec_block		: decoded_block_t;
   signal dec_count		: decode_count_t := ( others => '0' );
   signal dec_take		: decode_count_t;
   signal rob_tail		: rob_index_t := ( others => '0' );
   signal rob_free		: rob_count_t := to_unsigned( ROB_SIZE, ROB_INDEX_BITS + 1 );
   signal alloc_valid		: std_logic;
   signal alloc_block		: rob_alloc_block_t;
   signal alloc_count		: decode_count_t;
   signal ren_valid		: std_logic;
   signal ren_block		: renamed_block_t;
   signal ren_count		: decode_count_t;
   signal ren_ready		: std_logic := '1';
   signal retire_count		: retire_count_t := ( others => '0' );
   signal recovery		: recovery_t := NO_RECOVERY;
   signal sync_valid		: std_logic := '0';
   signal sync_frame		: frame_state_t;
   signal c_frame		: frame_state_t;
   signal limits		: limits_t;
   signal wakeup		: wakeup_bus_t( 0 to RESULT_PORTS - 1 ) := ( others => ( valid => '0', tag => ( others => '0' ) ) );
   signal xfer			: stack_xfer_bus_t;
   signal xfer_ready		: std_logic := '1';
   signal lookup_rsp		: stack_lookup_response_bus_t( 0 to MEMORY_LANES - 1 );
   signal lookup_req		: stack_lookup_request_bus_t( 0 to MEMORY_LANES - 1 ) :=
				  ( others => ( valid => '0', address => ( others => '0' ), rob_index => ( others => '0' ) ) );
   signal invalidate		: stack_invalidate_bus_t( 0 to MEMORY_LANES - 1 ) :=
				  ( others => ( valid => '0', address => ( others => '0' ), rob_index => ( others => '0' ) ) );
   signal maint		: stack_maint_t := ( valid => '0', kind => MAINT_WRITEBACK_ALL, base => ( others => '0' ),
					      length => ( others => '0' ) );
   signal maint_done		: std_logic;
   signal fupd			: frame_update_t := ( valid => '0', rob_index => ( others => '0' ), lvl => ( others => '0' ),
						 value => ( others => '0' ) );
   signal stalled		: std_logic;
   signal free_count		: physical_count_t;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.RENAME_DISPATCH
      generic map ( DEFERRED_SPILL_G => DEFERRED )
      port map (
         CLK_i => clk, RESET_i => reset,
         DECODE_BLOCK_i => dec_block, DECODE_COUNT_i => dec_count, DECODE_TAKE_o => dec_take,
         ROB_TAIL_i => rob_tail, ROB_FREE_i => rob_free,
         ROB_ALLOC_VALID_o => alloc_valid, ROB_ALLOC_BLOCK_o => alloc_block, ROB_ALLOC_COUNT_o => alloc_count,
         RENAME_VALID_o => ren_valid, RENAME_BLOCK_o => ren_block, RENAME_COUNT_o => ren_count, RENAME_READY_i => ren_ready,
         RETIRE_COUNT_i => retire_count, RECOVERY_i => recovery,
         SYNC_VALID_i => sync_valid, SYNC_FRAME_i => sync_frame, COMMITTED_FRAME_o => c_frame,
         DR_i => '0', LIMITS_i => limits, WAKEUP_i => wakeup,
         STACK_XFER_o => xfer, STACK_XFER_READY_i => xfer_ready,
         STACK_LOOKUP_i => lookup_req,
         STACK_LOOKUP_o => lookup_rsp, STACK_INVALIDATE_i => invalidate, WRITERS_IN_FLIGHT_i => '0',
         STACK_MAINT_i => maint, STACK_MAINT_DONE_o => maint_done, FRAME_UPDATE_i => fupd,
         STALLED_o => stalled, FREE_PHYSICAL_COUNT_o => free_count );

   clk <= not clk after PERIOD / 2 when running;

   STIMULI : process
      alias map_err is << signal .T_K1b_RENAME_DISPATCH_tb.DUT.dbg_map_err : natural >>;
      variable map_err_seen	: boolean := false;
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      -- référence séquentielle (spéculative : en avance, sur tout ce qui est généré)
      variable mem		: word_array_t( 0 to SWORDS - 1 );
      variable rmem		: word_array_t( 0 to RWORDS - 1 );
      variable fr		: frame_state_t;				-- après la dernière générée
      variable fr_c		: frame_state_t;				-- après la dernière retirée
      variable shadow_lvl	: integer;

      variable q		: ins_array_t;
      variable gen_seq		: natural := 0;				-- prochaine à générer
      variable take_seq	: natural := 0;				-- prochaine à renommer
      variable head_seq	: natural := 0;				-- la plus ancienne en vol
      variable rob_t		: natural := 0;				-- queue du ROB (index courant)
      variable halted_gen	: boolean := false;

      -- PRF du banc
      variable pv		: word_array_t( 0 to NTAGS - 1 );
      variable pvalid		: std_logic_vector( 0 to NTAGS - 1 ) := ( others => '0' );

      -- LSQ jouée : FILL et invalidations en attente
      type pend_t		is record
			  valid		: boolean;
			  at		: natural;
			  tag		: physical_tag_t;
			  val		: word64_t;
			  seq		: natural;
			  addr		: natural;			-- mot lu
			  completes	: boolean;			-- termine son instruction (DUP, OVER)
			end record;
      type pend_array_t		is array( 0 to 255 ) of pend_t;
      variable fills		: pend_array_t;
      type inv_t		is record
			  valid		: boolean;
			  at		: natural;
			  addr		: address_t;
			  rob		: rob_index_t;
			end record;
      type inv_array_t		is array( 0 to 63 ) of inv_t;
      variable invs		: inv_array_t;

      variable now		: natural := 0;
      variable last_progress	: natural := 0;
      variable x, k, n, sq	: integer;
      variable ok		: boolean;
      variable rec		: recovery_t;
      variable wk		: wakeup_bus_t( 0 to RESULT_PORTS - 1 );
      variable nwk		: natural;
      variable nret		: natural;
      variable keep		: integer;
      variable fu		: frame_update_t;
      variable inv		: stack_invalidate_bus_t( 0 to MEMORY_LANES - 1 );
      variable a		: natural;
      variable d		: natural;					-- recul sous DSP (spéc. V8)
      variable n_src_checked, n_fill, n_spill, n_mis, n_flt, n_unlink_wait, n_inval, n_sync, n_ckpt_rec : natural := 0;
      variable n_served		: natural := 0;				-- chargements servis par la fenêtre
      variable served_i		: boolean;
      variable conv_ld, conv_st	: boolean;
      variable n_conv		: natural := 0;				-- accès directs étroits convertis
      variable n_cconv		: natural := 0;				-- LIQ convertis (cellule pointeur en fenêtre)

      -- mémoire physique de la pile data, écrite seulement par les SPILL et les rangements :
      -- un journal (comme la LSQ) ordonné par clé (2 * n + 2 : les écritures de l'instruction n),
      -- versé dans pm au retrait ; ses lectures voient la clé 2 * n + 1 (avant ses écritures) ;
      -- un SPILL validé (vidage, réécriture) va dans pm aussitôt
      variable pm		: word_array_t( 0 to SWORDS - 1 );
      type log_t		is record
			  valid		: boolean;
			  key		: natural;
			  ord		: natural;
			  seq		: natural;
			  word		: natural;
			  spill		: boolean;
			  tag		: physical_tag_t;
			  captured	: boolean;
			  mask		: std_logic_vector( 7 downto 0 );
			  data		: word64_t;
			end record;
      type log_array_t		is array( 0 to 1023 ) of log_t;
      variable lg		: log_array_t;
      variable lg_ord		: natural := 0;
      variable n_mcheck, n_wb, n_wbcheck, n_def_spill, n_cspill : natural := 0;
      variable sync_pend	: boolean := false;				-- SYNC après la réécriture
      variable pload_next	: boolean := false;				-- un LQ par pointeur suit le LVA
      variable mok		: boolean;
      variable mw		: word64_t;
      variable mreq		: stack_maint_t;
      variable m_asked		: natural := 0;				-- demande du cycle précédent : 1 ALL, 2 RANGE
      variable o		: integer;

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

      function A64( n : natural ) return address_t is
      begin
         return to_unsigned( n, 64 );
      end function;

      function ROB( n : natural ) return rob_index_t is
      begin
         return to_unsigned( n mod ROB_SIZE, ROB_INDEX_BITS );
      end function;

      -- pile data : mot à l'adresse a (hors de la zone suivie : valeur fonction de l'adresse)
      impure function MREAD( a : address_t ) return word64_t is
         variable o : integer;
      begin
         o := ( to_integer( a( 30 downto 3 ) ) * 8 - SLOW ) / 8;
         if a( 63 downto 31 ) = 0 and to_integer( a( 30 downto 0 ) ) >= SLOW and o < SWORDS then return mem( o ); end if;
         return std_logic_vector( a xor x"5A5A5A5A5A5A5A5A" );
      end function;

      impure function RREAD( a : address_t ) return word64_t is
         variable o : integer;
      begin
         o := ( to_integer( a( 30 downto 0 ) ) - ( R0 - 8 * RWORDS ) ) / 8;
         if o >= 0 and o < RWORDS then return rmem( o ); end if;
         return std_logic_vector( a xor x"A5A5A5A5A5A5A5A5" );
      end function;

      -- écritures de la référence, notées pour être défaites
      procedure MWRITE( variable e : inout ins_t; a : address_t; v : word64_t; stack : boolean ) is
         variable o : integer;
      begin
         if stack then
            o := ( to_integer( a( 30 downto 0 ) ) - SLOW ) / 8;
            if a( 63 downto 31 ) = 0 and to_integer( a( 30 downto 0 ) ) >= SLOW and o < SWORDS then
               e.uaddr( e.nundo ) := o; e.uval( e.nundo ) := mem( o ); e.ustack( e.nundo ) := '1';
               e.nundo := e.nundo + 1; mem( o ) := v;
            end if;
         else
            o := ( to_integer( a( 30 downto 0 ) ) - ( R0 - 8 * RWORDS ) ) / 8;
            if o >= 0 and o < RWORDS then
               e.uaddr( e.nundo ) := o; e.uval( e.nundo ) := rmem( o ); e.ustack( e.nundo ) := '0';
               e.nundo := e.nundo + 1; rmem( o ) := v;
            end if;
         end if;
      end procedure;

      -- une cellule lue : sa valeur, retenue pour un FILL éventuel
      procedure READS( variable e : inout ins_t; a : address_t; v : word64_t ) is
      begin
         if e.nread < 5 then e.raddr( e.nread ) := to_integer( a( 30 downto 0 ) ); e.rval( e.nread ) := v; e.nread := e.nread + 1; end if;
      end procedure;

      procedure SRC( variable e : inout ins_t; v : word64_t ) is
      begin
         e.src( e.nsrc ) := v; e.nsrc := e.nsrc + 1;
      end procedure;

      procedure POP( variable e : inout ins_t; f : inout frame_state_t ) is	-- lit et dépile le sommet
         variable v : word64_t;
      begin
         v := MREAD( f.dsp ); READS( e, f.dsp, v ); SRC( e, v ); f.dsp := f.dsp - 8;
      end procedure;

      procedure PUSH( variable e : inout ins_t; f : inout frame_state_t; v : word64_t ) is
      begin
         f.dsp := f.dsp + 8; MWRITE( e, f.dsp, v, true );
         e.paddr( e.npush ) := to_integer( f.dsp( 30 downto 0 ) ); e.npush := e.npush + 1;
      end procedure;

      -- mot de la pile data suivie (−1 : hors de la zone)
      function TIDX( a : natural ) return integer is
      begin
         if a >= SLOW and a < SLOW + 8 * SWORDS then return ( a - SLOW ) / 8; end if;
         return -1;
      end function;

      -- valeur d'une variable locale non écrite (indéfinie) : non comparée
      function POISON( o : natural ) return word64_t is
      begin
         return x"DEAD0000" & std_logic_vector( to_unsigned( o, 32 ) );
      end function;

      -- indéfinie, même en partie (un octet rangé dans une locale non écrite : moitié basse)
      function IS_UNDEF( w : word64_t ) return boolean is
      begin
         return w( 63 downto 32 ) = x"DEAD0000";
      end function;

      -- n octets à partir de a, petit-boutistes : référence (poison : indéfinie)
      procedure REF_BYTES( a : natural; n : natural; v : out word64_t; p : out std_logic ) is
         variable w : std_logic_vector( 127 downto 0 );
         variable x0, x1 : word64_t;
         variable b : natural;
         variable o : integer;
      begin
         b := a - a mod 8; p := '0';
         x1 := MREAD( A64( b + 8 ) ); x0 := MREAD( A64( b ) ); w := x1 & x0;
         for j in 0 to 1 loop
            o := TIDX( b + 8 * j );
            if o >= 0 and ( j = 0 or a mod 8 + n > 8 ) then
               if IS_UNDEF( mem( o ) ) then p := '1'; end if;
            end if;
         end loop;
         w := std_logic_vector( shift_right( unsigned( w ), 8 * ( a mod 8 ) ) );
         v := ( others => '0' );
         v( 8 * n - 1 downto 0 ) := w( 8 * n - 1 downto 0 );
      end procedure;

      procedure LOG_ADD( key, seq, word : natural; spill : boolean; tag : physical_tag_t;
                         mask : std_logic_vector( 7 downto 0 ); data : word64_t ) is
      begin
         for j in lg'range loop
            if not lg( j ).valid then
               lg( j ) := ( valid => true, key => key, ord => lg_ord, seq => seq, word => word, spill => spill, tag => tag,
                            captured => not spill, mask => mask, data => data );
               lg_ord := lg_ord + 1;
               return;
            end if;
         end loop;
         CHECK( c, false, "journal de la mémoire physique plein" );
      end procedure;

      -- le mot o tel qu'une lecture de clé key le voit (pm, puis le journal dans l'ordre) ;
      -- ok = false : un SPILL dont la donnée n'est pas encore là
      procedure MODEL_WORD( o : natural; key : natural; ok : inout boolean; v : out word64_t ) is
         type idx_t is array( 0 to 31 ) of integer;
         variable ix	: idx_t;
         variable n, best : integer;
         variable w	: word64_t;
      begin
         w := pm( o ); n := 0;
         for j in lg'range loop
            if lg( j ).valid and lg( j ).word = o and lg( j ).key <= key and n < 32 then ix( n ) := j; n := n + 1; end if;
         end loop;
         for t in 0 to 31 loop							-- par clé, puis par ordre d'entrée
            exit when t >= n;
            best := -1;
            for u in 0 to 31 loop
               if u < n and ix( u ) >= 0 then
                  if best < 0 or lg( ix( u ) ).key < lg( ix( best ) ).key
                     or ( lg( ix( u ) ).key = lg( ix( best ) ).key and lg( ix( u ) ).ord < lg( ix( best ) ).ord ) then
                     best := u;
                  end if;
               end if;
            end loop;
            if not lg( ix( best ) ).captured then ok := false; end if;
            for bb in 0 to 7 loop
               if lg( ix( best ) ).mask( bb ) = '1' then w( 8 * bb + 7 downto 8 * bb ) := lg( ix( best ) ).data( 8 * bb + 7 downto 8 * bb ); end if;
            end loop;
            ix( best ) := -1;
         end loop;
         v := w;
      end procedure;

      -- n octets à partir de a vus par la mémoire physique (clé key)
      procedure MODEL_BYTES( a, n, key : natural; ok : inout boolean; v : out word64_t ) is
         variable w : std_logic_vector( 127 downto 0 );
         variable x0, x1 : word64_t;
         variable b : natural;
      begin
         b := a - a mod 8;
         x0 := MREAD( A64( b ) ); x1 := MREAD( A64( b + 8 ) );			-- (hors de la zone : la référence)
         if TIDX( b ) >= 0 then MODEL_WORD( TIDX( b ), key, ok, x0 ); end if;
         if a mod 8 + n > 8 and TIDX( b + 8 ) >= 0 then MODEL_WORD( TIDX( b + 8 ), key, ok, x1 ); end if;
         w := x1 & x0;
         w := std_logic_vector( shift_right( unsigned( w ), 8 * ( a mod 8 ) ) );
         v := ( others => '0' );
         v( 8 * n - 1 downto 0 ) := w( 8 * n - 1 downto 0 );
      end procedure;

      -- retrait de l'instruction sq : ses écritures vont dans pm (dans l'ordre des clés)
      procedure LOG_COMMIT( sq : natural ) is
         variable best : integer;
         variable w : word64_t;
      begin
         loop
            best := -1;
            for j in lg'range loop
               if lg( j ).valid and lg( j ).seq = sq then
                  if best < 0 or lg( j ).key < lg( best ).key or ( lg( j ).key = lg( best ).key and lg( j ).ord < lg( best ).ord ) then
                     best := j;
                  end if;
               end if;
            end loop;
            exit when best < 0;
            if lg( best ).spill and not lg( best ).captured and pvalid( to_integer( lg( best ).tag ) ) = '1' then
               lg( best ).data := pv( to_integer( lg( best ).tag ) ); lg( best ).captured := true;
            end if;
            if not lg( best ).captured then
               CHECK( c, false, "instruction " & integer'image( sq ) & " retirée avant la donnée de son SPILL" );
            end if;
            w := pm( lg( best ).word );
            for bb in 0 to 7 loop
               if lg( best ).mask( bb ) = '1' then w( 8 * bb + 7 downto 8 * bb ) := lg( best ).data( 8 * bb + 7 downto 8 * bb ); end if;
            end loop;
            pm( lg( best ).word ) := w;
            lg( best ).valid := false;
         end loop;
      end procedure;

      -- la référence à l'état retiré (avant l'instruction head_seq) : on défait les écritures
      -- des instructions en vol
      impure function REF_AT_HEAD( o : natural ) return word64_t is
         variable v : word64_t;
      begin
         v := mem( o );
         for sq2 in gen_seq - 1 downto head_seq loop
            for j in 9 downto 0 loop
               if j < q( sq2 mod WIN ).nundo and q( sq2 mod WIN ).ustack( j ) = '1' and q( sq2 mod WIN ).uaddr( j ) = o then
                  v := q( sq2 mod WIN ).uval( j );
               end if;
            end loop;
         end loop;
         return v;
      end function;

      ----------------------------------------------------------------------------
      -- Génération d'une instruction : son issue séquentielle
      ----------------------------------------------------------------------------
      procedure GENERATE_ONE is
         variable e	: ins_t;
         variable f	: frame_state_t;
         variable u	: real := RAND;
         variable lvl	: natural;
         variable v, w	: word64_t;
         variable op	: opcode_t;
         variable len	: natural;
         variable alloc	: natural;
         variable depth	: natural;
         variable lv	: integer;
      begin
         e.kind := K_LIN; e.nsrc := 0; e.nread := 0; e.npush := 0; e.dest := false; e.dval := RAND_WORD;
         e.addr_known := false; e.addr := ( others => '0' ); e.fault := 0; e.control := false; e.mispredict := false;
         e.is_store := false; e.ptr_ea := -1; e.nundo := 0; e.renamed := false; e.done := false; e.exec_at := -1;
         e.spills_seen := 0; e.exec_need := true;
         e.nmr := 0; e.mra := ( others => 0 ); e.mrn := ( others => 0 ); e.mrv := ( others => ( others => '0' ) );
         e.mrp := "00"; e.wb_lo := 0; e.wb_n := 0; e.wb_state := 2;
         e.frame_before := fr; f := fr;
         lvl := RAND_INT( 14 ); len := 1;
         op := x"00";
         depth := 0;								-- profondeur au-dessus de DSP0
         if fr.dsp >= A64( S0 ) and fr.dsp < A64( S0 + 2 ** 20 ) then depth := to_integer( fr.dsp - A64( S0 ) ) / 8; end if;
         if pload_next then e.kind := K_PLOAD; op := x"57"; len := 3;		-- LQ par pointeur, après un LVA
         elsif u < 0.10 then e.kind := K_LI; op := x"C0";
         elsif u < 0.13 then e.kind := K_LVA; op := x"47"; len := 3;
         elsif u < 0.16 then e.kind := K_CLOAD; op := x"97"; len := 4;		-- LIQ : cellule pointeur directe
         elsif u < 0.30 then e.kind := K_LIN; op := x"00";			-- ( a b -- r )
         elsif u < 0.34 then e.kind := K_LIN; op := x"03";			-- ( a -- r )
         elsif u < 0.36 then e.kind := K_LIN; op := x"18";			-- ( a b c -- r )
         elsif u < 0.40 then e.kind := K_DROP; op := x"30";
         elsif u < 0.45 then e.kind := K_DUP; op := x"31";
         elsif u < 0.49 then e.kind := K_OVER; op := x"32";
         elsif u < 0.55 then e.kind := K_LOAD; op := x"57"; len := 3;		-- LQ ; parfois LB, LW, LD
            if RAND < 0.3 then op := std_logic_vector( to_unsigned( 16#54# + RAND_INT( 2 ), 8 ) ); end if;
         elsif u < 0.60 then e.kind := K_STORE; op := x"67"; len := 3;
         elsif u < 0.62 then e.kind := K_STORE; op := x"64"; len := 3;		-- partiel (1 octet)
         elsif u < 0.66 then e.kind := K_PSTORE; op := x"67"; len := 1;		-- par pointeur
         elsif u < 0.68 then e.kind := K_CHK; op := x"5F"; len := 4;
         elsif u < 0.69 then e.kind := K_LEX; op := x"C8";
         elsif u < 0.73 then e.kind := K_CALL; op := x"F2"; len := 4;
         elsif u < 0.75 then e.kind := K_CALLI; op := x"33";
         elsif u < 0.80 then e.kind := K_RTD; op := x"F6"; len := 4;
         elsif u < 0.84 then e.kind := K_BT; op := x"E4"; len := 2;
         elsif u < 0.86 then e.kind := K_BRA; op := x"E0"; len := 2;
         elsif u < 0.91 then e.kind := K_LINK; op := x"44"; len := 3;
         elsif u < 0.96 then e.kind := K_UNLINK; op := x"F8"; len := 2;
         elsif u < 0.975 then e.kind := K_EXCM; op := x"45"; len := 3;
         elsif u < 0.99 then e.kind := K_TRAP16; op := OP_TRAP; len := 2;
         else e.kind := K_ILLEGAL; op := UOP_ILLEGAL; len := 0;
         end if;
         pload_next := false;
         if ( e.kind = K_LVA or e.kind = K_CLOAD ) then				-- un DISPLAY qui soit une adresse
            lv := -1;
            for j in 0 to 14 loop
               if lv < 0 and fr.display( ( lvl + j ) mod 15 )( 63 downto 31 ) = 0 then lv := ( lvl + j ) mod 15; end if;
            end loop;
            if lv < 0 or fr.dsp < A64( SLOW + 8 * 16 ) then e.kind := K_LI; op := x"C0"; len := 1; else lvl := lv; end if;
         end if;
         -- les UNLINK suivent les LINK (niveau de la pile d'ombre du banc) ; RTD les CALL
         if e.kind = K_UNLINK and shadow_lvl < 1 then e.kind := K_LI; op := x"C0"; len := 1; end if;
         -- spéc. V8 : UNLINK ne fait pas remonter DSP (DISPLAY[lvl] <= DSP)
         if e.kind = K_UNLINK and shadow_lvl >= 1 then
            if fr.dsp < fr.display( shadow_lvl ) then e.kind := K_LI; op := x"C0"; len := 1; end if;
         end if;
         if e.kind = K_RTD and f.rsp >= A64( R0 ) then e.kind := K_CALL; op := x"F2"; len := 4; end if;
         if fr.dsp < A64( S0 - 8 * 300 ) and ( e.kind = K_DROP or e.kind = K_LIN or e.kind = K_STORE or e.kind = K_PSTORE
                                             or e.kind = K_BT or e.kind = K_LEX or e.kind = K_CALLI or e.kind = K_RTD ) then
            e.kind := K_LI; op := x"C0"; len := 1;				-- la pile reste dans la zone suivie
         end if;

         e.slot := ( valid => '1', canon => CANON_NOP, pc => to_unsigned( 16#400000# + 16 * gen_seq, 64 ), pred => NO_PREDICTION );
         e.slot.canon.op := op; e.slot.canon.len := to_unsigned( len, 4 );
         e.slot.canon.lvl := to_unsigned( lvl, 4 );

         case e.kind is
            when K_LI =>
               e.slot.canon.val := to_signed( RAND_INT( 16#FFFFF# ), 32 );
               e.dest := true; PUSH( e, f, e.dval );
            when K_LIN =>
               if op = x"00" then POP( e, f ); POP( e, f );
               elsif op = x"03" then POP( e, f );
               else POP( e, f ); POP( e, f ); POP( e, f ); end if;
               -- sources du plus profond au sommet
               if e.nsrc = 2 then v := e.src( 0 ); e.src( 0 ) := e.src( 1 ); e.src( 1 ) := v;
               elsif e.nsrc = 3 then v := e.src( 0 ); e.src( 0 ) := e.src( 2 ); e.src( 2 ) := v; end if;
               e.dest := true; PUSH( e, f, e.dval );
            when K_DROP =>
               f.dsp := f.dsp - 8; e.exec_need := false;
            when K_DUP =>
               v := MREAD( f.dsp ); READS( e, f.dsp, v ); PUSH( e, f, v ); e.exec_need := false;
            when K_OVER =>
               v := MREAD( f.dsp - 8 ); READS( e, f.dsp - 8, v ); PUSH( e, f, v ); e.exec_need := false;
            when K_LOAD =>								-- lvl 0..14 : adresse connue
               e.slot.canon.val := to_signed( 8 * ( RAND_INT( 64 ) - 32 ), 32 );
               e.addr_known := true; e.addr := f.display( lvl ) + unsigned( resize( e.slot.canon.val, 64 ) );
               -- spéc. V8 : aucun accès au-dessus de DSP (dans la pile suivie)
               if e.addr >= A64( SLOW ) and e.addr < A64( SLOW + 8 * SWORDS ) and e.addr > f.dsp then
                  d := to_integer( e.addr - f.dsp ); d := 8 * ( ( d + 7 ) / 8 );
                  e.addr := e.addr - to_unsigned( d, 64 ); e.slot.canon.val := e.slot.canon.val - to_signed( d, 32 );
               end if;
               -- LB, LW, LD : un décalage dans la cellule, multiple de la taille
               if ( op = x"54" or op = x"55" or op = x"56" ) and e.addr( 2 downto 0 ) = "000" then
                  a := 2 ** ( to_integer( unsigned( op( 1 downto 0 ) ) ) );		-- taille
                  a := a * RAND_INT( 8 / a - 1 );					-- décalage
                  e.addr := e.addr + to_unsigned( a, 64 ); e.slot.canon.val := e.slot.canon.val + to_signed( a, 32 );
               end if;
               e.conv_old := MREAD( e.addr( 63 downto 3 ) & "000" ); e.conv_cell := to_integer( e.addr( 30 downto 3 ) & "000" );
               e.nmr := 1; e.mra( 0 ) := to_integer( e.addr( 30 downto 0 ) );
               e.mrn( 0 ) := 2 ** to_integer( unsigned( op( 1 downto 0 ) ) );
               REF_BYTES( e.mra( 0 ), e.mrn( 0 ), e.mrv( 0 ), e.mrp( 0 ) );
               e.dval := MREAD( e.addr( 63 downto 3 ) & "000" );			-- la valeur de la mémoire (servi
               a := 8 * to_integer( e.addr( 2 downto 0 ) );
               if a + 8 * 2 ** to_integer( unsigned( op( 1 downto 0 ) ) ) > 64 then	-- (base non alignée : à cheval)
                  e.dval := MREAD( e.addr ); a := 0;
               end if;
               case op is
                  when x"54" => e.dval := std_logic_vector( resize( signed( e.dval( a + 7 downto a ) ), 64 ) );
                  when x"55" => e.dval := std_logic_vector( resize( signed( e.dval( a + 15 downto a ) ), 64 ) );
                  when x"56" => e.dval := std_logic_vector( resize( signed( e.dval( a + 31 downto a ) ), 64 ) );
                  when others => null;
               end case;
               e.dest := true; PUSH( e, f, e.dval );					--  par la fenêtre, ou exécuté)
            when K_STORE =>								-- lvl 0..14
               e.slot.canon.val := to_signed( 8 * ( RAND_INT( 64 ) - 48 ), 32 );
               if RAND < 0.5 then e.slot.canon.val := to_signed( 8 * ( RAND_INT( 8 ) - 8 ), 32 ); lvl := 0;
                  e.slot.canon.lvl := "0000"; end if;
               e.addr_known := true; e.addr := f.display( lvl ) + unsigned( resize( e.slot.canon.val, 64 ) );
               -- spéc. V8 : aucun accès au-dessus de DSP (dans la pile suivie)
               if e.addr >= A64( SLOW ) and e.addr < A64( SLOW + 8 * SWORDS ) and e.addr > f.dsp then
                  d := to_integer( e.addr - f.dsp ); d := 8 * ( ( d + 7 ) / 8 );
                  e.addr := e.addr - to_unsigned( d, 64 ); e.slot.canon.val := e.slot.canon.val - to_signed( d, 32 );
               end if;
               if op = x"64" and RAND < 0.5 then e.addr := e.addr + 3; e.slot.canon.val := e.slot.canon.val + 3; end if;
               e.is_store := true;
               POP( e, f );
               if op = x"67" then MWRITE( e, e.addr, e.src( 0 ), true );
               else								-- un octet
                  w := MREAD( e.addr( 63 downto 3 ) & "000" );
                  e.conv_old := w; e.conv_cell := to_integer( e.addr( 30 downto 3 ) & "000" );
                  a := to_integer( e.addr( 2 downto 0 ) );
                  w( 8 * a + 7 downto 8 * a ) := e.src( 0 )( 7 downto 0 );
                  e.conv_new := w;
                  MWRITE( e, e.addr( 63 downto 3 ) & "000", w, true );
               end if;
               e.exec_need := true;
            when K_PSTORE =>								-- ( @ v -- ), lvl 1111 : adresse prise sur la pile
               e.slot.canon.lvl := "1111"; e.is_store := true;
               POP( e, f ); POP( e, f );
               v := e.src( 0 ); e.src( 0 ) := e.src( 1 ); e.src( 1 ) := v;	-- @ le plus profond
               -- la LSQ jouée choisit l'adresse : hors de la pile data (spéc. V8 : aucun accès
               -- calculé n'écrit une cellule de calcul, aucun accès au-dessus de DSP)
               a := SLOW + 8 * SWORDS + 8 * RAND_INT( 63 );
               e.ptr_ea := a;
               MWRITE( e, A64( a ), e.src( 1 ), true );
            when K_CHK =>								-- ( v -- v ), lvl 0..14
               e.slot.canon.val := to_signed( 8 * RAND_INT( 16 ), 32 );
               e.addr_known := true; e.addr := f.display( lvl ) + unsigned( resize( e.slot.canon.val, 64 ) );
               -- spéc. V8 : les deux bornes au plus à DSP (dans la pile suivie)
               if e.addr >= A64( SLOW ) and e.addr < A64( SLOW + 8 * SWORDS ) and e.addr + 8 > f.dsp then
                  d := to_integer( e.addr + 8 - f.dsp ); d := 8 * ( ( d + 7 ) / 8 );
                  e.addr := e.addr - to_unsigned( d, 64 ); e.slot.canon.val := e.slot.canon.val - to_signed( d, 32 );
               end if;
               e.nmr := 2;
               for j in 0 to 1 loop
                  e.mra( j ) := to_integer( e.addr( 30 downto 0 ) ) + 8 * j; e.mrn( j ) := 8;
                  REF_BYTES( e.mra( j ), 8, e.mrv( j ), e.mrp( j ) );
               end loop;
               v := MREAD( f.dsp ); READS( e, f.dsp, v ); SRC( e, v );
            when K_LEX =>								-- ( a b c d -- r )
               POP( e, f ); POP( e, f ); POP( e, f ); POP( e, f );
               -- en tête : MAINT_WRITEBACK_RANGE d'un intervalle sous DSP, puis lu en mémoire
               e.wb_n := 8 * ( 1 + RAND_INT( 7 ) ) - RAND_INT( 3 ); e.wb_lo := to_integer( f.dsp( 30 downto 0 ) ) - 8 * RAND_INT( 20 );
               if e.wb_lo < SLOW then e.wb_lo := SLOW; end if;
               e.wb_state := 0;
               v := e.src( 0 ); e.src( 0 ) := e.src( 3 ); e.src( 3 ) := v;
               v := e.src( 1 ); e.src( 1 ) := e.src( 2 ); e.src( 2 ) := v;
               e.dest := true; PUSH( e, f, e.dval );
            when K_CALL | K_CALLI =>
               if e.kind = K_CALLI then POP( e, f ); end if;
               e.slot.canon.val := to_signed( 64, 32 );
               e.dest := true; e.dval := std_logic_vector( e.slot.pc + len );	-- adresse de retour
               f.rsp := f.rsp - 8; MWRITE( e, f.rsp, e.dval, false );
               e.paddr( e.npush ) := to_integer( f.rsp( 30 downto 0 ) ); e.npush := e.npush + 1;
               e.control := true; e.mispredict := RAND < 0.03;
            when K_RTD =>
               e.slot.canon.val := to_signed( 8 * RAND_INT( 2 ), 32 );
               f.dsp := f.dsp - unsigned( resize( e.slot.canon.val, 64 ) );
               v := RREAD( f.rsp ); READS( e, f.rsp, v ); SRC( e, v );
               f.rsp := f.rsp + 8;
               e.control := true; e.mispredict := RAND < 0.03;
            when K_BT =>
               POP( e, f ); e.control := true; e.mispredict := RAND < 0.08;
            when K_BRA =>
               e.control := true; e.mispredict := RAND < 0.02;
            when K_LINK =>								-- lvl 1..14, alloc
               if lvl = 0 then lvl := 1; e.slot.canon.lvl := "0001"; end if;
               alloc := 8 * RAND_INT( 6 ) + RAND_INT( 7 );
               if RAND < 0.01 then alloc := 30000; end if;			-- faute 133
               e.slot.canon.val := to_signed( alloc, 32 );
               e.addr_known := true; e.addr := f.display( lvl );		-- ancien DISPLAY[lvl]
               e.dest := true; e.dval := std_logic_vector( f.display( lvl ) );
               PUSH( e, f, e.dval );
               f.display( lvl ) := f.dsp;
               if alloc <= 8 * 8 then						-- locales : indéfinies
                  for j in 1 to 8 loop
                     if j <= ( alloc + 7 ) / 8 and TIDX( to_integer( f.dsp( 30 downto 0 ) ) + 8 * j ) >= 0 then
                        MWRITE( e, f.dsp + 8 * j, POISON( TIDX( to_integer( f.dsp( 30 downto 0 ) ) + 8 * j ) ), true );
                     end if;
                  end loop;
               end if;
               f.dsp := f.dsp + 8 * ( ( alloc + 7 ) / 8 );
            when K_UNLINK =>								-- le niveau du dernier LINK du banc
               lvl := shadow_lvl; e.slot.canon.lvl := to_unsigned( lvl, 4 );
               f.dsp := f.display( lvl );
               v := MREAD( f.dsp ); READS( e, f.dsp, v ); SRC( e, v ); f.dsp := f.dsp - 8;
               f.display( lvl ) := unsigned( v );
               e.dest := true; e.dval := RAND_WORD;				-- registre caché (M64[CFP]), sans cellule
            when K_EXCM =>
               e.slot.canon.val := to_signed( 8 * RAND_INT( 8 ), 32 );
               e.addr_known := true; e.addr := f.display( lvl ) + unsigned( resize( e.slot.canon.val, 64 ) );
            when K_TRAP16 =>
               e.slot.canon.val := to_signed( 16, 32 );
               e.control := true;							-- contrôle dans la table (TRAP vectorisé)
               POP( e, f ); e.dest := true; PUSH( e, f, e.dval );
            when K_ILLEGAL =>
               e.fault := 137;
            when K_LVA =>								-- ( -- @ ), lvl 0..14 : une cellule récente
               a := to_integer( f.dsp( 30 downto 0 ) ) - 8 * RAND_INT( 12 );
               e.slot.canon.val := to_signed( a - to_integer( f.display( lvl )( 30 downto 0 ) ), 32 );
               e.addr_known := true; e.addr := A64( a );
               e.dest := true; e.dval := std_logic_vector( A64( a ) ); PUSH( e, f, e.dval );
               pload_next := RAND < 0.7;
            when K_PLOAD =>								-- ( @ -- v ), lvl 1111 : @ du LVA qui précède
               e.slot.canon.lvl := "1111";
               POP( e, f ); a := to_integer( unsigned( e.src( 0 )( 30 downto 0 ) ) );
               e.nmr := 1; e.mra( 0 ) := a; e.mrn( 0 ) := 8; REF_BYTES( a, 8, e.mrv( 0 ), e.mrp( 0 ) );
               e.dest := true; e.dval := e.mrv( 0 ); PUSH( e, f, e.dval );
            when K_CLOAD =>								-- ( -- v ) : M64[ M64[DISPLAY[lvl]+disp] + ofs ]
               a := to_integer( f.dsp( 30 downto 0 ) ) - 8 * RAND_INT( 12 );	-- cellule pointeur, sous DSP
               e.slot.canon.val := to_signed( a - to_integer( f.display( lvl )( 30 downto 0 ) ), 32 );
               e.addr_known := true; e.addr := A64( a );
               e.nmr := 1; e.mra( 0 ) := a; e.mrn( 0 ) := 8; REF_BYTES( a, 8, e.mrv( 0 ), e.mrp( 0 ) );
               e.dest := true; PUSH( e, f, e.dval );					-- (l'élément : hors de la pile)
         end case;
         -- fautes 133, 134 : aucun effet
         if e.fault = 0 and f.dsp > A64( LIM_DSP ) and f.dsp > fr.dsp then e.fault := 133; end if;
         if e.fault = 0 and f.rsp < A64( LIM_RSP ) and f.rsp < fr.rsp then e.fault := 134; end if;
         if e.fault /= 0 then
            for j in e.nundo - 1 downto 0 loop					-- défaire les écritures
               if e.ustack( j ) = '1' then mem( e.uaddr( j ) ) := e.uval( j ); else rmem( e.uaddr( j ) ) := e.uval( j ); end if;
            end loop;
            e.nundo := 0; e.nsrc := 0; e.nread := 0; e.npush := 0; e.dest := false; e.addr_known := false;
            e.control := false; e.mispredict := false; e.exec_need := false;
            e.nmr := 0; e.wb_state := 2; pload_next := false;
            f := fr;
         else
            if e.kind = K_LINK then shadow_lvl := lvl; end if;
            if e.kind = K_UNLINK then shadow_lvl := 0; end if;		-- un seul niveau suivi
         end if;
         e.frame_after := f; fr := f;
         q( gen_seq mod WIN ) := e;
         gen_seq := gen_seq + 1;
      end procedure;

      -- reprise : la référence revient à l'état après l'instruction keep (−1 : retirée)
      procedure REWIND( from : natural ) is
      begin
         for sq2 in gen_seq - 1 downto from loop
            x := sq2 mod WIN;
            for j in q( x ).nundo - 1 downto 0 loop
               if q( x ).ustack( j ) = '1' then mem( q( x ).uaddr( j ) ) := q( x ).uval( j );
               else rmem( q( x ).uaddr( j ) ) := q( x ).uval( j ); end if;
            end loop;
         end loop;
         if from > 0 then fr := q( ( from - 1 ) mod WIN ).frame_after; end if;
         if from = head_seq then fr := fr_c; end if;
         gen_seq := from; take_seq := from;
         shadow_lvl := -1;							-- (pas d'UNLINK avant un nouveau LINK)
         pload_next := false;
      end procedure;

   begin
      s2 := SEED_2;
      for i in mem'range loop mem( i ) := std_logic_vector( to_unsigned( SLOW + 8 * i, 64 ) xor x"0123456789ABCDEF" ); end loop;
      pm := mem;
      for j in lg'range loop lg( j ).valid := false; end loop;
      for i in rmem'range loop rmem( i ) := std_logic_vector( to_unsigned( 16#600000# + 4 * i, 64 ) ); end loop;
      fr.dsp := A64( S0 ); fr.rsp := A64( R0 );
      for l in 0 to 14 loop fr.display( l ) := A64( S0 - 8 * 64 * l ); end loop;
      fr_c := fr; shadow_lvl := -1;
      limits <= ( lim_dsp => A64( LIM_DSP ), lim_rsp => A64( LIM_RSP ), lim_csp => ( others => '1' ), lim_hp => ( others => '0' ) );
      for i in fills'range loop fills( i ).valid := false; end loop;
      for i in invs'range loop invs( i ).valid := false; end loop;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';
      -- état de départ : SYNC
      sync_frame <= fr; sync_valid <= '1';
      recovery <= ( valid => '1', kind => RECOVER_COMMITTED, keep_last => ( others => '0' ), checkpoint => ( others => '0' ),
                    new_pc => ( others => '0' ), ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );
      wait until falling_edge( clk );
      sync_valid <= '0'; recovery <= NO_RECOVERY;

      loop
         now := now + 1;
         exit when take_seq >= INSTRUCTIONS and head_seq = take_seq;
         if map_err /= 0 and not map_err_seen then				-- comptes de correspondances
            map_err_seen := true;
            CHECK( c, false, "cycle " & integer'image( now ) & " : " & integer'image( map_err )
                             & " registre(s) au compte de correspondances incohérent" );
         end if;
         if now - last_progress > 3000 then
            CHECK( c, false, "cycle " & integer'image( now ) & " : aucun progrès (tête " & integer'image( head_seq )
                             & ", prise " & integer'image( take_seq ) & ", bloqué " & std_logic'image( stalled ) & ") ; tête "
                             & kind_t'image( q( head_seq mod WIN ).kind ) & " renommée " & boolean'image( q( head_seq mod WIN ).renamed )
                             & " terminée " & boolean'image( q( head_seq mod WIN ).done ) & " exec_at "
                             & integer'image( q( head_seq mod WIN ).exec_at ) & " wb " & integer'image( q( head_seq mod WIN ).wb_state )
                             & " nmr " & integer'image( q( head_seq mod WIN ).nmr ) & " sync_pend " & boolean'image( sync_pend ) );
            exit;
         end if;

		-- LSQ jouée : la donnée d'un SPILL est prise dès que son registre est écrit
         for j in lg'range loop
            if lg( j ).valid and lg( j ).spill and not lg( j ).captured and pvalid( to_integer( lg( j ).tag ) ) = '1' then
               lg( j ).data := pv( to_integer( lg( j ).tag ) ); lg( j ).captured := true;
            end if;
         end loop;

		-- génération en avance ; file de décodage
         while gen_seq < take_seq + 16 and gen_seq < INSTRUCTIONS loop GENERATE_ONE; end loop;
         n := minimum( gen_seq - take_seq, 1 + RAND_INT( DECODE_WIDTH - 1 ) );
         for i in 0 to DECODE_WIDTH - 1 loop
            if i < n then dec_block( i ) <= q( ( take_seq + i ) mod WIN ).slot;
            else dec_block( i ) <= ( valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION ); end if;
         end loop;
         dec_count <= to_unsigned( n, dec_count'length );
         rob_tail <= ROB( rob_t );
         rob_free <= to_unsigned( ROB_SIZE - ( take_seq - head_seq ), rob_free'length );
         ren_ready <= B( RAND < 0.85 ); xfer_ready <= B( RAND < 0.9 );

		-- unités : exécution des instructions prêtes, écriture de la destination, réveil
         wk := ( others => ( valid => '0', tag => ( others => '0' ) ) ); nwk := 0;
         fu := ( valid => '0', rob_index => ( others => '0' ), lvl => ( others => '0' ), value => ( others => '0' ) );
         rec := NO_RECOVERY; keep := -1;
         for sq2 in head_seq to take_seq - 1 loop
            x := sq2 mod WIN;
            if q( x ).renamed and not q( x ).done and q( x ).exec_need then
               if q( x ).exec_at < 0 then
                  ok := true;
                  for j in 0 to 3 loop
                     if j < q( x ).nsrc and pvalid( to_integer( q( x ).tags( j ) ) ) = '0' then ok := false; end if;
                  end loop;
                  if ok then q( x ).exec_at := now + RAND_INT( 3 ); end if;
               elsif q( x ).exec_at <= now and nwk < RESULT_PORTS and rec.valid = '0'
                     and ( q( x ).wb_state = 2 or q( x ).kind /= K_LEX ) then
                  -- lectures en mémoire (chargement exécuté, bornes de CHK, cellule pointeur) : la
                  -- mémoire physique au point de l'instruction (attente si un SPILL n'a pas sa donnée)
                  mok := true;
                  for j in 0 to 1 loop
                     if j < q( x ).nmr then MODEL_BYTES( q( x ).mra( j ), q( x ).mrn( j ), 2 * sq2 + 1, mok, mw ); end if;
                  end loop;
                  next when not mok;
                  for j in 0 to 1 loop
                     if j < q( x ).nmr and q( x ).mrp( j ) = '0' then
                        MODEL_BYTES( q( x ).mra( j ), q( x ).mrn( j ), 2 * sq2 + 1, mok, mw );
                        if mw = q( x ).mrv( j ) then CHECK_PASSED( c ); n_mcheck := n_mcheck + 1; else
                           CHECK( c, false, "cycle " & integer'image( now ) & ", instruction " & integer'image( sq2 ) & " ("
                                            & kind_t'image( q( x ).kind ) & ") : mémoire lue à " & HEX( A64( q( x ).mra( j ) ) ),
                                  HEX( q( x ).mrv( j ) ), HEX( mw ) );
                        end if;
                     end if;
                  end loop;
                  for j in 0 to 3 loop							-- les sources lues
                     if j < q( x ).nsrc then
                        if pv( to_integer( q( x ).tags( j ) ) ) = q( x ).src( j ) and pvalid( to_integer( q( x ).tags( j ) ) ) = '1' then
                           CHECK_PASSED( c ); n_src_checked := n_src_checked + 1;
                        else
                           CHECK( c, false, "cycle " & integer'image( now ) & ", instruction " & integer'image( sq2 ) & " ("
                                            & kind_t'image( q( x ).kind ) & "), source " & integer'image( j ),
                                  HEX( q( x ).src( j ) ), HEX( pv( to_integer( q( x ).tags( j ) ) ) ) );
                        end if;
                     end if;
                  end loop;
                  if q( x ).dest then
                     pv( to_integer( q( x ).dtag ) ) := q( x ).dval; pvalid( to_integer( q( x ).dtag ) ) := '1';
                     wk( nwk ) := ( valid => '1', tag => q( x ).dtag ); nwk := nwk + 1;
                  end if;
                  if q( x ).kind = K_UNLINK then
                     fu := ( valid => '1', rob_index => q( x ).rob, lvl => q( x ).slot.canon.lvl, value => unsigned( q( x ).src( 0 ) ) );
                  end if;
                  q( x ).done := true; last_progress := now;
                  if q( x ).mispredict then						-- mauvaise prédiction : reprise
                     rec := ( valid => '1', kind => RECOVER_CHECKPOINT, keep_last => q( x ).rob, checkpoint => q( x ).ckpt,
                              new_pc => ( others => '0' ), ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );
                     keep := sq2;
                  end if;
               end if;
            end if;
         end loop;
		-- LSQ jouée : FILL servis, invalidations
         for i in fills'range loop
            mok := true; mw := fills( i ).val;
            if fills( i ).valid and fills( i ).at <= now and TIDX( fills( i ).addr ) >= 0 then
               MODEL_WORD( TIDX( fills( i ).addr ), 2 * fills( i ).seq + 1, mok, mw );	-- (avant ses écritures)
               if IS_UNDEF( fills( i ).val ) then mw := fills( i ).val;			-- locale non écrite
               elsif mok then
                  if mw = fills( i ).val then CHECK_PASSED( c ); n_mcheck := n_mcheck + 1; else
                     CHECK( c, false, "cycle " & integer'image( now ) & " : FILL de l'instruction " & integer'image( fills( i ).seq )
                                      & " à " & HEX( A64( fills( i ).addr ) ) & " (mémoire physique)",
                            HEX( fills( i ).val ), HEX( mw ) );
                  end if;
               end if;
            end if;
            if fills( i ).valid and fills( i ).at <= now and nwk < RESULT_PORTS and mok then
               pv( to_integer( fills( i ).tag ) ) := mw; pvalid( to_integer( fills( i ).tag ) ) := '1';
               wk( nwk ) := ( valid => '1', tag => fills( i ).tag ); nwk := nwk + 1;
               fills( i ).valid := false;
               if fills( i ).completes then q( fills( i ).seq mod WIN ).done := true; last_progress := now; end if;
            end if;
         end loop;
         inv := ( others => ( valid => '0', address => ( others => '0' ), rob_index => ( others => '0' ) ) );
         for i in invs'range loop
            if invs( i ).valid and invs( i ).at <= now then
               inv( 0 ) := ( valid => '1', address => invs( i ).addr, rob_index => invs( i ).rob );
               invs( i ).valid := false; n_inval := n_inval + 1;
               exit;
            end if;
         end loop;
         wakeup <= wk; fupd <= fu; invalidate <= inv;

		-- ROB : retrait dans l'ordre ; faute en tête : reprise RECOVER_COMMITTED
         nret := 0;
         mreq := ( valid => '0', kind => MAINT_WRITEBACK_ALL, base => ( others => '0' ), length => ( others => '0' ) );
         if rec.valid = '0' and not sync_pend then
            for i in 0 to RETIRE_WIDTH - 1 loop
               sq := head_seq + i;
               exit when sq >= take_seq;
               x := sq mod WIN;
               if q( x ).fault /= 0 then
                  if i = 0 then
                     rec := ( valid => '1', kind => RECOVER_COMMITTED, keep_last => ( others => '0' ), checkpoint => ( others => '0' ),
                              new_pc => ( others => '0' ), ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );
                     n_flt := n_flt + 1;
                  end if;
                  exit;
               end if;
               exit when not q( x ).done or RAND < 0.1;
               nret := i + 1;
            end loop;
            if rec.valid = '0' and nret = 0 and head_seq < take_seq and RAND < 0.002 then	-- interruption : SYNC
               sync_pend := true;						-- après MAINT_WRITEBACK_ALL (SYSTEM_UNIT)
            end if;
         end if;
         if sync_pend and rec.valid = '0' then
            if m_asked = 1 and maint_done = '1' then
               rec := ( valid => '1', kind => RECOVER_COMMITTED, keep_last => ( others => '0' ), checkpoint => ( others => '0' ),
                        new_pc => ( others => '0' ), ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );
               sync_valid <= '1'; n_sync := n_sync + 1;
               sync_frame <= fr_c;							-- même état, tables oubliées
               sync_pend := false;
            else
               mreq.valid := '1';
            end if;
         end if;
         -- LEXCMP en tête (COMPLEX_UNIT) : MAINT_WRITEBACK_RANGE de son intervalle, puis la mémoire
         -- physique doit y avoir la valeur retirée de chaque mot vivant
         if not sync_pend and rec.valid = '0' and head_seq < take_seq then
            x := head_seq mod WIN;
            if q( x ).renamed and q( x ).kind = K_LEX and q( x ).fault = 0 and q( x ).wb_state = 0 then
               if m_asked = 2 and maint_done = '1' then
                  q( x ).wb_state := 1;
               else
                  mreq := ( valid => '1', kind => MAINT_WRITEBACK_RANGE, base => A64( q( x ).wb_lo ),
                            length => to_unsigned( q( x ).wb_n, 64 ) );
               end if;
            elsif q( x ).renamed and q( x ).kind = K_LEX and q( x ).fault = 0 and q( x ).wb_state = 1 then
               a := q( x ).wb_lo - q( x ).wb_lo mod 8;
               while a < q( x ).wb_lo + q( x ).wb_n loop
                  o := TIDX( a );
                  if o >= 0 and A64( a ) <= fr_c.dsp and not IS_UNDEF( REF_AT_HEAD( o ) ) then
                     mok := true; MODEL_WORD( o, 2 * head_seq + 1, mok, mw );
                     if mw = REF_AT_HEAD( o ) then CHECK_PASSED( c ); n_wbcheck := n_wbcheck + 1; else
                        CHECK( c, false, "cycle " & integer'image( now ) & " : après MAINT_WRITEBACK_RANGE, mot " & HEX( A64( a ) ),
                               HEX( REF_AT_HEAD( o ) ), HEX( mw ) );
                     end if;
                  end if;
                  a := a + 8;
               end loop;
               q( x ).wb_state := 2;
            end if;
         end if;
         maint <= mreq;
         if mreq.valid = '0' then m_asked := 0; elsif mreq.kind = MAINT_WRITEBACK_ALL then m_asked := 1; else m_asked := 2; end if;
         retire_count <= to_unsigned( nret, retire_count'length );
         recovery <= rec;
         wait for 1 ns;

		-- le renommage : instructions renommées, échanges
         if ren_valid = '1' and ren_ready = '0' then				-- présenté, pas pris
            ok := dec_take = 0 and alloc_valid = '0';
            for xx in 0 to STACK_XFER_WIDTH - 1 loop ok := ok and xfer( xx ).valid = '0'; end loop;
            if ok then CHECK_PASSED( c ); else
               CHECK( c, false, "cycle " & integer'image( now ) & " : bloc non pris, mais prise, allocation ou échange" );
            end if;
         end if;
         if ren_valid = '1' and ren_ready = '1' then
            k := to_integer( ren_count );
            if k /= to_integer( dec_take ) or k /= to_integer( alloc_count ) or alloc_valid = '0' or k > n then
               CHECK( c, false, "cycle " & integer'image( now ) & " : prise, allocation et bloc renommé incohérents" );
            end if;
            for i in 0 to DECODE_WIDTH - 1 loop
               if i < k then
                  sq := take_seq + i; x := sq mod WIN;
                  ok := ren_block( i ).rob_index = ROB( rob_t + i ) and alloc_block( i ).valid = '1';
                  served_i := q( x ).kind = K_LOAD and q( x ).fault = 0 and alloc_block( i ).done = '1'
                              and ren_block( i ).destination_valid = '0' and ren_block( i ).stack_cache_hit = '1'
                              and ren_block( i ).execute_required = '0' and alloc_block( i ).fault.valid = '0'
                              and ren_block( i ).source_count = 0;
                  conv_ld := q( x ).kind = K_LOAD and q( x ).fault = 0
                             and ( ren_block( i ).slot.canon.op = x"C4" or ren_block( i ).slot.canon.op = x"C5" )
                             and ren_block( i ).source_count = 1 and ren_block( i ).destination_valid = '1'
                             and ren_block( i ).issue_class = ISSUE_INTEGER and ren_block( i ).execute_required = '1';
                  conv_st := q( x ).kind = K_STORE and q( x ).fault = 0 and ren_block( i ).slot.canon.op = x"C6"
                             and ren_block( i ).source_count = 2 and ren_block( i ).destination_valid = '1'
                             and ren_block( i ).issue_class = ISSUE_INTEGER and alloc_block( i ).is_store = '0';
                  -- LIQ dont la cellule pointeur est dans la fenêtre : LQ à lvl 1111, le
                  -- registre de la cellule (le pointeur) en source 0 ; aucune lecture en mémoire
                  if q( x ).kind = K_CLOAD and q( x ).fault = 0 and ren_block( i ).slot.canon.op = x"57" then
                     ok := ok and ren_block( i ).slot.canon.lvl = "1111" and ren_block( i ).address_known = '0'
                           and to_integer( ren_block( i ).slot.canon.val ) = 0;
                     q( x ).nsrc := 1; q( x ).src( 0 ) := q( x ).mrv( 0 ); q( x ).addr_known := false;
                     q( x ).nmr := 0; n_cconv := n_cconv + 1;
                  end if;
                  if served_i then							-- servi par la fenêtre (comme DUP)
                     q( x ).dest := false; q( x ).exec_need := false; n_served := n_served + 1;
                  elsif conv_ld then							-- lecture étroite : UBFXI, SBFXI de la cellule
                     q( x ).nsrc := 1; q( x ).src( 0 ) := q( x ).conv_old; n_conv := n_conv + 1;
                     q( x ).nmr := 0;							-- (aucune lecture en mémoire)
                     -- le champ : lsb = 8 * décalage, w = 8 * taille ; LB, LW, LD : SBFXI
                     ok := ok and ren_block( i ).slot.canon.op = x"C5"
                           and to_integer( ren_block( i ).slot.canon.val ) = 8 * ( to_integer( q( x ).addr( 30 downto 0 ) ) - q( x ).conv_cell )
                           and to_integer( ren_block( i ).slot.canon.ofs ) = 8 * 2 ** to_integer( unsigned( q( x ).slot.canon.op( 1 downto 0 ) ) );
                  elsif conv_st then							-- écriture étroite : BFII ( ancien donnée -- nouveau )
                     q( x ).nsrc := 2; q( x ).src( 1 ) := q( x ).src( 0 ); q( x ).src( 0 ) := q( x ).conv_old;
                     q( x ).dest := true; q( x ).dval := q( x ).conv_new; q( x ).is_store := false;
                     q( x ).npush := 1; q( x ).paddr( 0 ) := q( x ).conv_cell; n_conv := n_conv + 1;
                     ok := ok and to_integer( ren_block( i ).slot.canon.val ) = 8 * ( to_integer( q( x ).addr( 30 downto 0 ) ) - q( x ).conv_cell )
                           and to_integer( ren_block( i ).slot.canon.ofs ) = 8;		-- SB : un octet
                  elsif q( x ).fault /= 0 then
                     ok := ok and alloc_block( i ).fault.valid = '1' and alloc_block( i ).fault.code = q( x ).fault
                           and alloc_block( i ).done = '1' and ren_block( i ).execute_required = '0';
                  else
                     ok := ok and alloc_block( i ).fault.valid = '0' and ren_block( i ).source_count = q( x ).nsrc
                           and ren_block( i ).destination_valid = B( q( x ).dest )
                           and alloc_block( i ).is_store = B( q( x ).is_store )
                           and alloc_block( i ).is_control = B( q( x ).control )
                           and ( not q( x ).control or alloc_block( i ).checkpoint_valid = '1' )
                           and ( q( x ).kind = K_DUP or q( x ).kind = K_OVER		-- (vu avec les échanges)
                                 or alloc_block( i ).done = B( not q( x ).exec_need and q( x ).kind /= K_STORE ) )
                           and ( not q( x ).addr_known or ( ren_block( i ).address_known = '1' and ren_block( i ).address = q( x ).addr ) );
                     for j in 0 to 3 loop						-- source prête : sa valeur est là
                        if j < q( x ).nsrc and ren_block( i ).source_ready( j ) = '1' then
                           ok := ok and pvalid( to_integer( ren_block( i ).source( j ) ) ) = '1'
                                 and pv( to_integer( ren_block( i ).source( j ) ) ) = q( x ).src( j );
                        end if;
                     end loop;
                  end if;
                  if ok then CHECK_PASSED( c ); else
                     CHECK( c, false, "cycle " & integer'image( now ) & ", renommage de l'instruction " & integer'image( sq )
                                      & " (" & kind_t'image( q( x ).kind ) & ")",
                            "faute " & integer'image( q( x ).fault ) & " sources " & integer'image( q( x ).nsrc )
                               & " dest " & boolean'image( q( x ).dest ) & " store " & boolean'image( q( x ).is_store )
                               & " ctl " & boolean'image( q( x ).control ) & " adresse " & boolean'image( q( x ).addr_known )
                               & " " & HEX( q( x ).addr ),
                            "faute " & integer'image( to_integer( alloc_block( i ).fault.code ) ) & " sources "
                               & integer'image( ren_block( i ).source_count ) & " dest " & std_logic'image( ren_block( i ).destination_valid )
                               & " store " & std_logic'image( alloc_block( i ).is_store ) & " ctl "
                               & std_logic'image( alloc_block( i ).is_control ) & " done " & std_logic'image( alloc_block( i ).done )
                               & " adresse " & std_logic'image( ren_block( i ).address_known ) & " " & HEX( ren_block( i ).address )
                               & " rob " & integer'image( to_integer( ren_block( i ).rob_index ) ) & "/" & integer'image( rob_t + i ) );
                  end if;
                  if q( x ).kind = K_STORE and q( x ).fault = 0 and alloc_block( i ).is_store = '1'
                     and TIDX( to_integer( q( x ).addr( 30 downto 0 ) ) ) >= 0 then
                     a := to_integer( q( x ).addr( 30 downto 0 ) );
                     if q( x ).slot.canon.op = x"67" then
                        LOG_ADD( 2 * sq + 2, sq, TIDX( a ), false, ( others => '0' ), x"FF", q( x ).src( 0 ) );
                     else
                        mw := ( others => '0' ); mw( 8 * ( a mod 8 ) + 7 downto 8 * ( a mod 8 ) ) := q( x ).src( 0 )( 7 downto 0 );
                        LOG_ADD( 2 * sq + 2, sq, TIDX( a ), false, ( others => '0' ),
                                 std_logic_vector( shift_left( to_unsigned( 1, 8 ), a mod 8 ) ), mw );
                     end if;
                  end if;
                  q( x ).renamed := true; q( x ).rob := ROB( rob_t + i );
                  q( x ).tags := ren_block( i ).source; q( x ).dtag := ren_block( i ).destination;
                  q( x ).ckpt := alloc_block( i ).checkpoint;
                  if q( x ).dest then pvalid( to_integer( ren_block( i ).destination ) ) := '0'; end if;
                  if q( x ).fault /= 0 then q( x ).done := true; end if;
                  if not q( x ).exec_need and q( x ).fault = 0 and alloc_block( i ).done = '1' then q( x ).done := true; end if;
                  q( x ).spills_seen := 0;						-- (ici : FILL terminal vu)
                  last_progress := now;
               end if;
            end loop;
            -- échanges : SPILL d'une cellule empilée, FILL d'une cellule lue
            for xx in 0 to STACK_XFER_WIDTH - 1 loop
               if xfer( xx ).valid = '1' then
                  found_ins : for i in 0 to DECODE_WIDTH - 1 loop
                     exit found_ins when i >= k;
                     sq := take_seq + i; x := sq mod WIN;
                     if q( x ).rob = xfer( xx ).rob_index then
                        a := to_integer( xfer( xx ).address( 30 downto 0 ) );
                        if xfer( xx ).kind = XFER_SPILL then
                           ok := false;
                           for j in 0 to 1 loop
                              if j < q( x ).npush and q( x ).paddr( j ) = a then ok := true; end if;
                           end loop;
                           -- écriture différée : éviction, LVA, vidage : une cellule vivante
                           if DEFERRED and TIDX( a ) >= 0 and A64( a ) <= q( x ).frame_before.dsp then
                              ok := true; n_def_spill := n_def_spill + 1;
                           end if;
                           if ok then CHECK_PASSED( c ); n_spill := n_spill + 1; else
                              CHECK( c, false, "SPILL inattendu, instruction " & integer'image( sq ) & " adresse " & HEX( xfer( xx ).address ) );
                           end if;
                           if TIDX( a ) >= 0 then
                              if xfer( xx ).committed = '1' then				-- vidage : avant son instruction
                                 n_cspill := n_cspill + 1;
                                 if pvalid( to_integer( xfer( xx ).tag ) ) = '1' then pm( TIDX( a ) ) := pv( to_integer( xfer( xx ).tag ) );
                                 else CHECK( c, false, "SPILL validé sans donnée, instruction " & integer'image( sq ) ); end if;
                              else
                                 LOG_ADD( 2 * sq + 2, sq, TIDX( a ), true, xfer( xx ).tag, x"FF", ( others => '0' ) );
                              end if;
                           end if;
                        else
                           ok := false;
                           for j in 0 to 4 loop
                              if j < q( x ).nread and q( x ).raddr( j ) = a then
                                 ok := true;
                                 pvalid( to_integer( xfer( xx ).tag ) ) := '0';
                                 for f2 in fills'range loop
                                    if not fills( f2 ).valid then
                                       fills( f2 ) := ( valid => true, at => now + 1 + RAND_INT( 5 ), tag => xfer( xx ).tag,
                                                        val => q( x ).rval( j ), seq => sq, addr => a,
                                                        completes => xfer( xx ).completes = '1' );
                                       if xfer( xx ).completes = '1' then q( x ).spills_seen := 1; end if;
                                       exit;
                                    end if;
                                 end loop;
                                 exit;
                              end if;
                           end loop;
                           if ok then CHECK_PASSED( c ); n_fill := n_fill + 1; else
                              CHECK( c, false, "FILL inattendu, instruction " & integer'image( sq ) & " adresse " & HEX( xfer( xx ).address ) );
                           end if;
                        end if;
                        exit found_ins;
                     end if;
                  end loop;
               end if;
            end loop;
            -- DUP, OVER : non terminés à l'allocation si et seulement si un FILL les termine
            for i in 0 to DECODE_WIDTH - 1 loop
               if i < k then
                  x := ( take_seq + i ) mod WIN;
                  if ( q( x ).kind = K_DUP or q( x ).kind = K_OVER ) and q( x ).fault = 0 then
                     if ( alloc_block( i ).done = '0' ) = ( q( x ).spills_seen = 1 ) then CHECK_PASSED( c ); else
                        CHECK( c, false, "cycle " & integer'image( now ) & " : DUP/OVER, done et FILL terminal incohérents" );
                     end if;
                  end if;
               end if;
            end loop;
            take_seq := take_seq + k; rob_t := rob_t + k;
         end if;

         -- échanges sans bloc pris : réécriture (SPILL validés de cellules vivantes retirées)
         if not ( ren_valid = '1' and ren_ready = '1' ) then
            for xx in 0 to STACK_XFER_WIDTH - 1 loop
               if xfer( xx ).valid = '1' then
                  a := to_integer( xfer( xx ).address( 30 downto 0 ) );
                  if xfer( xx ).kind = XFER_SPILL and xfer( xx ).committed = '1' and TIDX( a ) >= 0 and A64( a ) <= fr_c.dsp
                     and pvalid( to_integer( xfer( xx ).tag ) ) = '1' then
                     pm( TIDX( a ) ) := pv( to_integer( xfer( xx ).tag ) ); n_wb := n_wb + 1; CHECK_PASSED( c );
                  else
                     CHECK( c, false, "cycle " & integer'image( now ) & " : échange hors d'un bloc pris (adresse "
                                      & HEX( xfer( xx ).address ) & ")" );
                  end if;
               end if;
            end loop;
         end if;

		-- front : retrait, reprise
         wait until rising_edge( clk );
         for i in 0 to nret - 1 loop
            x := ( head_seq + i ) mod WIN;
            fr_c := q( x ).frame_after;
            LOG_COMMIT( head_seq + i );
            if q( x ).kind = K_PSTORE then						-- l'invalidation viendra
               for j in invs'range loop
                  if not invs( j ).valid then
                     invs( j ) := ( valid => true, at => now + 1 + RAND_INT( 6 ), addr => A64( q( x ).ptr_ea ), rob => q( x ).rob );
                     exit;
                  end if;
               end loop;
            end if;
         end loop;
         head_seq := head_seq + nret;
         if nret > 0 then last_progress := now; end if;
         if rec.valid = '1' then
            if rec.kind = RECOVER_CHECKPOINT then
               keep := keep;
            else
               keep := head_seq - 1;						-- toutes les instructions en vol
            end if;
            for i in fills'range loop						-- FILL des abandonnées
               if fills( i ).valid and fills( i ).seq > keep then fills( i ).valid := false; end if;
            end loop;
            for j in lg'range loop						-- leurs écritures
               if lg( j ).valid and lg( j ).seq > keep then lg( j ).valid := false; end if;
            end loop;
            if rec.kind = RECOVER_CHECKPOINT then
               rob_t := to_integer( q( keep mod WIN ).rob ) + 1; n_mis := n_mis + 1;
            elsif head_seq < take_seq then
               rob_t := to_integer( q( head_seq mod WIN ).rob );		-- la queue revient à la tête
            end if;
            REWIND( keep + 1 );
            last_progress := now;
         end if;
         wait until falling_edge( clk );
         sync_valid <= '0';
         -- état retiré
         if c_frame = fr_c then CHECK_PASSED( c ); else
            n := -1;
            for l in 0 to 14 loop if c_frame.display( l ) /= fr_c.display( l ) then n := l; end if; end loop;
            CHECK( c, false, "cycle " & integer'image( now ) & " : COMMITTED_FRAME_o (DISPLAY différent au niveau "
                             & integer'image( n ) & ")",
                   "dsp " & HEX( fr_c.dsp ) & " rsp " & HEX( fr_c.rsp ) & " display " & HEX( fr_c.display( maximum( n, 0 ) ) ),
                   "dsp " & HEX( c_frame.dsp ) & " rsp " & HEX( c_frame.rsp ) & " display " & HEX( c_frame.display( maximum( n, 0 ) ) ) );
         end if;
      end loop;

		-- fin : une reprise et un SYNC vident les tables (la fenêtre retirée garde, sinon,
		-- les registres des cellules vivantes) ; tous les registres redeviennent libres
      recovery <= ( valid => '1', kind => RECOVER_COMMITTED, keep_last => ( others => '0' ), checkpoint => ( others => '0' ),
                    new_pc => ( others => '0' ), ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );
      sync_frame <= fr_c; sync_valid <= '1';
      retire_count <= ( others => '0' ); dec_count <= ( others => '0' );
      wait until falling_edge( clk );
      recovery <= NO_RECOVERY; sync_valid <= '0';
      for i in 1 to 10 loop wait until falling_edge( clk ); end loop;
      CHECK( c, to_integer( free_count ) = NTAGS, "tous les registres libres à la fin ("
                                                  & integer'image( to_integer( free_count ) ) & ")" );
      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; " & integer'image( INSTRUCTIONS )
             & " instructions ; sources vérifiées " & integer'image( n_src_checked ) & " ; FILL " & integer'image( n_fill ) & " (chargements servis par la fenêtre " & integer'image( n_served ) & ", accès étroits convertis " & integer'image( n_conv ) & ")"
             & ", SPILL " & integer'image( n_spill ) & " ; reprises : mauvaise prédiction " & integer'image( n_mis )
             & ", faute " & integer'image( n_flt ) & ", SYNC " & integer'image( n_sync ) & " ; invalidations "
             & integer'image( n_inval ) severity note;
      report "écriture différée " & boolean'image( DEFERRED ) & " ; lectures comparées à la mémoire physique "
             & integer'image( n_mcheck ) & ", SPILL hors push " & integer'image( n_def_spill ) & " (vidage "
             & integer'image( n_cspill ) & "), réécrits " & integer'image( n_wb ) & ", mots vérifiés après réécriture "
             & integer'image( n_wbcheck ) & ", LIQ convertis " & integer'image( n_cconv ) severity note;
      if DEFERRED then
         CHECK( c, n_src_checked > 5000 and n_fill > 300 and n_def_spill > 100 and n_cspill > 5 and n_wb > 20 and n_cconv > 50
                   and n_mis > 50 and n_flt > 20 and n_inval > 100 and n_mcheck > 600 and n_wbcheck > 100,
                "le tirage a exercé sources, FILL, SPILL d'éviction, vidages, réécritures, reprises et invalidations" );
      else
         CHECK( c, n_src_checked > 5000 and n_fill > 300 and n_spill > 3000 and n_mis > 50 and n_flt > 20 and n_inval > 100
                   and n_mcheck > 600 and n_wbcheck > 100,
                "le tirage a exercé sources, FILL, SPILL, reprises et invalidations" );
      end if;
      FINISH( c, "T_K1b_RENAME_DISPATCH_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
