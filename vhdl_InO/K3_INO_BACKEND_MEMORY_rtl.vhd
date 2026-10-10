library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

                                ---
architecture                    RTL
of INO_BACKEND_MEMORY is        ---

   signal base_issue_valid_s    : std_logic;
   signal base_issue_ready_s    : std_logic;
   signal base_complete_s       : ino_complete_t;

   signal mem_issue_valid_s     : std_logic;
   signal address_issue_ready_s : std_logic;
   signal address_s             : ino_address_t;
   signal address_ready_s       : std_logic;
   signal memory_complete_s     : ino_complete_t;
   signal slow_mem_req_s        : mem_request_t;

   -----------------------------------------------------------------------------
   -- Fast path des accès directs de famille B.
   --
   -- Quand STACK_UNIT connaît déjà l'adresse effective (lvl 0..14), un load/store
   -- simple n'a aucune raison de traverser le registre INO_ADDRESS_UNIT puis
   -- ST_DISPATCH de INO_MEMORY_UNIT. La requête DATA_CACHE est présentée pendant
   -- le cycle même de ISSUE ; seule la réponse est enregistrée.
   --
   -- CHK, lvl=15, familles C et tous les cas spéciaux restent intégralement sur
   -- le chemin lent de référence.
   -----------------------------------------------------------------------------

   type fast_state_t is ( FAST_IDLE, FAST_RSP );

   constant NO_COMPLETE : ino_complete_t := (
      valid        => '0',
      result_valid => '0',
      result       => ( others => '0' ),
      fault        => NO_FAULT,
      taken        => '0',
      target       => ( others => '0' ) );

   signal fast_state_s    : fast_state_t := FAST_IDLE;
   signal fast_slot_s     : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );
   signal fast_size_s     : natural range 0 to 3 := 0;
   signal fast_signed_s   : boolean := false;
   signal fast_store_s    : boolean := false;
   signal fast_complete_s : ino_complete_t := NO_COMPLETE;

   function FAST_DIRECT_MEMORY( ins : ino_issue_t ) return boolean is
      constant op   : opcode_t := ins.slot.canon.op;
      constant mode : std_logic_vector( 1 downto 0 ) := op( 5 downto 4 );
      constant fmt  : std_logic_vector( 1 downto 0 ) := op( 3 downto 2 );
   begin
      -- Famille B, adresse déjà calculée, load signé / store / load non signé.
      -- fmt="11" est réservé ici aux CHK directs, laissés au slow path.
      return ins.issue_class = ISSUE_MEMORY
         and ins.address_known = '1'
         and op( 7 downto 6 ) = "01"
         and mode /= "00"
         and fmt /= "11";
   end function FAST_DIRECT_MEMORY;

   function EXTEND( w : word64_t; sz : natural; sgn : boolean ) return word64_t is
      variable r : word64_t := ( others => '0' );
   begin
      case sz is
         when 0 =>
            r( 7 downto 0 ) := w( 7 downto 0 );
            if sgn and w( 7 ) = '1' then
               r( 63 downto 8 ) := ( others => '1' );
            end if;

         when 1 =>
            r( 15 downto 0 ) := w( 15 downto 0 );
            if sgn and w( 15 ) = '1' then
               r( 63 downto 16 ) := ( others => '1' );
            end if;

         when 2 =>
            r( 31 downto 0 ) := w( 31 downto 0 );
            if sgn and w( 31 ) = '1' then
               r( 63 downto 32 ) := ( others => '1' );
            end if;

         when others =>
            r := w;
      end case;
      return r;
   end function EXTEND;

