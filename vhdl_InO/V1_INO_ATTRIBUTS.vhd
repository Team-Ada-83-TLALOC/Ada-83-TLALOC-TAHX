library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

        --------------------------------------------------------------------------------
        -- INO_ATTRIBUTS : attributs memoire et port de registres R_*, devant le port EXEC
        --   du cache de donnees (ARCHI_SOC_TAHX.md § 2.2, § 3, § 4.3, § 6). Logique de
        --   liaison de TAHX_1 : aucune macro ne change.
        --
        -- Deux sources : le coeur (requetes EXEC) et, coeur arrete, le debogueur (G_*,
        -- ARCHI § 6 : par le cache, il voit les lignes sales). Une requete a la fois :
        -- la suivante n'est acceptee qu'apres la reponse de la precedente (le cache n'en
        -- sert de toute facon qu'une ; l'ordre des reponses du cache et des registres est
        -- ainsi garanti).
        --
        -- ATTR_EN_i = 0 : comportement d'origine (outside = adresse non realisable, pas
        -- de port R_*), pour les bancs et la plateforme N3. ATTR_EN_i = 1 (TAHX_SOC) :
        --   0xF000_0000 - 0xF00F_FFFF  -> R_* (R_ADDR_o : decalage sur 20 bits)
        --   fenetres 0..3 (bits 31..28) -> cache, outside = 1 si :
        --     selection absente (TYPE = 00), decalage >= 2 ** SIZE, ecriture vers une flash
        --     (TYPE = 01), ou, pour le coeur seulement, adresse < 2 ** NULL_GUARD
        --     (NULL_GUARD /= 0) ;
        --   toute autre adresse         -> cache, outside = 1 (faute 132 sans acces).
        -- Selection : fenetres 0, 1 port A (echangees si BOOT_SEL_i = 1, comme SOC_DECODE),
        -- 2, 3 port B. CS_TYPE_i : 2 bits par selection (A0, A1, B0, B1 de bas en haut),
        -- CS_SIZE_i : 5 bits par selection, depuis les registres des ports xSPI.
        -- Seule l'adresse de debut est comparee a SIZE.
        --------------------------------------------------------------------------------

entity INO_ATTRIBUTS is
   port (
      CLK_i         : in  std_logic;
      RESET_i       : in  std_logic;

      ATTR_EN_i     : in  std_logic;
      CS_TYPE_i     : in  std_logic_vector( 7 downto 0 );
      CS_SIZE_i     : in  std_logic_vector( 19 downto 0 );
      BOOT_SEL_i    : in  std_logic;
      NULL_GUARD_i  : in  unsigned( 4 downto 0 );
      HALTED_i      : in  std_logic;

      -- coeur
      C_REQ_i       : in  mem_request_t;
      C_READY_o     : out std_logic;
      C_RSP_o       : out mem_response_t;

      -- debogueur (adresse physique sur 32 bits)
      G_REQ_i       : in  std_logic;
      G_WRITE_i     : in  std_logic;
      G_ADDR_i      : in  unsigned( 31 downto 0 );
      G_SIZE_i      : in  unsigned( 1 downto 0 );
      G_WDATA_i     : in  word64_t;
      G_READY_o     : out std_logic;
      G_RSP_o       : out mem_response_t;

      -- cache de donnees, port EXEC
      DC_REQ_o      : out exec_mem_request_pa_t;
      DC_READY_i    : in  std_logic;
      DC_RSP_i      : in  mem_response_t;

      -- registres
      R_REQ_o       : out std_logic;
      R_WRITE_o     : out std_logic;
      R_ADDR_o      : out unsigned( 19 downto 0 );
      R_SIZE_o      : out unsigned( 1 downto 0 );
      R_WDATA_o     : out word64_t;
      R_READY_i     : in  std_logic;
      R_RVALID_i    : in  std_logic;
      R_RDATA_i     : in  word64_t;
      R_FAULT_i     : in  std_logic
   );
end entity INO_ATTRIBUTS;

architecture RTL of INO_ATTRIBUTS is

   signal dbg       : std_logic;                                 -- source choisie : debogueur
   signal req       : mem_request_t;
   signal vers_r    : std_logic;
   signal hors      : std_logic;
   signal attente   : std_logic;                                 -- requete acceptee, reponse attendue
   signal att_r     : std_logic;                                 -- ... vers R_*
   signal att_dbg   : std_logic;                                 -- ... venue du debogueur
   signal pret, pret_dest : std_logic;
   signal acc       : std_logic;
   signal rsp       : mem_response_t;

