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

                --------------------------------------------------------------------------------
                -- FETCH_BYTE_QUEUE, architecture IN_ORDER.
                --
                -- Derivee de l'architecture BANKED de asic/, avec la semantique
                -- PRELOAD du frontal courant restauree pour les redirections InO.
                --
                -- Organisation physique du tampon:
                --
                --   32 banques x 4 rangs x 9 bits = 128 x (8 bits + faute).
                --
                -- L'adresse circulaire sur 7 bits est scindee en:
                --   - bits 4..0 : numero de banque (0..31),
                --   - bits 6..5 : numero de rang   (0..3).
                --
                -- Toute fenetre de 32 octets consecutifs lit exactement une case
                -- de chacune des 32 banques. De meme, tout bloc entrant de 32 octets
                -- ecrit exactement une case de chacune des 32 banques.
                --
                -- Les rotations lecture/ecriture sont realisees explicitement par
                -- cinq etages 2:1 (1, 2, 4, 8, 16), afin d'eviter que la synthese
                -- construise 32 multiplexeurs 32-vers-1 independants.
                --
                -- Chaque banque est volontairement stockee comme un registre plat
                -- de 36 bits et non comme une memoire inferee: cela evite la creation
                -- d'une RAM logique a 32 ports lors de memory_map.
                --------------------------------------------------------------------------------

architecture IN_ORDER of FETCH_BYTE_QUEUE
is

   constant BANK_COUNT     : natural := 32;
   constant BANK_DEPTH     : natural := 4;
   constant SLOT_WIDTH     : natural := 9;

   subtype index_t         is natural range 0 to FETCH_QUEUE_SIZE - 1;
   subtype bank_word_t     is std_logic_vector( BANK_DEPTH * SLOT_WIDTH - 1 downto 0 );
   subtype slot_t          is std_logic_vector( SLOT_WIDTH - 1 downto 0 );

   type bank_array_t       is array( 0 to BANK_COUNT - 1 ) of bank_word_t;
   type slot_array_t       is array( 0 to BANK_COUNT - 1 ) of slot_t;

   signal banks            : bank_array_t;

   signal rd0              : slot_array_t;
   signal rd1              : slot_array_t;
   signal rd2              : slot_array_t;
   signal rd3              : slot_array_t;
   signal rd4              : slot_array_t;
   signal rd5              : slot_array_t;

   signal wr0              : slot_array_t;
   signal wr1              : slot_array_t;
   signal wr2              : slot_array_t;
   signal wr3              : slot_array_t;
   signal wr4              : slot_array_t;
   signal wr5              : slot_array_t;

   signal head             : index_t;
   signal count            : natural range 0 to FETCH_QUEUE_SIZE;
   signal head_pc          : address_t;
   signal pc_known         : std_logic;

   signal head_bits        : unsigned( 6 downto 0 );
   signal tail_bits        : unsigned( 6 downto 0 );
   signal tail_index       : index_t;

   signal ready            : std_logic;


   function SLOT_OF
     ( bank : bank_word_t;
       row  : natural )
      return slot_t
   is
   begin
      case row is
         when 0 =>
            return bank( 8 downto 0 );
         when 1 =>
            return bank( 17 downto 9 );
         when 2 =>
            return bank( 26 downto 18 );
         when others =>
            return bank( 35 downto 27 );
      end case;
   end function SLOT_OF;


   function PACK_SLOT
     ( data  : byte_t;
       fault : std_logic )
      return slot_t
   is
      variable r : slot_t;
   begin
      r( 7 downto 0 ) := std_logic_vector( data );
      r( 8 )           := fault;
      return r;
   end function PACK_SLOT;


