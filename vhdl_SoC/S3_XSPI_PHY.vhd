library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.SOC_TYPES.all;

        --------------------------------------------------------------------------------
        -- XSPI_PHY : couche physique d'un port xSPI (ARCHI_SOC_TAHX.md § 4.4, decision du
        --   18 novembre : SCLK = CLK / 2 au premier silicium, pas de capture sur DQS).
        --
        -- L'automate (XSPI_CONTROLLER) lui donne des CRENEAUX, un par cycle du coeur en
        -- octal DTR : envoi d'un octet (TX), attente (DUMMY), reception d'un octet (RX).
        -- En SPI 1S-1S-1S (demarrage, commande 0x03), un creneau est un octet transmis
        -- bit a bit sur DQ0 (sortie) et DQ1 (entree), a SCLK = CLK / (2 (DIV + 1)).
        --
        -- Octal DTR (8D-8D-8D), un octet par front de SCLK :
        --   cycle      c0      c1      c2      c3
        --   DQ (TX)    = o0 ==== o1 ==== o2 ==== o3 ==       change au front montant de CLK
        --   SCLK       ____/-------\_______/------\___       bascule au front descendant
        --                  ^ o0    ^ o1    ^ o2              la memoire echantillonne au
        --                                                    milieu de l'octet (T / 2)
        --   En reception, l'octet du front de SCLK du creneau k arrive apres le retard
        --   aller-retour t (plots, carte, memoire) ; on l'echantillonne, selon SAMPLE :
        --     0 : front montant de CLK suivant   (ck + T)       si t < T / 2
        --     1 : front descendant suivant       (ck + 1,5 T)   si 0 < t < T  (defaut)
        --     2 : front montant d'apres          (ck + 2 T)     si T / 2 < t < 1,5 T
        --   A 36 MHz (T = 27,5 ns), SAMPLE = 1 accepte 0 a 27,5 ns d'aller-retour.
        --   CS# reste bas deux cycles de plus apres le dernier creneau RX, SCLK arrete,
        --   pour que la memoire tienne DQ jusqu'au dernier echantillon.
        -- SPI 1S (mode 0) : SCLK repos bas ; DQ0 pose pendant la demi-periode basse, la
        -- memoire l'echantillonne au front montant ; DQ1 lu au front montant (pose par la
        -- memoire au front descendant precedent). DQ2 et DQ3 tenus a 1 (WP#, HOLD# /
        -- RESET# des flashs en mode SPI).
        -- RWDS / DQS : pilote a 0 pendant les octets ecrits (masque d'ecriture des PSRAM,
        -- TX_MASK_i = 0 : octet ecrit) ; DQS n'est pas lu.
        --------------------------------------------------------------------------------

entity XSPI_PHY is
   port (
      CLK_i         : in  std_logic;
      RESET_i       : in  std_logic;

      -- reglages (registres du contrôleur)
      MODE_8D_i     : in  std_logic;                             -- 1 : octal DTR, 0 : SPI 1S
      DIV_i         : in  unsigned( 3 downto 0 );                -- SPI 1S : SCLK = CLK / (2 (DIV + 1))
      SAMPLE_i      : in  unsigned( 1 downto 0 );                -- octal : point d'echantillonnage

      -- creneaux, depuis le contrôleur
      CS_SEL_i      : in  std_logic;                             -- selection 0 ou 1
      SLOT_VALID_i  : in  std_logic;                             -- un creneau est presente
      SLOT_KIND_i   : in  std_logic_vector( 1 downto 0 );        -- 00 TX, 01 DUMMY, 10 RX
      SLOT_BYTE_i   : in  std_logic_vector( 7 downto 0 );        -- octet a envoyer (TX)
      SLOT_MASK_i   : in  std_logic;                             -- TX : piloter RWDS a cette valeur
      SLOT_RWDS_i   : in  std_logic;                             -- TX : RWDS pilote (ecriture PSRAM)
      SLOT_LAST_i   : in  std_logic;                             -- dernier creneau de la transaction
      SLOT_TAKE_o   : out std_logic;                             -- creneau pris (passer au suivant)
      RX_VALID_o    : out std_logic;
      RX_BYTE_o     : out std_logic_vector( 7 downto 0 );
      BUSY_o        : out std_logic;                             -- transaction en cours (CS# bas)

      -- plots
      SCLK_o        : out std_logic;
      CS_N_o        : out std_logic_vector( 1 downto 0 );
      DQ_o          : out std_logic_vector( 7 downto 0 );
      DQ_OE_o       : out std_logic_vector( 7 downto 0 );
      DQ_i          : in  std_logic_vector( 7 downto 0 );
      RWDS_o        : out std_logic;
      RWDS_OE_o     : out std_logic
   );
end entity XSPI_PHY;

architecture RTL of XSPI_PHY is

   constant K_TX    : std_logic_vector( 1 downto 0 ) := "00";
   constant K_DUMMY : std_logic_vector( 1 downto 0 ) := "01";
   constant K_RX    : std_logic_vector( 1 downto 0 ) := "10";

   type etat_t is ( REPOS, OCTAL, OCTAL_FIN, SPI );
   signal etat      : etat_t;

   signal cs_n      : std_logic_vector( 1 downto 0 );
   signal cs_r      : std_logic;
   signal run_r     : std_logic;                                 -- octal : SCLK bascule ce cycle
   signal sclk_f    : std_logic;                                 -- octal : bascule sur front descendant
   signal sclk_s    : std_logic;                                 -- SPI : genere sur front montant
   signal dq_r, oe_r : std_logic_vector( 7 downto 0 );
   signal rwds_r, rwds_oe_r : std_logic;
   signal fin_cnt   : natural range 0 to 3;

   -- reception octale
   signal m0, m1, m2 : std_logic;                                -- marqueur du creneau RX, retarde
   signal r1, r1q, r2, f1, f1q : std_logic_vector( 7 downto 0 );
   signal rx_v      : std_logic;
   signal rx_b      : std_logic_vector( 7 downto 0 );

   -- SPI 1S
   signal div_cnt   : unsigned( 3 downto 0 );
   signal bit_cnt   : natural range 0 to 7;
   signal haut      : std_logic;                                 -- demi-periode haute de SCLK
   signal sh_tx, sh_rx : std_logic_vector( 7 downto 0 );
   signal kind_s    : std_logic_vector( 1 downto 0 );
   signal last_s    : std_logic;
   signal spi_load  : std_logic;                                 -- SPI : creneau charge ce cycle

begin

   BUSY_o  <= '0' when etat = REPOS else '1';
   CS_N_o  <= cs_n;
   DQ_o    <= dq_r;
   DQ_OE_o <= oe_r;
   RWDS_o  <= rwds_r;
   RWDS_OE_o <= rwds_oe_r;
   SCLK_o  <= sclk_f when MODE_8D_i = '1' else sclk_s;
   RX_VALID_o <= rx_v;
   RX_BYTE_o  <= rx_b;

   -- octal : un creneau par cycle ; SPI : au chargement de l'octet (debut, puis fin du
   -- huitieme bit de l'octet precedent)
   spi_load <= '1' when MODE_8D_i = '0' and SLOT_VALID_i = '1'
                        and ( etat = REPOS
                              or ( etat = SPI and div_cnt = 0 and haut = '1' and bit_cnt = 7
                                   and last_s = '0' ) ) else '0';
   SLOT_TAKE_o <= SLOT_VALID_i when MODE_8D_i = '1' and ( etat = REPOS or etat = OCTAL ) else
                  spi_load;

   -- SCLK octal : bascule au front descendant de CLK pendant les creneaux
   SCLK_DESCENDANT : process( CLK_i )
   begin
      if falling_edge( CLK_i ) then
         if RESET_i = '1' or run_r = '0' then
            sclk_f <= '0';
         else
            sclk_f <= not sclk_f;
         end if;
         f1 <= DQ_i;                                             -- echantillon SAMPLE = 1
      end if;
   end process;

   SEQUENTIEL : process( CLK_i )
      variable sel : std_logic_vector( 1 downto 0 );
   begin
      if rising_edge( CLK_i ) then
         -- echantillons de reception (toujours)
         r1 <= DQ_i; r2 <= DQ_i;
         r1q <= r1; f1q <= f1;
         m1 <= m0; m2 <= m1;
         rx_v <= '0';
         if m2 = '1' then
            rx_v <= '1';
            case to_integer( SAMPLE_i ) is
               when 0      => rx_b <= r1q;
               when 1      => rx_b <= f1q;
               when others => rx_b <= r2;
            end case;
         end if;
         m0 <= '0';

         if RESET_i = '1' then
            etat <= REPOS; cs_n <= "11"; run_r <= '0'; sclk_s <= '0';
            dq_r <= ( others => '0' ); oe_r <= ( others => '0' );
            rwds_r <= '0'; rwds_oe_r <= '0';
            m0 <= '0'; m1 <= '0'; m2 <= '0'; rx_v <= '0';
            fin_cnt <= 0; div_cnt <= ( others => '0' ); bit_cnt <= 0; haut <= '0';
         else
            case etat is
               ------------------------------------------------------------- octal
               when REPOS | OCTAL =>
                  run_r <= '0';
                  oe_r <= ( others => '0' ); rwds_oe_r <= '0';
                  if etat = REPOS and SLOT_VALID_i = '1' and MODE_8D_i = '0' then
                     -- debut d'une transaction SPI 1S
                     etat <= SPI; cs_r <= CS_SEL_i;
                     cs_n <= "11"; cs_n( 0 ) <= CS_SEL_i; cs_n( 1 ) <= not CS_SEL_i;
                     kind_s <= SLOT_KIND_i; last_s <= SLOT_LAST_i;
                     sh_tx <= SLOT_BYTE_i; bit_cnt <= 0; div_cnt <= DIV_i; haut <= '0';
                     sclk_s <= '0';
                     dq_r <= "00001100"; dq_r( 0 ) <= SLOT_BYTE_i( 7 );
                     oe_r <= "00001101";
                  elsif SLOT_VALID_i = '1' and MODE_8D_i = '1' then
                     etat <= OCTAL; cs_r <= CS_SEL_i;
                     cs_n( 0 ) <= CS_SEL_i; cs_n( 1 ) <= not CS_SEL_i;
                     run_r <= '1';
                     if SLOT_KIND_i = K_TX then
                        dq_r <= SLOT_BYTE_i; oe_r <= ( others => '1' );
                        rwds_r <= SLOT_MASK_i; rwds_oe_r <= SLOT_RWDS_i;
                     elsif SLOT_KIND_i = K_RX then
                        m0 <= '1';
                     end if;
                     if SLOT_LAST_i = '1' then
                        etat <= OCTAL_FIN;
                        fin_cnt <= 0;
                        if SLOT_KIND_i = K_RX then fin_cnt <= 2; end if;
                     end if;
                  elsif etat = OCTAL then
                     null;                                       -- creneau manquant : SCLK arrete
                  end if;
               when OCTAL_FIN =>
                  run_r <= '0';
                  oe_r <= ( others => '0' ); rwds_oe_r <= '0';
                  if fin_cnt = 0 then
                     cs_n <= "11"; etat <= REPOS;
                  else
                     fin_cnt <= fin_cnt - 1;
                  end if;

               ------------------------------------------------------------- SPI 1S
               when SPI =>
                  if div_cnt /= 0 then
                     div_cnt <= div_cnt - 1;
                  else
                     div_cnt <= DIV_i;
                     if haut = '0' then
                        -- fin de la demi-periode basse : front montant, lecture de DQ1
                        haut <= '1'; sclk_s <= '1';
                        sh_rx <= sh_rx( 6 downto 0 ) & DQ_i( 1 );
                     else
                        -- fin de la demi-periode haute : front descendant
                        haut <= '0'; sclk_s <= '0';
                        if bit_cnt = 7 then
                           -- octet fini
                           if kind_s = K_RX then
                              rx_v <= '1'; rx_b <= sh_rx;
                           end if;
                           if last_s = '1' then
                              etat <= REPOS; cs_n <= "11"; oe_r <= ( others => '0' );
                           elsif SLOT_VALID_i = '1' then
                              kind_s <= SLOT_KIND_i; last_s <= SLOT_LAST_i;
                              sh_tx <= SLOT_BYTE_i; bit_cnt <= 0;
                              dq_r( 0 ) <= SLOT_BYTE_i( 7 );
                           else
                              etat <= REPOS; cs_n <= "11"; oe_r <= ( others => '0' );
                           end if;
                        else
                           bit_cnt <= bit_cnt + 1;
                           sh_tx <= sh_tx( 6 downto 0 ) & '0';
                           dq_r( 0 ) <= sh_tx( 6 );
                        end if;
                     end if;
                  end if;
            end case;
         end if;
      end if;
   end process;

end architecture RTL;
