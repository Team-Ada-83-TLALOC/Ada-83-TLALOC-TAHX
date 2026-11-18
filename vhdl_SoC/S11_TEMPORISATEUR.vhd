library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
        --------------------------------------------------------------------------------
        -- TEMPORISATEUR : compteur sur 64 bits, deux comparateurs (ARCHI_SOC_TAHX.md § 5).
        --
        -- Le compteur avance d'un tous les PRE + 1 cycles quand ACTIF. Interruption k :
        -- niveau, IE_k et compteur >= CMP_k (comme mtimecmp de RISC-V : rien ne se perd ;
        -- le gestionnaire avance CMP_k pour l'eteindre). Pour changer CMP_k sans
        -- interruption parasite : ecrire d'abord la moitie haute a 0xFFFF_FFFF, puis la
        -- basse, puis la haute.
        -- Lecture coherente du compteur : lire CPT_BAS fige la moitie haute dans CPT_HAUT
        -- (lue ensuite).
        --
        -- Registres (bus de registres du SoC) :
        --   0 CPT_BAS   lecture : bits 31..0 (et fige les bits 63..32) ; ecriture : 31..0
        --   1 CPT_HAUT  lecture : bits 63..32 figes ; ecriture : 63..32
        --   2 CTRL      0 ACTIF, 1 IE_0, 2 IE_1
        --   3 PRE       prediviseur (32 bits)
        --   4 CMP0_BAS, 5 CMP0_HAUT, 6 CMP1_BAS, 7 CMP1_HAUT
        --   8 ETAT      (lecture) 0 compteur >= CMP0, 1 compteur >= CMP1
        -- Au RESET : compteur a 0, arrete, PRE = 0, comparateurs a 0xFFFF_FFFF_FFFF_FFFF.
        --------------------------------------------------------------------------------

entity TEMPORISATEUR is
   port (
      CLK_i        : in  std_logic;
      RESET_i      : in  std_logic;
      SEL_i        : in  std_logic;
      WE_i         : in  std_logic;
      ADDR_i       : in  unsigned( 3 downto 0 );
      WDATA_i      : in  std_logic_vector( 31 downto 0 );
      RDATA_o      : out std_logic_vector( 31 downto 0 );
      IRQ_o        : out std_logic_vector( 1 downto 0 )
   );
end entity TEMPORISATEUR;

architecture RTL of TEMPORISATEUR is
   signal cpt, cmp0, cmp1 : unsigned( 63 downto 0 );
   signal haut_fige : unsigned( 31 downto 0 );
   signal pre, div  : unsigned( 31 downto 0 );
   signal actif, ie0, ie1 : std_logic;
   signal ge0, ge1  : std_logic;
begin

   ge0 <= '1' when cpt >= cmp0 else '0';
   ge1 <= '1' when cpt >= cmp1 else '0';
   IRQ_o <= ( ie1 and ge1 ) & ( ie0 and ge0 );

   LECTURE : process( all )
   begin
      RDATA_o <= ( others => '0' );
      case to_integer( ADDR_i ) is
         when 0 => RDATA_o <= std_logic_vector( cpt( 31 downto 0 ) );
         when 1 => RDATA_o <= std_logic_vector( haut_fige );
         when 2 => RDATA_o( 2 downto 0 ) <= ie1 & ie0 & actif;
         when 3 => RDATA_o <= std_logic_vector( pre );
         when 4 => RDATA_o <= std_logic_vector( cmp0( 31 downto 0 ) );
         when 5 => RDATA_o <= std_logic_vector( cmp0( 63 downto 32 ) );
         when 6 => RDATA_o <= std_logic_vector( cmp1( 31 downto 0 ) );
         when 7 => RDATA_o <= std_logic_vector( cmp1( 63 downto 32 ) );
         when 8 => RDATA_o( 1 downto 0 ) <= ge1 & ge0;
         when others => null;
      end case;
   end process;

   SEQUENTIEL : process( CLK_i )
      variable w : unsigned( 31 downto 0 );
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            cpt <= ( others => '0' ); haut_fige <= ( others => '0' );
            cmp0 <= ( others => '1' ); cmp1 <= ( others => '1' );
            pre <= ( others => '0' ); div <= ( others => '0' );
            actif <= '0'; ie0 <= '0'; ie1 <= '0';
         else
            -- comptage
            if actif = '1' then
               if div >= pre then
                  div <= ( others => '0' ); cpt <= cpt + 1;
               else
                  div <= div + 1;
               end if;
            end if;
            -- registres
            w := unsigned( WDATA_i );
            if SEL_i = '1' and WE_i = '0' and ADDR_i = 0 then
               haut_fige <= cpt( 63 downto 32 );
            end if;
            if SEL_i = '1' and WE_i = '1' then
               case to_integer( ADDR_i ) is
                  when 0 => cpt( 31 downto 0 ) <= w; div <= ( others => '0' );
                  when 1 => cpt( 63 downto 32 ) <= w; div <= ( others => '0' );
                  when 2 => actif <= WDATA_i( 0 ); ie0 <= WDATA_i( 1 ); ie1 <= WDATA_i( 2 );
                  when 3 => pre <= w;
                  when 4 => cmp0( 31 downto 0 ) <= w;
                  when 5 => cmp0( 63 downto 32 ) <= w;
                  when 6 => cmp1( 31 downto 0 ) <= w;
                  when 7 => cmp1( 63 downto 32 ) <= w;
                  when others => null;
               end case;
            end if;
         end if;
      end if;
   end process;

end architecture RTL;
