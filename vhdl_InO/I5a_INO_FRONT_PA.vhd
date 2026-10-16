library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
-- Ports reduits du frontal InO durci en macros (INO_DECODE_PREDICT).
--
-- BRANCH_PREDICT(IN_ORDER) ne lit de RETIRE_i que la case 0, et de son pc et de
-- son ghist que les bits d'indice gshare ; de RECOVERY_i que valid, new_pc (coupe par CUT), ghist et
-- ras_ptr. Les types ci-dessous ne portent que ces champs ; TO_VA les rend aux
-- types communs, les champs absents etant nuls (ils ne sont pas lus).
--
-- Separe de INO_PORTS_PA parce qu'il depend de ROB_TYPES, que les bancs du coeur
-- n'analysent pas.
--
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.INO_PADDR.all;

package INO_FRONT_PA is

   -- Bits du pc retire utiles au predicteur : l'indice gshare. Doit valoir
   -- GSHARE_BITS de I4_BRANCH_PREDICT_in_order.vhd (verifie par le banc I5).
   constant RETIRE_PC_BITS : positive := 10;

   -- Bits du sommet de pile des retours lus a la reprise : la pile de
   -- BRANCH_PREDICT(IN_ORDER) a RAS_N = 8 entrees (pointeur reduit modulo 8).
   -- Doit valoir log2( RAS_N ) de I4_BRANCH_PREDICT_in_order.vhd (banc I5).
   constant RECOVERY_RAS_BITS : positive := 3;

   -- Retrait vers le predicteur : la case 0 de retire_block_t.
   type retire_bp_t is record
      valid       : std_logic;
      is_control  : std_logic;
      conditional : std_logic;
      taken       : std_logic;
      pc_low      : unsigned( RETIRE_PC_BITS - 1 downto 0 );   -- pc mod 2^RETIRE_PC_BITS
      ghist_low   : std_logic_vector( RETIRE_PC_BITS - 1 downto 0 ); -- bits d'indice de ghist
   end record;

   -- Reprise vers le predicteur.
   type recovery_bp_t is record
      valid       : std_logic;
      new_pc      : paddr_t;
      ghist       : ghist_t;
      ras_ptr     : unsigned( RECOVERY_RAS_BITS - 1 downto 0 );  -- ras_ptr mod RAS_N
   end record;

   function TO_BP( r : retire_block_t ) return retire_bp_t;
   function TO_VA( r : retire_bp_t ) return retire_block_t;

   function TO_PA( r : recovery_t ) return recovery_bp_t;
   function TO_VA( r : recovery_bp_t ) return recovery_t;

end package INO_FRONT_PA;

package body INO_FRONT_PA is

   function TO_BP( r : retire_block_t ) return retire_bp_t is
   begin
      return ( valid => r( 0 ).valid, is_control => r( 0 ).is_control,
               conditional => r( 0 ).conditional, taken => r( 0 ).taken,
               pc_low => r( 0 ).pc( RETIRE_PC_BITS - 1 downto 0 ),
               ghist_low => r( 0 ).ghist( RETIRE_PC_BITS - 1 downto 0 ) );
   end function;

   function TO_VA( r : retire_bp_t ) return retire_block_t is
      variable x : retire_block_t;
   begin
      for k in x'range loop
         x( k ) := ( valid => '0', rob_index => ( others => '0' ), pc => ( others => '0' ),
                     is_store => '0', is_control => '0', conditional => '0', taken => '0',
                     target => ( others => '0' ), ghist => ( others => '0' ) );
      end loop;
      x( 0 ).valid       := r.valid;
      x( 0 ).is_control  := r.is_control;
      x( 0 ).conditional := r.conditional;
      x( 0 ).taken       := r.taken;
      x( 0 ).pc          := resize( r.pc_low, x( 0 ).pc'length );
      x( 0 ).ghist       := std_logic_vector( resize( unsigned( r.ghist_low ), ghist_t'length ) );
      return x;
   end function;

   function TO_PA( r : recovery_t ) return recovery_bp_t is
   begin
      return ( valid => r.valid, new_pc => TO_PA( r.new_pc ), ghist => r.ghist,
               ras_ptr => r.ras_ptr( RECOVERY_RAS_BITS - 1 downto 0 ) );
   end function;

   function TO_VA( r : recovery_bp_t ) return recovery_t is
   begin
      return ( valid => r.valid, kind => RECOVER_CHECKPOINT, keep_last => ( others => '0' ),
               checkpoint => ( others => '0' ), new_pc => TO_VA( r.new_pc ),
               ghist => r.ghist, ras_ptr => resize( r.ras_ptr, ras_ptr_t'length ) );
   end function;

end package body INO_FRONT_PA;
