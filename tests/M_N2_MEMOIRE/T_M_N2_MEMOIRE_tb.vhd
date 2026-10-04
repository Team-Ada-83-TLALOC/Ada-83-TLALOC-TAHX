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
use work.MEMOIRE_DONNEES_PKG.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_M_N2_MEMOIRE_tb : second test d'assemblage (niveau N2), le côté mémoire :
		--  ADDRESS_UNIT, LOAD_STORE_QUEUE (première étape) et DATA_CACHE (1 Kio, 2 voies),
		--  devant une mémoire jouée par le banc (côté D_, latence tirée, protocole
		--  contrôlé).
		--
		--  Même référence que T_M_N2_MEMOIRE_tb : l'exécution séquentielle,
		--  calculée à la génération sur une mémoire spéculative. Le banc émet chaque
		--  accès vers ADDRESS_UNIT avec ses vraies sources (@ = EA - disp quand
		--  l'adresse est sur la pile, donnée v), réserve son entrée dans la LSQ, et joue
		--  le ROB (retrait, reprises). Chaque résultat est reconnu à son rob_index ; à la
		--  fin, après vidange, la zone entière est relue à travers le cache (port 2,
		--  celui de SYSTEM_UNIT) et comparée à la mémoire validée.
		--------------------------------------------------------------------------------


				-----------------
entity				T_M_N2_MEMOIRE_tb
is				-----------------
end entity			T_M_N2_MEMOIRE_tb;
				-----------------


architecture			TEST
of T_M_N2_MEMOIRE_tb is

   constant PERIOD		: time		:= 10 ns;
   constant DEPTH		: positive	:= 32;				-- profondeur de la LSQ du banc
   constant CYCLES		: positive	:= 30000;
   constant DRAIN_MAX		: positive	:= 5000;
   constant STALL_MAX		: positive	:= 1500;
   constant SEED_1		: positive	:= 1944;
   constant SEED_2		: positive	:= 1958;
   constant WIN		: positive	:= 512;				-- numéros en vol, modulo WIN
   constant HOT		: natural	:= DATA_BASE + 8 * POINTER_WORDS;	-- zone chaude, 128 octets

   type kind_t			is ( K_LOAD, K_STORE, K_LIVA, K_CHK );

   type ins_t			is record
			  live		: boolean;			-- en vol (ni retirée, ni abandonnée)
			  kind		: kind_t;
			  fam_c		: boolean;
			  checked		: boolean;			-- résultat vérifié (pas après une faute)
			  exp_fault	: natural;			-- 0, 131, 132
			  exp_value	: word64_t;
			  tag		: physical_tag_t;
			  ex_addr		: address_t;			-- pour EXEC_i
			  ex_data		: word64_t;
			  ex_due		: natural;
			  ex_sent		: boolean;
			  done		: boolean;
			  got_fault	: boolean;
			  st_ok		: boolean;			-- rangement sans faute : écrit au retrait
			  st_addr		: natural;			-- décalage dans la zone
			  st_size		: natural;
			  st_data		: word64_t;
			  known		: boolean;			-- adresse calculée au renommage
			  lvl		: unsigned( 3 downto 0 );
			  disp		: signed( 31 downto 0 );
			  src_n		: natural;			-- sources d'ADDRESS_UNIT
			  src0, src1	: word64_t;
			  op		: std_logic_vector( 7 downto 0 );
			  ofs		: natural range 0 to 255;
			end record;
   type ins_array_t		is array( 0 to WIN - 1 ) of ins_t;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal ins_valid		: std_logic := '0';
   signal ins_block		: renamed_block_t;
   signal ins_count		: dispatch_count_t := ( others => '0' );
   signal mem_cap, cpx_cap	: issue_capacity_t;
   signal exec			: lsq_exec_bus_t( 0 to LSQ_EXEC_PORTS - 1 );
   signal results		: exec_result_bus_t( 0 to MEMORY_LANES - 1 );
   signal rob_head		: rob_index_t := ( others => '0' );
   signal retire		: retire_block_t;
   signal recovery		: recovery_t := NO_RECOVERY;
   signal dc_req		: mem_request_bus_t( 0 to MEMORY_LANES - 1 );
   signal dc_ready		: std_logic_vector( 0 to MEMORY_LANES - 1 );
   signal dc_rsp		: mem_response_bus_t( 0 to MEMORY_LANES - 1 );
   signal drained		: std_logic;
   signal entries		: natural range 0 to DEPTH;
   signal dc_req_all		: mem_request_bus_t( 0 to 2 );
   signal dc_ready_all		: std_logic_vector( 0 to 2 );
   signal dc_rsp_all		: mem_response_bus_t( 0 to 2 );
   signal sys_req		: mem_request_t := NO_MEM_REQUEST;		-- port 2 : relecture finale
   signal d_req, d_write	: std_logic;
   signal d_addr		: address_t;
   signal d_size		: unsigned( 1 downto 0 );
   signal d_wdata		: word64_t;
   signal d_wstrb		: std_logic_vector( 7 downto 0 );
   signal d_ready, d_rvalid, d_fault : std_logic := '0';
   signal d_rdata		: word64_t := ( others => '0' );
   signal d_reads, d_writes, mem_errors : natural := 0;
   signal au_valid		: std_logic := '0';
   signal au_block		: renamed_block_t;
   signal au_count		: dispatch_count_t := ( others => '0' );
   signal au_ready		: std_logic;
   signal au_tags		: read_tags_bus_t( 0 to MEMORY_LANES - 1 );
   signal au_data		: read_data_bus_t( 0 to MEMORY_LANES - 1 );
   signal au_exec		: lsq_exec_bus_t( 0 to MEMORY_LANES - 1 );
   type word_array_t		is array( 0 to 2 ** PHYSICAL_TAG_BITS - 1 ) of word64_t;
   signal prf			: word_array_t := ( others => ( others => '0' ) );
   signal xfer_ready, wif	: std_logic;
   signal lookup		: stack_lookup_request_bus_t( 0 to MEMORY_LANES - 1 );
   signal invalidate		: stack_invalidate_bus_t( 0 to MEMORY_LANES - 1 );
   signal read_tags		: read_tags_bus_t( 0 to MEMORY_LANES - 1 );

   constant NO_EXEC		: lsq_exec_t := ( valid => '0', rob_index => ( others => '0' ), address => ( others => '0' ),
					  data => ( others => '0' ) );

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.LOAD_STORE_QUEUE
      generic map ( DEPTH_G => DEPTH )				-- le sommet : LSQ_DEPTH
      port map (
         CLK_i => clk, RESET_i => reset,
         MEMORY_INSERT_VALID_i => ins_valid, MEMORY_INSERT_BLOCK_i => ins_block, MEMORY_INSERT_COUNT_i => ins_count,
         MEMORY_CAPACITY_o => mem_cap,
         COMPLEX_INSERT_VALID_i => '0', COMPLEX_INSERT_BLOCK_i => ins_block, COMPLEX_INSERT_COUNT_i => ( others => '0' ),
         COMPLEX_CAPACITY_o => cpx_cap,
         EXEC_i => exec, RANGE_i => ( valid => '0', rob_index => ( others => '0' ), read_valid => '0',
                                      read_base => ( others => '0' ), read_length => ( others => '0' ),
                                      write_valid => '0', write_base => ( others => '0' ),
                                      write_length => ( others => '0' ) ),
         STACK_XFER_i => ( others => ( valid => '0', kind => stack_xfer_kind_t'low, address => ( others => '0' ),
                                       tag => ( others => '0' ), rob_index => ( others => '0' ), committed => '0',
                                       ready => '0' ) ),
         STACK_XFER_READY_o => xfer_ready,
         STACK_LOOKUP_o => lookup,
         STACK_LOOKUP_i => ( others => ( valid => '0', hit => '0', tag => ( others => '0' ) ) ),
         STACK_INVALIDATE_o => invalidate, WRITERS_IN_FLIGHT_o => wif,
         READ_TAGS_o => read_tags, READ_DATA_i => ( others => ( others => ( others => '0' ) ) ),
         WAKEUP_i => ( others => ( valid => '0', tag => ( others => '0' ) ) ),
         RESULT_o => results,
         ROB_HEAD_i => rob_head, RETIRE_i => retire, RECOVERY_i => recovery,
         DCACHE_REQ_o => dc_req, DCACHE_READY_i => dc_ready, DCACHE_RSP_i => dc_rsp,
         DRAINED_o => drained, ENTRY_COUNT_o => entries );

   UNITE : entity work.ADDRESS_UNIT
      generic map ( LANES_G => MEMORY_LANES )
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => au_valid, ISSUE_BLOCK_i => au_block, ISSUE_COUNT_i => au_count, ISSUE_READY_o => au_ready,
         READ_TAGS_o => au_tags, READ_DATA_i => au_data,
         BYPASS_i => ( others => ( valid => '0', destination_valid => '0', destination => ( others => '0' ),
                                   value => ( others => '0' ),
                                   completion => ( valid => '0', rob_index => ( others => '0' ), fault => NO_FAULT,
                                                   taken => '0', target => ( others => '0' ), mispredicted => '0' ) ) ),
         EXEC_o => au_exec,
         ROB_HEAD_i => rob_head, RECOVERY_i => recovery );

   exec( 0 to MEMORY_LANES - 1 ) <= au_exec;
   exec( MEMORY_LANES ) <= NO_EXEC;

   FICHIER : process( au_tags, prf )
   begin
      for ln in 0 to MEMORY_LANES - 1 loop
         for s in 0 to MAX_SOURCE_COUNT - 1 loop
            if is_x( std_logic_vector( au_tags( ln )( s ) ) ) then
               au_data( ln )( s ) <= ( others => 'X' );
            else
               au_data( ln )( s ) <= prf( to_integer( au_tags( ln )( s ) ) );
            end if;
         end loop;
      end loop;
   end process;

   dc_req_all( 0 to 1 ) <= dc_req;
   dc_req_all( 2 ) <= sys_req;
   dc_ready <= dc_ready_all( 0 to 1 );
   dc_rsp <= dc_rsp_all( 0 to 1 );

   CACHE : entity work.DATA_CACHE
      generic map ( PORTS_G => 3, SIZE_BYTES_G => 1024, LINE_BYTES_G => 32, WAYS_G => 2,
                    VALID_BASE_G => to_unsigned( DATA_BASE, 64 ), VALID_LIMIT_G => to_unsigned( DATA_BASE + DATA_SIZE, 64 ) )
      port map (
         CLK_i => clk, RESET_i => reset,
         REQ_i => dc_req_all, READY_o => dc_ready_all, RSP_o => dc_rsp_all,
         D_REQ_o => d_req, D_WRITE_o => d_write, D_ADDR_o => d_addr, D_SIZE_o => d_size,
         D_WDATA_o => d_wdata, D_WSTRB_o => d_wstrb, D_READY_i => d_ready,
         D_RVALID_i => d_rvalid, D_RDATA_i => d_rdata, D_FAULT_i => d_fault );

		--------------------------------------------------------------------------------
		-- Mémoire côté D_ : écritures appliquées à l'acceptation, lectures en ordre
		--------------------------------------------------------------------------------

   MEMOIRE : process
      constant CAP	: positive := 64;
      type pend_t	is record
			  data	: word64_t;
			  due	: natural;
			end record;
      type pend_array_t is array( 0 to CAP - 1 ) of pend_t;
      variable m		: data_memory_t := INITIAL_MEMORY;
      variable pq		: pend_array_t;
      variable head, n, now, last_due : natural := 0;
      variable s1, s2	: positive := 77;
      variable r		: real;
      variable rdy	: std_logic;
      variable off	: integer;
      variable w		: word64_t;
      variable nr, nw, ne : natural := 0;
   begin
      wait until falling_edge( clk );
      loop
         now := now + 1;
         if n > 0 and pq( head ).due <= now then
            d_rvalid <= '1'; d_rdata <= pq( head ).data;
            head := ( head + 1 ) mod CAP; n := n - 1;
         else
            d_rvalid <= '0';
         end if;
         uniform( s1, s2, r );
         if r < 0.7 and n < CAP then rdy := '1'; else rdy := '0'; end if;
         d_ready <= rdy;
         wait until rising_edge( clk );
         if d_req = '1' and rdy = '1' then
            off := to_integer( d_addr( 30 downto 0 ) ) - DATA_BASE;
            if d_addr( 2 downto 0 ) /= "000" or d_size /= "11" or d_addr( 63 downto 31 ) /= 0
               or off < 0 or off + 8 > DATA_SIZE then
               ne := ne + 1;
               report "mémoire : requête invalide à " & to_hstring( d_addr ) severity error;
            elsif d_write = '1' then
               for i in 0 to 7 loop
                  if d_wstrb( i ) = '1' then m( off + i ) := d_wdata( 8 * i + 7 downto 8 * i ); end if;
               end loop;
               nw := nw + 1;
            else
               for i in 0 to 7 loop w( 8 * i + 7 downto 8 * i ) := m( off + i ); end loop;
               uniform( s1, s2, r );
               last_due := maximum( last_due + 1, now + 1 + integer( trunc( r * 6.0 ) ) );
               pq( ( head + n ) mod CAP ) := ( data => w, due => last_due );
               n := n + 1; nr := nr + 1;
            end if;
            d_reads <= nr; d_writes <= nw; mem_errors <= ne;
         end if;
         wait until falling_edge( clk );
      end loop;
   end process;

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + DRAIN_MAX + 200 );
      if running then
         report "TEST T_M_N2_MEMOIRE_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      -- modèle
      variable q		: ins_array_t;
      variable head_seq, next_seq : natural := 0;
      variable committed	: data_memory_t := INITIAL_MEMORY;		-- mémoire validée
      variable spec		: data_memory_t := INITIAL_MEMORY;		-- et rangements en vol
      variable poisoned		: boolean := false;				-- une faute en vol
      variable next_tag		: natural := 0;
      variable last_progress	: natural := 0;

      -- cycle
      variable rec		: recovery_t;
      variable keep		: integer;
      variable ret		: retire_block_t;
      variable nret		: natural;
      variable blk		: renamed_block_t;
      variable nb, k, sq, x	: natural;
      variable aub		: renamed_block_t;
      variable src_tag		: natural := 0;
      variable got		: word64_t;
      variable fa		: natural;
      variable found		: integer;
      variable ok, generating, stalled : boolean;
      variable now		: natural := 0;
      variable n_cover, n_partial, n_ptr_update : natural := 0;				-- recouvrements à la génération
      variable n_checked, n_unchecked, n_load, n_store, n_c, n_liva, n_chk, n_131, n_132, n_rec_c, n_rec_k : natural := 0;

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

      function ROB( n : natural ) return rob_index_t is
      begin
         return to_unsigned( n mod ROB_SIZE, ROB_INDEX_BITS );
      end function;

      -- lecture de la mémoire spéculative : n octets dès a, étendus (signed)
      impure function READ_SPEC( a : address_t; n : natural; sgn : boolean ) return word64_t is
         variable w : word64_t := ( others => '0' );
         variable off : natural;
      begin
         off := to_integer( a( 30 downto 0 ) ) - DATA_BASE;
         for i in 0 to n - 1 loop
            w( 8 * i + 7 downto 8 * i ) := spec( off + i );
         end loop;
         if sgn and n < 8 and w( 8 * n - 1 ) = '1' then
            w( 63 downto 8 * n ) := ( others => '1' );
         end if;
         return w;
      end function;

      -- une adresse effective tirée : zone chaude, zone, hors zone
      impure function DRAW_EA( n : natural ) return address_t is
         variable u : real := RAND;
      begin
         if u < 0.88 then							-- zone chaude, 64 octets
            return to_unsigned( HOT + 8 * RAND_INT( 7 ) + RAND_INT( 7 ), 64 );
         elsif u < 0.98 then							-- zone, hors cellules pointeurs
            return to_unsigned( HOT + RAND_INT( DATA_SIZE - 8 * POINTER_WORDS - n ), 64 );
         elsif u < 0.99 then							-- à cheval sur la fin
            return to_unsigned( DATA_BASE + DATA_SIZE - n + 1 + RAND_INT( n ), 64 );
         else
            return to_unsigned( DATA_BASE - 1 - RAND_INT( 64 ), 64 );
         end if;
      end function;

      -- reconstruit la mémoire spéculative et l'état de faute après une reprise
      procedure REBUILD is
      begin
         spec := committed;
         poisoned := false;
         for n in head_seq to next_seq - 1 loop
            x := n mod WIN;
            if q( x ).live then
               if q( x ).exp_fault /= 0 then poisoned := true; end if;
               if q( x ).kind = K_STORE and q( x ).st_ok and not poisoned then
                  for i in 0 to q( x ).st_size - 1 loop
                     spec( q( x ).st_addr + i ) := q( x ).st_data( 8 * i + 7 downto 8 * i );
                  end loop;
               end if;
            end if;
         end loop;
      end procedure;

      -- une instruction : opcode, sources, résultat attendu (exécution séquentielle)
      procedure GENERATE_ONE( i : natural ) is
         variable u		: real := RAND;
         variable sz, n	: natural;
         variable signed_mode	: boolean;
         variable op		: std_logic_vector( 7 downto 0 );
         variable ea, cell, ptr, a2 : address_t;
         variable fault	: natural := 0;
         variable v, fst, lst	: word64_t;
         variable known	: boolean;
         variable ofs		: natural;
         variable e		: ins_t;
         variable ptr_update	: boolean;
      begin
         sz := RAND_INT( 3 ); n := 2 ** sz;
         signed_mode := RAND < 0.5 or sz = 3;
         e.fam_c := false;
         e.exp_value := ( others => '0' );
         e.ex_data := ( others => '0' );
         e.st_ok := false; e.st_addr := 0; e.st_size := n; e.st_data := ( others => '0' );
         if u < 0.32 then e.kind := K_LOAD;
         elsif u < 0.62 then e.kind := K_STORE;
         elsif u < 0.70 then e.kind := K_LOAD; e.fam_c := true;
         elsif u < 0.78 then e.kind := K_STORE; e.fam_c := true;
         elsif u < 0.85 then e.kind := K_LIVA; e.fam_c := true; sz := 3; n := 8;
         elsif u < 0.95 then e.kind := K_CHK;
         else e.kind := K_CHK; e.fam_c := true;
         end if;
         if e.kind = K_CHK and sz = 3 then signed_mode := true; end if;
         -- mise à jour d'un pointeur : 8 octets valides dans une cellule pointeur
         ptr_update := e.kind = K_STORE and not e.fam_c and RAND < 0.06;
         if ptr_update then sz := 3; n := 8; end if;
         if e.kind = K_STORE then e.st_size := n; end if;

         -- opcode (familles B et C, formats B16 / C24, CHK B24 / CHKI C32)
         if e.fam_c then op( 7 downto 6 ) := "10"; else op( 7 downto 6 ) := "01"; end if;
         case e.kind is
            when K_LOAD  => op( 3 downto 2 ) := "01"; if signed_mode then op( 5 downto 4 ) := "01"; else op( 5 downto 4 ) := "11"; end if;
            when K_STORE => op( 3 downto 2 ) := "01"; op( 5 downto 4 ) := "10";
            when K_LIVA  => op( 3 downto 2 ) := "01"; op( 5 downto 4 ) := "00";
            when K_CHK   => op( 3 downto 2 ) := "11"; if signed_mode then op( 5 downto 4 ) := "01"; else op( 5 downto 4 ) := "11"; end if;
         end case;
         op( 1 downto 0 ) := std_logic_vector( to_unsigned( sz, 2 ) );
         ofs := RAND_INT( 255 );
         blk( i ).slot.canon := CANON_NOP;
         blk( i ).slot.canon.op := op;
         blk( i ).slot.canon.ofs := to_unsigned( ofs, 8 );
         blk( i ).rob_index := ROB( next_seq );
         next_tag := ( next_tag + 1 ) mod 512;
         e.tag := to_unsigned( next_tag, PHYSICAL_TAG_BITS );
         blk( i ).destination := e.tag;
         blk( i ).destination_valid := B( e.kind = K_LOAD or e.kind = K_LIVA );
         known := RAND < 0.6 or e.kind = K_CHK;				-- CHK : lvl 0..14 seulement

         -- adresse : effective (B) ou cellule pointeur (C)
         if e.fam_c then
            u := RAND;
            if u < 0.97 then cell := to_unsigned( DATA_BASE + 8 * RAND_INT( POINTER_WORDS - 1 ), 64 );
            elsif u < 0.99 then cell := to_unsigned( HOT + 8 * RAND_INT( 7 ), 64 );		-- pointeur faux
            else cell := to_unsigned( DATA_BASE + DATA_SIZE - 4, 64 );			-- cellule invalide
            end if;
            e.ex_addr := cell;
            if not IN_ZONE( cell, 8 ) then
               fault := 132;
            else
               ptr := unsigned( READ_SPEC( cell, 8, false ) );
               ea := ptr + ofs;
               if e.kind = K_CHK then						-- bornes dans l'ordre, si possible
                  for essai in 1 to 4 loop
                     exit when not ( IN_ZONE( ea, n ) and IN_ZONE( ea + n, n ) )
                               or signed( READ_SPEC( ea, n, signed_mode ) ) <= signed( READ_SPEC( ea + n, n, signed_mode ) );
                     ofs := RAND_INT( 255 );
                     ea := ptr + ofs;
                  end loop;
                  blk( i ).slot.canon.ofs := to_unsigned( ofs, 8 );
               end if;
            end if;
            n_c := n_c + 1;
         else
            ea := DRAW_EA( n );
            if e.kind = K_CHK then						-- bornes dans l'ordre, si possible
               for essai in 1 to 4 loop
                  ea := DRAW_EA( 2 * n );
                  exit when not ( IN_ZONE( ea, n ) and IN_ZONE( ea + n, n ) )
                            or signed( READ_SPEC( ea, n, signed_mode ) ) <= signed( READ_SPEC( ea + n, n, signed_mode ) );
               end loop;
            end if;
            if ptr_update then ea := to_unsigned( DATA_BASE + 8 * RAND_INT( POINTER_WORDS - 1 ), 64 ); end if;
            e.ex_addr := ea;
         end if;
         blk( i ).address_known := B( known );
         blk( i ).address := e.ex_addr;

         -- résultat attendu
         if fault = 0 then
            case e.kind is
               when K_LOAD =>
                  if IN_ZONE( ea, n ) then e.exp_value := READ_SPEC( ea, n, signed_mode ); else fault := 132; end if;
                  n_load := n_load + 1;
                  -- couverture : le plus jeune rangement en vol qui recouvre ce chargement
                  if fault = 0 and not poisoned then
                     for older in next_seq - 1 downto head_seq loop
                        x := older mod WIN;
                        if q( x ).live and q( x ).kind = K_STORE and q( x ).st_ok then
                           a2 := to_unsigned( DATA_BASE + q( x ).st_addr, 64 );
                           if ea < a2 + q( x ).st_size and a2 < ea + n then
                              if a2 <= ea and ea + n <= a2 + q( x ).st_size then
                                 n_cover := n_cover + 1;
                              else
                                 n_partial := n_partial + 1;
                              end if;
                              exit;
                           end if;
                        end if;
                     end loop;
                  end if;
               when K_LIVA =>
                  e.exp_value := std_logic_vector( ea );
                  n_liva := n_liva + 1;
               when K_STORE =>
                  e.ex_data := RAND_WORD;
                  if ptr_update then						-- pointeur vers la zone chaude
                     e.ex_data := std_logic_vector( to_unsigned( HOT + RAND_INT( 56 ), 64 ) );
                     n_ptr_update := n_ptr_update + 1;
                  end if;
                  if IN_ZONE( ea, n ) then
                     e.st_ok := true;
                     e.st_addr := to_integer( ea( 30 downto 0 ) ) - DATA_BASE;
                     e.st_data := e.ex_data;
                  else
                     fault := 132;
                  end if;
                  n_store := n_store + 1;
               when K_CHK =>
                  a2 := ea + n;
                  if IN_ZONE( ea, n ) and IN_ZONE( a2, n ) then
                     fst := READ_SPEC( ea, n, signed_mode ); lst := READ_SPEC( a2, n, signed_mode );
                     case RAND_INT( 15 ) is
                        when 0 => v := std_logic_vector( signed( fst ) - 1 );
                        when 1 => v := std_logic_vector( signed( lst ) + 1 );
                        when 2 to 7 => v := fst;
                        when others => v := lst;
                     end case;
                     if signed( v ) < signed( fst ) or signed( v ) > signed( lst ) then fault := 131; end if;
                  else
                     v := RAND_WORD; fault := 132;
                  end if;
                  e.ex_data := v;
                  n_chk := n_chk + 1;
            end case;
         elsif e.kind = K_STORE then
            e.ex_data := RAND_WORD;
         elsif e.kind = K_CHK then
            e.ex_data := RAND_WORD;
         end if;

         -- sources d'ADDRESS_UNIT : adresse au renommage (lvl 0..14), ou sur la pile (1111)
         e.known := known;
         e.disp := to_signed( RAND_INT( 2000 ) - 1000, 32 );
         e.src0 := ( others => '0' ); e.src1 := ( others => '0' ); e.src_n := 0;
         if known then
            e.lvl := to_unsigned( RAND_INT( 14 ), 4 );
            if e.kind = K_STORE or e.kind = K_CHK then e.src_n := 1; e.src0 := e.ex_data; end if;
         else
            e.lvl := "1111";
            e.src0 := std_logic_vector( e.ex_addr - unsigned( resize( e.disp, 64 ) ) );	-- @ = EA - disp
            e.src_n := 1;
            if e.kind = K_STORE then e.src_n := 2; e.src1 := e.ex_data; end if;
         end if;
         blk( i ).slot.canon.lvl := e.lvl;
         blk( i ).slot.canon.val := e.disp;
         e.op := op;
         e.ofs := to_integer( blk( i ).slot.canon.ofs );

         e.exp_fault := fault;
         e.checked := not poisoned;
         e.live := true; e.done := false; e.got_fault := false;
         e.ex_sent := false; e.ex_due := now + 1 + RAND_INT( 12 );
         if fault /= 0 then
            if fault = 131 then n_131 := n_131 + 1; else n_132 := n_132 + 1; end if;
            poisoned := true;
         end if;
         -- la mémoire spéculative suit le rangement (s'il n'est pas après une faute)
         if e.kind = K_STORE and e.st_ok and e.checked then
            for bt in 0 to n - 1 loop
               spec( e.st_addr + bt ) := e.st_data( 8 * bt + 7 downto 8 * bt );
            end loop;
         end if;
         q( next_seq mod WIN ) := e;
         next_seq := next_seq + 1;
      end procedure;

   begin
      s2 := SEED_2;
      for i in 0 to RENAME_WIDTH - 1 loop
         blk( i ) := ( slot => ( valid => '1', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION ),
                       rob_index => ( others => '0' ), issue_class => ISSUE_MEMORY,
                       source_count => 0, source => ( others => ( others => '0' ) ),
                       source_ready => ( others => '1' ), destination_valid => '0',
                       destination => ( others => '0' ), execute_required => '1',
                       address_known => '0', address => ( others => '0' ),
                       stack_cache_hit => '0', checkpoint_valid => '0', checkpoint => ( others => '0' ) );
      end loop;
      for i in ret'range loop
         ret( i ) := ( valid => '0', rob_index => ( others => '0' ), pc => ( others => '0' ), is_store => '0',
                       is_control => '0', conditional => '0', taken => '0', target => ( others => '0' ),
                       ghist => ( others => '0' ) );
      end loop;
      for i in q'range loop
         q( i ).live := false;
      end loop;
      ins_block <= blk; retire <= ret;					-- exec : piloté par ADDRESS_UNIT
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      loop
         now := now + 1;
         generating := now <= CYCLES;
         while head_seq < next_seq and not q( head_seq mod WIN ).live loop	-- tête : la plus ancienne en vol
            head_seq := head_seq + 1;
         end loop;
         exit when not generating and head_seq = next_seq and drained = '1';
         if now > CYCLES + DRAIN_MAX then
            CHECK( c, false, "vidange inachevée : " & integer'image( next_seq - head_seq ) & " instruction(s) en vol" );
            exit;
         end if;
         rob_head <= ROB( head_seq );

		-- ROB : reprise (faute en tête, ou au hasard), retrait dans l'ordre
         rec := NO_RECOVERY; keep := -1;
         x := head_seq mod WIN;
         if head_seq < next_seq and q( x ).done and q( x ).got_fault then
            rec.valid := '1'; rec.kind := RECOVER_COMMITTED;			-- faute livrée
            n_rec_c := n_rec_c + 1;
         elsif head_seq < next_seq and RAND < 0.008 then
            keep := head_seq + RAND_INT( next_seq - 1 - head_seq );
            rec.valid := '1'; rec.kind := RECOVER_CHECKPOINT; rec.keep_last := ROB( keep );
            n_rec_k := n_rec_k + 1;
         end if;
         recovery <= rec;
         nret := 0;
         for i in ret'range loop
            ret( i ).valid := '0';
         end loop;
         if RAND < 0.8 then
            for i in 0 to RETIRE_WIDTH - 1 loop
               sq := head_seq + i;
               exit when sq >= next_seq;
               x := sq mod WIN;
               exit when not q( x ).live or not q( x ).done or q( x ).got_fault;
               exit when rec.valid = '1' and rec.kind = RECOVER_CHECKPOINT and sq > keep;
               ret( i ) := ( valid => '1', rob_index => ROB( sq ), pc => ( others => '0' ),
                             is_store => B( q( x ).kind = K_STORE ), is_control => '0', conditional => '0',
                             taken => '0', target => ( others => '0' ), ghist => ( others => '0' ) );
               nret := i + 1;
            end loop;
         end if;
         retire <= ret;

		-- répartition : bloc inséré (dans la fenêtre du ROB et la capacité de la LSQ)
         nb := 0;
         if generating and RAND < 0.6 then
            k := to_integer( mem_cap );
            if k > 3 then k := 3; end if;
            if next_seq + k - head_seq >= ROB_SIZE - 8 then k := 0; end if;
            nb := RAND_INT( k );
            for i in 0 to nb - 1 loop
               GENERATE_ONE( i );
            end loop;
         end if;
         ins_block <= blk;
         ins_count <= to_unsigned( nb, ins_count'length );
         ins_valid <= B( nb > 0 );

		-- émission vers ADDRESS_UNIT (jamais pour une instruction abandonnée)
         aub := au_block;
         k := 0;
         for sq2 in head_seq to next_seq - 1 - nb loop
            exit when k = MEMORY_LANES;
            x := sq2 mod WIN;
            if q( x ).live and not q( x ).ex_sent and q( x ).ex_due <= now
               and not ( rec.valid = '1' and ( rec.kind = RECOVER_COMMITTED or sq2 > keep ) ) then
               aub( k ) := blk( 0 );
               aub( k ).slot.canon := CANON_NOP;
               aub( k ).slot.canon.op := q( x ).op;
               aub( k ).slot.canon.lvl := q( x ).lvl;
               aub( k ).slot.canon.val := q( x ).disp;
               aub( k ).slot.canon.ofs := to_unsigned( q( x ).ofs, 8 );
               aub( k ).rob_index := ROB( sq2 );
               aub( k ).address_known := B( q( x ).known );
               aub( k ).address := q( x ).ex_addr;
               aub( k ).source_count := q( x ).src_n;
               for sr in 0 to MAX_SOURCE_COUNT - 1 loop
                  src_tag := ( src_tag + 1 ) mod 2 ** PHYSICAL_TAG_BITS;
                  aub( k ).source( sr ) := to_unsigned( src_tag, PHYSICAL_TAG_BITS );
               end loop;
               prf( to_integer( aub( k ).source( 0 ) ) ) <= q( x ).src0;
               prf( to_integer( aub( k ).source( 1 ) ) ) <= q( x ).src1;
               q( x ).ex_sent := true;
               k := k + 1;
            end if;
         end loop;
         au_block <= aub;
         au_count <= to_unsigned( k, au_count'length );
         au_valid <= B( k > 0 );

         wait for 1 ns;

		-- résultats
         for l in 0 to MEMORY_LANES - 1 loop
            if results( l ).valid = '1' then
               found := -1;
               for sq2 in head_seq to next_seq - 1 loop
                  x := sq2 mod WIN;
                  if q( x ).live and not q( x ).done and ROB( sq2 ) = results( l ).completion.rob_index then
                     found := sq2;
                  end if;
               end loop;
               if found < 0 then
                  CHECK( c, false, "cycle " & integer'image( now ) & ", voie " & integer'image( l )
                                   & " : résultat d'aucune instruction en attente" );
               elsif rec.valid = '1' and ( rec.kind = RECOVER_COMMITTED or found > keep ) then
                  CHECK( c, false, "cycle " & integer'image( now ) & " : résultat d'une instruction abandonnée" );
               else
                  x := found mod WIN;
                  if q( x ).checked then
                     ok := results( l ).completion.valid = '1';
                     if q( x ).exp_fault /= 0 then
                        ok := ok and results( l ).completion.fault.valid = '1'
                              and results( l ).completion.fault.code = q( x ).exp_fault
                              and results( l ).destination_valid = '0';
                     else
                        ok := ok and results( l ).completion.fault.valid = '0';
                        if q( x ).kind = K_LOAD or q( x ).kind = K_LIVA then
                           ok := ok and results( l ).destination_valid = '1' and results( l ).destination = q( x ).tag
                                 and results( l ).value = q( x ).exp_value;
                        else
                           ok := ok and results( l ).destination_valid = '0';
                        end if;
                     end if;
                     if ok then CHECK_PASSED( c ); else
                        CHECK( c, false, "cycle " & integer'image( now ) & ", instruction " & integer'image( found )
                                         & " (" & kind_t'image( q( x ).kind ) & ", famille C "
                                         & boolean'image( q( x ).fam_c ) & ")",
                               "faute " & integer'image( q( x ).exp_fault ) & " valeur " & HEX( q( x ).exp_value ),
                               "faute " & std_logic'image( results( l ).completion.fault.valid ) & "/"
                                  & integer'image( to_integer( results( l ).completion.fault.code ) ) & " valeur "
                                  & HEX( results( l ).value ) );
                     end if;
                     n_checked := n_checked + 1;
                  else
                     n_unchecked := n_unchecked + 1;
                  end if;
                  q( x ).done := true;
                  q( x ).got_fault := results( l ).completion.fault.valid = '1';
                  last_progress := now;
               end if;
            end if;
         end loop;
         -- deux entrées réservées aux échanges
         if mem_cap = to_unsigned( minimum( 8, maximum( 0, DEPTH - entries - STACK_XFER_WIDTH ) ), mem_cap'length )
            and cpx_cap = to_unsigned( minimum( 8, maximum( 0, DEPTH - entries - STACK_XFER_WIDTH - to_integer( mem_cap ) ) ),
                                       cpx_cap'length ) then
            CHECK_PASSED( c );
         else
            CHECK( c, false, "cycle " & integer'image( now ) & " : capacités" );
         end if;

		-- front : retrait, reprise
         wait until rising_edge( clk );
         for i in 0 to nret - 1 loop
            x := ( head_seq + i ) mod WIN;
            if q( x ).kind = K_STORE and q( x ).st_ok then
               for bt in 0 to q( x ).st_size - 1 loop
                  committed( q( x ).st_addr + bt ) := q( x ).st_data( 8 * bt + 7 downto 8 * bt );
               end loop;
            end if;
            q( x ).live := false;
            last_progress := now;
         end loop;
         if rec.valid = '1' then
            for sq2 in head_seq to next_seq - 1 loop
               x := sq2 mod WIN;
               if q( x ).live and ( rec.kind = RECOVER_COMMITTED or sq2 > keep ) then
                  q( x ).live := false;
               end if;
            end loop;
            REBUILD;
         end if;
         stalled := head_seq < next_seq and now - last_progress > STALL_MAX;
         if stalled then
            CHECK( c, false, "cycle " & integer'image( now ) & " : aucun progrès depuis " & integer'image( STALL_MAX )
                             & " cycles (instruction " & integer'image( head_seq ) & " en tête)" );
            exit;
         end if;
         wait until falling_edge( clk );
      end loop;

		-- vidange faite : la zone relue à travers le cache (port 2) est la mémoire validée
      ok := true;
      fa := 0;
      while fa < DATA_SIZE loop
         wait until falling_edge( clk );
         sys_req <= ( valid => '1', write => '0', probe => '0', address => to_unsigned( DATA_BASE + fa, 64 ),
                      size => "11", wdata => ( others => '0' ) );
         wait for 1 ns;
         if dc_ready_all( 2 ) = '1' then
            wait until falling_edge( clk );
            sys_req <= NO_MEM_REQUEST;
            while dc_rsp_all( 2 ).valid /= '1' loop
               wait until falling_edge( clk );
            end loop;
            got := dc_rsp_all( 2 ).rdata;
            for i in 0 to 7 loop
               if got( 8 * i + 7 downto 8 * i ) /= committed( fa + i ) then ok := false; end if;
            end loop;
            fa := fa + 8;
         end if;
      end loop;
      sys_req <= NO_MEM_REQUEST;
      if ok then CHECK_PASSED( c ); else
         CHECK( c, false, "zone relue à travers le cache différente de la mémoire validée" );
      end if;
      CHECK( c, mem_errors = 0, "protocole côté mémoire respecté" );

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; résultats vérifiés "
             & integer'image( n_checked ) & ", après une faute " & integer'image( n_unchecked ) & " ; générés : "
             & integer'image( n_load ) & " chargements, " & integer'image( n_store ) & " rangements, "
             & integer'image( n_liva ) & " LIVA, " & integer'image( n_chk ) & " CHK (famille C : " & integer'image( n_c )
             & ") ; fautes 131 " & integer'image( n_131 ) & ", 132 " & integer'image( n_132 ) & " ; reprises "
             & integer'image( n_rec_c ) & " + " & integer'image( n_rec_k ) & " ; chargements couverts par un rangement "
             & "en vol " & integer'image( n_cover ) & ", en partie " & integer'image( n_partial ) & " ; mises à jour de pointeur " & integer'image( n_ptr_update )
             & " ; mémoire : mots lus " & integer'image( d_reads ) & ", écrits " & integer'image( d_writes )
             severity note;
      CHECK( c, n_checked > 3000 and n_cover > 100 and n_partial > 150 and n_131 > 50 and n_132 > 50 and n_rec_k > 30
                and d_writes > 500 and d_reads > 1000,
             "le tirage a exercé chargements, rangements, fautes, reprises et le cache" );
      FINISH( c, "T_M_N2_MEMOIRE_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
