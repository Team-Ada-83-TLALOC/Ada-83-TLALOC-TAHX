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
use work.TAHX_1_ISA_TABLE.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;

		--------------------------------------------------------------------------------
		--  ISSUE_QUEUE, architecture RTL : modèle de référence.
		--
		--  QUEUE_DEPTH_G entrées, sans ordre : l'âge se lit dans rob_index. L'état est
		--  réparti pour la simulation comme il le serait en matériel : le contenu des
		--  instructions n'est écrit qu'à l'insertion, entrée par entrée ; les bits
		--  « valide » et « prêt » changent à chaque cycle ; le bus de réveil est d'abord
		--  rangé dans une table indexée par étiquette. Dans le cycle : éligibilité de chaque entrée, puis
		--  ISSUE_WIDTH_G recherches du plus ancien (éligible, ou, dans l'ordre, du plus
		--  ancien tout court tant qu'il est éligible). Au front : départ des émises,
		--  reprise, réveil des bits rangés, insertion dans les entrées libres au début
		--  du cycle. Une réalisation (matrice d'âge, arbre de sélection) devra passer le
		--  même banc (tests/K_ISSUE_QUEUE).
		--------------------------------------------------------------------------------


				---
architecture			RTL
of ISSUE_QUEUE is		---

   constant TAGS		: positive := 2 ** PHYSICAL_TAG_BITS;

   subtype ready_t		is std_logic_vector( 0 to MAX_SOURCE_COUNT - 1 );
   type ins_array_t		is array( 0 to QUEUE_DEPTH_G - 1 ) of renamed_instruction_t;
   type ready_array_t		is array( 0 to QUEUE_DEPTH_G - 1 ) of ready_t;
   type index_array_t		is array( 0 to ISSUE_WIDTH_G - 1 ) of natural range 0 to QUEUE_DEPTH_G - 1;
   type age_array_t		is array( 0 to QUEUE_DEPTH_G - 1 ) of natural range 0 to ROB_SIZE - 1;
   type wake_map_t		is array( 0 to TAGS - 1 ) of boolean;

   signal payload		: ins_array_t;				-- écrit à l'insertion
   signal valid		: std_logic_vector( 0 to QUEUE_DEPTH_G - 1 );
   signal ready		: ready_array_t;
   signal pick			: index_array_t;			-- entrées présentées, par âge
   signal npick		: natural range 0 to ISSUE_WIDTH_G;

   -- bits « prêt » après le réveil du cycle
   function WAKE( ins : renamed_instruction_t; r0 : ready_t; wmap : wake_map_t ) return ready_t is
      variable r : ready_t := r0;
   begin
      for s in 0 to MAX_SOURCE_COUNT - 1 loop
         if wmap( to_integer( ins.source( s ) ) ) then
            r( s ) := '1';
         end if;
      end loop;
      return r;
   end function;

   function SERIALIZING( ins : renamed_instruction_t ) return boolean is
   begin
      return ISA_TABLE( to_integer( unsigned( ins.slot.canon.op ) ) ).serializing;
   end function;

   -- étiquettes réveillées par le bus du cycle
   function WAKE_MAP( wb : wakeup_bus_t ) return wake_map_t is
      variable m : wake_map_t := ( others => false );
   begin
      for p in wb'range loop
         if wb( p ).valid = '1' and not is_x( std_logic_vector( wb( p ).tag ) ) then
            m( to_integer( wb( p ).tag ) ) := true;
         end if;
      end loop;
      return m;
   end function;

   signal woken		: wake_map_t;


   -- sources à attendre : toutes, sauf la donnée d'un rangement (la dernière, le sommet),
   -- que la LSQ capture elle-même (familles B et C, mode 10 : SB .. SQ, SIB .. SIQ)
   function NEEDED_SOURCES( ins : renamed_instruction_t ) return natural is
      variable op : opcode_t := ins.slot.canon.op;
   begin
      if ( op( 7 downto 6 ) = "01" or op( 7 downto 6 ) = "10" ) and op( 5 downto 4 ) = "10"
         and ins.source_count > 0 then
         return ins.source_count - 1;
      end if;
      return ins.source_count;
   end function;
begin

   woken <= WAKE_MAP( WAKEUP_I );

		--------------------------------------------------------------------------------
		-- Éligibilité et sélection, dans le cycle
		--------------------------------------------------------------------------------

   SELECTION : process( payload, valid, ready, woken, ROB_HEAD_I )
      variable eligible	: std_logic_vector( 0 to QUEUE_DEPTH_G - 1 );
      variable taken	: std_logic_vector( 0 to QUEUE_DEPTH_G - 1 );
      variable r	: ready_t;
      variable best	: integer;
      variable best_age	: natural;
      variable age	: age_array_t;					-- calculé une fois par cycle
      variable head	: natural;
      variable n	: natural range 0 to ISSUE_WIDTH_G;
      variable pk	: index_array_t;
   begin
      head := to_integer( ROB_HEAD_I );
      for e in 0 to QUEUE_DEPTH_G - 1 loop
         eligible( e ) := '0';
         age( e ) := 0;
         if valid( e ) = '1' then
            age( e ) := ( to_integer( payload( e ).rob_index ) - head ) mod ROB_SIZE;
            r := WAKE( payload( e ), ready( e ), woken );
            eligible( e ) := '1';
            for s in 0 to MAX_SOURCE_COUNT - 1 loop
               if s < NEEDED_SOURCES( payload( e ) ) and r( s ) = '0' then
                  eligible( e ) := '0';
               end if;
            end loop;
            if SERIALIZING( payload( e ) ) and payload( e ).rob_index /= ROB_HEAD_I then
               eligible( e ) := '0';
            end if;
         end if;
      end loop;

      taken := ( others => '0' );
      n := 0;
      pk := ( others => 0 );
      for k in 0 to ISSUE_WIDTH_G - 1 loop
         best := -1;
         best_age := ROB_SIZE;
         for e in 0 to QUEUE_DEPTH_G - 1 loop
            if valid( e ) = '1' and taken( e ) = '0'
               and ( IN_ORDER_G or eligible( e ) = '1' )
               and age( e ) < best_age then
               best := e;
               best_age := age( e );
            end if;
         end loop;
         exit when best < 0;
         exit when eligible( best ) = '0';				-- dans l'ordre : la plus ancienne bloque
         taken( best ) := '1';
         pk( k ) := best;
         n := n + 1;
      end loop;

      pick <= pk;
      npick <= n;
   end process;

   SORTIE : process( payload, pick, npick )
   begin
      for k in 0 to RENAME_WIDTH - 1 loop
         if k < npick then
            ISSUE_BLOCK_O( k ) <= payload( pick( k ) );
         else
            ISSUE_BLOCK_O( k ) <= payload( 0 );				-- sans objet
         end if;
      end loop;
      ISSUE_COUNT_O <= to_unsigned( npick, ISSUE_COUNT_O'length );
      if npick > 0 then
         ISSUE_VALID_O <= '1';
      else
         ISSUE_VALID_O <= '0';
      end if;
   end process;

		--------------------------------------------------------------------------------
		-- Capacité et nombre d'entrées : état seul
		--------------------------------------------------------------------------------

   ETAT : process( valid )
      variable n : natural range 0 to QUEUE_DEPTH_G;
   begin
      n := 0;
      for e in 0 to QUEUE_DEPTH_G - 1 loop
         if valid( e ) = '1' then
            n := n + 1;
         end if;
      end loop;
      ENTRY_COUNT_O <= n;
      if QUEUE_DEPTH_G - n > DECODE_WIDTH then				-- un bloc : DECODE_WIDTH au plus
         INSERT_CAPACITY_O <= to_unsigned( DECODE_WIDTH, INSERT_CAPACITY_O'length );
      else
         INSERT_CAPACITY_O <= to_unsigned( QUEUE_DEPTH_G - n, INSERT_CAPACITY_O'length );
      end if;
   end process;

		--------------------------------------------------------------------------------
		-- Front : départ, reprise, réveil, insertion
		--------------------------------------------------------------------------------

   FILE_ATTENTE : process( CLK_i )
      variable v	: std_logic_vector( 0 to QUEUE_DEPTH_G - 1 );
      variable rd	: ready_array_t;
      variable free	: std_logic_vector( 0 to QUEUE_DEPTH_G - 1 );
      variable slot	: natural;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            valid <= ( others => '0' );
         else
            v := valid;
            free := not valid;						-- libres au début du cycle

            -- départ des instructions transférées
            if ISSUE_READY_I = '1' then
               for k in 0 to ISSUE_WIDTH_G - 1 loop
                  if k < npick then
                     v( pick( k ) ) := '0';
                  end if;
               end loop;
            end if;

            -- reprise, puis réveil des bits rangés
            for e in 0 to QUEUE_DEPTH_G - 1 loop
               if valid( e ) = '1' then
                  if ABANDONED( payload( e ).rob_index, RECOVERY_I, ROB_HEAD_I ) then
                     v( e ) := '0';
                  end if;
                  rd( e ) := WAKE( payload( e ), ready( e ), woken );
               else
                  rd( e ) := ready( e );
               end if;
            end loop;

            -- insertion dans les entrées libres au début du cycle
            if INSERT_VALID_I = '1' then
               slot := 0;
               for i in 0 to RENAME_WIDTH - 1 loop
                  if i < INSERT_COUNT_I then
                     while slot < QUEUE_DEPTH_G and free( slot ) = '0' loop
                        slot := slot + 1;
                     end loop;

                     -- pragma translate_off
                     assert slot < QUEUE_DEPTH_G
                        report "ISSUE_QUEUE : insertion au-delà de la capacité annoncée" severity failure;
                     -- pragma translate_on

                     if not ABANDONED( INSERT_BLOCK_I( i ).rob_index, RECOVERY_I, ROB_HEAD_I ) then
                        v( slot ) := '1';
                        payload( slot ) <= INSERT_BLOCK_I( i );
                        rd( slot ) := WAKE( INSERT_BLOCK_I( i ), INSERT_BLOCK_I( i ).source_ready, woken );
                     end if;
                     free( slot ) := '0';
                  end if;
               end loop;
            end if;

            valid <= v;
            ready <= rd;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
