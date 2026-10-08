library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

                                ---
architecture                    RTL
of INO_COMPLEX_UNIT is          ---

   constant OP_FEXP_T           : opcode_t := x"24";
   constant OP_CO_VAR_T         : opcode_t := x"38";
   constant OP_HEAP_ALLOC_T     : opcode_t := x"39";
   constant OP_LINK16_T         : opcode_t := x"44";
   constant OP_LINK24_T         : opcode_t := x"48";

   type state_t                 is ( S_IDLE, S_FEXP, S_MEM_REQ, S_MEM_RSP, S_RETURN );
   signal state_s               : state_t := S_IDLE;

   signal copile_s              : copile_state_t := (
      cfp => ( others => '0' ), csp => ( others => '0' ),
      hp => ( others => '0' ), hp_valid => '0' );

   signal complete_s            : ino_complete_t;
   signal return_s              : ino_complete_t;

   signal mem_op_s              : opcode_t := ( others => '0' );
   signal mem_addr_s            : address_t := ( others => '0' );
   signal mem_data_s            : word64_t := ( others => '0' );
   signal link_new_csp_s        : address_t := ( others => '0' );

   signal fexp_start_s          : std_logic;
   signal fexp_abort_s          : std_logic;
   signal fexp_busy_s           : std_logic;
   signal fexp_done_s           : std_logic;
   signal fexp_r_s              : word64_t;

   function EMPTY_COMPLETE return ino_complete_t is
      variable r : ino_complete_t;
   begin
      r.valid        := '0';
      r.result_valid := '0';
      r.result       := ( others => '0' );
      r.fault        := NO_FAULT;
      r.taken        := '0';
      r.target       := ( others => '0' );
      return r;
   end function;

   function ROUND8( n : unsigned( 63 downto 0 ) ) return unsigned is
      variable r : unsigned( 64 downto 0 );
   begin
      r := resize( n, 65 ) + 7;
      r( 2 downto 0 ) := "000";
      return r;
   end function;

   function IS_LINK( op : opcode_t ) return boolean is
   begin
      return op = OP_LINK16_T or op = OP_LINK24_T;
   end function;

