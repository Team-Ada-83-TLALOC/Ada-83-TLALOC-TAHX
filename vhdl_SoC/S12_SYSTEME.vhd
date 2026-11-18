library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
        --------------------------------------------------------------------------------
        -- SYSTEME : registres systeme, GPIO, interruptions, MEM_RESET#, demarrage
        --   (ARCHI_SOC_TAHX.md § 4.3, § 4.5, § 5, § 6, § 7).
        --
        -- Demarrage : pendant RESET_i (RESET de la puce), MEM_RESET_x# en haute impedance
        -- (rappel sur la carte, programmateur externe possible). A la sortie du RESET :
        -- GPIO0 echantillonnee = BOOT_SEL ; impulsion basse de MR_IMPULSION_G cycles sur
        -- MEM_RESET_A# et MEM_RESET_B#, puis MR_REPRISE_G cycles de reprise des memoires ;
        -- CORE_HOLD_o tient le coeur en RESET jusque-la.
        --
        -- Registres (bus de registres du SoC) :
        --   0  ID          identifiant de la puce (ID_G)
        --   1  CONFIG      (lecture) 0 BOOT_SEL
        --   2  NULL_GUARD  4..0 : zone de garde contre null sous 2 ** n (0 : sans)
        --   3  IRQ_SOURCES (lecture) les 32 lignes avant masque
        --   4  IRQ_MASQUE  IRQ_PENDING du coeur = sources et masque (0 au RESET)
        --   5  CACHES      ecrire 1 au bit 0 : ICACHE_INVALIDATE_ALL (impulsion)
        --   6  MEM_RESET   ecrire 1 au bit 0 (port A), 1 (port B) : impulsion ; lecture :
        --                  0, 1 impulsion en cours, 2 demarrage termine
        --   7  GPIO_DIR    1 : sortie (8 bits, 0 au RESET)
        --   8  GPIO_SORTIE
        --   9  GPIO_ENTREE (lecture, resynchronisees)
        --   10 GPIO_IT_EN  interruption sur front montant, par broche
        --   11 GPIO_IT_ETAT fronts vus (collants, ecrire 1 pour effacer)
        --   12 GPIO_FONCTION 0 : GPIO7 = HALTED du coeur (1 au RESET : un premier
        --                  silicium qui se bloque se voit sans logiciel)
        --   13 EXIT_CODE bits 31..0, 14 EXIT_CODE bits 63..32, 15 FPC (31..0)
        --   16 FAUTE       7..0 FCODE, 10..8 HALT_CAUSE, 16 HALTED
        --   17 SCRATCH     libre
        -- IRQ_GPIO_o : OU des fronts vus et valides (une ligne de IRQ_SOURCES).
        --------------------------------------------------------------------------------

entity SYSTEME is
   generic (
      ID_G          : std_logic_vector( 31 downto 0 ) := x"7A580001";
      MR_IMPULSION_G : positive := 36;                           -- 1 us a 36 MHz
      MR_REPRISE_G  : positive := 3600                           -- 100 us
   );
   port (
      CLK_i         : in  std_logic;
      RESET_i       : in  std_logic;

      SEL_i         : in  std_logic;
      WE_i          : in  std_logic;
      ADDR_i        : in  unsigned( 4 downto 0 );
      WDATA_i       : in  std_logic_vector( 31 downto 0 );
      RDATA_o       : out std_logic_vector( 31 downto 0 );

      -- coeur
      CORE_HOLD_o   : out std_logic;
      BOOT_SEL_o    : out std_logic;
      NULL_GUARD_o  : out unsigned( 4 downto 0 );
      ICACHE_INVALIDATE_o : out std_logic;
      IRQ_SOURCES_i : in  std_logic_vector( 31 downto 0 );
      IRQ_PENDING_o : out std_logic_vector( 31 downto 0 );
      IRQ_GPIO_o    : out std_logic;
      EXIT_CODE_i   : in  std_logic_vector( 63 downto 0 );
      FPC_i         : in  std_logic_vector( 31 downto 0 );
      FCODE_i       : in  std_logic_vector( 7 downto 0 );
      HALT_CAUSE_i  : in  std_logic_vector( 2 downto 0 );
      HALTED_i      : in  std_logic;

      -- plots
      MEM_RESET_A_N_o : out std_logic;
      MEM_RESET_B_N_o : out std_logic;
      MEM_RESET_OE_o  : out std_logic;                           -- 0 pendant le RESET
      GPIO_o        : out std_logic_vector( 7 downto 0 );
      GPIO_OE_o     : out std_logic_vector( 7 downto 0 );
      GPIO_i        : in  std_logic_vector( 7 downto 0 )
   );
end entity SYSTEME;

architecture RTL of SYSTEME is
   type demar_t is ( D_RESET, D_IMPULSION, D_REPRISE, D_PRET );
   signal demar    : demar_t;
   signal cpt      : natural range 0 to MR_IMPULSION_G + MR_REPRISE_G;
   signal mr_a, mr_b : std_logic;                                -- impulsion logicielle en cours
   signal mr_cpt   : natural range 0 to MR_IMPULSION_G;
   signal boot_sel : std_logic;
   signal ng       : unsigned( 4 downto 0 );
   signal masque   : std_logic_vector( 31 downto 0 );
   signal inval    : std_logic;
   signal dir, sortie, it_en, it_etat : std_logic_vector( 7 downto 0 );
   signal e1, e2, e3 : std_logic_vector( 7 downto 0 );
   signal fonction : std_logic;
   signal scratch  : std_logic_vector( 31 downto 0 );
   signal pret     : std_logic;
