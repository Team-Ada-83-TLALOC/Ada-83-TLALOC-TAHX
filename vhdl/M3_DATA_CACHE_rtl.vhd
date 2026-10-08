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
use work.MEMORY_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  DATA_CACHE, architecture RTL : chemin rapide (succès, sur tous les ports, réponse
		--  au cycle suivant) et chemin lent (défaut, accès à cheval : un à la fois).
		--
		--  LIBRE      un port est choisi à tour de rôle parmi ceux qui présentent une
		--             requête ; READY_o( p ) = '1' pour lui seul ; la requête prise au
		--             front est contrôlée (validité) : sondage ou faute, réponse tout de
		--             suite ; sinon première partie (jusqu'à la fin de sa ligne).
		--  PARTIE     ligne présente : lecture ou écriture des octets de la partie,
		--             puis partie suivante ou réponse ; absente : victime (une voie
		--             libre, sinon la suivante à tour de rôle), RECRITURE si elle est
		--             modifiée, puis REMPLISSAGE.
		--  RECRITURE  les mots de la victime, écritures postées.
		--  REMPLISSAGE les mots de la ligne, lectures dans l'ordre ; faute : réponse en
		--             faute, ligne non rangée ; sinon rangée, retour en PARTIE.
		--  REPONSE    RSP_o( port ) pendant un cycle.
		--  Servir une seule requête à la fois satisfait par construction l'ordre de
		--  chaque port et la visibilité des écritures entre ports.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of DATA_CACHE is		---

   constant SETS		: positive := SIZE_BYTES_G / ( LINE_BYTES_G * WAYS_G );
   constant WORDS		: positive := LINE_BYTES_G / 8;

   type line_t			is array( 0 to LINE_BYTES_G - 1 ) of byte_t;
   type data_array_t		is array( 0 to SETS * WAYS_G - 1 ) of line_t;
   type tag_array_t		is array( 0 to SETS * WAYS_G - 1 ) of address_t;	-- adresse de la ligne
   type rr_array_t		is array( 0 to SETS - 1 ) of natural range 0 to WAYS_G - 1;

   type state_t		is ( LIBRE, PARTIE, RECRITURE, REMPLISSAGE, REPONSE );

   signal data			: data_array_t;
   signal tags			: tag_array_t;
   signal present, dirty	: std_logic_vector( 0 to SETS * WAYS_G - 1 );
   signal rr			: rr_array_t;

   signal state		: state_t;
   signal port_rr		: natural range 0 to PORTS_G - 1;		-- prochain port servi
   signal pick			: integer range -1 to PORTS_G - 1;		-- port choisi (LIBRE)
   signal cur_port		: natural range 0 to PORTS_G - 1;
   signal cur			: mem_request_t;
   signal part_addr		: address_t;				-- partie en cours
   signal part_n		: natural range 0 to 8;
   signal done_n		: natural range 0 to 8;			-- octets déjà servis
   signal rest_n		: natural range 0 to 8;			-- octets de la partie suivante
   signal result		: word64_t;
   signal result_fault		: std_logic;
   signal victim		: natural range 0 to SETS * WAYS_G - 1;
   signal line_addr		: address_t;				-- ligne à remplir
   signal issued, received	: natural range 0 to WORDS;
   signal fill			: line_t;
   signal fill_fault		: std_logic;

   -- chemin rapide : succès, adresse invalide ou sondage, sur tous les ports à la fois
   type hit_array_t		is array( 0 to PORTS_G - 1 ) of integer range -1 to SETS * WAYS_G - 1;
   signal fast			: std_logic_vector( 0 to PORTS_G - 1 );	-- acceptée par le chemin rapide
   signal fast_hit		: hit_array_t;				-- sa ligne (-1 : invalide, sondage)
   signal frsp			: mem_response_bus_t( 0 to PORTS_G - 1 );	-- réponses rapides, registrées

   function LINE_OF( a : address_t ) return address_t is
   begin
      return a - ( a mod LINE_BYTES_G );
   end function;

   function SET_OF( a : address_t ) return natural is
   begin
      return to_integer( ( a / LINE_BYTES_G ) mod SETS );
   end function;

   function VALID_ACCESS( a : address_t; n : natural ) return boolean is
   begin
      return a >= VALID_BASE_G and a <= VALID_LIMIT_G - n and VALID_LIMIT_G >= n;
   end function;

begin

		--------------------------------------------------------------------------------
		-- Choix du port (LIBRE) et sorties
		--------------------------------------------------------------------------------

   -- Au repos : chaque port dont la requête touche une ligne présente (sans être à
   -- cheval), ou dont l'adresse est invalide, ou qui sonde, est accepté par le chemin
   -- rapide (réponse au cycle suivant) ; deux écritures sur une même ligne ne le sont
   -- pas au même cycle. Une seule autre requête (défaut, à cheval) prend le chemin lent,
   -- qui bloque toute acceptation tant qu'il travaille.
   CHOIX : process( state, REQ_i, port_rr, present, tags )
      variable p, n		: natural;
      variable h		: integer;
      variable slow_taken	: boolean;
      variable slow_write	: boolean;
      variable written		: hit_array_t;
      variable nw		: natural;
      variable clash		: boolean;
      variable f		: std_logic_vector( 0 to PORTS_G - 1 );
      variable fh		: hit_array_t;
      variable pk		: integer;
      variable a		: address_t;
   begin
      f := ( others => '0' ); fh := ( others => -1 ); pk := -1;
      slow_taken := false; slow_write := false; nw := 0; written := ( others => -1 );
      if state = LIBRE then
         for k in 0 to PORTS_G - 1 loop
            p := ( port_rr + k ) mod PORTS_G;
            if REQ_i( p ).valid = '1' then
               a := REQ_i( p ).address;
               n := 2 ** to_integer( REQ_i( p ).size );
               h := -1;
               if not VALID_ACCESS( a, n ) or REQ_i( p ).probe = '1' then
                  f( p ) := '1';						-- faute ou sondage : sans ligne
               elsif to_integer( a mod LINE_BYTES_G ) + n <= LINE_BYTES_G then
                  for wy in 0 to WAYS_G - 1 loop
                     if present( SET_OF( a ) * WAYS_G + wy ) = '1'
                        and tags( SET_OF( a ) * WAYS_G + wy ) = LINE_OF( a ) then
                        h := SET_OF( a ) * WAYS_G + wy;
                     end if;
                  end loop;
               end if;
               if f( p ) = '0' and h >= 0 then
                  clash := false;
                  for j in 0 to PORTS_G - 1 loop
                     if j < nw and written( j ) = h then clash := true; end if;
                  end loop;
                  -- une écriture rapide ni sur une ligne déjà écrite ce cycle, ni à côté
                  -- d'une écriture lente (deux écritures d'un même front, sans ordre fixé)
                  if not ( REQ_i( p ).write = '1' and ( clash or slow_write ) ) then
                     f( p ) := '1'; fh( p ) := h;
                     if REQ_i( p ).write = '1' then written( nw ) := h; nw := nw + 1; end if;
                  end if;
               elsif f( p ) = '0' and not slow_taken and not ( REQ_i( p ).write = '1' and nw > 0 ) then
                  pk := p; slow_taken := true;				-- défaut ou à cheval : chemin lent
                  slow_write := REQ_i( p ).write = '1';
               end if;
            end if;
         end loop;
      end if;
      fast <= f; fast_hit <= fh; pick <= pk;
   end process;

   PRETS : process( pick, fast )
   begin
      for p in 0 to PORTS_G - 1 loop
         if pick = p or fast( p ) = '1' then READY_o( p ) <= '1'; else READY_o( p ) <= '0'; end if;
      end loop;
   end process;

   REPONSES : process( state, cur_port, result, result_fault, frsp )
   begin
      for p in 0 to PORTS_G - 1 loop
         RSP_o( p ) <= frsp( p );
         if state = REPONSE and p = cur_port then
            RSP_o( p ) <= ( valid => '1', rdata => result, fault => result_fault );
         end if;
      end loop;
   end process;

   MEMOIRE : process( state, issued, victim, tags, data, line_addr )
      variable w : word64_t;
   begin
      D_REQ_o <= '0'; D_WRITE_o <= '0'; D_SIZE_o <= "11"; D_WSTRB_o <= ( others => '1' );
      D_ADDR_o <= ( others => '0' ); D_WDATA_o <= ( others => '0' );
      if state = RECRITURE and issued < WORDS then
         for i in 0 to 7 loop
            w( 8 * i + 7 downto 8 * i ) := data( victim )( 8 * issued + i );
         end loop;
         D_REQ_o <= '1'; D_WRITE_o <= '1';
         D_ADDR_o <= tags( victim ) + 8 * issued;
         D_WDATA_o <= w;
      elsif state = REMPLISSAGE and issued < WORDS then
         D_REQ_o <= '1';
         D_ADDR_o <= line_addr + 8 * issued;
      end if;
   end process;

		--------------------------------------------------------------------------------
		-- Automate
		--------------------------------------------------------------------------------

   AUTOMATE : process( CLK_i )
      variable n, first_n	: natural;
      variable s, base, way	: natural;
      variable hit		: integer;
      variable off		: natural;
      variable r		: word64_t;
      variable ln		: line_t;
   begin
      if rising_edge( CLK_i ) then
         frsp <= ( others => NO_MEM_RESPONSE );				-- un cycle
         if RESET_i = '1' then
            state <= LIBRE;
            present <= ( others => '0' );
            dirty <= ( others => '0' );
            rr <= ( others => 0 );
            port_rr <= 0;
         else
            case state is

               when LIBRE =>
                  -- chemin rapide : lecture ou écriture de la ligne présente, réponse au cycle suivant
                  for p in 0 to PORTS_G - 1 loop
                     if fast( p ) = '1' then
                        n := 2 ** to_integer( REQ_i( p ).size );
                        if not VALID_ACCESS( REQ_i( p ).address, n ) then
                           frsp( p ) <= ( valid => '1', rdata => ( others => '0' ), fault => '1' );
                        elsif REQ_i( p ).probe = '1' then
                           frsp( p ) <= ( valid => '1', rdata => ( others => '0' ), fault => '0' );
                        else
                           off := to_integer( REQ_i( p ).address mod LINE_BYTES_G );
                           if REQ_i( p ).write = '1' then
                              ln := data( fast_hit( p ) );
                              for i in 0 to 7 loop
                                 if i < n then ln( off + i ) := REQ_i( p ).wdata( 8 * i + 7 downto 8 * i ); end if;
                              end loop;
                              data( fast_hit( p ) ) <= ln;
                              dirty( fast_hit( p ) ) <= '1';
                              frsp( p ) <= ( valid => '1', rdata => ( others => '0' ), fault => '0' );
                           else
                              r := ( others => '0' );
                              for i in 0 to 7 loop
                                 if i < n then r( 8 * i + 7 downto 8 * i ) := data( fast_hit( p ) )( off + i ); end if;
                              end loop;
                              frsp( p ) <= ( valid => '1', rdata => r, fault => '0' );
                           end if;
                        end if;
                     end if;
                  end loop;
                  if pick >= 0 then
                     cur <= REQ_i( pick );
                     cur_port <= pick;
                     port_rr <= ( pick + 1 ) mod PORTS_G;
                     n := 2 ** to_integer( REQ_i( pick ).size );
                     result <= ( others => '0' );
                     done_n <= 0;
                     if not VALID_ACCESS( REQ_i( pick ).address, n ) then
                        result_fault <= '1';
                        state <= REPONSE;
                     elsif REQ_i( pick ).probe = '1' then
                        result_fault <= '0';
                        state <= REPONSE;
                     else
                        result_fault <= '0';
                        first_n := LINE_BYTES_G - to_integer( REQ_i( pick ).address mod LINE_BYTES_G );
                        if first_n > n then first_n := n; end if;
                        part_addr <= REQ_i( pick ).address;
                        part_n <= first_n;
                        rest_n <= n - first_n;
                        state <= PARTIE;
                     end if;
                  end if;

               when PARTIE =>
                  s := SET_OF( part_addr );
                  base := s * WAYS_G;
                  hit := -1;
                  for wy in 0 to WAYS_G - 1 loop
                     if present( base + wy ) = '1' and tags( base + wy ) = LINE_OF( part_addr ) then
                        hit := base + wy;
                     end if;
                  end loop;
                  if hit >= 0 then
                     off := to_integer( part_addr mod LINE_BYTES_G );
                     if cur.write = '1' then
                        ln := data( hit );
                        for i in 0 to 7 loop
                           if i < part_n then
                              ln( off + i ) := cur.wdata( 8 * ( done_n + i ) + 7 downto 8 * ( done_n + i ) );
                           end if;
                        end loop;
                        data( hit ) <= ln;
                        dirty( hit ) <= '1';
                     else
                        r := result;
                        for i in 0 to 7 loop
                           if i < part_n then
                              r( 8 * ( done_n + i ) + 7 downto 8 * ( done_n + i ) ) := data( hit )( off + i );
                           end if;
                        end loop;
                        result <= r;
                     end if;
                     if rest_n > 0 then						-- seconde partie : ligne suivante
                        part_addr <= LINE_OF( part_addr ) + LINE_BYTES_G;
                        done_n <= done_n + part_n;
                        part_n <= rest_n;
                        rest_n <= 0;
                     else
                        state <= REPONSE;
                     end if;
                  else
                     -- défaut : victime = une voie libre, sinon la suivante à tour de rôle
                     way := rr( s );
                     for wy in WAYS_G - 1 downto 0 loop
                        if present( base + wy ) = '0' then way := wy; end if;
                     end loop;
                     victim <= base + way;
                     rr( s ) <= ( rr( s ) + 1 ) mod WAYS_G;
                     line_addr <= LINE_OF( part_addr );
                     issued <= 0; received <= 0; fill_fault <= '0';
                     if present( base + way ) = '1' and dirty( base + way ) = '1' then
                        state <= RECRITURE;
                     else
                        state <= REMPLISSAGE;
                     end if;
                  end if;

               when RECRITURE =>
                  if D_READY_i = '1' then
                     if issued = WORDS - 1 then
                        dirty( victim ) <= '0';
                        issued <= 0;
                        state <= REMPLISSAGE;
                     else
                        issued <= issued + 1;
                     end if;
                  end if;

               when REMPLISSAGE =>
                  if issued < WORDS and D_READY_i = '1' then
                     issued <= issued + 1;
                  end if;
                  if D_RVALID_i = '1' then
                     ln := fill;
                     for i in 0 to 7 loop
                        ln( 8 * received + i ) := D_RDATA_i( 8 * i + 7 downto 8 * i );
                     end loop;
                     fill <= ln;
                     if received = WORDS - 1 then
                        if fill_fault = '1' or D_FAULT_i = '1' then
                           result_fault <= '1';					-- ligne non rangée
                           present( victim ) <= '0';
                           state <= REPONSE;
                        else
                           data( victim ) <= ln;
                           tags( victim ) <= line_addr;
                           present( victim ) <= '1';
                           dirty( victim ) <= '0';
                           state <= PARTIE;
                        end if;
                     else
                        received <= received + 1;
                        if D_FAULT_i = '1' then fill_fault <= '1'; end if;
                     end if;
                  end if;

               when REPONSE =>
                  state <= LIBRE;

            end case;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
