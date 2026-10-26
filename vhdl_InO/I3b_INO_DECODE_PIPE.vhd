library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.INO_DECODE_PKG.all;

        --------------------------------------------------------------------------------
        -- INO_DECODE_PIPE : decodage d'un bloc en deux etages (etude IPC x f, 26 octobre).
        --
        -- Le chemin registres de la file d'octets -> predecodage -> chaine des debuts ->
        -- champs -> registres du predicteur etait, une fois route, la famille limitante
        -- du coeur (etude, § 8.7). Il est coupe apres le predecodage :
        --
        --  etage 1 : PRE pour les 32 positions de la fenetre, enregistre (pre_q), avec
        --            le nombre d'octets presents (count_q) ;
        --  etage 2 : CHAIN sur pre_q, champs lus dans la fenetre courante.
        --
        -- pre_q vaut pour la fenetre courante si, depuis le front precedent, la tete de
        -- la file n'a pas bouge et le nombre d'octets n'a pas diminue (pas de vidage) :
        -- les octets des positions < count_q sont alors inchanges, et un predecodage
        -- fait avec moins d'octets n'est que plus prudent (K_NEED plus tot). La tete
        -- bouge au front ou CONSUME_o vaut '1' (consommation differee, P2) : moved_q.
        -- Sinon le bloc presente est vide (DECODE_VALID_o = '0') pendant un cycle.
        --
        -- Apres une prise (cycle t), la tete bouge au front t+1 -> t+2 et le nouveau
        -- predecodage est valide a t+3 ; BRANCH_PREDICT(IN_ORDER) revient en IDLE au
        -- plus tot a t+3 (EVAL, OUTPUT) : aucun cycle perdu en regime etabli. Apres une
        -- redirection, le premier bloc arrive un cycle plus tard qu'avec DECODE_BLOC.
        --
        -- CONSUME_o, CONSUMED_BYTES_o et STOP_o sont enregistres (P2) : la prise est
        -- appliquee a la file d'octets au cycle suivant.
        --------------------------------------------------------------------------------

				---------------
entity				INO_DECODE_PIPE
is				---------------
   port (
      CLK_i              :in  std_logic;
      RESET_i            :in  std_logic;

      WINDOW_i           :in  decode_window_t;
      WINDOW_COUNT_i     :in  window_count_t;
      WINDOW_PC_i        :in  address_t;
      WINDOW_FAULT_i     :in  window_flags_t;

      DECODED_o          :out decoded_block_t;
      DECODED_COUNT_o    :out decode_count_t;
      DECODE_VALID_o     :out std_logic;
      DECODE_READY_i     :in  std_logic;

      CONSUME_o          :out std_logic;          -- enregistre : prise du cycle precedent
      CONSUMED_BYTES_o   :out window_count_t;
      STOP_o             :out std_logic
   );
end entity			INO_DECODE_PIPE;

architecture RTL of INO_DECODE_PIPE is

   signal count_s    : natural range 0 to DECODE_WINDOW_SIZE;
   signal pre_s      : pre_array_t;
   signal pre_q      : pre_array_t := ( others => ( kind => K_NEED, nxt => 0 ) );
   signal count_q    : natural range 0 to DECODE_WINDOW_SIZE := 0;
   signal moved_q    : std_logic := '0';
   signal valid_s    : std_logic;
   signal chain_s    : chain_t;
   signal take_s     : std_logic;
   signal consume_q  : std_logic := '0';
   signal consumed_q : window_count_t := ( others => '0' );
   signal stop_q     : std_logic := '0';

begin

   count_s <= DECODE_WINDOW_SIZE when to_integer( WINDOW_COUNT_i ) > DECODE_WINDOW_SIZE
              else to_integer( WINDOW_COUNT_i );

   PREDECODE : for i in 0 to DECODE_WINDOW_SIZE - 1 generate
      pre_s( i ) <= PRE( i, WINDOW_i, count_s, WINDOW_FAULT_i );
   end generate PREDECODE;
   pre_s( DECODE_WINDOW_SIZE ) <= ( kind => K_NEED, nxt => 0 );

   -- Etage 2 : chaine sur le predecodage enregistre, champs de la fenetre courante.
   valid_s <= '1' when moved_q = '0' and count_s >= count_q else '0';
   chain_s <= CHAIN( pre_q, WINDOW_i, WINDOW_PC_i );
   take_s  <= '1' when valid_s = '1' and chain_s.n > 0 and DECODE_READY_i = '1' else '0';

   DECODED_o        <= chain_s.slots;
   DECODED_COUNT_o  <= to_unsigned( chain_s.n, DECODED_COUNT_o'length );
   DECODE_VALID_o   <= '1' when valid_s = '1' and chain_s.n > 0 else '0';

   CONSUME_o        <= consume_q;
   CONSUMED_BYTES_o <= consumed_q;
   STOP_o           <= stop_q;

   ETAGES : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         pre_q      <= pre_s;
         count_q    <= count_s;
         consumed_q <= to_unsigned( chain_s.consumed, consumed_q'length );
         if RESET_i = '1' then
            pre_q     <= ( others => ( kind => K_NEED, nxt => 0 ) );
            count_q   <= 0;
            moved_q   <= '0';
            consume_q <= '0';
            stop_q    <= '0';
         else
            moved_q   <= consume_q;
            consume_q <= take_s;
            stop_q    <= chain_s.stop and take_s;
         end if;
      end if;
   end process ETAGES;

end architecture RTL;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
