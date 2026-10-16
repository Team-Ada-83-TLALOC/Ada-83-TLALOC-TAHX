library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
-- Ports a adresses physiques (INO_PADDR) des blocs InO durcis separement.
--
-- Les types de IN_ORDER_TYPES portent des adresses de 64 bits. A l'interieur
-- d'un bloc, les 32 bits hauts sont nuls (CUT) et la synthese les elimine ;
-- mais sur le bord d'une macro ils deviennent des broches. Les types ci-dessous
-- sont ceux des ports : memes champs, adresses en paddr_t.
--
-- Conversions : TO_PA (64 -> 32 bits, troncature) et TO_VA (32 -> 64 bits,
-- extension par des zeros), surchargees pour chaque type. Une conversion n'est
-- exacte que si l'adresse est realisable : chaque usage ci-dessous le justifie.
--
-- Cas particulier : l'adresse d'emission d'une instruction a niveau lexical vaut
-- DISPLAY(lvl) + val ; ce n'est pas une adresse realisable (le decalage peut
-- sortir de l'espace) et c'est aussi une valeur architecturale (adresse empilee).
-- Le port transporte donc la base DISPLAY(lvl) (realisable) et address_ofs ;
-- TO_VA ajoute le decalage canon.val en 64 bits, exactement comme avant.
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.INO_PADDR.all;

package INO_PORTS_PA is

   type pred_pa_t is record
      taken     : std_logic;
      target    : paddr_t;
      ghist     : ghist_t;
      ras_ptr   : ras_ptr_t;
   end record;

   type slot_pa_t is record
      valid     : std_logic;
      canon     : canon_t;
      pc        : paddr_t;
      pred      : pred_pa_t;
   end record;

   -- Bloc d'entree de INO_DECODE_QUEUE (depuis le frontal).
   type block_pa_t is array( 0 to DECODE_WIDTH - 1 ) of slot_pa_t;

   type display_pa_t is array( 0 to 14 ) of paddr_t;

   -- Indice d'une entrée de DISPLAY sur un port de lecture ou d'écriture (0 .. 14).
   subtype disp_sel_t is unsigned( 3 downto 0 );

   type frame_pa_t is record
      dsp       : paddr_t;
      rsp       : paddr_t;
      display   : display_pa_t;
   end record;

   type issue_pa_t is record
      slot          : slot_pa_t;
      issue_class   : issue_class_t;
      operand_count : stack_count_t;
      operand       : ino_operand_array_t;
      address_known : std_logic;
      address_ofs   : std_logic;          -- '1' : adresse = address + canon.val (64 bits)
      address       : paddr_t;
   end record;

   type complete_pa_t is record
      valid         : std_logic;
      result_valid  : std_logic;
      result        : word64_t;
      fault         : fault_t;
      taken         : std_logic;
      target        : paddr_t;
   end record;

   type commit_pa_t is record
      valid     : std_logic;
      slot      : slot_pa_t;
      fault     : fault_t;
      taken     : std_logic;
      target    : paddr_t;
   end record;

   type mem_request_pa_t is record
      valid     : std_logic;
      write     : std_logic;
      probe     : std_logic;
      address   : paddr_t;
      size      : unsigned( 1 downto 0 );
      wdata     : word64_t;
   end record;

   function TO_PA( s : decoded_slot_t ) return slot_pa_t;
   function TO_VA( s : slot_pa_t ) return decoded_slot_t;
   function TO_PA( b : decoded_block_t ) return block_pa_t;
   function TO_VA( b : block_pa_t ) return decoded_block_t;

   function TO_PA( f : frame_state_t ) return frame_pa_t;
   function TO_VA( f : frame_pa_t ) return frame_state_t;

   function TO_VA( i : issue_pa_t ) return ino_issue_t;

   function TO_PA( c : ino_complete_t ) return complete_pa_t;
   function TO_VA( c : complete_pa_t ) return ino_complete_t;

   function TO_PA( c : ino_commit_t ) return commit_pa_t;
   function TO_VA( c : commit_pa_t ) return ino_commit_t;

   function TO_PA( r : mem_request_t ) return mem_request_pa_t;
   function TO_VA( r : mem_request_pa_t ) return mem_request_t;

