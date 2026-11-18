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
        -- XSPI_PORT : un port xSPI complet, XSPI_CONTROLLER + XSPI_PHY (ARCHI § 4.4).
        --------------------------------------------------------------------------------

entity XSPI_PORT is
   generic (
      BOOT_G        : boolean := true
   );
   port (
      CLK_i         : in  std_logic;
      RESET_i       : in  std_logic;
      S_REQ_i       : in  std_logic;
      S_WRITE_i     : in  std_logic;
      S_CS_i        : in  std_logic;
      S_ADDR_i      : in  soc_pa_t;
      S_WDATA_i     : in  word64_t;
      S_READY_o     : out std_logic;
      S_RVALID_o    : out std_logic;
      S_RDATA_o     : out word64_t;
      S_FAULT_o     : out std_logic;
      REG_WE_i      : in  std_logic;
      REG_ADDR_i    : in  unsigned( 3 downto 0 );
      REG_WDATA_i   : in  std_logic_vector( 31 downto 0 );
      REG_RDATA_o   : out std_logic_vector( 31 downto 0 );
      CS_TYPE_o     : out std_logic_vector( 3 downto 0 );
      CS_SIZE_o     : out std_logic_vector( 9 downto 0 );
      SCLK_o        : out std_logic;
      CS_N_o        : out std_logic_vector( 1 downto 0 );
      DQ_o          : out std_logic_vector( 7 downto 0 );
      DQ_OE_o       : out std_logic_vector( 7 downto 0 );
      DQ_i          : in  std_logic_vector( 7 downto 0 );
      RWDS_o        : out std_logic;
      RWDS_OE_o     : out std_logic
   );
end entity XSPI_PORT;

architecture STRUCTURE of XSPI_PORT is
   signal mode_8d, cs_sel, s_valid, s_mask, s_rwds, s_last, s_take, rx_valid, busy : std_logic;
   signal div  : unsigned( 3 downto 0 );
   signal smp  : unsigned( 1 downto 0 );
   signal kind : std_logic_vector( 1 downto 0 );
   signal byte, rx_byte : std_logic_vector( 7 downto 0 );
begin

   CTRL : entity work.XSPI_CONTROLLER
      generic map ( BOOT_G => BOOT_G )
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         S_REQ_i => S_REQ_i, S_WRITE_i => S_WRITE_i, S_CS_i => S_CS_i, S_ADDR_i => S_ADDR_i,
         S_WDATA_i => S_WDATA_i, S_READY_o => S_READY_o, S_RVALID_o => S_RVALID_o,
         S_RDATA_o => S_RDATA_o, S_FAULT_o => S_FAULT_o,
         REG_WE_i => REG_WE_i, REG_ADDR_i => REG_ADDR_i, REG_WDATA_i => REG_WDATA_i,
         REG_RDATA_o => REG_RDATA_o, CS_TYPE_o => CS_TYPE_o, CS_SIZE_o => CS_SIZE_o,
         MODE_8D_o => mode_8d, DIV_o => div, SAMPLE_o => smp, CS_SEL_o => cs_sel,
         SLOT_VALID_o => s_valid, SLOT_KIND_o => kind, SLOT_BYTE_o => byte,
         SLOT_MASK_o => s_mask, SLOT_RWDS_o => s_rwds, SLOT_LAST_o => s_last,
         SLOT_TAKE_i => s_take, RX_VALID_i => rx_valid, RX_BYTE_i => rx_byte, PHY_BUSY_i => busy );

   PHY : entity work.XSPI_PHY
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         MODE_8D_i => mode_8d, DIV_i => div, SAMPLE_i => smp,
         CS_SEL_i => cs_sel, SLOT_VALID_i => s_valid, SLOT_KIND_i => kind, SLOT_BYTE_i => byte,
         SLOT_MASK_i => s_mask, SLOT_RWDS_i => s_rwds, SLOT_LAST_i => s_last,
         SLOT_TAKE_o => s_take, RX_VALID_o => rx_valid, RX_BYTE_o => rx_byte, BUSY_o => busy,
         SCLK_o => SCLK_o, CS_N_o => CS_N_o, DQ_o => DQ_o, DQ_OE_o => DQ_OE_o, DQ_i => DQ_i,
         RWDS_o => RWDS_o, RWDS_OE_o => RWDS_OE_o );

end architecture STRUCTURE;
