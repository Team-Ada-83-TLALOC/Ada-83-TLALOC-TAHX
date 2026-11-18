library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.SOC_TYPES.all;

        --------------------------------------------------------------------------------
        -- SOC_MATRICE : matrice 2 x 2 entre les bus memoire du coeur et les deux ports xSPI
        --   (ARCHI_SOC_TAHX.md § 2, § 2.1, § 3).
        --
        --   maitres : I (instructions, lecture seule), D (donnees)
        --   esclaves : port A (0), port B (1) ; un contrôleur xSPI par port.
        --
        -- Protocole de chaque cote, celui de TAHX_1 : REQ / READY (requete acceptee quand
        -- les deux sont a 1), reponses de lecture RVALID / RDATA / FAULT dans l'ordre, une
        -- par mot ; une ecriture n'a pas de reponse. Les caches demandent une ligne de
        -- 32 octets par quatre mots de 64 bits aux adresses ligne + 0, 8, 16, 24, sans
        -- attendre les reponses ; le contrôleur xSPI les regroupe en une transaction.
        --
        -- Regles :
        --   - decodage par SOC_DECODE (fenetres de 256 Mio, BOOT_SEL echange les deux
        --     fenetres du port A) ; hors fenetre, la matrice repond elle-meme : requete
        --     acceptee tout de suite, lecture rendue en faute au cycle suivant (I_FAULT /
        --     D_FAULT, faute 132 du coeur) ;
        --   - deux maitres vers deux ports differents travaillent en parallele ;
        --   - sur un meme port, attribution par ligne, donnees avant instructions (D > I) ;
        --     un port est pris a l'acceptation du premier mot et rendu apres le quatrieme
        --     mot accepte (ecriture) ou la quatrieme reponse (lecture) : une ligne
        --     commencee n'est jamais interrompue ;
        --   - un maitre n'a qu'une ligne en cours (les caches sont serialises).
        -- Le troisieme maitre (debogage, priorite la plus basse) viendra avec le module
        -- de debogage (ARCHI § 5.1).
        --------------------------------------------------------------------------------

entity SOC_MATRICE is
   port (
      CLK_i        : in  std_logic;
      RESET_i      : in  std_logic;
      BOOT_SEL_i   : in  std_logic;                              -- constant apres le RESET

      -- maitre I (TAHX_1, I_*)
      I_REQ_i      : in  std_logic;
      I_ADDR_i     : in  address_t;
      I_READY_o    : out std_logic;
      I_RVALID_o   : out std_logic;
      I_RDATA_o    : out word64_t;
      I_FAULT_o    : out std_logic;

      -- maitre D (TAHX_1, D_*)
      D_REQ_i      : in  std_logic;
      D_WRITE_i    : in  std_logic;
      D_ADDR_i     : in  address_t;
      D_WDATA_i    : in  word64_t;
      D_READY_o    : out std_logic;
      D_RVALID_o   : out std_logic;
      D_RDATA_o    : out word64_t;
      D_FAULT_o    : out std_logic;

      -- esclaves : ports xSPI A (0) et B (1)
      S_REQ_o      : out std_logic_vector( 0 to SOC_PORTS - 1 );
      S_WRITE_o    : out std_logic_vector( 0 to SOC_PORTS - 1 );
      S_CS_o       : out std_logic_vector( 0 to SOC_PORTS - 1 );     -- selection du port
      S_ADDR_o     : out soc_pa_array_t( 0 to SOC_PORTS - 1 );       -- adresse physique
      S_WDATA_o    : out soc_word_array_t( 0 to SOC_PORTS - 1 );
      S_READY_i    : in  std_logic_vector( 0 to SOC_PORTS - 1 );
      S_RVALID_i   : in  std_logic_vector( 0 to SOC_PORTS - 1 );
      S_RDATA_i    : in  soc_word_array_t( 0 to SOC_PORTS - 1 );
      S_FAULT_i    : in  std_logic_vector( 0 to SOC_PORTS - 1 )
   );
end entity SOC_MATRICE;

architecture RTL of SOC_MATRICE is

   type owner_t is ( LIBRE, PAR_I, PAR_D );
   type owner_array_t is array( 0 to SOC_PORTS - 1 ) of owner_t;
   subtype count_t is natural range 0 to SOC_LINE_WORDS;
   type count_array_t is array( 0 to SOC_PORTS - 1 ) of count_t;

   signal owner     : owner_array_t;
   signal acc, rsp  : count_array_t;                             -- mots acceptes, reponses
   signal ecriture  : std_logic_vector( 0 to SOC_PORTS - 1 );    -- ligne en cours en ecriture

   signal ti, td    : soc_target_t;
   signal sel       : owner_array_t;                             -- maitre servi ce cycle par port
   signal i_hors, d_hors : std_logic;                            -- requete hors fenetre
   signal i_faute_r, d_faute_r : std_logic;                      -- reponse en faute au cycle suivant

   function port_de( t : soc_target_t ) return natural is
   begin
      if t.port_b = '1' then return 1; else return 0; end if;
   end function;