begin

   COPILE_o      <= copile_s;
   COMPLETE_o    <= complete_s;
   ISSUE_READY_o <= '1' when state_s = S_IDLE and SYNC_VALID_i = '0' else '0';

   MEM_REQ_o.valid   <= '1' when state_s = S_MEM_REQ else '0';
   MEM_REQ_o.write   <= '1' when state_s = S_MEM_REQ and IS_LINK( mem_op_s ) else '0';
   MEM_REQ_o.probe   <= '0';
   MEM_REQ_o.address <= mem_addr_s;
   MEM_REQ_o.size    <= "11";
   MEM_REQ_o.wdata   <= mem_data_s;

   fexp_start_s <= '1' when state_s = S_IDLE and ISSUE_VALID_i = '1'
                            and ISSUE_i.issue_class = ISSUE_COMPLEX
                            and ISSUE_i.slot.canon.op = OP_FEXP_T
                            and SYNC_VALID_i = '0'
                   else '0';
   fexp_abort_s <= SYNC_VALID_i;

   U_FEXP : entity work.FEXP_UNIT
      port map (
         CLK_i   => CLK_i,
         RESET_i => RESET_i,
         START_i => fexp_start_s,
         X_i     => ISSUE_i.operand( 0 ),
         N_i     => ISSUE_i.operand( 1 ),
         ABORT_i => fexp_abort_s,
         BUSY_o  => fexp_busy_s,
         DONE_o  => fexp_done_s,
         R_o     => fexp_r_s );

   SEQUENCEUR : process( CLK_i )
      variable c       : ino_complete_t;
      variable sz65    : unsigned( 64 downto 0 );
      variable nxt66   : unsigned( 65 downto 0 );
      variable hp65    : unsigned( 64 downto 0 );
      variable nhp65   : unsigned( 64 downto 0 );
      variable csp65   : unsigned( 64 downto 0 );
      variable op      : opcode_t;
   begin
      if rising_edge( CLK_i ) then
         complete_s <= EMPTY_COMPLETE;

         if RESET_i = '1' then
            state_s <= S_IDLE;
            copile_s <= (
               cfp => ( others => '0' ), csp => ( others => '0' ),
               hp => ( others => '0' ), hp_valid => '0' );
            return_s <= EMPTY_COMPLETE;
            mem_op_s <= ( others => '0' );
            mem_addr_s <= ( others => '0' );
            mem_data_s <= ( others => '0' );
            link_new_csp_s <= ( others => '0' );

         elsif SYNC_VALID_i = '1' then
            state_s <= S_IDLE;
            copile_s.cfp <= SYNC_COPILE_i.cfp;
            copile_s.csp <= SYNC_COPILE_i.csp;
            if SYNC_COPILE_i.hp_valid = '1' then
               copile_s.hp <= SYNC_COPILE_i.hp;
               copile_s.hp_valid <= '1';
            end if;
            return_s <= EMPTY_COMPLETE;

         else
            case state_s is

               when S_IDLE =>
                  if ISSUE_VALID_i = '1' then
                     op := ISSUE_i.slot.canon.op;

                     -- pragma translate_off
                     assert ISSUE_i.issue_class = ISSUE_COMPLEX
                        report "INO_COMPLEX_UNIT : classe d'emission incorrecte"
                        severity failure;
                     assert op = OP_FEXP_T or op = OP_CO_VAR_T or op = OP_HEAP_ALLOC_T
                            or IS_LINK( op ) or op = OP_UNLINK or op = OP_UNLINKR
                        report "INO_COMPLEX_UNIT : opcode complexe non encore implemente"
                        severity failure;
                     -- pragma translate_on

                     c := EMPTY_COMPLETE;
                     c.valid := '1';

                     if op = OP_FEXP_T then
                        state_s <= S_FEXP;

                     elsif op = OP_CO_VAR_T then
                        sz65  := ROUND8( unsigned( ISSUE_i.operand( 0 ) ) );
                        nxt66 := resize( copile_s.csp, 66 ) + resize( sz65, 66 );
                        if nxt66 > resize( LIMITS_i.lim_csp, 66 ) then
                           c.result_valid := '0';
                           c.fault := ( valid => '1', code => FAULT_CSP_LIMIT );
                        else
                           c.result_valid := '1';
                           c.result := std_logic_vector( copile_s.csp );
                           copile_s.csp <= nxt66( 63 downto 0 );
                        end if;
                        return_s <= c;
                        state_s <= S_RETURN;

                     elsif op = OP_HEAP_ALLOC_T then
                        sz65 := ROUND8( unsigned( ISSUE_i.operand( 0 ) ) );
                        hp65 := resize( copile_s.hp, 65 );
                        if copile_s.hp_valid = '0' or sz65 > hp65 then
                           c.result_valid := '0';
                           c.fault := ( valid => '1', code => FAULT_HEAP );
                        else
                           nhp65 := hp65 - sz65;
                           if nhp65( 63 downto 0 ) < LIMITS_i.lim_hp then
                              c.result_valid := '0';
                              c.fault := ( valid => '1', code => FAULT_HEAP );
                           else
                              c.result_valid := '1';
                              c.result := std_logic_vector( nhp65( 63 downto 0 ) );
                              copile_s.hp <= nhp65( 63 downto 0 );
                           end if;
                        end if;
                        return_s <= c;
                        state_s <= S_RETURN;

                     elsif IS_LINK( op ) then
                        -- Le LINK sauvegarde CFP dans la co-pile avant de changer CFP/CSP.
                        -- L'effet architectural n'est appliqué qu'après réponse mémoire sans faute.
                        csp65 := resize( copile_s.csp, 65 ) + 8;
                        if csp65( 64 ) = '1' or csp65( 63 downto 0 ) > LIMITS_i.lim_csp then
                           c.fault := ( valid => '1', code => FAULT_CSP_LIMIT );
                           return_s <= c;
                           state_s <= S_RETURN;
                        else
                           mem_op_s       <= op;
                           mem_addr_s     <= copile_s.csp;
                           mem_data_s     <= std_logic_vector( copile_s.cfp );
                           link_new_csp_s <= csp65( 63 downto 0 );
                           state_s        <= S_MEM_REQ;
                        end if;

                     else
                        -- UNLINK / UNLINKR : lecture du CFP sauvegardé à l'adresse CFP.
                        mem_op_s   <= op;
                        mem_addr_s <= copile_s.cfp;
                        mem_data_s <= ( others => '0' );
                        state_s    <= S_MEM_REQ;
                     end if;
                  end if;

               when S_FEXP =>
                  if fexp_done_s = '1' then
                     c := EMPTY_COMPLETE;
                     c.valid := '1';
                     c.result_valid := '1';
                     c.result := fexp_r_s;
                     return_s <= c;
                     state_s <= S_RETURN;
                  end if;

               when S_MEM_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= S_MEM_RSP;
                  end if;

               when S_MEM_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     c := EMPTY_COMPLETE;
                     c.valid := '1';
                     if MEM_RSP_i.fault = '1' then
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                     elsif IS_LINK( mem_op_s ) then
                        copile_s.cfp <= copile_s.csp;
                        copile_s.csp <= link_new_csp_s;
                     elsif mem_op_s = OP_UNLINK then
                        copile_s.cfp <= unsigned( MEM_RSP_i.rdata );
                     else                                             -- UNLINKR
                        copile_s.csp <= copile_s.cfp;
                        copile_s.cfp <= unsigned( MEM_RSP_i.rdata );
                     end if;
                     return_s <= c;
                     state_s <= S_RETURN;
                  end if;

               when S_RETURN =>
                  complete_s <= return_s;
                  state_s <= S_IDLE;
            end case;
         end if;
      end if;
   end process SEQUENCEUR;

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
