library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
        --------------------------------------------------------------------------------
        -- DEBUG_MODULE : module de debogage, domaine du coeur (ARCHI_SOC_TAHX.md § 5.1).
        --
        -- Commandes du TAP (JTAG_TAP) : CMD_BASCULE_i resynchronisee (deux bascules) ;
        -- a chaque changement, DBG_CONTROL (CTL_i) est pris :
        --   0 HALT           niveau : HALT_REQ_o (arret a une frontiere d'instruction)
        --   1 RESUME         impulsion : reprise a DPC si le coeur est arrete
        --   2 CORE_RESET     niveau : CORE_RESET_o (RESET du coeur seul, le TAP reste)
        --   3 HALT_ON_RESET  niveau : HALT_REQ_o aussi (tenu pendant et apres un RESET :
        --                    le coeur s'arrete avant sa premiere instruction)
        --   4 ACCES          impulsion : lance un acces (5 ECRITURE, 7..6 TAILLE : octet,
        --                    16, 32, 64 bits ; 8 INTERNE : registre du module, numero dans
        --                    DBG_ADDRESS)
        -- Acces memoire : coeur arrete seulement (sinon ACC_REFUSE), par le port maitre
        -- M_* (vers le port EXEC du cache de donnees au sommet : il voit les lignes sales,
        -- ARCHI § 6) : requete tenue jusqu'a M_READY, puis une reponse M_RVALID (donnee,
        -- M_FAULT), pour une lecture comme pour une ecriture.
        -- Registres internes (INTERNE) : 0 DPC (lecture, ecriture ; charge depuis
        -- HALT_PC_i a chaque arret, presente sur RESUME_PC_o), 1 HALT_PC, 2 FPC, 3 FCODE,
        -- 4 HALT_CAUSE. Autres numeros : faute.
        -- DBG_STATUS (STATUS_o, vers le TAP) : 0 HALTED, 1 ACC_OCCUPE, 2 ACC_FAIT,
        -- 3 ACC_FAUTE, 4 ACC_REFUSE, 15..8 HALT_CAUSE, 16 CORE_RESET, 17 HALT_REQ,
        -- 31..24 version du module. ACC_FAIT, ACC_FAUTE et ACC_REFUSE sont remis a 0 par
        -- la commande suivante. RDATA_o : donnee lue, stable quand ACC_FAIT.
        -- RESET_i : RESET de la puce seulement (pas CORE_RESET_o).
        --------------------------------------------------------------------------------

entity DEBUG_MODULE is
   generic (
      VERSION_G    : natural := 1
   );
   port (
      CLK_i        : in  std_logic;
      RESET_i      : in  std_logic;

      -- TAP
      CTL_i        : in  std_logic_vector( 31 downto 0 );
      ADR_i        : in  std_logic_vector( 31 downto 0 );
      WDATA_i      : in  std_logic_vector( 63 downto 0 );
      CMD_BASCULE_i : in std_logic;
      STATUS_o     : out std_logic_vector( 31 downto 0 );
      RDATA_o      : out std_logic_vector( 63 downto 0 );

      -- coeur (ino_system, ARCHI § 5.1)
      HALT_REQ_o   : out std_logic;
      RESUME_REQ_o : out std_logic;
      RESUME_PC_o  : out std_logic_vector( 31 downto 0 );
      CORE_RESET_o : out std_logic;
      HALTED_i     : in  std_logic;
      HALT_PC_i    : in  std_logic_vector( 31 downto 0 );
      HALT_CAUSE_i : in  std_logic_vector( 7 downto 0 );
      FPC_i        : in  std_logic_vector( 31 downto 0 );
      FCODE_i      : in  std_logic_vector( 15 downto 0 );

      -- acces memoire
      M_REQ_o      : out std_logic;
      M_WRITE_o    : out std_logic;
      M_ADDR_o     : out std_logic_vector( 31 downto 0 );
      M_SIZE_o     : out std_logic_vector( 1 downto 0 );
      M_WDATA_o    : out std_logic_vector( 63 downto 0 );
      M_READY_i    : in  std_logic;
      M_RVALID_i   : in  std_logic;
      M_RDATA_i    : in  std_logic_vector( 63 downto 0 );
      M_FAULT_i    : in  std_logic
   );
end entity DEBUG_MODULE;

architecture RTL of DEBUG_MODULE is

   signal b1, b2, b3 : std_logic;                                -- resynchronisation
   signal halt, core_reset, halt_on_reset : std_logic;
   signal ctl       : std_logic_vector( 31 downto 0 );
   signal dpc       : std_logic_vector( 31 downto 0 );
   signal halted_p  : std_logic;
   signal rdata     : std_logic_vector( 63 downto 0 );
   signal occupe, fait, faute, refuse : std_logic;
   signal attente   : std_logic;                                 -- requete acceptee, reponse attendue
   signal resume    : std_logic;

begin

   HALT_REQ_o   <= halt or halt_on_reset;
   CORE_RESET_o <= core_reset;
   RESUME_REQ_o <= resume;
   RESUME_PC_o  <= dpc;
   RDATA_o      <= rdata;

   M_REQ_o   <= occupe and not attente;
   M_WRITE_o <= ctl( 5 );
   M_SIZE_o  <= ctl( 7 downto 6 );
   M_ADDR_o  <= ADR_i;
   M_WDATA_o <= WDATA_i;

   STATUS_o <= std_logic_vector( to_unsigned( VERSION_G, 8 ) ) & "000000"
               & ( halt or halt_on_reset ) & core_reset
               & HALT_CAUSE_i & "000" & refuse & faute & fait & occupe & HALTED_i;

   SEQUENTIEL : process( CLK_i )
      variable n : natural;
   begin
      if rising_edge( CLK_i ) then
         b1 <= CMD_BASCULE_i; b2 <= b1;
         if RESET_i = '1' then
            b1 <= '0'; b2 <= '0'; b3 <= '0';
            halt <= '0'; core_reset <= '0'; halt_on_reset <= '0'; resume <= '0';
            ctl <= ( others => '0' ); dpc <= ( others => '0' ); halted_p <= '0';
            rdata <= ( others => '0' );
            occupe <= '0'; fait <= '0'; faute <= '0'; refuse <= '0'; attente <= '0';
         else
            b3 <= b2;
            resume <= '0';

            -- DPC : charge a chaque arret
            halted_p <= HALTED_i;
            if HALTED_i = '1' and halted_p = '0' then
               dpc <= HALT_PC_i;
            end if;

            -- nouvelle commande
            if b2 /= b3 then
               ctl <= CTL_i;
               halt <= CTL_i( 0 ); core_reset <= CTL_i( 2 ); halt_on_reset <= CTL_i( 3 );
               fait <= '0'; faute <= '0'; refuse <= '0';
               if CTL_i( 1 ) = '1' and HALTED_i = '1' then
                  resume <= '1';
               end if;
               if CTL_i( 4 ) = '1' and occupe = '0' then
                  if CTL_i( 8 ) = '1' then
                     -- registre interne
                     fait <= '1';
                     n := to_integer( unsigned( ADR_i( 2 downto 0 ) ) );
                     if unsigned( ADR_i( 31 downto 3 ) ) /= 0 or n > 4 then
                        faute <= '1';
                     elsif CTL_i( 5 ) = '1' then
                        if n = 0 then dpc <= WDATA_i( 31 downto 0 ); else faute <= '1'; end if;
                     else
                        rdata <= ( others => '0' );
                        case n is
                           when 0      => rdata( 31 downto 0 ) <= dpc;
                           when 1      => rdata( 31 downto 0 ) <= HALT_PC_i;
                           when 2      => rdata( 31 downto 0 ) <= FPC_i;
                           when 3      => rdata( 15 downto 0 ) <= FCODE_i;
                           when others => rdata( 7 downto 0 ) <= HALT_CAUSE_i;
                        end case;
                     end if;
                  elsif HALTED_i = '0' then
                     refuse <= '1'; fait <= '1';
                  else
                     occupe <= '1'; attente <= '0';
                  end if;
               end if;
            end if;

            -- acces memoire en cours
            if occupe = '1' then
               if attente = '0' and M_READY_i = '1' then
                  attente <= '1';
               end if;
               if M_RVALID_i = '1' and ( attente = '1' or M_READY_i = '1' ) then
                  occupe <= '0'; attente <= '0'; fait <= '1'; faute <= M_FAULT_i;
                  if ctl( 5 ) = '0' then rdata <= M_RDATA_i; end if;
               end if;
            end if;
         end if;
      end if;
   end process;

end architecture RTL;
