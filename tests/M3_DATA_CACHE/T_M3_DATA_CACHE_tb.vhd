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
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_M3_DATA_CACHE_tb : le contrat de l'en-tête de M3_DATA_CACHE.
		--
		--  Configuration réduite (512 octets, 2 voies) devant 2 Kio de mémoire : défauts,
		--  évictions et réécritures fréquents. Le banc joue les PORTS clients (lectures,
		--  écritures, sondages ; tailles 1 à 8 ; souvent non alignés ou à cheval sur deux
		--  lignes ; parfois hors zone) et la mémoire côté D_ (latence tirée ; contrôle du
		--  protocole : mots alignés, dans la zone). Référence : la mémoire séquentielle,
		--  mise à jour au front d'acceptation de chaque écriture ; une lecture attend la
		--  valeur de ce front (sauf octets écrits au même front par un autre port, non
		--  vérifiés). Chaque réponse est comparée dans l'ordre de son port ; à la fin, la
		--  zone entière est relue à travers le cache.
		--------------------------------------------------------------------------------


				-----------------
entity				T_M3_DATA_CACHE_tb
is				-----------------
end entity			T_M3_DATA_CACHE_tb;
				-----------------


architecture			TEST
of T_M3_DATA_CACHE_tb is

   constant PERIOD		: time		:= 10 ns;
   constant CYCLES		: positive	:= 60000;
   constant PORTS		: positive	:= 4;
   constant BASE		: natural	:= 16#10000#;
   constant ZONE		: natural	:= 2048;
   constant HOT		: natural	:= BASE + 512;			-- 256 octets, 8 lignes
   constant MAX_WAIT		: positive	:= 2000;
   constant SEED_1		: positive	:= 1789;
   constant SEED_2		: positive	:= 1848;

   type bytes_t		is array( 0 to ZONE - 1 ) of byte_t;

   function INIT_BYTE( i : natural ) return byte_t is
   begin
      return std_logic_vector( to_unsigned( ( i * 151 + ( i / 256 ) * 89 + 3 ) mod 256, 8 ) );
   end function;

   function INIT_MEMORY return bytes_t is
      variable m : bytes_t;
   begin
      for i in m'range loop m( i ) := INIT_BYTE( i ); end loop;
      return m;
   end function;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal req			: mem_request_bus_t( 0 to PORTS - 1 ) := ( others => NO_MEM_REQUEST );
   signal ready		: std_logic_vector( 0 to PORTS - 1 );
   signal rsp			: mem_response_bus_t( 0 to PORTS - 1 );
   signal d_req, d_write	: std_logic;
   signal d_addr		: address_t;
   signal d_size		: unsigned( 1 downto 0 );
   signal d_wdata		: word64_t;
   signal d_wstrb		: std_logic_vector( 7 downto 0 );
   signal d_ready		: std_logic := '0';
   signal d_rvalid		: std_logic := '0';
   signal d_rdata		: word64_t := ( others => '0' );
   signal d_fault		: std_logic := '0';
   signal d_reads, d_writes	: natural := 0;
   signal mem_errors		: natural := 0;