begin

   pret         <= '1' when demar = D_PRET else '0';
   CORE_HOLD_o  <= not pret;
   BOOT_SEL_o   <= boot_sel;
   NULL_GUARD_o <= ng;
   ICACHE_INVALIDATE_o <= inval;
   IRQ_PENDING_o <= IRQ_SOURCES_i and masque;
   IRQ_GPIO_o   <= '1' when ( it_etat and it_en ) /= x"00" else '0';

   MEM_RESET_OE_o  <= '0' when demar = D_RESET else '1';
   MEM_RESET_A_N_o <= '0' when demar = D_IMPULSION or mr_a = '1' else '1';
   MEM_RESET_B_N_o <= '0' when demar = D_IMPULSION or mr_b = '1' else '1';

   GPIO_OE_o( 6 downto 0 ) <= dir( 6 downto 0 );
   GPIO_OE_o( 7 ) <= dir( 7 ) or fonction;
   GPIO_o( 6 downto 0 ) <= sortie( 6 downto 0 );
   GPIO_o( 7 ) <= HALTED_i when fonction = '1' else sortie( 7 );

   LECTURE : process( all )
   begin
      RDATA_o <= ( others => '0' );
      case to_integer( ADDR_i ) is
         when 0  => RDATA_o <= ID_G;
         when 1  => RDATA_o( 0 ) <= boot_sel;
         when 2  => RDATA_o( 4 downto 0 ) <= std_logic_vector( ng );
         when 3  => RDATA_o <= IRQ_SOURCES_i;
         when 4  => RDATA_o <= masque;
         when 6  => RDATA_o( 2 downto 0 ) <= pret & mr_b & mr_a;
         when 7  => RDATA_o( 7 downto 0 ) <= dir;
         when 8  => RDATA_o( 7 downto 0 ) <= sortie;
         when 9  => RDATA_o( 7 downto 0 ) <= e2;
         when 10 => RDATA_o( 7 downto 0 ) <= it_en;
         when 11 => RDATA_o( 7 downto 0 ) <= it_etat;
         when 12 => RDATA_o( 0 ) <= fonction;
         when 13 => RDATA_o <= EXIT_CODE_i( 31 downto 0 );
         when 14 => RDATA_o <= EXIT_CODE_i( 63 downto 32 );
         when 15 => RDATA_o <= FPC_i;
         when 16 => RDATA_o( 7 downto 0 ) <= FCODE_i; RDATA_o( 10 downto 8 ) <= HALT_CAUSE_i;
                    RDATA_o( 16 ) <= HALTED_i;
         when 17 => RDATA_o <= scratch;
         when others => null;
      end case;
   end process;

   SEQUENTIEL : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         e1 <= GPIO_i; e2 <= e1; e3 <= e2;
         if RESET_i = '1' then
            demar <= D_RESET; cpt <= 0; mr_a <= '0'; mr_b <= '0'; mr_cpt <= 0;
            boot_sel <= '0'; ng <= ( others => '0' ); masque <= ( others => '0' ); inval <= '0';
            dir <= ( others => '0' ); sortie <= ( others => '0' ); it_en <= ( others => '0' );
            it_etat <= ( others => '0' ); fonction <= '1'; scratch <= ( others => '0' );
         else
            inval <= '0';
            -- demarrage
            case demar is
               when D_RESET =>
                  boot_sel <= e2( 0 );                           -- GPIO0, rappel sur la carte
                  demar <= D_IMPULSION; cpt <= 0;
               when D_IMPULSION =>
                  if cpt = MR_IMPULSION_G - 1 then demar <= D_REPRISE; cpt <= 0; else cpt <= cpt + 1; end if;
               when D_REPRISE =>
                  if cpt = MR_REPRISE_G - 1 then demar <= D_PRET; else cpt <= cpt + 1; end if;
               when D_PRET => null;
            end case;
            -- impulsion logicielle
            if mr_a = '1' or mr_b = '1' then
               if mr_cpt = MR_IMPULSION_G - 1 then mr_a <= '0'; mr_b <= '0'; mr_cpt <= 0;
               else mr_cpt <= mr_cpt + 1; end if;
            end if;
            -- fronts montants des GPIO
            it_etat <= it_etat or ( e2 and not e3 );
            -- registres
            if SEL_i = '1' and WE_i = '1' then
               case to_integer( ADDR_i ) is
                  when 2  => ng <= unsigned( WDATA_i( 4 downto 0 ) );
                  when 4  => masque <= WDATA_i;
                  when 5  => inval <= WDATA_i( 0 );
                  when 6  =>
                     if mr_a = '0' and mr_b = '0' then
                        mr_a <= WDATA_i( 0 ); mr_b <= WDATA_i( 1 ); mr_cpt <= 0;
                     end if;
                  when 7  => dir <= WDATA_i( 7 downto 0 );
                  when 8  => sortie <= WDATA_i( 7 downto 0 );
                  when 10 => it_en <= WDATA_i( 7 downto 0 );
                  when 11 => it_etat <= ( it_etat or ( e2 and not e3 ) ) and not WDATA_i( 7 downto 0 );
                  when 12 => fonction <= WDATA_i( 0 );
                  when 17 => scratch <= WDATA_i;
                  when others => null;
               end case;
            end if;
         end if;
      end if;
   end process;

end architecture RTL;
