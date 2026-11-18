library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
        --------------------------------------------------------------------------------
        -- JTAG_TAP : port d'acces de test IEEE 1149.1 et registres de debogage, domaine
        --   TCK (ARCHI_SOC_TAHX.md § 5.1).
        --
        -- Automate a 16 etats ; TDO change au front descendant de TCK. Pas de TRST# : le
        -- TAP revient en Test-Logic-Reset par cinq TCK avec TMS = 1, et sur RESET_i (RESET
        -- de la puce, asynchrone). Registre d'instruction de 4 bits, capture "0001".
        --   0000 EXTEST          BSR ; EXTEST_o = 1 (plots pilotes par le BSR)
        --   0001 IDCODE          32 bits, instruction apres Test-Logic-Reset
        --   0010 SAMPLE/PRELOAD  BSR
        --   1000 DBG_CONTROL     32 bits : a Update-DR, commande au module de debogage
        --   1001 DBG_ADDRESS     32 bits
        --   1010 DBG_DATA        64 bits : Update-DR fixe la donnee a ecrire ; Capture-DR
        --                        prend la donnee lue (stable quand ACC_FAIT)
        --   1011 DBG_STATUS      32 bits, lecture seule (Capture-DR)
        --   autres, dont 1111    BYPASS
        -- Chaine de balayage des plots (BSR) : hors du TAP, pilotee par BSR_CAPTURE_o,
        -- BSR_SHIFT_o, BSR_UPDATE_o (impulsions d'un TCK, au front montant) ; elle decale
        -- TDI vers BSR_TDO_i. Elle viendra avec le sommet TAHX_SOC (liste des plots).
        --
        -- Vers le domaine du coeur (DEBUG_MODULE) : CTL_o, ADR_o, WDATA_o, stables, et
        -- CMD_BASCULE_o qui change a chaque Update-DR de DBG_CONTROL. Le module de debogage
        -- la resynchronise et lit alors CTL_o, ADR_o, WDATA_o. Depuis le coeur : STATUS_i,
        -- resynchronise ici (deux bascules par bit), et RDATA_i, prise telle quelle a
        -- Capture-DR (le debogueur attend ACC_FAIT dans DBG_STATUS avant de la lire).
        -- Deux Update-DR de DBG_CONTROL sont separes d'au moins 35 TCK, assez pour le
        -- coeur tant que TCK <= CLK.
        --------------------------------------------------------------------------------

entity JTAG_TAP is
   generic (
      IDCODE_G     : std_logic_vector( 31 downto 0 ) := x"1ADA8301"   -- version, piece, fabricant, 1
   );
   port (
      TCK_i        : in  std_logic;
      TMS_i        : in  std_logic;
      TDI_i        : in  std_logic;
      TDO_o        : out std_logic;
      TDO_OE_o     : out std_logic;                              -- Shift-DR / Shift-IR
      RESET_i      : in  std_logic;                              -- RESET de la puce (asynchrone)

      -- chaine de balayage des plots
      EXTEST_o     : out std_logic;
      BSR_CAPTURE_o : out std_logic;
      BSR_SHIFT_o  : out std_logic;
      BSR_UPDATE_o : out std_logic;
      BSR_TDO_i    : in  std_logic;

      -- module de debogage
      CTL_o        : out std_logic_vector( 31 downto 0 );
      ADR_o        : out std_logic_vector( 31 downto 0 );
      WDATA_o      : out std_logic_vector( 63 downto 0 );
      CMD_BASCULE_o : out std_logic;
      STATUS_i     : in  std_logic_vector( 31 downto 0 );
      RDATA_i      : in  std_logic_vector( 63 downto 0 )
   );
end entity JTAG_TAP;

architecture RTL of JTAG_TAP is

   type tap_t is ( TLR, RTI, SEL_DR, CAP_DR, SH_DR, EX1_DR, PA_DR, EX2_DR, UPD_DR,
                   SEL_IR, CAP_IR, SH_IR, EX1_IR, PA_IR, EX2_IR, UPD_IR );
   signal etat     : tap_t;

   constant I_EXTEST  : std_logic_vector( 3 downto 0 ) := "0000";
   constant I_IDCODE  : std_logic_vector( 3 downto 0 ) := "0001";
   constant I_SAMPLE  : std_logic_vector( 3 downto 0 ) := "0010";
   constant I_CTL     : std_logic_vector( 3 downto 0 ) := "1000";
   constant I_ADR     : std_logic_vector( 3 downto 0 ) := "1001";
   constant I_DATA    : std_logic_vector( 3 downto 0 ) := "1010";
   constant I_STATUS  : std_logic_vector( 3 downto 0 ) := "1011";

   signal ir, ir_sh : std_logic_vector( 3 downto 0 );
   signal dr       : std_logic_vector( 63 downto 0 );           -- registre a decalage commun
   signal lg       : natural range 1 to 64;                      -- longueur du DR choisi
   signal bsr_choisi : std_logic;
   signal tdo_r, tdo_oe_r : std_logic;

   signal ctl, adr : std_logic_vector( 31 downto 0 );
   signal wdata    : std_logic_vector( 63 downto 0 );
   signal bascule  : std_logic;
   signal st1, st2 : std_logic_vector( 31 downto 0 );

begin

   CTL_o <= ctl; ADR_o <= adr; WDATA_o <= wdata; CMD_BASCULE_o <= bascule;
   EXTEST_o <= '1' when ir = I_EXTEST else '0';
   TDO_o    <= tdo_r;
   TDO_OE_o <= tdo_oe_r;

   bsr_choisi <= '1' when ir = I_EXTEST or ir = I_SAMPLE else '0';
   BSR_CAPTURE_o <= '1' when etat = CAP_DR and bsr_choisi = '1' else '0';
   BSR_SHIFT_o   <= '1' when etat = SH_DR and bsr_choisi = '1' else '0';
   BSR_UPDATE_o  <= '1' when etat = UPD_DR and bsr_choisi = '1' else '0';

   with ir select lg <=
      32 when I_IDCODE | I_CTL | I_ADR | I_STATUS,
      64 when I_DATA,
      1  when others;                                            -- BYPASS (le BSR est dehors)

   AUTOMATE : process( TCK_i, RESET_i )
   begin
      if RESET_i = '1' then
         etat <= TLR;
      elsif rising_edge( TCK_i ) then
         case etat is
            when TLR    => if TMS_i = '1' then etat <= TLR;   else etat <= RTI;    end if;
            when RTI    => if TMS_i = '1' then etat <= SEL_DR;else etat <= RTI;    end if;
            when SEL_DR => if TMS_i = '1' then etat <= SEL_IR;else etat <= CAP_DR; end if;
            when CAP_DR => if TMS_i = '1' then etat <= EX1_DR;else etat <= SH_DR;  end if;
            when SH_DR  => if TMS_i = '1' then etat <= EX1_DR;else etat <= SH_DR;  end if;
            when EX1_DR => if TMS_i = '1' then etat <= UPD_DR;else etat <= PA_DR;  end if;
            when PA_DR  => if TMS_i = '1' then etat <= EX2_DR;else etat <= PA_DR;  end if;
            when EX2_DR => if TMS_i = '1' then etat <= UPD_DR;else etat <= SH_DR;  end if;
            when UPD_DR => if TMS_i = '1' then etat <= SEL_DR;else etat <= RTI;    end if;
            when SEL_IR => if TMS_i = '1' then etat <= TLR;   else etat <= CAP_IR; end if;
            when CAP_IR => if TMS_i = '1' then etat <= EX1_IR;else etat <= SH_IR;  end if;
            when SH_IR  => if TMS_i = '1' then etat <= EX1_IR;else etat <= SH_IR;  end if;
            when EX1_IR => if TMS_i = '1' then etat <= UPD_IR;else etat <= PA_IR;  end if;
            when PA_IR  => if TMS_i = '1' then etat <= EX2_IR;else etat <= PA_IR;  end if;
            when EX2_IR => if TMS_i = '1' then etat <= UPD_IR;else etat <= SH_IR;  end if;
            when UPD_IR => if TMS_i = '1' then etat <= SEL_DR;else etat <= RTI;    end if;
         end case;
      end if;
   end process;

   REGISTRES : process( TCK_i, RESET_i )
   begin
      if RESET_i = '1' then
         ir <= I_IDCODE; ir_sh <= ( others => '0' );
         ctl <= ( others => '0' ); adr <= ( others => '0' ); wdata <= ( others => '0' );
         bascule <= '0'; st1 <= ( others => '0' ); st2 <= ( others => '0' );
      elsif rising_edge( TCK_i ) then
         st1 <= STATUS_i; st2 <= st1;
         case etat is
            when TLR =>
               ir <= I_IDCODE;
            when CAP_IR =>
               ir_sh <= "0001";
            when SH_IR =>
               ir_sh <= TDI_i & ir_sh( 3 downto 1 );
            when UPD_IR =>
               ir <= ir_sh;
            when CAP_DR =>
               case ir is
                  when I_IDCODE => dr( 31 downto 0 ) <= IDCODE_G;
                  when I_CTL    => dr( 31 downto 0 ) <= ctl;
                  when I_ADR    => dr( 31 downto 0 ) <= adr;
                  when I_DATA   => dr <= RDATA_i;
                  when I_STATUS => dr( 31 downto 0 ) <= st2;
                  when others   => dr( 0 ) <= '0';                  -- BYPASS
               end case;
            when SH_DR =>
               -- decalage vers le bit 0 ; TDI entre au bit lg - 1
               for i in 0 to 62 loop
                  if i < lg - 1 then dr( i ) <= dr( i + 1 ); end if;
               end loop;
               for i in 0 to 63 loop
                  if i = lg - 1 then dr( i ) <= TDI_i; end if;
               end loop;
            when UPD_DR =>
               case ir is
                  when I_CTL  => ctl <= dr( 31 downto 0 ); bascule <= not bascule;
                  when I_ADR  => adr <= dr( 31 downto 0 );
                  when I_DATA => wdata <= dr;
                  when others => null;
               end case;
            when others => null;
         end case;
      end if;
   end process;

   -- TDO au front descendant : bit 0 du registre en cours de decalage
   SORTIE : process( TCK_i, RESET_i )
   begin
      if RESET_i = '1' then
         tdo_r <= '0'; tdo_oe_r <= '0';
      elsif falling_edge( TCK_i ) then
         tdo_oe_r <= '0';
         if etat = SH_IR then
            tdo_r <= ir_sh( 0 ); tdo_oe_r <= '1';
         elsif etat = SH_DR then
            tdo_oe_r <= '1';
            if bsr_choisi = '1' then tdo_r <= BSR_TDO_i; else tdo_r <= dr( 0 ); end if;
         end if;
      end if;
   end process;

end architecture RTL;
