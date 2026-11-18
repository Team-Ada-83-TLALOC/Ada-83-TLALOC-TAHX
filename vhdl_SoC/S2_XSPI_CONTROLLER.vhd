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
        -- XSPI_CONTROLLER : automate d'un port xSPI (ARCHI_SOC_TAHX.md § 4.1, § 4.3).
        --   Mode memoire : lecture et ecriture d'une ligne, demarrage en SPI 1S-1S-1S
        --   (0x03, adresse sur 3 octets), octal DTR 8D-8D-8D ensuite. Mode indirect :
        --   transaction quelconque composee par le logiciel (identifiant, registre
        --   d'etat, passage en octal, effacement, programmation, registres de PSRAM).
        --
        -- Cote matrice (S_*) : quatre mots de 64 bits consecutifs d'une meme ligne de
        -- 32 octets (garanti par SOC_MATRICE). Lecture : la transaction part au premier
        -- mot ; les trois autres sont acceptes pendant qu'elle se deroule ; chaque mot
        -- est rendu des que ses 8 octets sont arrives (petit-boutiste : l'octet de plus
        -- petite adresse dans les bits 7..0). Ecriture : les quatre mots sont acceptes,
        -- puis ecrits en une rafale (pas de reponse).
        -- Transaction, en creneaux (XSPI_PHY) :
        --   SPI 1S : commande (1 octet), adresse (3 octets, poids fort d'abord), donnees ;
        --   octal  : commande (2 octets : code, puis code ou son complement), adresse
        --            (4 octets), attente (2 x LATENCE creneaux : LATENCE cycles de SCLK),
        --            donnees (32 creneaux) ; en ecriture, RWDS pilote a 0 (masque) sur les
        --            octets de donnees.
        -- Adresse envoyee : decalage dans la fenetre de 256 Mio (bits 27..0 de l'adresse
        -- physique).
        -- Selection absente (TYPE = 00) : lecture rendue en faute, ecriture ignoree.
        --
        -- Registres (REG_ADDR : indice de mot de 32 bits) :
        --   0  CTRL     3..0 DIV (SPI 1S : SCLK = CLK / (2 (DIV + 1))), 5..4 SAMPLE (PHY)
        --   1  CFG_CS0  0 MODE_8D, 6..1 LATENCE (cycles de SCLK), 15..8 CMD_LECTURE,
        --   2  CFG_CS1  23..16 CMD_ECRITURE, 25..24 TYPE (00 absente, 01 flash, 10 PSRAM),
        --               30..26 SIZE (log2 de la taille), 31 CMD_INV (octal : second octet
        --               de commande = complement du premier)
        --   3  ETAT     (lecture seule) 0 port occupe, 1 transaction indirecte demandee
        --               ou en cours, 2 erreur : dernier GO refuse
        --   4  IND_CMD  7..0 CODE, 8 CS, 9 MODE_8D (1 octal DTR, 0 SPI 1S), 12..10 NADR
        --               (octets d'adresse, 0 a 4), 18..13 ATTENTE (octal : cycles de SCLK ;
        --               SPI : octets de 8 coups d'horloge), 19 ECRITURE (donnees envoyees
        --               depuis le tampon ; 0 : recues dans le tampon), 25..20 NDATA (0 a
        --               32 octets), 26 INV (octal : second octet de commande = complement),
        --               27 RWDS (octal, ecriture : RWDS pilote a 0, masque des PSRAM),
        --               31 GO (ecrire 1 lance la transaction)
        --   5  IND_ADR  adresse envoyee (ses NADR octets de poids faible, fort d'abord)
        --   8..15       IND_DONNEES : tampon de 32 octets, l'octet 0 dans les bits 7..0 de
        --               IND_DONNEES0 ; a ecrire avant GO, a lire apres la fin (bit 1 de
        --               ETAT a 0) ; ecritures ignorees pendant la transaction
        -- GO est refuse (bit 2 de ETAT) si une transaction indirecte est deja demandee
        -- ou en cours, si NADR > 4 ou NDATA > 32, et en octal si NADR + NDATA est impair
        -- (un octet par front : CS# doit remonter SCLK bas). Une transaction indirecte
        -- part des que le port est libre ; les requetes de la matrice attendent derriere.
        -- Le tampon indirect est distinct de la ligne du mode memoire : un defaut de cache
        -- servi par le meme port entre l'ecriture des donnees et GO ne les ecrase pas.
        -- Pendant un effacement ou une programmation, la flash ne rend pas de donnees : le
        -- code qui les pilote ne s'execute pas depuis cette flash.
        -- Au RESET, port de demarrage (BOOT_G) : CS0 flash de 16 Mio, SPI 1S, 0x03 ;
        -- CS1 absente. Autre port : les deux selections absentes. DIV = 1, SAMPLE = 1.
        -- A venir : delai de garde, MEM_RESET#, latence variable des PSRAM, adresse en
        -- mots de 16 bits de certaines PSRAM.
        --------------------------------------------------------------------------------

entity XSPI_CONTROLLER is
   generic (
      BOOT_G        : boolean := true                            -- port de demarrage (A)
   );
   port (
      CLK_i         : in  std_logic;
      RESET_i       : in  std_logic;

      -- cote matrice
      S_REQ_i       : in  std_logic;
      S_WRITE_i     : in  std_logic;
      S_CS_i        : in  std_logic;
      S_ADDR_i      : in  soc_pa_t;
      S_WDATA_i     : in  word64_t;
      S_READY_o     : out std_logic;
      S_RVALID_o    : out std_logic;
      S_RDATA_o     : out word64_t;
      S_FAULT_o     : out std_logic;

      -- registres
      REG_WE_i      : in  std_logic;
      REG_ADDR_i    : in  unsigned( 3 downto 0 );
      REG_WDATA_i   : in  std_logic_vector( 31 downto 0 );
      REG_RDATA_o   : out std_logic_vector( 31 downto 0 );

      -- vers le decodeur d'attributs (ARCHI § 2.2)
      CS_TYPE_o     : out std_logic_vector( 3 downto 0 );        -- 1..0 : CS0, 3..2 : CS1
      CS_SIZE_o     : out std_logic_vector( 9 downto 0 );        -- 4..0 : CS0, 9..5 : CS1

      -- vers le PHY
      MODE_8D_o     : out std_logic;
      DIV_o         : out unsigned( 3 downto 0 );
      SAMPLE_o      : out unsigned( 1 downto 0 );
      CS_SEL_o      : out std_logic;
      SLOT_VALID_o  : out std_logic;
      SLOT_KIND_o   : out std_logic_vector( 1 downto 0 );
      SLOT_BYTE_o   : out std_logic_vector( 7 downto 0 );
      SLOT_MASK_o   : out std_logic;
      SLOT_RWDS_o   : out std_logic;
      SLOT_LAST_o   : out std_logic;
      SLOT_TAKE_i   : in  std_logic;
      RX_VALID_i    : in  std_logic;
      RX_BYTE_i     : in  std_logic_vector( 7 downto 0 );
      PHY_BUSY_i    : in  std_logic
   );
end entity XSPI_CONTROLLER;

architecture RTL of XSPI_CONTROLLER is

   constant K_TX    : std_logic_vector( 1 downto 0 ) := "00";
   constant K_DUMMY : std_logic_vector( 1 downto 0 ) := "01";
   constant K_RX    : std_logic_vector( 1 downto 0 ) := "10";

   type cfg_array_t is array( 0 to 1 ) of std_logic_vector( 31 downto 0 );
   type tampon_t is array( 0 to 7 ) of std_logic_vector( 31 downto 0 );

   function CFG_INIT( cs : natural ) return std_logic_vector is
      variable v : std_logic_vector( 31 downto 0 ) := ( others => '0' );
   begin
      if BOOT_G and cs = 0 then
         v( 15 downto 8 )  := x"03";                             -- lecture SPI
         v( 25 downto 24 ) := "01";                              -- flash
         v( 30 downto 26 ) := std_logic_vector( to_unsigned( 24, 5 ) );   -- 16 Mio
      end if;
      return v;
   end function;

   signal ctrl    : std_logic_vector( 5 downto 0 );
   signal cfg     : cfg_array_t;

   type etat_t is ( LIBRE, COLLECTE, TRANSFERT, FAUTE );
   signal etat    : etat_t;
   signal ecr     : std_logic;
   signal cs_l    : std_logic;
   signal base    : unsigned( 27 downto 5 );                     -- ligne, dans la fenetre
   signal acc     : natural range 0 to SOC_LINE_WORDS;           -- mots acceptes
   signal ligne   : soc_word_array_t( 0 to SOC_LINE_WORDS - 1 );
   signal nrx     : natural range 0 to 32;                       -- octets recus
   signal rendus  : natural range 0 to SOC_LINE_WORDS;           -- mots rendus
   signal slot    : natural range 0 to 255;                      -- creneau courant
   signal faute_r : std_logic;

   -- mode indirect
   signal ind     : std_logic;                                   -- la transaction en cours est indirecte
   signal ind_cmd : std_logic_vector( 30 downto 0 );
   signal ind_adr : std_logic_vector( 31 downto 0 );
   signal ind_dem : std_logic;                                   -- GO accepte, transaction pas encore partie
   signal ind_err : std_logic;
   signal tampon  : tampon_t;
   signal ind_act : std_logic;
   signal go_ok   : boolean;

   -- parametres de la transaction en cours
   signal c_8d    : std_logic;
   signal c_lat   : natural range 0 to 63;
   signal c_type  : std_logic_vector( 1 downto 0 );
   signal t_cmd   : std_logic_vector( 7 downto 0 );
   signal t_inv   : std_logic;
   signal t_nadr  : natural range 0 to 7;
   signal t_att   : natural range 0 to 127;
   signal t_ndon  : natural range 0 to 63;
   signal t_ecr   : std_logic;                                   -- donnees envoyees
   signal t_rwds  : std_logic;
   signal t_adr   : std_logic_vector( 31 downto 0 );

   -- decoupage de la transaction
   signal n_cmd, n_adr, n_att, n_tot : natural range 0 to 255;

   signal pret    : std_logic;
   signal occupe, mot_pret, rvalid : std_logic;

   function CS_IDX( s : std_logic ) return natural is
   begin
      if s = '1' then return 1; else return 0; end if;
   end function;

begin

   CS_TYPE_o <= cfg( 1 )( 25 downto 24 ) & cfg( 0 )( 25 downto 24 );
   CS_SIZE_o <= cfg( 1 )( 30 downto 26 ) & cfg( 0 )( 30 downto 26 );
   DIV_o     <= unsigned( ctrl( 3 downto 0 ) );
   SAMPLE_o  <= unsigned( ctrl( 5 downto 4 ) );
   MODE_8D_o <= c_8d;
   CS_SEL_o  <= cs_l;

   -- transaction indirecte demandee ou en cours, jusqu'a la remontee de CS# (le PHY
   -- emet encore le dernier octet en SPI 1S quand tous les creneaux sont pris)
   ind_act <= ind_dem or ( ind and ( occupe or PHY_BUSY_i ) );

   LECTURE_REG : process( all )
      variable j : natural;
   begin
      REG_RDATA_o <= ( others => '0' );
      j := to_integer( REG_ADDR_i );
      case j is
         when 0      => REG_RDATA_o( 5 downto 0 ) <= ctrl;
         when 1      => REG_RDATA_o <= cfg( 0 );
         when 2      => REG_RDATA_o <= cfg( 1 );
         when 3      => REG_RDATA_o( 2 downto 0 ) <= ind_err & ind_act & ( PHY_BUSY_i or occupe );
         when 4      => REG_RDATA_o( 30 downto 0 ) <= ind_cmd;
         when 5      => REG_RDATA_o <= ind_adr;
         when 8 to 15 => REG_RDATA_o <= tampon( j - 8 );
         when others => null;
      end case;
   end process;

   -- validite d'une commande indirecte ecrite avec GO
   go_ok <= ind_act = '0'
            and unsigned( REG_WDATA_i( 12 downto 10 ) ) <= 4
            and unsigned( REG_WDATA_i( 25 downto 20 ) ) <= 32
            and ( REG_WDATA_i( 9 ) = '0'
                  or ( REG_WDATA_i( 10 ) xor REG_WDATA_i( 20 ) ) = '0' );   -- NADR + NDATA pair

   -- parametres : selection visee (au premier mot) ou transaction en cours
   c_type <= cfg( CS_IDX( S_CS_i ) )( 25 downto 24 ) when etat = LIBRE else
             cfg( CS_IDX( cs_l ) )( 25 downto 24 );
   c_lat  <= to_integer( unsigned( cfg( CS_IDX( cs_l ) )( 6 downto 1 ) ) );

   PARAMETRES : process( all )
      variable m8d : std_logic;
   begin
      if ind = '1' then
         m8d    := ind_cmd( 9 );
         t_cmd  <= ind_cmd( 7 downto 0 );
         t_inv  <= ind_cmd( 26 );
         t_nadr <= to_integer( unsigned( ind_cmd( 12 downto 10 ) ) );
         if m8d = '1' then
            t_att <= 2 * to_integer( unsigned( ind_cmd( 18 downto 13 ) ) );
         else
            t_att <= to_integer( unsigned( ind_cmd( 18 downto 13 ) ) );
         end if;
         t_ndon <= to_integer( unsigned( ind_cmd( 25 downto 20 ) ) );
         t_ecr  <= ind_cmd( 19 );
         t_rwds <= ind_cmd( 27 ) and m8d;
         t_adr  <= ind_adr;
      else
         m8d    := cfg( CS_IDX( cs_l ) )( 0 );
         if ecr = '0' then
            t_cmd <= cfg( CS_IDX( cs_l ) )( 15 downto 8 );
         else
            t_cmd <= cfg( CS_IDX( cs_l ) )( 23 downto 16 );
         end if;
         t_inv  <= cfg( CS_IDX( cs_l ) )( 31 );
         if m8d = '1' then
            t_nadr <= 4; t_att <= 2 * c_lat;
         else
            t_nadr <= 3; t_att <= 0;
         end if;
         t_ndon <= 32;
         t_ecr  <= ecr;
         t_rwds <= m8d;
         t_adr  <= "0000" & std_logic_vector( base ) & "00000";
      end if;
      c_8d <= m8d;
   end process;

   n_cmd  <= 2 when c_8d = '1' else 1;
   n_adr  <= n_cmd + t_nadr;
   n_att  <= n_adr + t_att;
   n_tot  <= n_att + t_ndon;

   -- acceptation des mots (une transaction indirecte demandee passe d'abord)
   pret <= '1' when ( etat = LIBRE and PHY_BUSY_i = '0' and ind_dem = '0' )
                  or ( etat = COLLECTE and acc < SOC_LINE_WORDS )
                  or ( etat = TRANSFERT and ind = '0' and ecr = '0' and acc < SOC_LINE_WORDS )
                  or ( etat = FAUTE and acc < SOC_LINE_WORDS ) else '0';
   S_READY_o <= pret;

   -- creneau courant
   CRENEAU : process( all )
      variable k : natural;
      variable o : natural;
   begin
      SLOT_VALID_o <= '0';
      SLOT_KIND_o  <= K_TX;
      SLOT_BYTE_o  <= ( others => '0' );
      SLOT_MASK_o  <= '1';
      SLOT_RWDS_o  <= '0';
      SLOT_LAST_o  <= '0';
      if etat = TRANSFERT and slot < n_tot then
         SLOT_VALID_o <= '1';
         k := slot;
         if k = n_tot - 1 then SLOT_LAST_o <= '1'; end if;
         if k < n_cmd then
            SLOT_BYTE_o <= t_cmd;
            if k = 1 and t_inv = '1' then SLOT_BYTE_o <= not t_cmd; end if;
         elsif k < n_adr then
            o := n_adr - 1 - k;                                  -- octet d'adresse, poids fort d'abord
            for i in 0 to 3 loop
               if o = i then
                  SLOT_BYTE_o <= t_adr( 8 * i + 7 downto 8 * i );
               end if;
            end loop;
         elsif k < n_att then
            SLOT_KIND_o <= K_DUMMY;
         else
            o := k - n_att;                                      -- octet de donnees 0..31
            if t_ecr = '1' then
               for i in 0 to 31 loop
                  if o = i then
                     if ind = '1' then
                        SLOT_BYTE_o <= tampon( i / 4 )( 8 * ( i mod 4 ) + 7 downto 8 * ( i mod 4 ) );
                     else
                        SLOT_BYTE_o <= ligne( i / 8 )( 8 * ( i mod 8 ) + 7 downto 8 * ( i mod 8 ) );
                     end if;
                  end if;
               end loop;
               SLOT_MASK_o <= '0';
               SLOT_RWDS_o <= t_rwds;
            else
               SLOT_KIND_o <= K_RX;
            end if;
         end if;
      end if;
   end process;

   -- reponses
   occupe  <= '0' when etat = LIBRE else '1';
   mot_pret <= '1' when etat = TRANSFERT and ind = '0' and ecr = '0' and rendus < acc
                        and 8 * ( rendus + 1 ) <= nrx else '0';
   rvalid  <= faute_r or mot_pret;
   S_RVALID_o <= rvalid;
   S_FAULT_o  <= faute_r;
   S_RDATA_o  <= ligne( rendus ) when etat = TRANSFERT and rendus < SOC_LINE_WORDS else
                 ( others => '0' );

   SEQUENTIEL : process( CLK_i )
      variable j : natural;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            ctrl <= "010001";                                    -- SAMPLE = 1, DIV = 1
            cfg( 0 ) <= CFG_INIT( 0 );
            cfg( 1 ) <= CFG_INIT( 1 );
            etat <= LIBRE; acc <= 0; nrx <= 0; rendus <= 0; slot <= 0;
            ecr <= '0'; cs_l <= '0'; faute_r <= '0';
            ind <= '0'; ind_dem <= '0'; ind_err <= '0';
            ind_cmd <= ( others => '0' ); ind_adr <= ( others => '0' );
         else
            faute_r <= '0';
            if REG_WE_i = '1' then
               j := to_integer( REG_ADDR_i );
               case j is
                  when 0      => ctrl <= REG_WDATA_i( 5 downto 0 );
                  when 1      => cfg( 0 ) <= REG_WDATA_i;
                  when 2      => cfg( 1 ) <= REG_WDATA_i;
                  when 4      =>
                     if ind_act = '0' then
                        ind_cmd <= REG_WDATA_i( 30 downto 0 );
                     end if;
                     ind_err <= '0';
                     if REG_WDATA_i( 31 ) = '1' then
                        if go_ok then
                           ind_dem <= '1';
                        else
                           ind_err <= '1';
                        end if;
                     end if;
                  when 5      =>
                     if ind_act = '0' then ind_adr <= REG_WDATA_i; end if;
                  when 8 to 15 =>
                     if ind_act = '0' then tampon( j - 8 ) <= REG_WDATA_i; end if;
                  when others => null;
               end case;
            end if;

            case etat is
               when LIBRE =>
                  if ind_dem = '1' and PHY_BUSY_i = '0' then
                     ind <= '1'; ind_dem <= '0';
                     cs_l <= ind_cmd( 8 ); ecr <= ind_cmd( 19 );
                     nrx <= 0; slot <= 0;
                     etat <= TRANSFERT;
                  elsif S_REQ_i = '1' and pret = '1' then
                     ind <= '0';
                     cs_l <= S_CS_i; ecr <= S_WRITE_i;
                     base <= S_ADDR_i( 27 downto 5 );
                     acc <= 1; nrx <= 0; rendus <= 0; slot <= 0;
                     ligne( 0 ) <= S_WDATA_i;
                     if c_type = "00" then
                        etat <= FAUTE;
                        faute_r <= not S_WRITE_i;
                     elsif S_WRITE_i = '1' then
                        etat <= COLLECTE;
                     else
                        etat <= TRANSFERT;
                     end if;
                  end if;

               when COLLECTE =>
                  if S_REQ_i = '1' and pret = '1' then
                     ligne( acc ) <= S_WDATA_i;
                     acc <= acc + 1;
                     if acc = SOC_LINE_WORDS - 1 then
                        etat <= TRANSFERT;
                     end if;
                  end if;

               when FAUTE =>
                  if S_REQ_i = '1' and pret = '1' then
                     faute_r <= not ecr;
                     acc <= acc + 1;
                  end if;
                  if acc = SOC_LINE_WORDS and faute_r = '0' then
                     etat <= LIBRE;
                  end if;

               when TRANSFERT =>
                  if ind = '0' and ecr = '0' and S_REQ_i = '1' and pret = '1' then
                     acc <= acc + 1;
                  end if;
                  if SLOT_TAKE_i = '1' then
                     slot <= slot + 1;
                  end if;
                  if RX_VALID_i = '1' and nrx < 32 then
                     for i in 0 to 31 loop
                        if nrx = i then
                           if ind = '1' then
                              tampon( i / 4 )( 8 * ( i mod 4 ) + 7 downto 8 * ( i mod 4 ) ) <= RX_BYTE_i;
                           else
                              ligne( i / 8 )( 8 * ( i mod 8 ) + 7 downto 8 * ( i mod 8 ) ) <= RX_BYTE_i;
                           end if;
                        end if;
                     end loop;
                     nrx <= nrx + 1;
                  end if;
                  if mot_pret = '1' then
                     rendus <= rendus + 1;
                  end if;
                  -- fin : ecriture, tous les creneaux pris ; lecture en mode memoire, quatre
                  -- mots rendus ; lecture indirecte, tous les creneaux pris et NDATA octets recus
                  if ( t_ecr = '1' and slot = n_tot )
                     or ( ind = '0' and ecr = '0' and rendus = SOC_LINE_WORDS )
                     or ( ind = '1' and t_ecr = '0' and slot = n_tot and nrx = t_ndon ) then
                     etat <= LIBRE;
                  end if;
            end case;
         end if;
      end if;
   end process;

end architecture RTL;