begin

   -- source : le debogueur, coeur arrete seulement
   dbg <= HALTED_i and G_REQ_i;
   req <= ( valid => G_REQ_i, write => G_WRITE_i, probe => '0',
            address => x"00000000" & G_ADDR_i, size => G_SIZE_i, wdata => G_WDATA_i )
          when dbg = '1' else C_REQ_i;

   DECODAGE : process( all )
      variable a    : address_t;
      variable sel  : natural range 0 to 3;
      variable typ  : std_logic_vector( 1 downto 0 );
      variable taille : natural range 0 to 31;
      variable ng   : natural range 0 to 31;
      variable absente, flash_ec, trop_loin, sous_garde : boolean;
   begin
      a := req.address;
      vers_r <= '0';
      hors   <= '0';
      if not PA_OK( a ) then
         hors <= '1';
      elsif ATTR_EN_i = '1' then
         if a( 31 downto 20 ) = x"F00" then
            vers_r <= '1';
         elsif a( 31 downto 30 ) /= "00" then
            hors <= '1';                                         -- fenetre non attribuee
         else
            sel := to_integer( a( 29 downto 28 ) );
            if sel < 2 and BOOT_SEL_i = '1' then sel := 1 - sel; end if;
            case sel is
               when 0 =>      typ := CS_TYPE_i( 1 downto 0 ); taille := to_integer( unsigned( CS_SIZE_i( 4 downto 0 ) ) );
               when 1 =>      typ := CS_TYPE_i( 3 downto 2 ); taille := to_integer( unsigned( CS_SIZE_i( 9 downto 5 ) ) );
               when 2 =>      typ := CS_TYPE_i( 5 downto 4 ); taille := to_integer( unsigned( CS_SIZE_i( 14 downto 10 ) ) );
               when others => typ := CS_TYPE_i( 7 downto 6 ); taille := to_integer( unsigned( CS_SIZE_i( 19 downto 15 ) ) );
            end case;
            absente  := typ = "00";
            flash_ec := typ = "01" and req.write = '1';
            trop_loin := false;                                  -- decalage >= 2 ** SIZE
            for k in 0 to 27 loop
               if k >= taille and a( k ) = '1' then trop_loin := true; end if;
            end loop;
            sous_garde := false;                                 -- zone de garde contre null
            ng := to_integer( NULL_GUARD_i );
            if dbg = '0' and ng /= 0 then
               sous_garde := true;
               for k in 0 to 31 loop
                  if k >= ng and a( k ) = '1' then sous_garde := false; end if;
               end loop;
            end if;
            if absente or flash_ec or trop_loin or sous_garde then
               hors <= '1';
            end if;
         end if;
      end if;
   end process;

   -- requetes (aucune tant qu'une reponse est attendue)
   DC_REQ_o <= ( valid => req.valid and not attente and not vers_r, write => req.write,
                 probe => req.probe, outside => hors,
                 address => req.address( PA_BITS - 1 downto 0 ), size => req.size,
                 wdata => req.wdata );
   R_REQ_o   <= req.valid and not attente and vers_r;
   R_WRITE_o <= req.write;
   R_ADDR_o  <= req.address( 19 downto 0 );
   R_SIZE_o  <= req.size;
   R_WDATA_o <= req.wdata;

   pret_dest <= R_READY_i when vers_r = '1' else DC_READY_i;
   pret <= pret_dest and not attente;
   acc  <= pret and req.valid;
   C_READY_o <= pret and not dbg;
   G_READY_o <= pret and dbg;

   -- reponses, vers la source de la requete en attente
   rsp <= ( valid => R_RVALID_i, rdata => R_RDATA_i, fault => R_FAULT_i ) when att_r = '1' else DC_RSP_i;
   C_RSP_o <= rsp when att_dbg = '0' else NO_MEM_RESPONSE;
   G_RSP_o <= rsp when att_dbg = '1' else NO_MEM_RESPONSE;

   SEQUENTIEL : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            attente <= '0'; att_r <= '0'; att_dbg <= '0';
         elsif attente = '0' then
            if acc = '1' then
               attente <= '1'; att_r <= vers_r; att_dbg <= dbg;
            end if;
         elsif rsp.valid = '1' then
            attente <= '0';
         end if;
      end if;
   end process;

end architecture RTL;