begin

   DUT : entity work.DATA_CACHE
      generic map ( PORTS_G => PORTS, SIZE_BYTES_G => 512, LINE_BYTES_G => 32, WAYS_G => 2,
                    VALID_BASE_G => to_unsigned( BASE, 64 ), VALID_LIMIT_G => to_unsigned( BASE + ZONE, 64 ) )
      port map (
         CLK_i => clk, RESET_i => reset,
         REQ_i => req, READY_o => ready, RSP_o => rsp,
         D_REQ_o => d_req, D_WRITE_o => d_write, D_ADDR_o => d_addr, D_SIZE_o => d_size,
         D_WDATA_o => d_wdata, D_WSTRB_o => d_wstrb, D_READY_i => d_ready,
         D_RVALID_i => d_rvalid, D_RDATA_i => d_rdata, D_FAULT_i => d_fault );

   clk <= not clk after PERIOD / 2 when running;

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
      variable m		: bytes_t := INIT_MEMORY;
      variable q		: pend_array_t;
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
         if n > 0 and q( head ).due <= now then
            d_rvalid <= '1'; d_rdata <= q( head ).data;
            head := ( head + 1 ) mod CAP; n := n - 1;
         else
            d_rvalid <= '0';
         end if;
         uniform( s1, s2, r );
         if r < 0.7 and n < CAP then rdy := '1'; else rdy := '0'; end if;
         d_ready <= rdy;
         wait until rising_edge( clk );
         if d_req = '1' and rdy = '1' then
            off := to_integer( d_addr( 30 downto 0 ) ) - BASE;
            if d_addr( 2 downto 0 ) /= "000" or d_size /= "11" or d_addr( 63 downto 31 ) /= 0
               or off < 0 or off + 8 > ZONE then
               ne := ne + 1;						-- protocole violé
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
               q( ( head + n ) mod CAP ) := ( data => w, due => last_due );
               n := n + 1;
               nr := nr + 1;
            end if;
            d_reads <= nr; d_writes <= nw; mem_errors <= ne;
         end if;
         wait until falling_edge( clk );
      end loop;
   end process;

		--------------------------------------------------------------------------------
		-- Clients
		--------------------------------------------------------------------------------

   CLIENTS : process
      constant FCAP		: positive := 256;
      type exp_t		is record
			  kind		: natural;			-- 0 lecture, 1 écriture, 2 sondage
			  fault		: std_logic;
			  data		: word64_t;
			  mask		: word64_t;			-- octets vérifiés
			  since		: natural;
			end record;
      type fifo_t		is array( 0 to FCAP - 1 ) of exp_t;
      type fifo_array_t		is array( 0 to PORTS - 1 ) of fifo_t;
      type nat_ports_t		is array( 0 to PORTS - 1 ) of natural;
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;
      variable ref		: bytes_t := INIT_MEMORY;
      variable before		: bytes_t;
      variable fifo		: fifo_array_t;
      variable fh, fn		: nat_ports_t := ( others => 0 );
      variable rq		: mem_request_bus_t( 0 to PORTS - 1 );
      variable acc		: std_logic_vector( 0 to PORTS - 1 );
      variable e		: exp_t;
      variable nb, off, a	: integer;
      variable valid_acc	: boolean;
      variable w, got		: word64_t;
      variable now		: natural := 0;
      variable final_phase	: boolean := false;
      variable final_addr	: natural := 0;
      variable n_reads, n_writes, n_probes, n_faults, n_cross, n_same_edge, n_checked : natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

      impure function DRAW_ADDR( n : natural ) return address_t is
         variable u : real := RAND;
      begin
         if u < 0.70 then return to_unsigned( HOT + RAND_INT( 256 - n ), 64 );
         elsif u < 0.92 then return to_unsigned( BASE + RAND_INT( ZONE - n ), 64 );
         elsif u < 0.95 then return to_unsigned( BASE - 1 - RAND_INT( 7 ), 64 );
         elsif u < 0.98 then return to_unsigned( BASE + ZONE - n + 1 + RAND_INT( 6 ), 64 );
         else return x"8000000000001000";
         end if;
      end function;

   begin
      s2 := SEED_2;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      loop
         now := now + 1;
         exit when final_phase and final_addr >= ZONE and fn( 0 ) = 0;

		-- requêtes du cycle (retirées au hasard si elles ne sont pas acceptées)
         for p in 0 to PORTS - 1 loop
            rq( p ) := NO_MEM_REQUEST;
            if final_phase then
               if p = 0 and final_addr < ZONE then
                  rq( 0 ) := ( valid => '1', write => '0', probe => '0', address => to_unsigned( BASE + final_addr, 64 ),
                               size => "11", wdata => ( others => '0' ) );
               end if;
            elsif RAND < 0.5 then
               rq( p ).valid := '1';
               rq( p ).size := to_unsigned( RAND_INT( 3 ), 2 );
               nb := 2 ** to_integer( rq( p ).size );
               rq( p ).address := DRAW_ADDR( nb );
               rq( p ).wdata := std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) )
                                & std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) );
               case RAND_INT( 19 ) is
                  when 0 to 9   => null;						-- lecture
                  when 10 to 16 => rq( p ).write := '1';
                  when others   => rq( p ).probe := '1';
               end case;
            end if;
         end loop;
         req <= rq;
         wait for 1 ns;
         acc := ready;

		-- réponses : dans l'ordre de chaque port
         for p in 0 to PORTS - 1 loop
            if rsp( p ).valid = '1' then
               if fn( p ) = 0 then
                  CHECK( c, false, "cycle " & integer'image( now ) & ", port " & integer'image( p ) & " : réponse sans requête" );
               else
                  e := fifo( p )( fh( p ) );
                  fh( p ) := ( fh( p ) + 1 ) mod FCAP; fn( p ) := fn( p ) - 1;
                  got := rsp( p ).rdata;
                  if rsp( p ).fault = e.fault
                     and ( e.kind /= 0 or e.fault = '1' or ( got and e.mask ) = ( e.data and e.mask ) ) then
                     CHECK_PASSED( c );
                  else
                     CHECK( c, false, "cycle " & integer'image( now ) & ", port " & integer'image( p )
                                      & ", requête du cycle " & integer'image( e.since ),
                            "faute " & std_logic'image( e.fault ) & " donnée " & HEX( e.data ),
                            "faute " & std_logic'image( rsp( p ).fault ) & " donnée " & HEX( got ) );
                  end if;
                  n_checked := n_checked + 1;
               end if;
            end if;
            if fn( p ) > 0 and now - fifo( p )( fh( p ) ).since > MAX_WAIT then
               CHECK( c, false, "port " & integer'image( p ) & " : pas de réponse après " & integer'image( MAX_WAIT )
                                & " cycles" );
               fh( p ) := ( fh( p ) + 1 ) mod FCAP; fn( p ) := fn( p ) - 1;
            end if;
         end loop;

		-- front : requêtes acceptées ; la référence suit les écritures de ce front
         wait until rising_edge( clk );
         before := ref;
         for p in 0 to PORTS - 1 loop
            if rq( p ).valid = '1' and acc( p ) = '1' then
               nb := 2 ** to_integer( rq( p ).size );
               off := to_integer( rq( p ).address( 30 downto 0 ) ) - BASE;
               valid_acc := rq( p ).address( 63 downto 31 ) = 0 and off >= 0 and off + nb <= ZONE;
               e := ( kind => 0, fault => '0', data => ( others => '0' ), mask => ( others => '0' ), since => now );
               if not valid_acc then e.fault := '1'; n_faults := n_faults + 1; end if;
               if valid_acc and ( off / 32 ) /= ( ( off + nb - 1 ) / 32 ) then n_cross := n_cross + 1; end if;
               if rq( p ).probe = '1' then
                  e.kind := 2; n_probes := n_probes + 1;
               elsif rq( p ).write = '1' then
                  e.kind := 1; n_writes := n_writes + 1;
                  if valid_acc then
                     for i in 0 to nb - 1 loop ref( off + i ) := rq( p ).wdata( 8 * i + 7 downto 8 * i ); end loop;
                  end if;
               else
                  n_reads := n_reads + 1;
                  e.mask := ( others => '1' );					-- octets hauts : nuls
                  if valid_acc then
                     for i in 0 to nb - 1 loop e.data( 8 * i + 7 downto 8 * i ) := before( off + i ); end loop;
                     -- un octet écrit à ce même front par un autre port : non vérifié
                     for q2 in 0 to PORTS - 1 loop
                        if q2 /= p and rq( q2 ).valid = '1' and acc( q2 ) = '1' and rq( q2 ).write = '1' then
                           a := to_integer( rq( q2 ).address( 30 downto 0 ) ) - BASE;
                           for i in 0 to nb - 1 loop
                              if off + i >= a and off + i < a + 2 ** to_integer( rq( q2 ).size ) then
                                 e.mask( 8 * i + 7 downto 8 * i ) := ( others => '0' ); n_same_edge := n_same_edge + 1;
                              end if;
                           end loop;
                        end if;
                     end loop;
                  end if;
               end if;
               fifo( p )( ( fh( p ) + fn( p ) ) mod FCAP ) := e;
               fn( p ) := fn( p ) + 1;
               if final_phase and p = 0 then final_addr := final_addr + 8; end if;
            end if;
         end loop;
         if not final_phase and now >= CYCLES and fn( 0 ) + fn( 1 ) + fn( 2 ) + fn( 3 ) = 0 then
            final_phase := true;						-- relecture de toute la zone
         end if;
         if now > CYCLES + 20 * ZONE then
            CHECK( c, false, "relecture finale inachevée" );
            exit;
         end if;
         wait until falling_edge( clk );
      end loop;

      CHECK( c, mem_errors = 0, "protocole côté mémoire respecté" );
      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; réponses vérifiées "
             & integer'image( n_checked ) & " (lectures " & integer'image( n_reads ) & ", écritures "
             & integer'image( n_writes ) & ", sondages " & integer'image( n_probes ) & ", hors zone "
             & integer'image( n_faults ) & ", à cheval sur deux lignes " & integer'image( n_cross )
             & ", octets non vérifiés (même front) " & integer'image( n_same_edge ) & ") ; mémoire : mots lus "
             & integer'image( d_reads ) & ", écrits " & integer'image( d_writes ) severity note;
      CHECK( c, n_checked > 8000 and n_faults > 500 and n_cross > 500 and d_writes > 3000 and d_reads > 6000,
             "le tirage a exercé fautes, accès à cheval, défauts et réécritures" );
      FINISH( c, "T_M3_DATA_CACHE_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
