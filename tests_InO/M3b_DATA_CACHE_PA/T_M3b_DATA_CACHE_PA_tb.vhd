library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- Banc dirige : espace d'adressage physique de l'implantation InO (INO_PADDR).
--
-- DATA_CACHE(IN_ORDER) avec les generiques par defaut de TAHX_1 (VALID_LIMIT_G =
-- DATA_VALID_LIMIT, bien au-dela de 2**PA_BITS). Des sondages (probe) donnent le
-- verdict de validite sans acces memoire : un acces qui ne tient pas entierement
-- sous 2**PA_BITS doit fauter (faute 132), sans etre tronque.
------------------------------------------------------------------------------------------------------------------------
use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.EXEC_TYPES.all;
use work.INO_PADDR.all;
use work.TB_UTILS.all;

entity T_M3b_DATA_CACHE_PA_tb is end entity;

architecture TEST of T_M3b_DATA_CACHE_PA_tb is
   constant PERIOD : time := 10 ns;
   signal clk      : std_logic := '0';
   signal running  : boolean := true;
   signal reset    : std_logic := '1';
   signal req      : mem_request_bus_t( 0 to 0 ) := ( others => NO_MEM_REQUEST );
   signal ready    : std_logic_vector( 0 to 0 );
   signal rsp      : mem_response_bus_t( 0 to 0 );
   signal d_req, d_write : std_logic;
   signal d_addr   : address_t;
   signal d_size   : unsigned( 1 downto 0 );
   signal d_wdata  : word64_t;
   signal d_wstrb  : std_logic_vector( 7 downto 0 );
begin
   DUT : entity work.DATA_CACHE(IN_ORDER)
      generic map ( PORTS_G => 1 )
      port map (
         CLK_i => clk, RESET_i => reset,
         REQ_i => req, READY_o => ready, RSP_o => rsp,
         D_REQ_o => d_req, D_WRITE_o => d_write, D_ADDR_o => d_addr, D_SIZE_o => d_size,
         D_WDATA_o => d_wdata, D_WSTRB_o => d_wstrb, D_READY_i => '0',
         D_RVALID_i => '0', D_RDATA_i => ( others => '0' ), D_FAULT_i => '0' );

   clk <= not clk after PERIOD / 2 when running;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure SONDE( a : address_t; size : natural; faute : std_logic; quoi : string ) is
      begin
         req( 0 ) <= ( valid => '1', write => '0', probe => '1', address => a,
                       size => to_unsigned( size, 2 ), wdata => ( others => '0' ) );
         loop
            wait until rising_edge( clk );
            exit when ready( 0 ) = '1';
         end loop;
         req( 0 ) <= NO_MEM_REQUEST;
         loop
            wait until rising_edge( clk );
            exit when rsp( 0 ).valid = '1';
         end loop;
         CHECK( c, rsp( 0 ).fault = faute, quoi & " (" & HEX( a ) & ", " & integer'image( 2 ** size ) & " octets)",
                std_logic'image( faute ), std_logic'image( rsp( 0 ).fault ) );
         wait until falling_edge( clk );
      end procedure;

      constant HAUT : address_t := PA_LIMIT;
   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      wait until falling_edge( clk );

      SONDE( x"0000000000400000", 3, '0', "acces ordinaire" );
      SONDE( HAUT - 8,             3, '0', "dernier quad realise" );
      SONDE( HAUT - 1,             0, '0', "dernier octet realise" );
      SONDE( HAUT - 4,             3, '1', "quad a cheval sur 2**PA_BITS" );
      SONDE( HAUT,                 0, '1', "premier octet non realise" );
      SONDE( HAUT + x"400000",     3, '1', "alias d'une adresse valide" );
      SONDE( x"0000010000400000",  2, '1', "adresse haute (bit 40)" );
      SONDE( x"8000000000400000",  1, '1', "adresse haute (bit 63)" );
      SONDE( x"00000000003FFFF8",  3, '1', "sous DATA_VALID_BASE" );

      running <= false;
      FINISH( c, "T_M3b_DATA_CACHE_PA_tb" );
      wait;
   end process;
end architecture;
