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
        -- TAHX_SOC : sommet du SoC (ARCHI_SOC_TAHX.md § 2 a § 7).
        --
        --                 I_*  ┌──────────┐  S_*(0) ┌────────────┐
        --   ┌────────┐ ───────>│          │────────>│ XSPI_PORT A│── plots xSPI A
        --   │        │  D_*    │  SOC_    │  S_*(1) ├────────────┤
        --   │ TAHX_1 │ ───────>│  MATRICE │────────>│ XSPI_PORT B│── plots xSPI B
        --   │        │         └──────────┘         └────────────┘
        --   │ (attri-│  R_*  ┌──────────────┐  SEL(0) SYSTEME       (18 registres)
        --   │  buts) │──────>│ SOC_REGISTRES│  SEL(1) TEMPORISATEUR ( 9)
        --   │        │       │ 0xF00b_b000  │  SEL(2) UART          ( 3)
        --   │        │       └──────────────┘  SEL(3) I2C           ( 4)
        --   │        │  DBG_*                  SEL(4) xSPI A        (16)
        --   │        │<──────── DEBUG_MODULE   SEL(5) xSPI B        (16)
        --   └────────┘             ^ CTL/ADR/WDATA, CMD_BASCULE (domaine TCK)
        --                       JTAG_TAP ── TCK, TMS, TDI, TDO
        --
        -- RESET :
        --   RESET_i (plot, actif haut) -> deux bascules -> rst_sys, sauf pour le TAP
        --   (asynchrone, domaine TCK). rst_sys = RESET synchronise ou CORE_RESET du
        --   debogueur : matrice, ports xSPI, peripheriques et registres systeme repartent
        --   comme au RESET de la puce (impulsion MEM_RESET#, BOOT_SEL relu, port A en SPI
        --   0x03) ; le TAP et le module de debogage restent.
        --   Coeur : rst_sys ou CORE_HOLD (SYSTEME : impulsion MEM_RESET# et reprise des
        --   memoires, ARCHI § 4.5).
        -- Plots : pendant rst_sys, xSPI (SCLK, CS#, DQ, DQS) et MEM_RESET# en haute
        --   impedance (programmation en circuit, ARCHI § 4.3). Chaque plot est decrit par
        --   un triplet (sortie, validation, entree) ; le registre de balayage (BSR) viendra
        --   entre ces triplets et les plots (BSR_TDO du TAP a 0 en attendant).
        -- Interruptions (bit i de IRQ_SOURCES, code 32 + i ; le plus petit est servi
        --   d'abord) : 0 temporisateur CMP0, 1 temporisateur CMP1, 2 UART, 3 I2C, 4 GPIO.
        --   SYSTEME.IRQ_MASQUE filtre avant le coeur, qui masque encore par IMASK.
        -- BOOT_BLOCK : 0x0000_0000, ou 0x1000_0000 si BOOT_SEL = 1 (la flash de demarrage
        --   reste sur CS0 du port A, ARCHI § 4.3).
        --------------------------------------------------------------------------------

entity TAHX_SOC is
   generic (
      MR_IMPULSION_G : positive := 36;                           -- MEM_RESET# : 1 us a 36 MHz
      MR_REPRISE_G   : positive := 3600;                         -- reprise des memoires : 100 us
      UART_DIV_G     : natural  := 311                           -- 115 200 bauds a 36 MHz
   );
   port (
      CLK_i          : in  std_logic;
      RESET_i        : in  std_logic;

      -- xSPI A (ouest) et B (sud)
      XA_SCLK_o      : out std_logic;
      XA_SCLK_OE_o   : out std_logic;
      XA_CS_N_o      : out std_logic_vector( 1 downto 0 );
      XA_CS_OE_o     : out std_logic;
      XA_DQ_o        : out std_logic_vector( 7 downto 0 );
      XA_DQ_OE_o     : out std_logic_vector( 7 downto 0 );
      XA_DQ_i        : in  std_logic_vector( 7 downto 0 );
      XA_DQS_o       : out std_logic;
      XA_DQS_OE_o    : out std_logic;
      XB_SCLK_o      : out std_logic;
      XB_SCLK_OE_o   : out std_logic;
      XB_CS_N_o      : out std_logic_vector( 1 downto 0 );
      XB_CS_OE_o     : out std_logic;
      XB_DQ_o        : out std_logic_vector( 7 downto 0 );
      XB_DQ_OE_o     : out std_logic_vector( 7 downto 0 );
      XB_DQ_i        : in  std_logic_vector( 7 downto 0 );
      XB_DQS_o       : out std_logic;
      XB_DQS_OE_o    : out std_logic;
      MEM_RESET_A_N_o : out std_logic;
      MEM_RESET_B_N_o : out std_logic;
      MEM_RESET_OE_o : out std_logic;

      -- UART, I2C
      UART_TX_o      : out std_logic;
      UART_RX_i      : in  std_logic;
      SCL_o          : out std_logic;
      SCL_OE_o       : out std_logic;
      SCL_i          : in  std_logic;
      SDA_o          : out std_logic;
      SDA_OE_o       : out std_logic;
      SDA_i          : in  std_logic;
      I2C_RAPPEL_o   : out std_logic;

      -- GPIO (GPIO0 : BOOT_SEL a la sortie du RESET ; GPIO7 : HALTED par defaut)
      GPIO_o         : out std_logic_vector( 7 downto 0 );
      GPIO_OE_o      : out std_logic_vector( 7 downto 0 );
      GPIO_i         : in  std_logic_vector( 7 downto 0 );

      -- JTAG
      TCK_i          : in  std_logic;
      TMS_i          : in  std_logic;
      TDI_i          : in  std_logic;
      TDO_o          : out std_logic;
      TDO_OE_o       : out std_logic
   );
end entity TAHX_SOC;

architecture STRUCTURE of TAHX_SOC is

   constant NB_BLOCS : positive := 6;

   -- RESET
   signal rst_s1, rst_s2 : std_logic;                            -- RESET_i synchronise
   signal rst_sys     : std_logic;
   signal rst_coeur   : std_logic;
   signal core_hold, core_reset : std_logic;

   -- coeur
   signal boot_block  : address_t;
   signal i_req, i_ready, i_rvalid, i_fault : std_logic;
   signal i_addr      : address_t;
   signal i_rdata     : word64_t;
   signal d_req, d_write, d_ready, d_rvalid, d_fault : std_logic;
   signal d_addr      : address_t;
   signal d_wdata, d_rdata : word64_t;
   signal irq_pending : irq_vector_t;
   signal halt_req, resume_req, halted : std_logic;
   signal halt_cause  : halt_cause_t;
   signal resume_pc, halt_pc, fpc : address_t;
   signal exit_code   : word64_t;
   signal fcode       : trap_code_t;
   signal icache_inval : std_logic;
   signal boot_sel    : std_logic;
   signal null_guard  : unsigned( 4 downto 0 );
   signal cs_type     : std_logic_vector( 7 downto 0 );
   signal cs_size     : std_logic_vector( 19 downto 0 );

   -- registres
   signal r_req, r_write, r_ready, r_rvalid, r_fault : std_logic;
   signal r_addr      : unsigned( 19 downto 0 );
   signal r_size      : unsigned( 1 downto 0 );
   signal r_wdata, r_rdata : word64_t;
   signal sel         : std_logic_vector( NB_BLOCS - 1 downto 0 );
   signal we          : std_logic;
   signal addr        : unsigned( 9 downto 0 );
   signal wdata       : std_logic_vector( 31 downto 0 );
   signal rdata       : std_logic_vector( 32 * NB_BLOCS - 1 downto 0 );
   signal nb_regs     : std_logic_vector( 11 * NB_BLOCS - 1 downto 0 );

   -- debogage
   signal dbg_req, dbg_write, dbg_ready, dbg_rvalid, dbg_fault : std_logic;
   signal dbg_addr, dbg_wdata, dbg_rdata : std_logic_vector( 63 downto 0 );
   signal dbg_size    : std_logic_vector( 1 downto 0 );
   signal dbg_resume_pc : std_logic_vector( 31 downto 0 );
   signal tap_ctl, tap_adr, dm_status : std_logic_vector( 31 downto 0 );
   signal tap_wdata, dm_rdata : std_logic_vector( 63 downto 0 );
   signal tap_bascule : std_logic;

   -- matrice et ports xSPI
   signal s_req, s_write, s_cs, s_ready, s_rvalid, s_fault : std_logic_vector( 0 to SOC_PORTS - 1 );
   signal s_addr      : soc_pa_array_t( 0 to SOC_PORTS - 1 );
   signal s_wdata, s_rdata : soc_word_array_t( 0 to SOC_PORTS - 1 );
   signal xa_cs_type, xb_cs_type : std_logic_vector( 3 downto 0 );
   signal xa_cs_size, xb_cs_size : std_logic_vector( 9 downto 0 );
   signal xa_we, xb_we : std_logic;
   signal xa_dq_oe, xb_dq_oe : std_logic_vector( 7 downto 0 );
   signal xa_dqs_oe, xb_dqs_oe : std_logic;

   -- peripheriques
   signal irq_sources : std_logic_vector( 31 downto 0 );
   signal irq_tmp     : std_logic_vector( 1 downto 0 );
   signal irq_uart, irq_i2c, irq_gpio : std_logic;

   function NB( n : natural ) return std_logic_vector is
   begin
      return std_logic_vector( to_unsigned( n, 11 ) );
   end function;

begin

   ---------------------------------------------------------------------------------- RESET
   SYNCHRO_RESET : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         rst_s1 <= RESET_i;
         rst_s2 <= rst_s1;
      end if;
   end process;
   rst_sys   <= rst_s2 or core_reset;
   rst_coeur <= rst_sys or core_hold;

   ---------------------------------------------------------------------------------- coeur
   boot_block <= x"0000_0000_1000_0000" when boot_sel = '1' else ( others => '0' );
   cs_type <= xb_cs_type & xa_cs_type;                           -- A0 A1 B0 B1, de bas en haut
   cs_size <= xb_cs_size & xa_cs_size;
   resume_pc <= x"00000000" & unsigned( dbg_resume_pc );

   U_TAHX_1 : entity work.TAHX_1
      port map (
         CLK_i => CLK_i, RESET_i => rst_coeur, BOOT_BLOCK_i => boot_block,
         I_REQ_o => i_req, I_ADDR_o => i_addr, I_READY_i => i_ready,
         I_RVALID_i => i_rvalid, I_RDATA_i => i_rdata, I_FAULT_i => i_fault,
         D_REQ_o => d_req, D_WRITE_o => d_write, D_ADDR_o => d_addr, D_SIZE_o => open,
         D_WDATA_o => d_wdata, D_WSTRB_o => open, D_READY_i => d_ready,
         D_RVALID_i => d_rvalid, D_RDATA_i => d_rdata, D_FAULT_i => d_fault,
         IRQ_PENDING_i => irq_pending, IRQ_ACK_o => open, IRQ_ACK_CODE_o => open,
         HALT_REQ_i => halt_req, HALTED_o => halted, HALT_CAUSE_o => halt_cause,
         RESUME_REQ_i => resume_req, RESUME_PC_i => resume_pc, HALT_PC_o => halt_pc,
         ICACHE_INVALIDATE_i => icache_inval, EXIT_CODE_o => exit_code,
         FPC_o => fpc, FCODE_o => fcode,
         ATTR_EN_i => '1', CS_TYPE_i => cs_type, CS_SIZE_i => cs_size,
         BOOT_SEL_i => boot_sel, NULL_GUARD_i => null_guard,
         R_REQ_o => r_req, R_WRITE_o => r_write, R_ADDR_o => r_addr, R_SIZE_o => r_size,
         R_WDATA_o => r_wdata, R_READY_i => r_ready, R_RVALID_i => r_rvalid,
         R_RDATA_i => r_rdata, R_FAULT_i => r_fault,
         DBG_REQ_i => dbg_req, DBG_WRITE_i => dbg_write, DBG_ADDR_i => unsigned( dbg_addr( 31 downto 0 ) ),
         DBG_SIZE_i => unsigned( dbg_size ), DBG_WDATA_i => dbg_wdata,
         DBG_READY_o => dbg_ready, DBG_RVALID_o => dbg_rvalid, DBG_RDATA_o => dbg_rdata,
         DBG_FAULT_o => dbg_fault );

   ---------------------------------------------------------------------------------- matrice, xSPI
   U_MATRICE : entity work.SOC_MATRICE
      port map (
         CLK_i => CLK_i, RESET_i => rst_sys, BOOT_SEL_i => boot_sel,
         I_REQ_i => i_req, I_ADDR_i => i_addr, I_READY_o => i_ready,
         I_RVALID_o => i_rvalid, I_RDATA_o => i_rdata, I_FAULT_o => i_fault,
         D_REQ_i => d_req, D_WRITE_i => d_write, D_ADDR_i => d_addr, D_WDATA_i => d_wdata,
         D_READY_o => d_ready, D_RVALID_o => d_rvalid, D_RDATA_o => d_rdata, D_FAULT_o => d_fault,
         S_REQ_o => s_req, S_WRITE_o => s_write, S_CS_o => s_cs, S_ADDR_o => s_addr,
         S_WDATA_o => s_wdata, S_READY_i => s_ready, S_RVALID_i => s_rvalid,
         S_RDATA_i => s_rdata, S_FAULT_i => s_fault );

   xa_we <= we and sel( 4 );
   xb_we <= we and sel( 5 );

   U_XSPI_A : entity work.XSPI_PORT
      generic map ( BOOT_G => true )
      port map (
         CLK_i => CLK_i, RESET_i => rst_sys,
         S_REQ_i => s_req( 0 ), S_WRITE_i => s_write( 0 ), S_CS_i => s_cs( 0 ), S_ADDR_i => s_addr( 0 ),
         S_WDATA_i => s_wdata( 0 ), S_READY_o => s_ready( 0 ), S_RVALID_o => s_rvalid( 0 ),
         S_RDATA_o => s_rdata( 0 ), S_FAULT_o => s_fault( 0 ),
         REG_WE_i => xa_we, REG_ADDR_i => addr( 3 downto 0 ), REG_WDATA_i => wdata,
         REG_RDATA_o => rdata( 4 * 32 + 31 downto 4 * 32 ),
         CS_TYPE_o => xa_cs_type, CS_SIZE_o => xa_cs_size,
         SCLK_o => XA_SCLK_o, CS_N_o => XA_CS_N_o, DQ_o => XA_DQ_o, DQ_OE_o => xa_dq_oe,
         DQ_i => XA_DQ_i, RWDS_o => XA_DQS_o, RWDS_OE_o => xa_dqs_oe );

   U_XSPI_B : entity work.XSPI_PORT
      generic map ( BOOT_G => false )
      port map (
         CLK_i => CLK_i, RESET_i => rst_sys,
         S_REQ_i => s_req( 1 ), S_WRITE_i => s_write( 1 ), S_CS_i => s_cs( 1 ), S_ADDR_i => s_addr( 1 ),
         S_WDATA_i => s_wdata( 1 ), S_READY_o => s_ready( 1 ), S_RVALID_o => s_rvalid( 1 ),
         S_RDATA_o => s_rdata( 1 ), S_FAULT_o => s_fault( 1 ),
         REG_WE_i => xb_we, REG_ADDR_i => addr( 3 downto 0 ), REG_WDATA_i => wdata,
         REG_RDATA_o => rdata( 5 * 32 + 31 downto 5 * 32 ),
         CS_TYPE_o => xb_cs_type, CS_SIZE_o => xb_cs_size,
         SCLK_o => XB_SCLK_o, CS_N_o => XB_CS_N_o, DQ_o => XB_DQ_o, DQ_OE_o => xb_dq_oe,
         DQ_i => XB_DQ_i, RWDS_o => XB_DQS_o, RWDS_OE_o => xb_dqs_oe );

   -- haute impedance pendant le RESET (programmation en circuit)
   XA_SCLK_OE_o <= not rst_sys;
   XA_CS_OE_o   <= not rst_sys;
   XA_DQ_OE_o   <= xa_dq_oe when rst_sys = '0' else ( others => '0' );
   XA_DQS_OE_o  <= xa_dqs_oe and not rst_sys;
   XB_SCLK_OE_o <= not rst_sys;
   XB_CS_OE_o   <= not rst_sys;
   XB_DQ_OE_o   <= xb_dq_oe when rst_sys = '0' else ( others => '0' );
   XB_DQS_OE_o  <= xb_dqs_oe and not rst_sys;

   ---------------------------------------------------------------------------------- registres
   nb_regs <= NB( 16 ) & NB( 16 ) & NB( 4 ) & NB( 3 ) & NB( 9 ) & NB( 18 );

   U_REGISTRES : entity work.SOC_REGISTRES
      generic map ( NB_BLOCS_G => NB_BLOCS )
      port map (
         CLK_i => CLK_i, RESET_i => rst_sys,
         R_REQ_i => r_req, R_WRITE_i => r_write, R_ADDR_i => r_addr, R_SIZE_i => r_size,
         R_WDATA_i => r_wdata, R_READY_o => r_ready, R_RVALID_o => r_rvalid,
         R_RDATA_o => r_rdata, R_FAULT_o => r_fault,
         SEL_o => sel, WE_o => we, ADDR_o => addr, WDATA_o => wdata,
         RDATA_i => rdata, NB_i => nb_regs );

   irq_sources <= ( 0 => irq_tmp( 0 ), 1 => irq_tmp( 1 ), 2 => irq_uart, 3 => irq_i2c,
                    4 => irq_gpio, others => '0' );

   U_SYSTEME : entity work.SYSTEME
      generic map ( MR_IMPULSION_G => MR_IMPULSION_G, MR_REPRISE_G => MR_REPRISE_G )
      port map (
         CLK_i => CLK_i, RESET_i => rst_sys,
         SEL_i => sel( 0 ), WE_i => we, ADDR_i => addr( 4 downto 0 ), WDATA_i => wdata,
         RDATA_o => rdata( 31 downto 0 ),
         CORE_HOLD_o => core_hold, BOOT_SEL_o => boot_sel, NULL_GUARD_o => null_guard,
         ICACHE_INVALIDATE_o => icache_inval,
         IRQ_SOURCES_i => irq_sources, IRQ_PENDING_o => irq_pending, IRQ_GPIO_o => irq_gpio,
         EXIT_CODE_i => exit_code, FPC_i => std_logic_vector( fpc( 31 downto 0 ) ),
         FCODE_i => std_logic_vector( fcode ), HALT_CAUSE_i => std_logic_vector( halt_cause ),
         HALTED_i => halted,
         MEM_RESET_A_N_o => MEM_RESET_A_N_o, MEM_RESET_B_N_o => MEM_RESET_B_N_o,
         MEM_RESET_OE_o => MEM_RESET_OE_o,           -- 0 pendant rst_sys (SYSTEME)
         GPIO_o => GPIO_o, GPIO_OE_o => GPIO_OE_o, GPIO_i => GPIO_i );

   U_TEMPORISATEUR : entity work.TEMPORISATEUR
      port map (
         CLK_i => CLK_i, RESET_i => rst_sys,
         SEL_i => sel( 1 ), WE_i => we, ADDR_i => addr( 3 downto 0 ), WDATA_i => wdata,
         RDATA_o => rdata( 63 downto 32 ), IRQ_o => irq_tmp );

   U_UART : entity work.UART
      generic map ( PROF_G => 8, DIV_RESET_G => UART_DIV_G )
      port map (
         CLK_i => CLK_i, RESET_i => rst_sys,
         SEL_i => sel( 2 ), WE_i => we, ADDR_i => addr( 1 downto 0 ), WDATA_i => wdata,
         RDATA_o => rdata( 95 downto 64 ), IRQ_o => irq_uart,
         TX_o => UART_TX_o, RX_i => UART_RX_i );

   U_I2C : entity work.I2C
      generic map ( PROF_G => 8 )
      port map (
         CLK_i => CLK_i, RESET_i => rst_sys,
         SEL_i => sel( 3 ), WE_i => we, ADDR_i => addr( 1 downto 0 ), WDATA_i => wdata,
         RDATA_o => rdata( 127 downto 96 ), IRQ_o => irq_i2c,
         SCL_o => SCL_o, SCL_OE_o => SCL_OE_o, SCL_i => SCL_i,
         SDA_o => SDA_o, SDA_OE_o => SDA_OE_o, SDA_i => SDA_i, RAPPEL_o => I2C_RAPPEL_o );

   ---------------------------------------------------------------------------------- debogage
   U_TAP : entity work.JTAG_TAP
      port map (
         TCK_i => TCK_i, TMS_i => TMS_i, TDI_i => TDI_i, TDO_o => TDO_o, TDO_OE_o => TDO_OE_o,
         RESET_i => RESET_i,
         EXTEST_o => open, BSR_CAPTURE_o => open, BSR_SHIFT_o => open, BSR_UPDATE_o => open,
         BSR_TDO_i => '0',
         CTL_o => tap_ctl, ADR_o => tap_adr, WDATA_o => tap_wdata, CMD_BASCULE_o => tap_bascule,
         STATUS_i => dm_status, RDATA_i => dm_rdata );

   U_DEBUG : entity work.DEBUG_MODULE
      port map (
         CLK_i => CLK_i, RESET_i => rst_s2,
         CTL_i => tap_ctl, ADR_i => tap_adr, WDATA_i => tap_wdata, CMD_BASCULE_i => tap_bascule,
         STATUS_o => dm_status, RDATA_o => dm_rdata,
         HALT_REQ_o => halt_req, RESUME_REQ_o => resume_req, RESUME_PC_o => dbg_resume_pc,
         CORE_RESET_o => core_reset, HALTED_i => halted,
         HALT_PC_i => std_logic_vector( halt_pc( 31 downto 0 ) ),
         HALT_CAUSE_i => "00000" & std_logic_vector( halt_cause ),
         FPC_i => std_logic_vector( fpc( 31 downto 0 ) ),
         FCODE_i => x"00" & std_logic_vector( fcode ),
         M_REQ_o => dbg_req, M_WRITE_o => dbg_write, M_ADDR_o => dbg_addr( 31 downto 0 ),
         M_SIZE_o => dbg_size, M_WDATA_o => dbg_wdata,
         M_READY_i => dbg_ready, M_RVALID_i => dbg_rvalid, M_RDATA_i => dbg_rdata,
         M_FAULT_i => dbg_fault );
   dbg_addr( 63 downto 32 ) <= ( others => '0' );

end architecture STRUCTURE;
