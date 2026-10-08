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

		--------------------------------------------------------------------------------
		--  MEMOIRE_DONNEES_PKG : la mémoire de données des bancs.
		--    Zone valide : [DATA_BASE, DATA_BASE + DATA_SIZE) ; tout autre octet est
		--    invalide (faute 132).
		--    Contenu initial (INITIAL_BYTE) : les POINTER_WORDS premiers mots de 64
		--    bits sont des pointeurs vers la zone (accès de la famille C) ; le reste est
		--    fonction de l'adresse.
		--------------------------------------------------------------------------------

				-------------------
package				MEMOIRE_DONNEES_PKG
is				-------------------

   constant DATA_BASE		: natural := 16#10000#;
   constant DATA_SIZE		: natural := 4096;
   constant POINTER_WORDS	: natural := 32;

   type data_memory_t		is array( 0 to DATA_SIZE - 1 ) of byte_t;

   function IN_ZONE( a : address_t; n : positive ) return boolean;		-- n octets dès a
   function INITIAL_BYTE( offset : natural ) return byte_t;			-- offset dans la zone
   function INITIAL_MEMORY return data_memory_t;

end package			MEMOIRE_DONNEES_PKG;


package body			MEMOIRE_DONNEES_PKG
is

   function IN_ZONE( a : address_t; n : positive ) return boolean is
   begin
      return a( 63 downto 31 ) = 0
             and to_integer( a( 30 downto 0 ) ) >= DATA_BASE
             and to_integer( a( 30 downto 0 ) ) + n <= DATA_BASE + DATA_SIZE;
   end function;

   function INITIAL_BYTE( offset : natural ) return byte_t is
      variable p : natural;
   begin
      if offset < 8 * POINTER_WORDS then					-- pointeur vers la zone
         p := DATA_BASE + 8 * POINTER_WORDS + ( ( offset / 8 ) * 104729 ) mod ( DATA_SIZE - 8 * POINTER_WORDS - 16 );
         if offset mod 8 >= 4 then						-- p < 2^31 : octets hauts nuls
            return x"00";
         end if;
         return std_logic_vector( to_unsigned( ( p / 2 ** ( 8 * ( offset mod 8 ) ) ) mod 256, 8 ) );
      end if;
      return std_logic_vector( to_unsigned( ( offset * 151 + ( offset / 256 ) * 89 + 7 ) mod 256, 8 ) );
   end function;

   function INITIAL_MEMORY return data_memory_t is
      variable m : data_memory_t;
   begin
      for i in m'range loop
         m( i ) := INITIAL_BYTE( i );
      end loop;
      return m;
   end function;

end package body		MEMOIRE_DONNEES_PKG;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.EXEC_TYPES.all;
use work.BACKEND_TYPES.all;
use work.MEMOIRE_DONNEES_PKG.all;

		--------------------------------------------------------------------------------
		--  MODELE_CACHE_DONNEES : le contrat de DATA_CACHE, côté machine, pour les
		--  bancs. PORTS_G ports ; READY_o tiré au hasard ; une requête acceptée lit ou
		--  écrit la mémoire au front de son acceptation (une requête voit les écritures
		--  acceptées à un front antérieur, quel que soit leur port) ; sa réponse arrive
		--  dans l'ordre des requêtes de son port, après une latence tirée dans
		--  [LATENCY_MIN_G, LATENCY_MAX_G]. Lecture, écriture, sondage (probe) ; faute si
		--  un octet sort de la zone ; une écriture en faute n'écrit rien.
		--  MEMORY_o : contenu de la zone (vérification des écritures par les bancs) ;
		--  ACCEPTED_o : requêtes acceptées, lectures, écritures, sondages.
		--------------------------------------------------------------------------------

				--------------------
entity				MODELE_CACHE_DONNEES
is				--------------------
   generic (
      PORTS_G		: positive := 2;
      LATENCY_MIN_G	: positive := 1;
      LATENCY_MAX_G	: positive := 8;
      READY_PROB_G	: real := 0.8;
      SEED_1_G		: positive := 1;
      SEED_2_G		: positive := 2
   );
   port (
      CLK_i		: in  std_logic;
      REQ_i		: in  mem_request_bus_t( 0 to PORTS_G - 1 );
      READY_o		: out std_logic_vector( 0 to PORTS_G - 1 ) := ( others => '0' );
      RSP_o		: out mem_response_bus_t( 0 to PORTS_G - 1 ) := ( others => NO_MEM_RESPONSE );
      MEMORY_o		: out data_memory_t := INITIAL_MEMORY;
      READS_o, WRITES_o, PROBES_o : out natural := 0
   );
