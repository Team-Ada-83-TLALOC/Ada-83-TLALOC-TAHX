library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
        --------------------------------------------------------------------------------
        -- I2C : maitre I2C (Standard, Fast 400 kHz, Fast-mode Plus 1 MHz), couche d'octets
        --   et registres, sur la couche de bits I2C_BITS (ARCHI_SOC_TAHX.md § 5).
        --
        -- Le logiciel empile des commandes ; chacune : START (si demande), un octet emis ou
        -- recu avec son bit d'acquittement (sauf SANS_OCTET), STOP (si demande). L'adresse
        -- d'esclave est un octet emis avec START : (adresse << 1) | lecture. Un START sur un
        -- bus deja a nous est un START repete.
        -- NACK recu sur un octet emis : bit 3 de ETAT, FIFO de commandes videe, STOP.
        -- Arbitrage perdu : bit 4, FIFO videe, lignes relachees (pas de STOP).
        -- Une lecture attend une place dans la FIFO de reception.
        --
        -- Registres (bus de registres du SoC, comme l'UART) :
        --   0  ecriture : COMMANDE  7..0 octet emis, 8 START avant, 9 STOP apres, 10 LECTURE
        --               (recevoir un octet), 11 NACK (lecture : acquitter par NACK, dernier
        --               octet), 12 SANS_OCTET (START et / ou STOP seuls). Perdue si la FIFO
        --               est pleine (bit 5).
        --      lecture : RECU  7..0 octet, 8 valide (l'octet est alors retire).
        --   1  ETAT     0 occupe (commande en cours ou en attente), 1 FIFO de commandes
        --               pleine, 2 reception non vide, 3 NACK recu (collant), 4 arbitrage perdu
        --               (collant), 5 commande perdue (collant), 6 bus occupe (vu sur les
        --               lignes), 7 bus a nous, 11..8 commandes en attente, 15..12 octets
        --               recus. Ecrire 1 sur les bits 3 a 5 les efface.
        --   2  TEMPS    15..0 T_BAS, 31..16 T_HAUT (cycles du coeur).
        --   3  CONF     0 ACTIF, 1 IE_FIN (interruption : plus rien a faire), 2 IE_ERR
        --               (NACK ou arbitrage perdu), 3 SCL_PP (SCL en push-pull), 4 RAPPEL
        --               (resistance de rappel commandee, sortie RAPPEL_o : I3C demande un
        --               rappel pilote par le controleur ; en I2C, rappel externe).
        -- Au RESET : 100 kHz a 36 MHz (T_BAS = 180, T_HAUT = 160), inactif.
        -- Plots : bidirectionnels a trois etats (IOPadInOut30mA pour Fm+), en drain ouvert
        -- par la validation de sortie ; la sortie push-pull servira a I3C.
        --------------------------------------------------------------------------------

entity I2C is
   generic (
      PROF_G       : positive := 8                               -- profondeur des FIFO (<= 15)
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

      SCL_o        : out std_logic;
      SCL_OE_o     : out std_logic;
      SCL_i        : in  std_logic;
      SDA_o        : out std_logic;
      SDA_OE_o     : out std_logic;
      SDA_i        : in  std_logic;
      RAPPEL_o     : out std_logic
   );
end entity I2C;

architecture RTL of I2C is

   type cmdf_t is array( 0 to PROF_G - 1 ) of std_logic_vector( 12 downto 0 );
   type rxf_t is array( 0 to PROF_G - 1 ) of std_logic_vector( 7 downto 0 );
   subtype idx_t is natural range 0 to PROF_G - 1;
   subtype cnt_t is natural range 0 to PROF_G;

   function SUIV( i : idx_t ) return idx_t is
   begin
      if i = PROF_G - 1 then return 0; else return i + 1; end if;
   end function;

   constant C_START : std_logic_vector( 1 downto 0 ) := "00";
   constant C_STOP  : std_logic_vector( 1 downto 0 ) := "01";
   constant C_ECR   : std_logic_vector( 1 downto 0 ) := "10";
   constant C_LEC   : std_logic_vector( 1 downto 0 ) := "11";

   signal t_bas, t_haut : unsigned( 15 downto 0 );
   signal actif, ie_fin, ie_err, scl_pp, rappel : std_logic;
   signal nack_c, perdu_c, cmd_perdue : std_logic;

   signal cmdf     : cmdf_t;
   signal cf_lec, cf_ecr : idx_t;
   signal cf_n      : cnt_t;
   signal rxf      : rxf_t;
   signal r_lec, r_ecr : idx_t;
   signal r_n      : cnt_t;

   -- execution d'une commande
   type etape_t is ( E_REPOS, E_START, E_BITS, E_ACK, E_STOP, E_ATTENTE );
   signal etape    : etape_t;
   signal suite    : etape_t;                                    -- etape apres l'attente
   signal cour     : std_logic_vector( 12 downto 0 );            -- commande en cours
   signal nbit     : natural range 0 to 7;
   signal sh       : std_logic_vector( 7 downto 0 );
   signal abandon  : std_logic;                                  -- NACK : STOP puis fin

   -- couche de bits
   signal b_valid, b_bit, b_pret, b_fait, b_lu, b_perdu, b_possede, b_occupe : std_logic;
   signal b_cmd    : std_logic_vector( 1 downto 0 );

   signal occupe, fin, err : std_logic;

begin

   BITS : entity work.I2C_BITS
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i, ACTIF_i => actif,
         T_BAS_i => t_bas, T_HAUT_i => t_haut, SCL_PP_i => scl_pp,
         CMD_VALID_i => b_valid, CMD_i => b_cmd, CMD_BIT_i => b_bit,
         PRET_o => b_pret, FAIT_o => b_fait, BIT_o => b_lu, PERDU_o => b_perdu,
         POSSEDE_o => b_possede, BUS_OCCUPE_o => b_occupe,
         SCL_o => SCL_o, SCL_OE_o => SCL_OE_o, SCL_i => SCL_i,
         SDA_o => SDA_o, SDA_OE_o => SDA_OE_o, SDA_i => SDA_i );

   RAPPEL_o <= rappel;
   occupe   <= '0' when etape = E_REPOS and cf_n = 0 else '1';
   fin      <= not occupe;
   err      <= nack_c or perdu_c;
   IRQ_o    <= ( ie_fin and fin and actif ) or ( ie_err and err );

   LECTURE : process( all )
   begin
      RDATA_o <= ( others => '0' );
      case to_integer( ADDR_i ) is
         when 0 =>
            if r_n /= 0 then
               RDATA_o( 7 downto 0 ) <= rxf( r_lec );
               RDATA_o( 8 ) <= '1';
            end if;
         when 1 =>
            RDATA_o( 0 ) <= occupe;
            RDATA_o( 1 ) <= '1' when cf_n = PROF_G else '0';
            RDATA_o( 2 ) <= '1' when r_n /= 0 else '0';
            RDATA_o( 3 ) <= nack_c;
            RDATA_o( 4 ) <= perdu_c;
            RDATA_o( 5 ) <= cmd_perdue;
            RDATA_o( 6 ) <= b_occupe;
            RDATA_o( 7 ) <= b_possede;
            RDATA_o( 11 downto 8 )  <= std_logic_vector( to_unsigned( cf_n, 4 ) );
            RDATA_o( 15 downto 12 ) <= std_logic_vector( to_unsigned( r_n, 4 ) );
         when 2 =>
            RDATA_o <= std_logic_vector( t_haut ) & std_logic_vector( t_bas );
         when others =>
            RDATA_o( 4 downto 0 ) <= rappel & scl_pp & ie_err & ie_fin & actif;
      end case;
   end process;

   -- commande vers la couche de bits, selon l'etape
   b_valid <= '1' when b_pret = '1' and ( etape = E_START or etape = E_BITS or etape = E_ACK
                                          or etape = E_STOP ) else '0';
   b_cmd   <= C_START when etape = E_START else
              C_STOP  when etape = E_STOP else
              C_LEC   when ( etape = E_BITS and cour( 10 ) = '1' )
                           or ( etape = E_ACK and cour( 10 ) = '0' ) else
              C_ECR;
   b_bit   <= cour( 11 ) when etape = E_ACK else sh( 7 );

   SEQUENTIEL : process( CLK_i )
      variable c_push, c_pop, r_push, r_pop, vider : boolean;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            t_bas <= to_unsigned( 180, 16 ); t_haut <= to_unsigned( 160, 16 );
            actif <= '0'; ie_fin <= '0'; ie_err <= '0'; scl_pp <= '0'; rappel <= '0';
            nack_c <= '0'; perdu_c <= '0'; cmd_perdue <= '0';
            cf_lec <= 0; cf_ecr <= 0; cf_n <= 0; r_lec <= 0; r_ecr <= 0; r_n <= 0;
            etape <= E_REPOS; abandon <= '0';
         else
            c_push := false; c_pop := false; r_push := false; r_pop := false; vider := false;

            -- registres
            if SEL_i = '1' and WE_i = '1' then
               case to_integer( ADDR_i ) is
                  when 0 =>
                     if cf_n = PROF_G then
                        cmd_perdue <= '1';
                     else
                        cmdf( cf_ecr ) <= WDATA_i( 12 downto 0 ); c_push := true;
                     end if;
                  when 1 =>
                     if WDATA_i( 3 ) = '1' then nack_c <= '0'; end if;
                     if WDATA_i( 4 ) = '1' then perdu_c <= '0'; end if;
                     if WDATA_i( 5 ) = '1' then cmd_perdue <= '0'; end if;
                  when 2 =>
                     t_bas <= unsigned( WDATA_i( 15 downto 0 ) );
                     t_haut <= unsigned( WDATA_i( 31 downto 16 ) );
                  when others =>
                     actif <= WDATA_i( 0 ); ie_fin <= WDATA_i( 1 ); ie_err <= WDATA_i( 2 );
                     scl_pp <= WDATA_i( 3 ); rappel <= WDATA_i( 4 );
               end case;
            end if;
            if SEL_i = '1' and WE_i = '0' and ADDR_i = 0 and r_n /= 0 then
               r_pop := true;
            end if;

            -- execution
            case etape is
               when E_REPOS =>
                  if actif = '1' and cf_n /= 0
                     and not ( cmdf( cf_lec )( 10 ) = '1' and cmdf( cf_lec )( 12 ) = '0' and r_n = PROF_G ) then
                     cour <= cmdf( cf_lec ); c_pop := true;
                     sh <= cmdf( cf_lec )( 7 downto 0 ); nbit <= 0; abandon <= '0';
                     if cmdf( cf_lec )( 8 ) = '1' then etape <= E_START;
                     elsif cmdf( cf_lec )( 12 ) = '0' then etape <= E_BITS;
                     elsif cmdf( cf_lec )( 9 ) = '1' then etape <= E_STOP;
                     end if;
                  end if;

               when E_START | E_BITS | E_ACK | E_STOP =>
                  if b_valid = '1' then
                     suite <= etape; etape <= E_ATTENTE;
                  end if;

               when E_ATTENTE =>
                  if b_fait = '1' then
                     if b_perdu = '1' then
                        perdu_c <= '1'; vider := true; etape <= E_REPOS;
                     else
                        case suite is
                           when E_START =>
                              if cour( 12 ) = '0' then etape <= E_BITS;
                              elsif cour( 9 ) = '1' then etape <= E_STOP;
                              else etape <= E_REPOS; end if;
                           when E_BITS =>
                              sh <= sh( 6 downto 0 ) & b_lu;
                              if nbit = 7 then etape <= E_ACK; else nbit <= nbit + 1; etape <= E_BITS; end if;
                           when E_ACK =>
                              if cour( 10 ) = '1' then
                                 rxf( r_ecr ) <= sh; r_push := true;
                              end if;
                              if cour( 10 ) = '0' and b_lu = '1' then  -- NACK de l'esclave
                                 nack_c <= '1'; vider := true; abandon <= '1';
                                 etape <= E_STOP;
                              elsif cour( 9 ) = '1' then
                                 etape <= E_STOP;
                              else
                                 etape <= E_REPOS;
                              end if;
                           when others =>                        -- STOP fait
                              etape <= E_REPOS;
                        end case;
                     end if;
                  end if;

               when others => etape <= E_REPOS;
            end case;

            if actif = '0' then
               etape <= E_REPOS;
            end if;

            -- pointeurs et compteurs des FIFO
            if vider then
               cf_lec <= 0; cf_ecr <= 0; cf_n <= 0;
            else
               if c_push then cf_ecr <= SUIV( cf_ecr ); end if;
               if c_pop then cf_lec <= SUIV( cf_lec ); end if;
               if c_push and not c_pop then cf_n <= cf_n + 1;
               elsif c_pop and not c_push then cf_n <= cf_n - 1; end if;
            end if;
            if r_push then r_ecr <= SUIV( r_ecr ); end if;
            if r_pop then r_lec <= SUIV( r_lec ); end if;
            if r_push and not r_pop then r_n <= r_n + 1;
            elsif r_pop and not r_push then r_n <= r_n - 1; end if;
         end if;
      end if;
   end process;

end architecture RTL;