begin

   assert FETCH_QUEUE_SIZE = 128
     report "FETCH_BYTE_QUEUE/IN_ORDER : FETCH_QUEUE_SIZE doit valoir 128"
     severity failure;

   assert FETCH_BLOCK_SIZE = 32
     report "FETCH_BYTE_QUEUE/IN_ORDER : FETCH_BLOCK_SIZE doit valoir 32"
     severity failure;

   assert DECODE_WINDOW_SIZE = 32
     report "FETCH_BYTE_QUEUE/IN_ORDER : DECODE_WINDOW_SIZE doit valoir 32"
     severity failure;


                --------------------------------------------------------------------------------
                -- Adresse de tete et adresse de queue sous forme binaire.
                --------------------------------------------------------------------------------

   head_bits  <= to_unsigned( head, head_bits'length );
   tail_index <= ( head + count ) mod FETCH_QUEUE_SIZE;
   tail_bits  <= to_unsigned( tail_index, tail_bits'length );


                --------------------------------------------------------------------------------
                -- 1. Place pour un bloc entier.
                --------------------------------------------------------------------------------

   ready         <= '1' when count <= FETCH_QUEUE_SIZE - FETCH_BLOCK_SIZE else '0';
   FETCH_READY_o <= ready;


                --------------------------------------------------------------------------------
                -- 2. Lecture des 32 banques.
                --
                -- Pour une fenetre commencant a head:
                --   banques head_bank..31 : rang head_row
                --   banques 0..head_bank-1: rang head_row+1 modulo 4
                --------------------------------------------------------------------------------

   BANK_READ :
   process( banks, head )
      variable head_bank : natural range 0 to BANK_COUNT - 1;
      variable head_row  : natural range 0 to BANK_DEPTH - 1;
      variable row       : natural range 0 to BANK_DEPTH - 1;
   begin
      head_bank := head mod BANK_COUNT;
      head_row  := head / BANK_COUNT;

      for b in 0 to BANK_COUNT - 1 loop
         row := head_row;

         if b < head_bank then
            if head_row = BANK_DEPTH - 1 then
               row := 0;
            else
               row := head_row + 1;
            end if;
         end if;

         rd0( b ) <= SLOT_OF( banks( b ), row );
      end loop;
   end process BANK_READ;


                --------------------------------------------------------------------------------
                -- Rotation lecture vers la gauche de head mod 32.
                -- A la sortie: rd5(i) = octet d'adresse head+i.
                --------------------------------------------------------------------------------

   RD_ROT_1 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      rd1( i ) <= rd0( ( i + 1 ) mod BANK_COUNT )
                  when head_bits( 0 ) = '1' else rd0( i );
   end generate RD_ROT_1;

   RD_ROT_2 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      rd2( i ) <= rd1( ( i + 2 ) mod BANK_COUNT )
                  when head_bits( 1 ) = '1' else rd1( i );
   end generate RD_ROT_2;

   RD_ROT_4 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      rd3( i ) <= rd2( ( i + 4 ) mod BANK_COUNT )
                  when head_bits( 2 ) = '1' else rd2( i );
   end generate RD_ROT_4;

   RD_ROT_8 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      rd4( i ) <= rd3( ( i + 8 ) mod BANK_COUNT )
                  when head_bits( 3 ) = '1' else rd3( i );
   end generate RD_ROT_8;

   RD_ROT_16 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      rd5( i ) <= rd4( ( i + 16 ) mod BANK_COUNT )
                  when head_bits( 4 ) = '1' else rd4( i );
   end generate RD_ROT_16;


   WINDOW_OUTPUTS :
   for i in 0 to DECODE_WINDOW_SIZE - 1 generate
   begin
      WINDOW_o( i )       <= byte_t( rd5( i )( 7 downto 0 ) );
      WINDOW_FAULT_o( i ) <= rd5( i )( 8 );
   end generate WINDOW_OUTPUTS;


   WINDOW_COUNT :
   process( count )
   begin
      if count > DECODE_WINDOW_SIZE then
         WINDOW_COUNT_o <= to_unsigned( DECODE_WINDOW_SIZE, WINDOW_COUNT_o'length );
      else
         WINDOW_COUNT_o <= to_unsigned( count, WINDOW_COUNT_o'length );
      end if;
   end process WINDOW_COUNT;


   WINDOW_PC_o  <= head_pc;
   EMPTY_o      <= '1' when count = 0 else '0';
   BYTE_COUNT_o <= to_unsigned( count, BYTE_COUNT_o'length );


                --------------------------------------------------------------------------------
                -- Preparation du bloc entrant.
                --
                -- wr0(j) est l'octet j du bloc. La rotation vers la droite de
                -- tail mod 32 place ensuite dans wr5(b) l'octet destine a la banque b.
                --------------------------------------------------------------------------------

   WR_INPUT :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      wr0( i ) <= PACK_SLOT( FETCH_BLOCK_i( i ), FETCH_FAULT_i );
   end generate WR_INPUT;


   WR_ROT_1 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      wr1( i ) <= wr0( ( i + BANK_COUNT - 1 ) mod BANK_COUNT )
                  when tail_bits( 0 ) = '1' else wr0( i );
   end generate WR_ROT_1;

   WR_ROT_2 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      wr2( i ) <= wr1( ( i + BANK_COUNT - 2 ) mod BANK_COUNT )
                  when tail_bits( 1 ) = '1' else wr1( i );
   end generate WR_ROT_2;

   WR_ROT_4 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      wr3( i ) <= wr2( ( i + BANK_COUNT - 4 ) mod BANK_COUNT )
                  when tail_bits( 2 ) = '1' else wr2( i );
   end generate WR_ROT_4;

   WR_ROT_8 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      wr4( i ) <= wr3( ( i + BANK_COUNT - 8 ) mod BANK_COUNT )
                  when tail_bits( 3 ) = '1' else wr3( i );
   end generate WR_ROT_8;

   WR_ROT_16 :
   for i in 0 to BANK_COUNT - 1 generate
   begin
      wr5( i ) <= wr4( ( i + BANK_COUNT - 16 ) mod BANK_COUNT )
                  when tail_bits( 4 ) = '1' else wr4( i );
   end generate WR_ROT_16;


                --------------------------------------------------------------------------------
                -- 3., 4. Etat et ecriture au front d'horloge.
                --------------------------------------------------------------------------------

   FILE_OCTETS :
   process( CLK_i )
      variable pop        : natural range 0 to 2 ** window_count_t'length - 1;
      variable push       : natural range 0 to 2 ** fetch_count_t'length - 1;
      variable remaining  : natural range 0 to FETCH_QUEUE_SIZE;

      variable tail       : index_t;
      variable tail_bank  : natural range 0 to BANK_COUNT - 1;
      variable tail_row   : natural range 0 to BANK_DEPTH - 1;
      variable row        : natural range 0 to BANK_DEPTH - 1;
   begin
      if rising_edge( CLK_i ) then

         if RESET_i = '1' or FLUSH_i = '1' then
            head     <= 0;
            count    <= 0;
            pc_known <= '0';

            -- Comme dans l'architecture RTL commune, un FLUSH peut charger
            -- directement le bloc de cible deja lu par FETCH_UNIT.  La file
            -- repart alors de l'indice 0 : les 32 octets vont donc dans le
            -- rang 0 des 32 banques, sans rotation.
            if RESET_i = '0' and PRELOAD_VALID_i = '1' then
               for b in 0 to BANK_COUNT - 1 loop
                  banks( b )( 8 downto 0 ) <= PACK_SLOT( PRELOAD_BLOCK_i( b ), '0' );
               end loop;
               count    <= to_integer( PRELOAD_COUNT_i );
               head_pc  <= PRELOAD_PC_i;
               pc_known <= '1';
            end if;

            -- pragma translate_off
            assert not ( FLUSH_i = '1' and RESET_i = '0' and FETCH_VALID_i = '1' )
              report "FETCH_BYTE_QUEUE : bloc presente pendant un vidage"
              severity error;
            -- pragma translate_on

         else
            pop  := 0;
            push := 0;

            if CONSUME_i = '1' then
               pop := to_integer( CONSUMED_BYTES_i );
            end if;

            if FETCH_VALID_i = '1' and ready = '1' then
               push := to_integer( FETCH_COUNT_i );
            end if;

            -- pragma translate_off
            assert pop <= count and pop <= DECODE_WINDOW_SIZE
              report "FETCH_BYTE_QUEUE : retrait de " & integer'image( pop ) &
                     " octets, " & integer'image( count ) & " presents"
              severity error;

            assert push <= FETCH_BLOCK_SIZE
              report "FETCH_BYTE_QUEUE : bloc de plus de 32 octets"
              severity error;

            assert push = 0 or pc_known = '0' or FETCH_PC_i = head_pc + count
              report "FETCH_BYTE_QUEUE : bloc non consecutif"
              severity error;
            -- pragma translate_on

            if pop > count then
               pop := count;
            end if;


                --------------------------------------------------------------------------------
                -- Ecriture du bloc derriere la queue.
                --
                -- Une banque recoit exactement une ecriture. Les banques situees
                -- avant tail_bank correspondent au rang suivant (avec enroulement).
                --
                -- Comme dans l'architecture d'origine, lorsque push > 0 les 32
                -- octets du bus sont ecrits; seules les "push" premieres positions
                -- appartiennent effectivement a la file.
                --------------------------------------------------------------------------------

            tail      := ( head + count ) mod FETCH_QUEUE_SIZE;
            tail_bank := tail mod BANK_COUNT;
            tail_row  := tail / BANK_COUNT;

            if push > 0 then
               for b in 0 to BANK_COUNT - 1 loop
                  row := tail_row;

                  if b < tail_bank then
                     if tail_row = BANK_DEPTH - 1 then
                        row := 0;
                     else
                        row := tail_row + 1;
                     end if;
                  end if;

                  case row is
                     when 0 =>
                        banks( b )( 8 downto 0 ) <= wr5( b );

                     when 1 =>
                        banks( b )( 17 downto 9 ) <= wr5( b );

                     when 2 =>
                        banks( b )( 26 downto 18 ) <= wr5( b );

                     when others =>
                        banks( b )( 35 downto 27 ) <= wr5( b );
                  end case;
               end loop;
            end if;


                --------------------------------------------------------------------------------
                -- Tete, nombre, PC.
                --------------------------------------------------------------------------------

            remaining := count - pop;

            head  <= ( head + pop ) mod FETCH_QUEUE_SIZE;
            count <= remaining + push;

            if remaining = 0 and push > 0 then
               head_pc <= FETCH_PC_i;
            else
               head_pc <= head_pc + pop;
            end if;

            if push > 0 then
               pc_known <= '1';
            end if;
         end if;
      end if;
   end process FILE_OCTETS;

end architecture IN_ORDER;

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
