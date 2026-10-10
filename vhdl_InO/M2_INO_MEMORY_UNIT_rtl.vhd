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
of INO_MEMORY_UNIT is           ---

   type state_t is (
      ST_IDLE,
      ST_DISPATCH,
      ST_PTR_REQ,
      ST_PTR_RSP,
      ST_DATA_REQ,
      ST_DATA_RSP,
      ST_CHK_FST_REQ,
      ST_CHK_FST_RSP,
      ST_CHK_LST_REQ,
      ST_CHK_LST_RSP
   );

   constant NO_COMPLETE : ino_complete_t := (
      valid        => '0',
      result_valid => '0',
      result       => ( others => '0' ),
      fault        => NO_FAULT,
      taken        => '0',
      target       => ( others => '0' ) );

   signal state_s        : state_t := ST_IDLE;
   signal slot_s         : decoded_slot_t;
   signal cell_address_s : address_t := ( others => '0' );
   signal ea_s           : address_t := ( others => '0' );
   signal data_s         : word64_t := ( others => '0' );
   signal fst_s          : word64_t := ( others => '0' );
   signal size_s         : natural range 0 to 3 := 0;
   signal family_c_s     : boolean := false;
   signal store_s        : boolean := false;
   signal chk_s          : boolean := false;
   signal signed_s       : boolean := false;
   signal special_s      : boolean := false;
   signal complete_s     : ino_complete_t := NO_COMPLETE;

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

   ADDRESS_READY_o <= '1' when state_s = ST_IDLE else '0';
   COMPLETE_o      <= complete_s;

        --------------------------------------------------------------------------------
        -- Requête mémoire de l'état courant.
        --------------------------------------------------------------------------------

   OUTPUTS : process( all )
      variable rq : mem_request_t;
   begin
      rq := NO_MEM_REQUEST;

      case state_s is
         when ST_PTR_REQ =>
            rq.valid   := '1';
            rq.address := cell_address_s;
            rq.size    := "11";

         when ST_DATA_REQ =>
            rq.valid   := '1';
            rq.write   := '1' when store_s else '0';
            rq.address := ea_s;
            rq.size    := to_unsigned( size_s, 2 );
            rq.wdata   := data_s;

         when ST_CHK_FST_REQ =>
            rq.valid   := '1';
            rq.address := ea_s;
            rq.size    := to_unsigned( size_s, 2 );

         when ST_CHK_LST_REQ =>
            rq.valid   := '1';
            rq.address := ea_s + 2 ** size_s;
            rq.size    := to_unsigned( size_s, 2 );

         when others =>
            null;
      end case;

      MEM_REQ_o <= rq;
   end process OUTPUTS;

        --------------------------------------------------------------------------------
        -- Automate bloquant : une seule requête en vol.
        --------------------------------------------------------------------------------

   SEQUENTIAL : process( CLK_i )
      variable op     : opcode_t;
      variable mode   : std_logic_vector( 1 downto 0 );
      variable fmt    : std_logic_vector( 1 downto 0 );
      variable ea_v   : address_t;
      variable value_v: word64_t;
      variable lst_v  : word64_t;
      variable c      : ino_complete_t;
   begin
      if rising_edge( CLK_i ) then
         complete_s <= NO_COMPLETE;

         if RESET_i = '1' then
            state_s        <= ST_IDLE;
            cell_address_s <= ( others => '0' );
            ea_s           <= ( others => '0' );
            data_s         <= ( others => '0' );
            fst_s          <= ( others => '0' );
            size_s         <= 0;
            family_c_s     <= false;
            store_s        <= false;
            chk_s          <= false;
            signed_s       <= false;
            special_s      <= false;

         else
            case state_s is

               when ST_IDLE =>
                  if ADDRESS_i.valid = '1' then
                     op   := ADDRESS_i.slot.canon.op;
                     mode := op( 5 downto 4 );
                     fmt  := op( 3 downto 2 );

                     slot_s         <= ADDRESS_i.slot;
                     cell_address_s <= ADDRESS_i.address;
                     data_s         <= ADDRESS_i.data;
                     size_s         <= to_integer( unsigned( op( 1 downto 0 ) ) );
                     family_c_s     <= op( 7 downto 6 ) = "10";
                     store_s        <= mode = "10";
                     chk_s          <= fmt = "11" and ( mode = "01" or mode = "11" );
                     signed_s       <= mode = "01";
                     special_s      <= mode = "00";
                     state_s        <= ST_DISPATCH;
                  end if;

               when ST_DISPATCH =>
                  if family_c_s then
                     state_s <= ST_PTR_REQ;
                  else
                     ea_s <= cell_address_s;
                     if special_s then
                        -- Ce cas n'est normalement pas ISSUE_MEMORY en famille B
                        -- (LVA est exécuté par INTEGER), mais le comportement est défini.
                        c := NO_COMPLETE;
                        c.valid := '1'; c.result_valid := '1';
                        c.result := std_logic_vector( cell_address_s );
                        complete_s <= c;
                        state_s <= ST_IDLE;
                     elsif chk_s then
                        state_s <= ST_CHK_FST_REQ;
                     else
                        state_s <= ST_DATA_REQ;
                     end if;
                  end if;

               when ST_PTR_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_PTR_RSP;
                  end if;

               when ST_PTR_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        c := NO_COMPLETE;
                        c.valid := '1';
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                        complete_s <= c;
                        state_s <= ST_IDLE;
                     else
                        ea_v := unsigned( MEM_RSP_i.rdata ) + resize( unsigned( slot_s.canon.ofs ), 64 );
                        ea_s <= ea_v;
                        if special_s then
                           -- LIVA : le pointeur lu, augmenté de ofs, est le résultat.
                           c := NO_COMPLETE;
                           c.valid := '1'; c.result_valid := '1';
                           c.result := std_logic_vector( ea_v );
                           complete_s <= c;
                           state_s <= ST_IDLE;
                        elsif chk_s then
                           state_s <= ST_CHK_FST_REQ;
                        else
                           state_s <= ST_DATA_REQ;
                        end if;
                     end if;
                  end if;

               when ST_DATA_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_DATA_RSP;
                  end if;

               when ST_DATA_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     c := NO_COMPLETE;
                     c.valid := '1';
                     if MEM_RSP_i.fault = '1' then
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                     elsif not store_s then
                        c.result_valid := '1';
                        c.result := EXTEND( MEM_RSP_i.rdata, size_s, signed_s );
                     end if;
                     complete_s <= c;
                     state_s <= ST_IDLE;
                  end if;

               when ST_CHK_FST_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_CHK_FST_RSP;
                  end if;

               when ST_CHK_FST_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        c := NO_COMPLETE;
                        c.valid := '1';
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                        complete_s <= c;
                        state_s <= ST_IDLE;
                     else
                        fst_s <= EXTEND( MEM_RSP_i.rdata, size_s, signed_s );
                        state_s <= ST_CHK_LST_REQ;
                     end if;
                  end if;

               when ST_CHK_LST_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_CHK_LST_RSP;
                  end if;

               when ST_CHK_LST_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     c := NO_COMPLETE;
                     c.valid := '1';
                     if MEM_RSP_i.fault = '1' then
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                     else
                        lst_v := EXTEND( MEM_RSP_i.rdata, size_s, signed_s );
                        if signed( data_s ) < signed( fst_s ) or signed( data_s ) > signed( lst_v ) then
                           c.fault := ( valid => '1', code => FAULT_CHK );
                        end if;
                     end if;
                     complete_s <= c;
                     state_s <= ST_IDLE;
                  end if;

            end case;
         end if;
      end if;
   end process SEQUENTIAL;

   -- pragma translate_off
   CHECK_PROTOCOL : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ADDRESS_i.valid = '1' then
            assert state_s = ST_IDLE
               report "INO_MEMORY_UNIT : adresse presente alors que l'unite est occupee"
               severity failure;
            assert ADDRESS_i.slot.canon.op( 7 downto 6 ) = "01"
                or ADDRESS_i.slot.canon.op( 7 downto 6 ) = "10"
               report "INO_MEMORY_UNIT : opcode hors familles B/C"
               severity failure;
         end if;
      end if;
   end process CHECK_PROTOCOL;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
