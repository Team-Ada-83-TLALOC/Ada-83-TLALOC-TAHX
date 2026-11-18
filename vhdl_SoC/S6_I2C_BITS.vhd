library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
        --------------------------------------------------------------------------------
        -- I2C_BITS : couche de bits d'un maitre I2C (ARCHI_SOC_TAHX.md § 5). Separee de la
        --   couche d'octets (I2C) pour qu'un controleur I3C basic reutilise les plots, la
        --   synchronisation et le decoupage du temps, et y ajoute plus tard son mode SDR.
        --
        -- Commandes (CMD_i, prises quand PRET_o = 1 et CMD_VALID_i = 1) :
        --   00 START (START repete si le bus est deja a nous), 01 STOP, 10 ecriture du bit
        --   CMD_BIT_i, 11 lecture d'un bit (SDA relachee). FAIT_o : fin de la commande, avec
        --   BIT_o (bit lu sur SDA au milieu de SCL haut) et PERDU_o (arbitrage perdu : un 1
        --   ecrit lu a 0, START ou STOP empeches ; les lignes sont alors relachees).
        -- Un bit : SCL bas (T_BAS cycles ; SDA change au milieu), SCL relache, attente de
        -- SCL haut (etirement par l'esclave), T_HAUT cycles, SCL bas. START depuis le repos :
        -- attente du bus libre (ni START sans STOP vu sur les lignes, ni ligne basse), SDA
        -- basse, T_HAUT (tHD;STA), SCL basse. START repete : SDA relachee pendant SCL bas,
        -- SCL haut, T_HAUT (tSU;STA), SDA basse, T_HAUT, SCL bas. STOP : SDA basse pendant
        -- SCL bas, SCL haut, T_HAUT (tSU;STO), SDA relachee, T_BAS de bus libre (tBUF).
        -- Reglages a 36 MHz : 100 kHz T_BAS = 180, T_HAUT = 160 ; 400 kHz 48 / 24 ;
        -- 1 MHz (Fm+) 20 / 12 (tLOW >= 0,5 us, tHIGH >= 0,26 us).
        --
        -- Plots : drain ouvert (X_o = 0, X_OE_o = 1 pour tirer la ligne a 0, X_OE_o = 0
        -- pour la relacher). SCL_PP_i = 1 : SCL en push-pull (X_OE_o = 1, X_o = niveau ;
        -- maitre unique, sans etirement) ; I3C pilotera aussi SDA en push-pull. SCL_i et
        -- SDA_i sont resynchronisees (deux bascules). ACTIF_i = 0 : lignes relachees.
        --------------------------------------------------------------------------------

entity I2C_BITS is
   port (
      CLK_i        : in  std_logic;
      RESET_i      : in  std_logic;
      ACTIF_i      : in  std_logic;
      T_BAS_i      : in  unsigned( 15 downto 0 );
      T_HAUT_i     : in  unsigned( 15 downto 0 );
      SCL_PP_i     : in  std_logic;

      CMD_VALID_i  : in  std_logic;
      CMD_i        : in  std_logic_vector( 1 downto 0 );
      CMD_BIT_i    : in  std_logic;
      PRET_o       : out std_logic;
      FAIT_o       : out std_logic;
      BIT_o        : out std_logic;
      PERDU_o      : out std_logic;
      POSSEDE_o    : out std_logic;                              -- bus a nous (START sans STOP)
      BUS_OCCUPE_o : out std_logic;                              -- START vu sur les lignes, sans STOP

      SCL_o        : out std_logic;
      SCL_OE_o     : out std_logic;
      SCL_i        : in  std_logic;
      SDA_o        : out std_logic;
      SDA_OE_o     : out std_logic;
      SDA_i        : in  std_logic
   );
end entity I2C_BITS;

architecture RTL of I2C_BITS is

   constant C_START : std_logic_vector( 1 downto 0 ) := "00";
   constant C_STOP  : std_logic_vector( 1 downto 0 ) := "01";
   constant C_ECR   : std_logic_vector( 1 downto 0 ) := "10";

   type etat_t is ( REPOS, ATT_LIBRE, BAS1, BAS2, MONTE, HAUT1, HAUT2, TIENT, LIBRE, PERTE );
   signal etat     : etat_t;
   signal cmd      : std_logic_vector( 1 downto 0 );
   signal bit_e    : std_logic;
   signal cpt      : unsigned( 15 downto 0 );
   signal scl_bas, sda_bas : std_logic;                          -- lignes tirees a 0 par nous
   signal possede  : std_logic;
   signal lu       : std_logic;

   signal scl_s1, scl_s, sda_s1, sda_s, sda_p, scl_p : std_logic;
   signal occupe   : std_logic;

begin

   PRET_o       <= '1' when etat = REPOS else '0';
   POSSEDE_o    <= possede;
   BUS_OCCUPE_o <= occupe;

   SCL_o    <= '0' when SCL_PP_i = '0' else not scl_bas;
   SCL_OE_o <= ACTIF_i and ( scl_bas or SCL_PP_i );
   SDA_o    <= '0';
   SDA_OE_o <= ACTIF_i and sda_bas;

   SEQUENTIEL : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         scl_s1 <= SCL_i; scl_s <= scl_s1; sda_s1 <= SDA_i; sda_s <= sda_s1;
         scl_p <= scl_s; sda_p <= sda_s;
         FAIT_o <= '0'; PERDU_o <= '0';

         -- bus occupe : START (SDA descend, SCL haut) ... STOP (SDA monte, SCL haut)
         if scl_s = '1' and scl_p = '1' and sda_p = '1' and sda_s = '0' then
            occupe <= '1';
         elsif scl_s = '1' and scl_p = '1' and sda_p = '0' and sda_s = '1' then
            occupe <= '0';
         end if;

         if RESET_i = '1' or ACTIF_i = '0' then
            etat <= REPOS; scl_bas <= '0'; sda_bas <= '0'; possede <= '0'; occupe <= '0';
            scl_s1 <= '1'; scl_s <= '1'; sda_s1 <= '1'; sda_s <= '1'; scl_p <= '1'; sda_p <= '1';
            BIT_o <= '0';
         else
            case etat is
               when REPOS =>
                  if CMD_VALID_i = '1' then
                     cmd <= CMD_i; bit_e <= CMD_BIT_i;
                     if CMD_i = C_START and possede = '0' then
                        etat <= ATT_LIBRE;
                     else
                        etat <= BAS1; cpt <= '0' & T_BAS_i( 15 downto 1 );
                     end if;
                  end if;

               when ATT_LIBRE =>                                  -- START depuis le repos
                  if occupe = '0' and scl_s = '1' and sda_s = '1' then
                     sda_bas <= '1'; possede <= '1';
                     etat <= TIENT; cpt <= T_HAUT_i;
                  end if;

               when BAS1 =>                                       -- SCL bas, premiere moitie
                  if cpt /= 0 then
                     cpt <= cpt - 1;
                  else
                     if cmd = C_STOP then sda_bas <= '1';
                     elsif cmd = C_ECR then sda_bas <= not bit_e;
                     else sda_bas <= '0'; end if;                   -- lecture, START repete
                     etat <= BAS2; cpt <= T_BAS_i - ( '0' & T_BAS_i( 15 downto 1 ) );
                  end if;

               when BAS2 =>
                  if cpt /= 0 then
                     cpt <= cpt - 1;
                  else
                     scl_bas <= '0'; etat <= MONTE;
                  end if;

               when MONTE =>                                      -- etirement par l'esclave
                  if scl_s = '1' or SCL_PP_i = '1' then
                     etat <= HAUT1; cpt <= '0' & T_HAUT_i( 15 downto 1 );
                  end if;

               when HAUT1 =>
                  if cpt /= 0 then
                     cpt <= cpt - 1;
                  else
                     lu <= sda_s;
                     if ( cmd = C_ECR and bit_e = '1' and sda_s = '0' )
                        or ( cmd = C_START and sda_s = '0' ) then
                        etat <= PERTE;
                     else
                        etat <= HAUT2; cpt <= T_HAUT_i - ( '0' & T_HAUT_i( 15 downto 1 ) );
                     end if;
                  end if;

               when HAUT2 =>
                  if cpt /= 0 then
                     cpt <= cpt - 1;
                  elsif cmd = C_STOP then
                     sda_bas <= '0'; etat <= LIBRE; cpt <= T_BAS_i;
                  elsif cmd = C_START then
                     sda_bas <= '1'; etat <= TIENT; cpt <= T_HAUT_i;   -- START repete
                  else
                     scl_bas <= '1'; etat <= REPOS;
                     FAIT_o <= '1'; BIT_o <= lu;
                  end if;

               when TIENT =>                                      -- tHD;STA
                  if cpt /= 0 then
                     cpt <= cpt - 1;
                  else
                     scl_bas <= '1'; etat <= REPOS; FAIT_o <= '1';
                  end if;

               when LIBRE =>                                      -- tBUF apres STOP
                  if cpt /= 0 then
                     cpt <= cpt - 1;
                  else
                     possede <= '0'; etat <= REPOS; FAIT_o <= '1';
                     if sda_s = '0' then PERDU_o <= '1'; end if;
                  end if;

               when PERTE =>
                  scl_bas <= '0'; sda_bas <= '0'; possede <= '0';
                  etat <= REPOS; FAIT_o <= '1'; PERDU_o <= '1';
            end case;
         end if;
      end if;
   end process;

end architecture RTL;
