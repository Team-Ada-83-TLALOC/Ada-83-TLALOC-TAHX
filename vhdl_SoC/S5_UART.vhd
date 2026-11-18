library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
        --------------------------------------------------------------------------------
        -- UART : 8N1, diviseur de debit sur 16 bits, FIFO de PROF_G octets en emission et
        --   en reception (ARCHI_SOC_TAHX.md § 5).
        --
        -- Bit = DIV + 1 cycles du coeur (36 MHz, 115 200 bauds : DIV = 311, ecart 0,2 %).
        -- Reception : RX_i resynchronisee (deux bascules) ; un front descendant ouvre un
        -- bit de start, verifie a mi-bit (une impulsion plus courte qu'un demi-bit est
        -- ignoree) ; les 8 bits de donnees puis le stop sont echantillonnes au milieu de
        -- chaque bit. Stop a 0 : octet range avec son erreur de trame, puis attente du
        -- retour de la ligne a 1 (break). DIV >= 3.
        --
        -- Registres (bus de registres du SoC : SEL_i, WE_i, ADDR_i, WDATA_i ; RDATA_o
        -- combinatoire, effet d'une lecture au front qui la termine) :
        --   0  DONNEE   ecriture : octet ajoute a la FIFO d'emission (perdu si elle est
        --               pleine : bit 6 de ETAT). Lecture : 7..0 octet, 8 valide (la FIFO de
        --               reception n'etait pas vide ; l'octet en est alors retire), 9 erreur
        --               de trame de cet octet.
        --   1  ETAT     0 emission pleine, 1 emission vide (FIFO vide et emetteur au repos),
        --               2 reception non vide, 3 reception pleine, 4 debordement en reception
        --               (collant), 5 erreur de trame (collante), 6 octet d'emission perdu
        --               (collant), 11..8 octets en reception, 15..12 octets en emission.
        --               Ecrire 1 sur les bits 4 a 6 les efface.
        --   2  CTRL     15..0 DIV, 16 IE_RX (interruption : reception non vide), 17 IE_TX
        --               (emission vide), 18 BOUCLE (TX reliee a RX dans la puce, TX_o a 1).
        -- Au RESET : DIV = 311, interruptions masquees, pas de boucle.
        --------------------------------------------------------------------------------

entity UART is
   generic (
      PROF_G       : positive := 8;                              -- profondeur des FIFO (<= 15)
      DIV_RESET_G  : natural  := 311
   );
   port (
      CLK_i        : in  std_logic;
      RESET_i      : in  std_logic;

      SEL_i        : in  std_logic;
      WE_i         : in  std_logic;
      ADDR_i       : in  unsigned( 1 downto 0 );
      WDATA_i      : in  std_logic_vector( 31 downto 0 );
      RDATA_o      : out std_logic_vector( 31 downto 0 );
      IRQ_o        : out std_logic;

      TX_o         : out std_logic;
      RX_i         : in  std_logic
   );
end entity UART;

architecture RTL of UART is

   type fifo_t is array( 0 to PROF_G - 1 ) of std_logic_vector( 8 downto 0 );
   subtype idx_t is natural range 0 to PROF_G - 1;
   subtype cnt_t is natural range 0 to PROF_G;

   function SUIV( i : idx_t ) return idx_t is
   begin
      if i = PROF_G - 1 then return 0; else return i + 1; end if;
   end function;

   signal div      : unsigned( 15 downto 0 );
   signal ie_rx, ie_tx, boucle : std_logic;
   signal deb, ferr_c, perdu : std_logic;

   -- emission
   signal txf      : fifo_t;
   signal tx_lec, tx_ecr : idx_t;
   signal tx_n     : cnt_t;
   signal tx_occ   : std_logic;                                  -- emetteur en cours
   signal tx_sh    : std_logic_vector( 9 downto 0 );             -- stop & donnees & start
   signal tx_bit   : natural range 0 to 9;
   signal tx_cpt   : unsigned( 15 downto 0 );
   signal tx_ligne : std_logic;

   -- reception
   signal rxf      : fifo_t;
   signal rx_lec, rx_ecr : idx_t;
   signal rx_n     : cnt_t;
   signal rx_s1, rx_s2, rx_l : std_logic;
   type rx_etat_t is ( R_REPOS, R_START, R_DONNEES, R_STOP, R_BREAK );
   signal rx_etat  : rx_etat_t;
   signal rx_cpt   : unsigned( 15 downto 0 );
   signal rx_bit   : natural range 0 to 7;
   signal rx_sh    : std_logic_vector( 7 downto 0 );

   signal lec_don, ecr_don : std_logic;
   signal tx_vide, rx_nv : std_logic;

