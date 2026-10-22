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
   -- Fast path des chargements et rangements des familles B et C.
   --
   -- Un load/store simple n'a aucune raison de traverser le registre
   -- INO_ADDRESS_UNIT puis ST_DISPATCH de INO_MEMORY_UNIT. La première requête
   -- DATA_CACHE est présentée pendant le cycle même de ISSUE, à l'adresse :
   --   - DISPLAY(lvl) + val, connue de STACK_UNIT (lvl 0..14, address_known) ;
   --   - opérande 0 + val (lvl = 15, adresse sur la pile ; V4), comme
   --     INO_ADDRESS_UNIT.
   -- Famille B : c'est l'accès. Famille C (V4) : c'est la lecture de la cellule
   -- pointeur ; au cycle de sa réponse, ea = pointeur + ofs est enregistré
   -- (FAST_PTR), la requête de donnée est présentée au cycle suivant (FAST_DATA,
   -- le cache n'accepte qu'en LIBRE). La réponse de l'accès devient COMPLETE dans
   -- son propre cycle (V3 : combinatoire) ; STACK_UNIT l'enregistre au commit.
   -- Sémantique de INO_MEMORY_UNIT : pointeur de 64 bits, ofs non signé, faute
   -- 132 sur une réponse en faute (pointeur ou donnée), donnée d'un rangement =
   -- dernière source dans l'ordre de pile.
   --
   -- CHK (fmt = 11) et les cas spéciaux (mode = 00 : LIVA) restent intégralement
   -- sur le chemin lent de référence.
   -----------------------------------------------------------------------------

   type fast_state_t is ( FAST_IDLE, FAST_PTR, FAST_DATA, FAST_RSP );

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
   signal fast_ofs_s      : unsigned( 7 downto 0 ) := ( others => '0' );
   signal fast_ea_s       : address_t := ( others => '0' );
   signal fast_wdata_s    : word64_t := ( others => '0' );
   signal fast_complete_c : ino_complete_t;

   function FAST_DIRECT_MEMORY( ins : ino_issue_t ) return boolean is
      constant op   : opcode_t := ins.slot.canon.op;
      constant mode : std_logic_vector( 1 downto 0 ) := op( 5 downto 4 );
      constant fmt  : std_logic_vector( 1 downto 0 ) := op( 3 downto 2 );
   begin
      -- Familles B et C, load signé / store / load non signé, adresse connue
      -- (lvl 0..14) ou sur la pile (lvl = 15, opérande 0).
      -- fmt="11" est réservé ici aux CHK, laissés au slow path.
      return ins.issue_class = ISSUE_MEMORY
         and ( op( 7 downto 6 ) = "01" or op( 7 downto 6 ) = "10" )
         and mode /= "00"
         and fmt /= "11";
   end function FAST_DIRECT_MEMORY;

   -- Adresse de la première requête : accès (famille B) ou cellule pointeur (C).
   function FAST_ADDRESS( ins : ino_issue_t ) return address_t is
   begin
      if ins.address_known = '1' then
         return ins.address;
      end if;
      -- Addition modulo 2^64, comme INO_ADDRESS_UNIT.
      return unsigned( ins.operand( 0 ) ) + unsigned( resize( ins.slot.canon.val, 64 ) );
   end function FAST_ADDRESS;

   -- Donnée d'un rangement : la dernière source dans l'ordre de pile.
   function FAST_WDATA( ins : ino_issue_t ) return word64_t is
      variable data : word64_t := ( others => '0' );
   begin
      for s in 0 to 3 loop
         if s = ins.operand_count - 1 then
            data := ins.operand( s );
         end if;
      end loop;
      return data;
   end function FAST_WDATA;

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
   begin
      rq := slow_mem_req_s;

      if fast_state_s = FAST_IDLE
         and ISSUE_VALID_i = '1'
         and FAST_DIRECT_MEMORY( ISSUE_i ) then
         rq := NO_MEM_REQUEST;
         rq.valid   := '1';
         rq.probe   := '0';
         rq.address := FAST_ADDRESS( ISSUE_i );
         if ISSUE_i.slot.canon.op( 7 downto 6 ) = "10" then
            -- Famille C : lecture de la cellule pointeur (64 bits).
            rq.write := '0';
            rq.size  := "11";
         else
            if ISSUE_i.slot.canon.op( 5 downto 4 ) = "10" then
               rq.write := '1';
               rq.wdata := FAST_WDATA( ISSUE_i );
            end if;
            rq.size := unsigned( ISSUE_i.slot.canon.op( 1 downto 0 ) );
         end if;

      elsif fast_state_s = FAST_DATA then
         -- Famille C : accès à pointeur + ofs.
         rq := NO_MEM_REQUEST;
         rq.valid   := '1';
         rq.probe   := '0';
         rq.address := fast_ea_s;
         rq.size    := to_unsigned( fast_size_s, 2 );
         if fast_store_s then
            rq.write := '1';
            rq.wdata := fast_wdata_s;
         end if;
      end if;

      MEM_REQ_o <= rq;
   end process MEM_MUX;

   -----------------------------------------------------------------------------
   -- Une seule transaction fast peut être en vol. La réponse DATA_CACHE est
   -- transformée directement en COMPLETE.
   -----------------------------------------------------------------------------

   FAST_PIPE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            fast_state_s  <= FAST_IDLE;
            fast_slot_s   <= ( valid => '0', canon => CANON_NOP,
                               pc => ( others => '0' ), pred => NO_PREDICTION );
            fast_size_s   <= 0;
            fast_signed_s <= false;
            fast_store_s  <= false;
            fast_ofs_s    <= ( others => '0' );
            fast_ea_s     <= ( others => '0' );
            fast_wdata_s  <= ( others => '0' );

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
                     fast_ofs_s    <= unsigned( ISSUE_i.slot.canon.ofs );
                     fast_wdata_s  <= FAST_WDATA( ISSUE_i );
                     if ISSUE_i.slot.canon.op( 7 downto 6 ) = "10" then
                        fast_state_s <= FAST_PTR;
                     else
                        fast_state_s <= FAST_RSP;
                     end if;
                  end if;

               when FAST_PTR =>
                  -- Pointeur lu : ea = pointeur + ofs (non signé), comme
                  -- INO_MEMORY_UNIT ; une faute termine ici (FAST_COMPLETE).
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        fast_state_s <= FAST_IDLE;
                     else
                        fast_ea_s    <= unsigned( MEM_RSP_i.rdata ) + resize( fast_ofs_s, 64 );
                        fast_state_s <= FAST_DATA;
                     end if;
                  end if;

               when FAST_DATA =>
                  if MEM_READY_i = '1' then
                     fast_state_s <= FAST_RSP;
                  end if;

               when FAST_RSP =>
                  -- COMPLETE rendu dans ce cycle (FAST_COMPLETE).
                  if MEM_RSP_i.valid = '1' then
                     fast_state_s <= FAST_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process FAST_PIPE;

   -- Terminaison du fast path dans le cycle de la réponse du cache (V3).
   FAST_COMPLETE : process( all )
      variable c : ino_complete_t;
   begin
      c := NO_COMPLETE;
      if fast_state_s = FAST_RSP and MEM_RSP_i.valid = '1' and RESET_i = '0' then
         c.valid := '1';
         if MEM_RSP_i.fault = '1' then
            c.fault := ( valid => '1', code => FAULT_ACCESS );
         elsif not fast_store_s then
            c.result_valid := '1';
            c.result := EXTEND( MEM_RSP_i.rdata, fast_size_s, fast_signed_s );
         end if;
      elsif fast_state_s = FAST_PTR and MEM_RSP_i.valid = '1' and MEM_RSP_i.fault = '1'
            and RESET_i = '0' then
         -- Cellule pointeur en faute (famille C).
         c.valid := '1';
         c.fault := ( valid => '1', code => FAULT_ACCESS );
      end if;
      fast_complete_c <= c;
   end process FAST_COMPLETE;

   COMPLETE_o <= fast_complete_c when fast_complete_c.valid = '1'
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
