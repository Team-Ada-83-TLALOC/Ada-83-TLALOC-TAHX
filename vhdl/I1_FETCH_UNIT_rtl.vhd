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

		--------------------------------------------------------------------------------
		--  FETCH_UNIT, architecture RTL : modèle de référence.
		--
		--  Cache d'instructions à correspondance directe, LINES lignes de 32 octets
		--  (16 Kio) ; une ligne présente sert le bloc du PC dans le cycle.
		--  Défaut : une ligne à la fois ; ses quatre mots sont demandés puis rangés à
		--  l'arrivée du dernier. Un remplissage commencé va jusqu'au bout, même après
		--  une redirection (toute requête acceptée reçoit sa réponse), et la ligne est
		--  rangée : elle servira peut-être. Une ligne en faute n'est pas rangée : un
		--  registre la retient et le bloc part avec FETCH_FAULT_o, sans relecture.
		--  Préchargement : moteur libre et ligne du PC présente, la première des deux
		--  lignes suivantes qui manque est remplie (pas une ligne connue en faute).
		--  Une réalisation (plusieurs défauts en vol, lecture de mot critique d'abord)
		--  devra passer le même banc (tests/I1_FETCH_UNIT).
		--------------------------------------------------------------------------------


				---
architecture			RTL
of FETCH_UNIT is		---

   constant LINES		: positive := 512;
   constant WORDS		: positive := FETCH_BLOCK_SIZE / 8;			-- 4 mots par ligne

   type data_array_t		is array( 0 to LINES - 1 ) of fetch_block_t;
   type tag_array_t		is array( 0 to LINES - 1 ) of address_t;		-- adresse de la ligne

   signal data		: data_array_t;
   signal tag			: tag_array_t;
   signal present		: std_logic_vector( 0 to LINES - 1 );

   signal pc			: address_t;
   signal active		: std_logic;

   signal fault_valid		: std_logic;					-- dernière ligne en faute
   signal fault_line		: address_t;

   signal filling		: std_logic;					-- remplissage en cours
   signal fill_line		: address_t;
   signal fill_data		: fetch_block_t;
   signal fill_fault		: std_logic;
   signal req_k, resp_k	: natural range 0 to WORDS;

   signal line_base		: address_t;
   signal index		: natural range 0 to LINES - 1;
   signal hit, faulty_hit	: std_logic;
   signal next1, next2		: address_t;					-- préchargement : les deux
   signal miss1, miss2		: std_logic;					--  lignes qui suivent
   signal redirect		: std_logic;
   signal show			: std_logic;

   function LINE_OF( a : address_t ) return address_t is
   begin
      return a( a'high downto 5 ) & "00000";
   end function;

   function INDEX_OF( a : address_t ) return natural is
   begin
      return to_integer( a( 13 downto 5 ) );				-- LINES = 512
   end function;

begin

   assert LINES = 512 report "FETCH_UNIT : INDEX_OF suppose 512 lignes" severity failure;

		--------------------------------------------------------------------------------
		-- Dans le cycle : ligne du PC, présentation, redirection
		--------------------------------------------------------------------------------

   line_base	<= LINE_OF( pc );
   index		<= INDEX_OF( pc );
   hit		<= '1' when present( index ) = '1' and tag( index ) = line_base else '0';
   faulty_hit	<= '1' when fault_valid = '1' and fault_line = line_base else '0';
   redirect	<= RECOVERY_i.valid or PREDICT_VALID_i or STOP_i;
   next1		<= line_base + FETCH_BLOCK_SIZE;
   next2		<= line_base + 2 * FETCH_BLOCK_SIZE;
   miss1		<= '1' when ( present( INDEX_OF( next1 ) ) = '0' or tag( INDEX_OF( next1 ) ) /= next1 )
			   and not ( fault_valid = '1' and fault_line = next1 ) else '0';
   miss2		<= '1' when ( present( INDEX_OF( next2 ) ) = '0' or tag( INDEX_OF( next2 ) ) /= next2 )
			   and not ( fault_valid = '1' and fault_line = next2 ) else '0';
   show		<= active and ( hit or faulty_hit ) and not redirect;

   FLUSH_o		<= redirect;
   FETCH_VALID_o	<= show;
   FETCH_PC_o		<= pc;
   FETCH_COUNT_o	<= to_unsigned( FETCH_BLOCK_SIZE - to_integer( pc( 4 downto 0 ) ), FETCH_COUNT_o'length );
   FETCH_FAULT_o	<= faulty_hit and not hit;

   BLOC : process( pc, data, index )
      variable off : natural range 0 to FETCH_BLOCK_SIZE - 1;
   begin
      off := to_integer( pc( 4 downto 0 ) );
      for i in 0 to FETCH_BLOCK_SIZE - 1 loop
         if off + i < FETCH_BLOCK_SIZE then
            FETCH_BLOCK_o( i ) <= data( index )( off + i );
         else
            FETCH_BLOCK_o( i ) <= ( others => '0' );
         end if;
      end loop;
   end process;

   I_REQ_o		<= '1' when filling = '1' and req_k < WORDS else '0';
   I_ADDR_o		<= fill_line + 8 * req_k;

		--------------------------------------------------------------------------------
		-- Au front : remplissage, défaut, PC
		--------------------------------------------------------------------------------

   CHARGEMENT : process( CLK_i )
      variable fd	: fetch_block_t;
      variable ff	: std_logic;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            active <= '0';
            present <= ( others => '0' );
            fault_valid <= '0';
            filling <= '0';
            req_k <= 0;
            resp_k <= 0;
         else

            -- remplissage : requêtes acceptées, réponses rangées
            if filling = '1' then
               if req_k < WORDS and I_READY_i = '1' then
                  req_k <= req_k + 1;
               end if;
               if I_RVALID_i = '1' then
                  fd := fill_data;
                  for j in 0 to 7 loop
                     fd( 8 * resp_k + j ) := I_RDATA_i( 8 * j + 7 downto 8 * j );
                  end loop;
                  ff := fill_fault or I_FAULT_i;
                  fill_data <= fd;
                  fill_fault <= ff;
                  if resp_k = WORDS - 1 then				-- dernier mot : la ligne est complète
                     filling <= '0';
                     resp_k <= 0;
                     if ff = '1' then
                        fault_valid <= '1';
                        fault_line <= fill_line;
                     else
                        data( INDEX_OF( fill_line ) ) <= fd;
                        tag( INDEX_OF( fill_line ) ) <= fill_line;
                        present( INDEX_OF( fill_line ) ) <= '1';
                     end if;
                  else
                     resp_k <= resp_k + 1;
                  end if;
               end if;

            -- défaut : la ligne du PC manque, pas de redirection ce cycle
            elsif active = '1' and hit = '0' and faulty_hit = '0' and redirect = '0' then
               filling <= '1';
               fill_line <= line_base;
               fill_fault <= '0';
               req_k <= 0;
               resp_k <= 0;

            -- préchargement : la ligne du PC est là, le moteur est libre ; la première des
            -- deux lignes suivantes qui manque (une ligne connue en faute n'est pas reprise)
            elsif active = '1' and hit = '1' and redirect = '0' and ( miss1 = '1' or miss2 = '1' ) then
               filling <= '1';
               if miss1 = '1' then fill_line <= next1; else fill_line <= next2; end if;
               fill_fault <= '0';
               req_k <= 0;
               resp_k <= 0;
            end if;

            -- PC
            if RECOVERY_i.valid = '1' then
               pc <= RECOVERY_i.new_pc;
               active <= '1';
            elsif PREDICT_VALID_i = '1' then
               pc <= PREDICT_PC_i;
            elsif STOP_i = '1' then
               active <= '0';
            elsif show = '1' and FETCH_READY_i = '1' then
               pc <= line_base + FETCH_BLOCK_SIZE;
            end if;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