begin

   tx_vide <= '1' when tx_n = 0 and tx_occ = '0' else '0';
   rx_nv   <= '1' when rx_n /= 0 else '0';
   IRQ_o   <= ( ie_rx and rx_nv ) or ( ie_tx and tx_vide );
   TX_o    <= '1' when boucle = '1' else tx_ligne;
   rx_l    <= tx_ligne when boucle = '1' else rx_s2;

   lec_don <= '1' when SEL_i = '1' and WE_i = '0' and ADDR_i = 0 else '0';
   ecr_don <= '1' when SEL_i = '1' and WE_i = '1' and ADDR_i = 0 else '0';

   LECTURE : process( all )
   begin
      RDATA_o <= ( others => '0' );
      case to_integer( ADDR_i ) is
         when 0 =>
            if rx_n /= 0 then
               RDATA_o( 7 downto 0 ) <= rxf( rx_lec )( 7 downto 0 );
               RDATA_o( 8 ) <= '1';
               RDATA_o( 9 ) <= rxf( rx_lec )( 8 );
            end if;
         when 1 =>
            RDATA_o( 0 ) <= '1' when tx_n = PROF_G else '0';
            RDATA_o( 1 ) <= tx_vide;
            RDATA_o( 2 ) <= '1' when rx_n /= 0 else '0';
            RDATA_o( 3 ) <= '1' when rx_n = PROF_G else '0';
            RDATA_o( 4 ) <= deb;
            RDATA_o( 5 ) <= ferr_c;
            RDATA_o( 6 ) <= perdu;
            RDATA_o( 11 downto 8 )  <= std_logic_vector( to_unsigned( rx_n, 4 ) );
            RDATA_o( 15 downto 12 ) <= std_logic_vector( to_unsigned( tx_n, 4 ) );
         when 2 =>
            RDATA_o( 15 downto 0 ) <= std_logic_vector( div );
            RDATA_o( 16 ) <= ie_rx; RDATA_o( 17 ) <= ie_tx; RDATA_o( 18 ) <= boucle;
         when others => null;
      end case;
   end process;

   SEQUENTIEL : process( CLK_i )
      variable tx_pop, tx_push, rx_push, rx_pop : boolean;
      variable octet_rx : std_logic_vector( 8 downto 0 );
   begin
      if rising_edge( CLK_i ) then
         rx_s1 <= RX_i; rx_s2 <= rx_s1;
         if RESET_i = '1' then
            div <= to_unsigned( DIV_RESET_G, 16 ); ie_rx <= '0'; ie_tx <= '0'; boucle <= '0';
            deb <= '0'; ferr_c <= '0'; perdu <= '0';
            tx_lec <= 0; tx_ecr <= 0; tx_n <= 0; tx_occ <= '0'; tx_ligne <= '1';
            rx_lec <= 0; rx_ecr <= 0; rx_n <= 0; rx_etat <= R_REPOS;
            rx_s1 <= '1'; rx_s2 <= '1';
         else
            tx_pop := false; tx_push := false; rx_push := false; rx_pop := false;

            -- registres
            if SEL_i = '1' and WE_i = '1' then
               case to_integer( ADDR_i ) is
                  when 1 =>
                     if WDATA_i( 4 ) = '1' then deb <= '0'; end if;
                     if WDATA_i( 5 ) = '1' then ferr_c <= '0'; end if;
                     if WDATA_i( 6 ) = '1' then perdu <= '0'; end if;
                  when 2 =>
                     div <= unsigned( WDATA_i( 15 downto 0 ) );
                     ie_rx <= WDATA_i( 16 ); ie_tx <= WDATA_i( 17 ); boucle <= WDATA_i( 18 );
                  when others => null;
               end case;
            end if;
            if ecr_don = '1' then
               if tx_n = PROF_G then
                  perdu <= '1';
               else
                  txf( tx_ecr ) <= '0' & WDATA_i( 7 downto 0 );
                  tx_push := true;
               end if;
            end if;
            if lec_don = '1' and rx_n /= 0 then
               rx_pop := true;
            end if;

            -- emetteur
            if tx_occ = '0' then
               tx_ligne <= '1';
               if tx_n /= 0 then
                  tx_sh <= '1' & txf( tx_lec )( 7 downto 0 ) & '0';
                  tx_pop := true;
                  tx_occ <= '1'; tx_bit <= 0; tx_cpt <= div;
                  tx_ligne <= '0';                               -- bit de start
               end if;
            elsif tx_cpt /= 0 then
               tx_cpt <= tx_cpt - 1;
            elsif tx_bit = 9 then
               tx_occ <= '0'; tx_ligne <= '1';
            else
               tx_bit <= tx_bit + 1; tx_cpt <= div;
               tx_ligne <= tx_sh( tx_bit + 1 );
            end if;

            -- recepteur
            case rx_etat is
               when R_REPOS =>
                  if rx_l = '0' then
                     rx_etat <= R_START; rx_cpt <= '0' & div( 15 downto 1 );   -- demi-bit
                  end if;
               when R_START =>
                  if rx_cpt /= 0 then
                     rx_cpt <= rx_cpt - 1;
                  elsif rx_l = '0' then
                     rx_etat <= R_DONNEES; rx_bit <= 0; rx_cpt <= div;
                  else
                     rx_etat <= R_REPOS;                         -- parasite
                  end if;
               when R_DONNEES =>
                  if rx_cpt /= 0 then
                     rx_cpt <= rx_cpt - 1;
                  else
                     rx_sh <= rx_l & rx_sh( 7 downto 1 );         -- poids faible d'abord
                     rx_cpt <= div;
                     if rx_bit = 7 then rx_etat <= R_STOP; else rx_bit <= rx_bit + 1; end if;
                  end if;
               when R_STOP =>
                  if rx_cpt /= 0 then
                     rx_cpt <= rx_cpt - 1;
                  else
                     octet_rx := not rx_l & rx_sh;
                     if rx_l = '0' then ferr_c <= '1'; rx_etat <= R_BREAK; else rx_etat <= R_REPOS; end if;
                     if rx_n = PROF_G and not rx_pop then
                        deb <= '1';
                     else
                        rxf( rx_ecr ) <= octet_rx;
                        rx_push := true;
                     end if;
                  end if;
               when R_BREAK =>
                  if rx_l = '1' then rx_etat <= R_REPOS; end if;
            end case;

            -- pointeurs et compteurs des FIFO
            if tx_push then tx_ecr <= SUIV( tx_ecr ); end if;
            if tx_pop then tx_lec <= SUIV( tx_lec ); end if;
            if tx_push and not tx_pop then tx_n <= tx_n + 1;
            elsif tx_pop and not tx_push then tx_n <= tx_n - 1; end if;
            if rx_push then rx_ecr <= SUIV( rx_ecr ); end if;
            if rx_pop then rx_lec <= SUIV( rx_lec ); end if;
            if rx_push and not rx_pop then rx_n <= rx_n + 1;
            elsif rx_pop and not rx_push then rx_n <= rx_n - 1; end if;
         end if;
      end if;
   end process;

end architecture RTL;
