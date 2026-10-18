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
use work.INO_PADDR.all;

                --------------------------------------------------------------------------------
                -- INO_BYTE_QUEUE : file d'octets de INO_FETCH, rangee par adresse.
                --
                -- Meme organisation que FETCH_BYTE_QUEUE(IN_ORDER) : 32 banques x 4 rangs
                -- x 9 bits (octet + faute), adresse circulaire sur 7 bits (bits 4..0 :
                -- banque, bits 6..5 : rang), meme fenetre de lecture (rotation de head
                -- mod 32 en cinq etages 2:1), memes nombre, PC et place libre.
                --
                -- Difference : la file garde l'invariant
                --
                --      head mod 32 = head_pc mod 32   (des qu'elle contient un octet),
                --
                -- c'est-a-dire que l'octet d'adresse a est toujours dans la banque a mod 32.
                -- Comme les blocs entrants sont consecutifs (FETCH_PC = head_pc + count),
                -- la queue est alors a la banque FETCH_PC mod 32 : l'octet j de la ligne
                -- brute (FETCH_LINE_i, adresse LINE_OF(FETCH_PC) + j) va directement dans
                -- la banque j. Ni le cadrage du bloc dans FETCH_UNIT ni la rotation
                -- d'ecriture de FETCH_BYTE_QUEUE ne sont necessaires : seul le choix du
                -- rang depend de la queue.
                --
                -- L'invariant est etabli quand un bloc entre dans une file qui sera vide
                -- (remaining = 0) : head prend alors la position de queue de ce bloc.
                --
                -- Les octets utiles de la fenetre (WINDOW_o(i), i < WINDOW_COUNT_o) sont ceux
                -- de FETCH_BYTE_QUEUE(IN_ORDER) ; au-dela, le contenu est sans
                -- signification dans les deux files (et differe).
                --
                -- Sans prechargement des cibles (PRELOAD_* toujours inactif dans InO), ni
                -- EMPTY_o / BYTE_COUNT_o (sans lecteur dans INO_FETCH).
                --------------------------------------------------------------------------------

                                --------------
entity                          INO_BYTE_QUEUE
is                              --------------
   port (
      CLK_i             :in  std_logic;
      RESET_i           :in  std_logic;

      FETCH_VALID_i     :in  std_logic;
      FETCH_READY_o     :out std_logic;                 -- place pour un bloc entier
      FETCH_PC_i        :in  address_t;                 -- adresse du premier octet utile
      FETCH_LINE_i      :in  fetch_block_t;             -- ligne brute de FETCH_PC_i
      FETCH_COUNT_i     :in  fetch_count_t;             -- 32 - FETCH_PC_i(4 downto 0)
      FETCH_FAULT_i     :in  std_logic;

      WINDOW_o          :out decode_window_t;
      WINDOW_COUNT_o    :out window_count_t;
      WINDOW_PC_o       :out address_t;
      WINDOW_FAULT_o    :out window_flags_t;

      CONSUME_i         :in  std_logic;
      CONSUMED_BYTES_i  :in  window_count_t;

      FLUSH_i           :in  std_logic
   );
end entity                      INO_BYTE_QUEUE;
                                --------------


architecture RTL of INO_BYTE_QUEUE
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

   signal head             : index_t;
   signal count            : natural range 0 to FETCH_QUEUE_SIZE;
   signal head_pc          : address_t;
   signal pc_known         : std_logic;

   signal head_bits        : unsigned( 6 downto 0 );

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
     report "INO_BYTE_QUEUE : FETCH_QUEUE_SIZE doit valoir 128"
     severity failure;

   assert FETCH_BLOCK_SIZE = 32
     report "INO_BYTE_QUEUE : FETCH_BLOCK_SIZE doit valoir 32"
     severity failure;

   assert DECODE_WINDOW_SIZE = 32
     report "INO_BYTE_QUEUE : DECODE_WINDOW_SIZE doit valoir 32"
     severity failure;


   head_bits     <= to_unsigned( head, head_bits'length );

   ready         <= '1' when count <= FETCH_QUEUE_SIZE - FETCH_BLOCK_SIZE else '0';
   FETCH_READY_o <= ready;


                --------------------------------------------------------------------------------
                -- Lecture des 32 banques, puis rotation vers la gauche de head mod 32 :
                -- rd5(i) = octet d'adresse head_pc + i. Identique a FETCH_BYTE_QUEUE(IN_ORDER).
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


                --------------------------------------------------------------------------------
                -- Etat et ecriture au front d'horloge.
                --------------------------------------------------------------------------------

   FILE_OCTETS :
   process( CLK_i )
      variable pop        : natural range 0 to 2 ** window_count_t'length - 1;
      variable push       : natural range 0 to 2 ** fetch_count_t'length - 1;
      variable remaining  : natural range 0 to FETCH_QUEUE_SIZE;

      variable tail_bank  : natural range 0 to BANK_COUNT - 1;
      variable tail_row   : natural range 0 to BANK_DEPTH - 1;
      variable row        : natural range 0 to BANK_DEPTH - 1;
   begin
      if rising_edge( CLK_i ) then

         if RESET_i = '1' or FLUSH_i = '1' then
            head     <= 0;
            count    <= 0;
            pc_known <= '0';

            -- pragma translate_off
            assert not ( FLUSH_i = '1' and RESET_i = '0' and FETCH_VALID_i = '1' )
              report "INO_BYTE_QUEUE : bloc presente pendant un vidage"
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
              report "INO_BYTE_QUEUE : retrait de " & integer'image( pop ) &
                     " octets, " & integer'image( count ) & " presents"
              severity error;

            assert push <= FETCH_BLOCK_SIZE
              report "INO_BYTE_QUEUE : bloc de plus de 32 octets"
              severity error;

            assert push = 0 or pc_known = '0' or CUT(FETCH_PC_i) = CUT(head_pc + count)
              report "INO_BYTE_QUEUE : bloc non consecutif"
              severity error;

            assert push = 0 or push = FETCH_BLOCK_SIZE - to_integer( FETCH_PC_i( 4 downto 0 ) )
              report "INO_BYTE_QUEUE : nombre d'octets incoherent avec le PC du bloc"
              severity error;

            assert count = 0 or ( head mod BANK_COUNT ) = to_integer( head_pc( 4 downto 0 ) )
              report "INO_BYTE_QUEUE : file non rangee par adresse"
              severity error;
            -- pragma translate_on

            if pop > count then
               pop := count;
            end if;


                --------------------------------------------------------------------------------
                -- Ecriture de la ligne : l'octet j va dans la banque j. La queue est a la
                -- banque FETCH_PC mod 32 ; les banques situees avant elle prennent le rang
                -- suivant (avec enroulement), comme dans FETCH_BYTE_QUEUE. Les octets
                -- j < FETCH_PC mod 32 tombent ainsi derriere les push octets du bloc, dans
                -- des places libres (count + 32 <= 128) : sans effet.
                --
                -- Le rang de queue vient de head + count tant que la file n'est pas vide
                -- (invariant : sa banque est alors FETCH_PC mod 32) ; une file vide repart
                -- au rang 0.
                --------------------------------------------------------------------------------

            tail_bank := to_integer( FETCH_PC_i( 4 downto 0 ) );
            if count = 0 then
               tail_row := 0;
            else
               tail_row := ( ( head + count ) mod FETCH_QUEUE_SIZE ) / BANK_COUNT;
            end if;

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
                        banks( b )( 8 downto 0 ) <= PACK_SLOT( FETCH_LINE_i( b ), FETCH_FAULT_i );

                     when 1 =>
                        banks( b )( 17 downto 9 ) <= PACK_SLOT( FETCH_LINE_i( b ), FETCH_FAULT_i );

                     when 2 =>
                        banks( b )( 26 downto 18 ) <= PACK_SLOT( FETCH_LINE_i( b ), FETCH_FAULT_i );

                     when others =>
                        banks( b )( 35 downto 27 ) <= PACK_SLOT( FETCH_LINE_i( b ), FETCH_FAULT_i );
                  end case;
               end loop;
            end if;


                --------------------------------------------------------------------------------
                -- Tete, nombre, PC. Un bloc qui entre dans une file qui sera vide fixe la
                -- tete a sa propre position de queue : l'invariant est (re)etabli.
                --------------------------------------------------------------------------------

            remaining := count - pop;

            if remaining = 0 and push > 0 then
               head    <= tail_row * BANK_COUNT + tail_bank;
               head_pc <= CUT(FETCH_PC_i);
            else
               head    <= ( head + pop ) mod FETCH_QUEUE_SIZE;
               head_pc <= CUT(head_pc + pop);
            end if;

            count <= remaining + push;

            if push > 0 then
               pc_known <= '1';
            end if;
         end if;
      end if;
   end process FILE_OCTETS;

end architecture RTL;

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
