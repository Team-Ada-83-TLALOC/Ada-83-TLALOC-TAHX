library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.INO_PADDR.all;

        --------------------------------------------------------------------------------
        -- FETCH_UNIT, architecture IN_ORDER.
        --
        -- Enveloppe de INO_FETCH_LINE(IN_ORDER) (I1d) pour le contrat commun : le cache
        -- d'instructions de 16 Kio y est decrit ; ici, seul le cadrage du bloc sur le
        -- PC est ajoute :
        --   FETCH_BLOCK_o(i) = FETCH_LINE(off + i) si off + i < 32, 0 sinon,
        --   avec off = FETCH_PC_o(4 downto 0).
        -- INO_FETCH n'utilise pas cette enveloppe : sa file range les octets par
        -- adresse et prend la ligne brute. L'enveloppe sert de reference (bancs I1 et
        -- I6).
        --
        -- Pas de prechargement des cibles : PRELOAD_VALID_o vaut toujours '0' et les
        -- entrees TRAIN_* ne sont pas lues.
        --------------------------------------------------------------------------------

architecture IN_ORDER of FETCH_UNIT is

   signal pc   : address_t;
   signal line : fetch_block_t;

begin

U_LINE :
  entity work.INO_FETCH_LINE( IN_ORDER )
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      I_REQ_o => I_REQ_o, I_ADDR_o => I_ADDR_o, I_READY_i => I_READY_i,
      I_RVALID_i => I_RVALID_i, I_RDATA_i => I_RDATA_i, I_FAULT_i => I_FAULT_i,
      FETCH_VALID_o => FETCH_VALID_o, FETCH_PC_o => pc, FETCH_LINE_o => line,
      FETCH_COUNT_o => FETCH_COUNT_o, FETCH_READY_i => FETCH_READY_i,
      FETCH_FAULT_o => FETCH_FAULT_o,
      RECOVERY_i => RECOVERY_i, PREDICT_VALID_i => PREDICT_VALID_i,
      PREDICT_PC_i => PREDICT_PC_i, STOP_i => STOP_i, FLUSH_o => FLUSH_o
    );

   FETCH_PC_o <= pc;

   BLOC : process(pc, line)
      variable off : natural range 0 to FETCH_BLOCK_SIZE - 1;
   begin
      off := to_integer(pc(4 downto 0));
      for i in 0 to FETCH_BLOCK_SIZE - 1 loop
         if off + i < FETCH_BLOCK_SIZE then
            FETCH_BLOCK_o(i) <= line(off + i);
         else
            FETCH_BLOCK_o(i) <= (others => '0');
         end if;
      end loop;
   end process BLOC;

   -- Pas de prechargement des cibles.
   PRELOAD_VALID_o <= '0';
   PRELOAD_PC_o    <= (others => '0');
   PRELOAD_BLOCK_o <= (others => (others => '0'));
   PRELOAD_COUNT_o <= (others => '0');

end architecture IN_ORDER;