begin

   base_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class /= ISSUE_MEMORY else '0';

   -- Slow path historique : seulement si l'accès n'est pas éligible au fast path.
   -- INO_ADDRESS_UNIT n'a pas de file interne : ne lui présenter l'instruction
   -- que si INO_MEMORY_UNIT est prête à accepter le résultat au cycle suivant.
   mem_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class = ISSUE_MEMORY
       and not FAST_DIRECT_MEMORY( ISSUE_i )
       and address_ready_s = '1' else '0';

   ISSUE_READY_o <= MEM_READY_i
      when ISSUE_i.issue_class = ISSUE_MEMORY
       and FAST_DIRECT_MEMORY( ISSUE_i )
       and fast_state_s = FAST_IDLE
      else address_issue_ready_s and address_ready_s
      when ISSUE_i.issue_class = ISSUE_MEMORY
      else base_issue_ready_s;

   U_BASE : entity work.INO_BACKEND
      port map (
         CLK_i         => CLK_i,
         RESET_i       => RESET_i,
         ISSUE_VALID_i => base_issue_valid_s,
         ISSUE_i       => ISSUE_i,
         ISSUE_READY_o => base_issue_ready_s,
         COMPLETE_o    => base_complete_s );

   U_ADDRESS : entity work.INO_ADDRESS_UNIT
      port map (
         CLK_i         => CLK_i,
         RESET_i       => RESET_i,
         ISSUE_VALID_i => mem_issue_valid_s,
         ISSUE_i       => ISSUE_i,
         ISSUE_READY_o => address_issue_ready_s,
         ADDRESS_o     => address_s );

   U_MEMORY : entity work.INO_MEMORY_UNIT
      port map (
         CLK_i           => CLK_i,
         RESET_i         => RESET_i,
         ADDRESS_i       => address_s,
         ADDRESS_READY_o => address_ready_s,
         MEM_REQ_o       => slow_mem_req_s,
         MEM_READY_i     => MEM_READY_i,
         MEM_RSP_i       => MEM_RSP_i,
         COMPLETE_o      => memory_complete_s );

   -----------------------------------------------------------------------------
   -- Port mémoire : le fast path présente la requête directement pendant ISSUE.
   -----------------------------------------------------------------------------

   MEM_MUX : process( all )
      variable rq   : mem_request_t;
      variable data : word64_t;
   begin
      rq := slow_mem_req_s;

      if fast_state_s = FAST_IDLE
         and ISSUE_VALID_i = '1'
         and FAST_DIRECT_MEMORY( ISSUE_i ) then
         rq := NO_MEM_REQUEST;
         rq.valid   := '1';
         if ISSUE_i.slot.canon.op( 5 downto 4 ) = "10" then
            rq.write := '1';
         else
            rq.write := '0';
         end if;
         rq.probe   := '0';
         rq.address := ISSUE_i.address;
         rq.size    := unsigned( ISSUE_i.slot.canon.op( 1 downto 0 ) );
         data := ( others => '0' );
         if ISSUE_i.slot.canon.op( 5 downto 4 ) = "10" then
            for s in 0 to 3 loop
               if s = ISSUE_i.operand_count - 1 then
                  data := ISSUE_i.operand( s );
               end if;
            end loop;
         end if;
         rq.wdata := data;
      end if;

      MEM_REQ_o <= rq;
   end process MEM_MUX;

   -----------------------------------------------------------------------------
   -- Une seule transaction fast peut être en vol. La réponse DATA_CACHE est
   -- transformée directement en COMPLETE.
   -----------------------------------------------------------------------------

   FAST_PIPE : process( CLK_i )
      variable c : ino_complete_t;
   begin
      if rising_edge( CLK_i ) then
         fast_complete_s <= NO_COMPLETE;

         if RESET_i = '1' then
            fast_state_s  <= FAST_IDLE;
            fast_slot_s   <= ( valid => '0', canon => CANON_NOP,
                               pc => ( others => '0' ), pred => NO_PREDICTION );
            fast_size_s   <= 0;
            fast_signed_s <= false;
            fast_store_s  <= false;

         else
            case fast_state_s is
               when FAST_IDLE =>
                  if ISSUE_VALID_i = '1'
                     and FAST_DIRECT_MEMORY( ISSUE_i )
                     and MEM_READY_i = '1' then
                     fast_slot_s   <= ISSUE_i.slot;
                     fast_size_s   <= to_integer( unsigned( ISSUE_i.slot.canon.op( 1 downto 0 ) ) );
                     fast_signed_s <= ISSUE_i.slot.canon.op( 5 downto 4 ) = "01";
                     fast_store_s  <= ISSUE_i.slot.canon.op( 5 downto 4 ) = "10";
                     fast_state_s  <= FAST_RSP;
                  end if;

               when FAST_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     c := NO_COMPLETE;
                     c.valid := '1';
                     if MEM_RSP_i.fault = '1' then
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                     elsif not fast_store_s then
                        c.result_valid := '1';
                        c.result := EXTEND( MEM_RSP_i.rdata, fast_size_s, fast_signed_s );
                     end if;
                     fast_complete_s <= c;
                     fast_state_s <= FAST_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process FAST_PIPE;

   COMPLETE_o <= fast_complete_s when fast_complete_s.valid = '1'
                 else memory_complete_s when memory_complete_s.valid = '1'
                 else base_complete_s;

   -- pragma translate_off
   CHECK_CLASS : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ISSUE_VALID_i = '1' then
            assert ISSUE_i.issue_class = ISSUE_INTEGER
                or ISSUE_i.issue_class = ISSUE_MUL_DIV
                or ISSUE_i.issue_class = ISSUE_BRANCH
                or ISSUE_i.issue_class = ISSUE_MEMORY
               report "INO_BACKEND_MEMORY : classe d'emission non encore implementee"
               severity failure;

            if FAST_DIRECT_MEMORY( ISSUE_i ) then
               assert fast_state_s = FAST_IDLE
                  report "INO_BACKEND_MEMORY : nouvel acces fast pendant une transaction fast"
                  severity failure;
            end if;
         end if;
      end if;
   end process CHECK_CLASS;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