begin

   ti <= SOC_DECODE( I_ADDR_i, BOOT_SEL_i );
   td <= SOC_DECODE( D_ADDR_i, BOOT_SEL_i );
   i_hors <= I_REQ_i and not ti.mapped;
   d_hors <= D_REQ_i and not td.mapped;

   -- attribution, par port
   ATTRIBUTION : process( all )
      variable veut_i, veut_d : boolean;
   begin
      for p in 0 to SOC_PORTS - 1 loop
         veut_i := I_REQ_i = '1' and ti.mapped = '1' and port_de( ti ) = p;
         veut_d := D_REQ_i = '1' and td.mapped = '1' and port_de( td ) = p;
         sel( p ) <= LIBRE;
         case owner( p ) is
            when LIBRE =>
               if veut_d then
                  sel( p ) <= PAR_D;
               elsif veut_i then
                  sel( p ) <= PAR_I;
               end if;
            when PAR_I =>
               if veut_i and acc( p ) < SOC_LINE_WORDS then
                  sel( p ) <= PAR_I;
               end if;
            when PAR_D =>
               if veut_d and acc( p ) < SOC_LINE_WORDS then
                  sel( p ) <= PAR_D;
               end if;
         end case;
      end loop;
   end process;

   -- requetes vers les ports
   VERS_PORTS : process( all )
   begin
      for p in 0 to SOC_PORTS - 1 loop
         S_REQ_o( p )   <= '0';
         S_WRITE_o( p ) <= '0';
         S_CS_o( p )    <= '0';
         S_ADDR_o( p )  <= ( others => '0' );
         S_WDATA_o( p ) <= D_WDATA_i;
         if sel( p ) = PAR_D then
            S_REQ_o( p )   <= '1';
            S_WRITE_o( p ) <= D_WRITE_i;
            S_CS_o( p )    <= td.cs;
            S_ADDR_o( p )  <= D_ADDR_i( SOC_PA_BITS - 1 downto 0 );
         elsif sel( p ) = PAR_I then
            S_REQ_o( p )   <= '1';
            S_CS_o( p )    <= ti.cs;
            S_ADDR_o( p )  <= I_ADDR_i( SOC_PA_BITS - 1 downto 0 );
         end if;
      end loop;
   end process;

   -- acceptation vers les maitres
   I_READY_o <= '1' when i_hors = '1' else
                S_READY_i( port_de( ti ) ) when sel( port_de( ti ) ) = PAR_I else '0';
   D_READY_o <= '1' when d_hors = '1' else
                S_READY_i( port_de( td ) ) when sel( port_de( td ) ) = PAR_D else '0';

   -- reponses vers les maitres
   REPONSES : process( all )
   begin
      I_RVALID_o <= i_faute_r;
      I_FAULT_o  <= i_faute_r;
      I_RDATA_o  <= ( others => '0' );
      D_RVALID_o <= d_faute_r;
      D_FAULT_o  <= d_faute_r;
      D_RDATA_o  <= ( others => '0' );
      for p in 0 to SOC_PORTS - 1 loop
         if S_RVALID_i( p ) = '1' and owner( p ) = PAR_I then
            I_RVALID_o <= '1';
            I_FAULT_o  <= S_FAULT_i( p );
            I_RDATA_o  <= S_RDATA_i( p );
         elsif S_RVALID_i( p ) = '1' and owner( p ) = PAR_D then
            D_RVALID_o <= '1';
            D_FAULT_o  <= S_FAULT_i( p );
            D_RDATA_o  <= S_RDATA_i( p );
         end if;
      end loop;
   end process;

   SEQUENTIEL : process( CLK_i )
      variable a, r : count_t;
      variable o    : owner_t;
      variable w    : std_logic;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            owner     <= ( others => LIBRE );
            acc       <= ( others => 0 );
            rsp       <= ( others => 0 );
            ecriture  <= ( others => '0' );
            i_faute_r <= '0';
            d_faute_r <= '0';
         else
            i_faute_r <= i_hors;                                  -- I ne fait que lire
            d_faute_r <= d_hors and not D_WRITE_i;                -- ecriture hors fenetre : perdue
            for p in 0 to SOC_PORTS - 1 loop
               o := owner( p ); a := acc( p ); r := rsp( p ); w := ecriture( p );
               if S_REQ_o( p ) = '1' and S_READY_i( p ) = '1' then
                  if o = LIBRE then
                     o := sel( p ); w := S_WRITE_o( p ); a := 0; r := 0;
                  end if;
                  a := a + 1;
               end if;
               if S_RVALID_i( p ) = '1' and o /= LIBRE and r < SOC_LINE_WORDS then
                  r := r + 1;
               end if;
               if a = SOC_LINE_WORDS and ( w = '1' or r = SOC_LINE_WORDS ) then
                  o := LIBRE; a := 0; r := 0; w := '0';            -- ligne terminee
               end if;
               owner( p ) <= o; acc( p ) <= a; rsp( p ) <= r; ecriture( p ) <= w;
            end loop;
         end if;
      end if;
   end process;

   -- pragma translate_off
   CONTROLES : process( CLK_i )
   begin
      if rising_edge( CLK_i ) and RESET_i = '0' then
         for p in 0 to SOC_PORTS - 1 loop
            assert not ( S_RVALID_i( p ) = '1' and owner( p ) = LIBRE )
               report "SOC_MATRICE : reponse du port " & integer'image( p ) & " sans ligne en cours"
               severity error;
            assert not ( S_RVALID_i( p ) = '1' and ecriture( p ) = '1' )
               report "SOC_MATRICE : reponse du port " & integer'image( p ) & " a une ecriture"
               severity error;
         end loop;
         assert not ( d_hors = '1' and D_WRITE_i = '1' )
            report "SOC_MATRICE : ecriture hors fenetre, perdue" severity warning;
      end if;
   end process;
   -- pragma translate_on

end architecture RTL;