end entity			MODELE_CACHE_DONNEES;


architecture			MODELE
of MODELE_CACHE_DONNEES is
begin

   process
      constant CAPACITY	: positive := 64;
      type pending_t	is record
			  rsp	: mem_response_t;
			  due	: natural;
			end record;
      type queue_t	is array( 0 to CAPACITY - 1 ) of pending_t;
      type queue_array_t	is array( 0 to PORTS_G - 1 ) of queue_t;
      type nat_array_t	is array( 0 to PORTS_G - 1 ) of natural;
      variable q		: queue_array_t;
      variable head, n, last_due : nat_array_t := ( others => 0 );
      variable mem		: data_memory_t := INITIAL_MEMORY;
      variable now	: natural := 0;
      variable s1		: positive := SEED_1_G;
      variable s2		: positive := SEED_2_G;
      variable r		: real;
      variable ready	: std_logic_vector( 0 to PORTS_G - 1 );
      variable req	: mem_request_t;
      variable rsp	: mem_response_t;
      variable nb, off	: natural;
      variable reads, writes, probes : natural := 0;
      variable wrote	: boolean := false;
   begin
      wait until falling_edge( CLK_i );
      loop
         now := now + 1;
         -- réponses du cycle : la plus ancienne de chaque port, si elle est échue
         for p in 0 to PORTS_G - 1 loop
            if n( p ) > 0 and q( p )( head( p ) ).due <= now then
               RSP_o( p ) <= q( p )( head( p ) ).rsp;
               head( p ) := ( head( p ) + 1 ) mod CAPACITY;
               n( p ) := n( p ) - 1;
            else
               RSP_o( p ) <= NO_MEM_RESPONSE;
            end if;
            uniform( s1, s2, r );
            if r < READY_PROB_G and n( p ) < CAPACITY then ready( p ) := '1'; else ready( p ) := '0'; end if;
         end loop;
         READY_o <= ready;

         -- front : requêtes acceptées, lues ou écrites tout de suite
         wait until rising_edge( CLK_i );
         for p in 0 to PORTS_G - 1 loop
            req := REQ_i( p );
            if req.valid = '1' and ready( p ) = '1' then
               nb := 2 ** to_integer( req.size );
               rsp := ( valid => '1', rdata => ( others => '0' ), fault => '0' );
               if not IN_ZONE( req.address, nb ) then
                  rsp.fault := '1';
               else
                  off := to_integer( req.address( 30 downto 0 ) ) - DATA_BASE;
                  if req.probe = '1' then
                     probes := probes + 1;
                  elsif req.write = '1' then
                     for i in 0 to nb - 1 loop
                        mem( off + i ) := req.wdata( 8 * i + 7 downto 8 * i );
                     end loop;
                     writes := writes + 1;
                     wrote := true;
                  else
                     for i in 0 to nb - 1 loop
                        rsp.rdata( 8 * i + 7 downto 8 * i ) := mem( off + i );
                     end loop;
                     reads := reads + 1;
                  end if;
               end if;
               uniform( s1, s2, r );
               last_due( p ) := maximum( last_due( p ) + 1,
                                         now + LATENCY_MIN_G
                                         + integer( trunc( r * real( LATENCY_MAX_G - LATENCY_MIN_G + 1 ) ) ) );
               q( p )( ( head( p ) + n( p ) ) mod CAPACITY ) := ( rsp => rsp, due => last_due( p ) );
               n( p ) := n( p ) + 1;
            end if;
         end loop;
         if wrote then							-- recopie seulement après une écriture
            MEMORY_o <= mem;
            wrote := false;
         end if;
         READS_o <= reads; WRITES_o <= writes; PROBES_o <= probes;
         wait until falling_edge( CLK_i );
      end loop;
   end process;

end architecture		MODELE;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