end package INO_PORTS_PA;

package body INO_PORTS_PA is

   function TO_PA( s : decoded_slot_t ) return slot_pa_t is
   begin
      return ( valid => s.valid, canon => s.canon, pc => TO_PA( s.pc ),
               pred => ( taken => s.pred.taken, target => TO_PA( s.pred.target ),
                         ghist => s.pred.ghist, ras_ptr => s.pred.ras_ptr ) );
   end function;

   function TO_VA( s : slot_pa_t ) return decoded_slot_t is
   begin
      return ( valid => s.valid, canon => s.canon, pc => TO_VA( s.pc ),
               pred => ( taken => s.pred.taken, target => TO_VA( s.pred.target ),
                         ghist => s.pred.ghist, ras_ptr => s.pred.ras_ptr ) );
   end function;

   function TO_PA( b : decoded_block_t ) return block_pa_t is
      variable r : block_pa_t;
   begin
      for k in b'range loop r( k ) := TO_PA( b( k ) ); end loop;
      return r;
   end function;

   function TO_VA( b : block_pa_t ) return decoded_block_t is
      variable r : decoded_block_t;
   begin
      for k in b'range loop r( k ) := TO_VA( b( k ) ); end loop;
      return r;
   end function;

   function TO_PA( f : frame_state_t ) return frame_pa_t is
      variable r : frame_pa_t;
   begin
      r.dsp := TO_PA( f.dsp );
      r.rsp := TO_PA( f.rsp );
      for i in r.display'range loop r.display( i ) := TO_PA( f.display( i ) ); end loop;
      return r;
   end function;

   function TO_VA( f : frame_pa_t ) return frame_state_t is
      variable r : frame_state_t;
   begin
      r.dsp := TO_VA( f.dsp );
      r.rsp := TO_VA( f.rsp );
      for i in f.display'range loop r.display( i ) := TO_VA( f.display( i ) ); end loop;
      return r;
   end function;

   function TO_VA( i : issue_pa_t ) return ino_issue_t is
      variable r : ino_issue_t;
   begin
      r.slot          := TO_VA( i.slot );
      r.issue_class   := i.issue_class;
      r.operand_count := i.operand_count;
      r.operand       := i.operand;
      r.address_known := i.address_known;
      r.address       := TO_VA( i.address );
      if i.address_ofs = '1' then
         r.address := r.address + unsigned( std_logic_vector( resize( i.slot.canon.val, 64 ) ) );
      end if;
      return r;
   end function;

   function TO_PA( c : ino_complete_t ) return complete_pa_t is
   begin
      return ( valid => c.valid, result_valid => c.result_valid, result => c.result,
               fault => c.fault, taken => c.taken, target => TO_PA( c.target ) );
   end function;

   function TO_VA( c : complete_pa_t ) return ino_complete_t is
   begin
      return ( valid => c.valid, result_valid => c.result_valid, result => c.result,
               fault => c.fault, taken => c.taken, target => TO_VA( c.target ) );
   end function;

   function TO_PA( c : ino_commit_t ) return commit_pa_t is
   begin
      return ( valid => c.valid, slot => TO_PA( c.slot ), fault => c.fault,
               taken => c.taken, target => TO_PA( c.target ) );
   end function;

   function TO_VA( c : commit_pa_t ) return ino_commit_t is
   begin
      return ( valid => c.valid, slot => TO_VA( c.slot ), fault => c.fault,
               taken => c.taken, target => TO_VA( c.target ) );
   end function;

   function TO_PA( r : mem_request_t ) return mem_request_pa_t is
   begin
      return ( valid => r.valid, write => r.write, probe => r.probe, address => TO_PA( r.address ),
               size => r.size, wdata => r.wdata );
   end function;

   function TO_VA( r : mem_request_pa_t ) return mem_request_t is
   begin
      return ( valid => r.valid, write => r.write, probe => r.probe, address => TO_VA( r.address ),
               size => r.size, wdata => r.wdata );
   end function;

end package body INO_PORTS_PA;
------------------------------------------------------------------------------------------------------------------------
