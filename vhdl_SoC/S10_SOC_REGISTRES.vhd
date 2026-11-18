library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;

        --------------------------------------------------------------------------------
        -- SOC_REGISTRES : port R_* de TAHX_1 (0xF000_0000, 1 Mio) vers le bus de registres
        --   des peripheriques (ARCHI_SOC_TAHX.md § 2.2, § 5).
        --
        -- Un bloc de 4 Kio par peripherique (R_ADDR_i 19..12) ; registres de 32 bits,
        -- numero R_ADDR_i 11..2 :
        --   0xF000_0000  registres systeme  (NB_G( 0 ) registres)
        --   0xF000_1000  temporisateur
        --   0xF000_2000  UART
        --   0xF000_3000  I2C
        --   0xF000_4000  xSPI A
        --   0xF000_5000  xSPI B
        -- Acces valide : 32 bits (R_SIZE = 10), aligne, bloc existant, numero < NB_G du
        -- bloc ; sinon faute (132 au coeur), sans acces. Lecture : valeur dans les bits
        -- 31..0 de la reponse, 63..32 a 0 ; ecriture : bits 31..0 de R_WDATA.
        -- Temps : requete prise (R_READY = 1 au repos), mise en registre ; au cycle
        -- suivant, SEL d'un cycle vers le bloc (effet d'une lecture a ce front) et reponse
        -- mise en registre ; R_RVALID au cycle d'apres. Une requete a la fois (le cache
        -- et INO_ATTRIBUTS n'en presentent qu'une). Les fils de R_* traversent la puce
        -- (est du cache de donnees -> bloc sud-est) : rien de combinatoire de R_* aux
        -- peripheriques.
        --------------------------------------------------------------------------------

entity SOC_REGISTRES is
   generic (
      NB_BLOCS_G    : positive := 6
   );
   port (
      CLK_i         : in  std_logic;
      RESET_i       : in  std_logic;

      R_REQ_i       : in  std_logic;
      R_WRITE_i     : in  std_logic;
      R_ADDR_i      : in  unsigned( 19 downto 0 );
      R_SIZE_i      : in  unsigned( 1 downto 0 );
      R_WDATA_i     : in  word64_t;
      R_READY_o     : out std_logic;
      R_RVALID_o    : out std_logic;
      R_RDATA_o     : out word64_t;
      R_FAULT_o     : out std_logic;

      -- bus de registres (commun) ; SEL_o( b ) : bloc b
      SEL_o         : out std_logic_vector( NB_BLOCS_G - 1 downto 0 );
      WE_o          : out std_logic;
      ADDR_o        : out unsigned( 9 downto 0 );                -- numero de registre
      WDATA_o       : out std_logic_vector( 31 downto 0 );
      RDATA_i       : in  std_logic_vector( 32 * NB_BLOCS_G - 1 downto 0 );   -- bloc b : 32 b + 31 .. 32 b
      NB_i          : in  std_logic_vector( 11 * NB_BLOCS_G - 1 downto 0 )    -- registres par bloc
   );
end entity SOC_REGISTRES;

architecture RTL of SOC_REGISTRES is

   type etat_t is ( REPOS, ACCES, REPONSE );
   signal etat    : etat_t;
   signal ecr     : std_logic;
   signal bloc    : natural range 0 to 255;
   signal num     : unsigned( 9 downto 0 );
   signal donnee  : std_logic_vector( 31 downto 0 );
   signal valide  : std_logic;
   signal lu      : std_logic_vector( 31 downto 0 );
   signal faute   : std_logic;

begin

   R_READY_o  <= '1' when etat = REPOS else '0';
   R_RVALID_o <= '1' when etat = REPONSE else '0';
   R_RDATA_o  <= x"00000000" & lu;
   R_FAULT_o  <= faute;

   WE_o    <= ecr;
   ADDR_o  <= num;
   WDATA_o <= donnee;

   SELECTION : process( all )
   begin
      SEL_o <= ( others => '0' );
      if etat = ACCES and valide = '1' then
         for b in 0 to NB_BLOCS_G - 1 loop
            if bloc = b then SEL_o( b ) <= '1'; end if;
         end loop;
      end if;
   end process;

   SEQUENTIEL : process( CLK_i )
      variable ok : boolean;
      variable b  : natural range 0 to 255;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            etat <= REPOS; valide <= '0'; faute <= '0'; lu <= ( others => '0' );
         else
            case etat is
               when REPOS =>
                  if R_REQ_i = '1' then
                     b := to_integer( R_ADDR_i( 19 downto 12 ) );
                     ok := R_SIZE_i = "10" and R_ADDR_i( 1 downto 0 ) = "00" and b < NB_BLOCS_G;
                     if ok then
                        for k in 0 to NB_BLOCS_G - 1 loop
                           if b = k and R_ADDR_i( 11 downto 2 ) >= unsigned( NB_i( 11 * k + 10 downto 11 * k ) ) then
                              ok := false;
                           end if;
                        end loop;
                     end if;
                     bloc <= b; num <= R_ADDR_i( 11 downto 2 );
                     ecr <= R_WRITE_i; donnee <= R_WDATA_i( 31 downto 0 );
                     valide <= '1' when ok else '0';
                     etat <= ACCES;
                  end if;
               when ACCES =>
                  faute <= not valide;
                  lu <= ( others => '0' );
                  if valide = '1' and ecr = '0' then
                     for k in 0 to NB_BLOCS_G - 1 loop
                        if bloc = k then lu <= RDATA_i( 32 * k + 31 downto 32 * k ); end if;
                     end loop;
                  end if;
                  etat <= REPONSE;
               when REPONSE =>
                  etat <= REPOS; faute <= '0';
            end case;
         end if;
      end if;
   end process;

end architecture RTL;
