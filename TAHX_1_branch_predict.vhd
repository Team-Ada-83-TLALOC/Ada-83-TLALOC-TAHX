library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  BRANCH_PREDICT : prédiction au décodage, première version.
--
--  Le bloc décodé montre les transferts de contrôle et leurs déplacements : la cible de BRA, BT,
--  BF et CALL est PC + len + val, calculée ici. Il reste à prédire :
--    BT, BF         le sens, par gshare (64 K compteurs de 2 bits, historique global de 16 bits) ;
--    RTD            la cible, par la pile des retours (32 entrées) que CALL et CALLI alimentent ;
--    CALLI          la cible : non prédite en v1 (le chargement attend la résolution).
--  Étude de limites : 0,74 erreur pour 1000 instructions, moins de 6 % de perte avec 10 cycles de
--  pénalité.
--
--  Le bloc sortant est coupé après le premier transfert prédit pris, et PREDICT_VALID_O redirige
--  le chargement. Chaque case de transfert reçoit sa prédiction (champ pred), que l'unité de
--  branchement vérifiera. La prédiction au chargement (BTB), qui supprimerait la bulle d'un saut
--  pris, pourra s'ajouter plus tard sans changer cette interface.
--
--  Mise à jour : au retrait (RETIRE_I), pour les transferts retirés. Reprise : RECOVERY_I rend
--  l'historique et le sommet de la pile des retours de l'instruction fautive ou mal prédite.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.TAHX_1_DECODE_TYPES.all;
use work.TAHX_1_ROB_TYPES.all;

                                --------------
entity                          BRANCH_PREDICT
is                              --------------
   port (

      CLK_I             :in  std_logic;
      RESET_I           :in  std_logic;

      ----------------------------------------------------------------
      -- Entrée venant de DECODE_BLOC
      ----------------------------------------------------------------

      IN_VALID_I        :in  std_logic;
      IN_BLOCK_I        :in  decoded_block_t;
      IN_COUNT_I        :in  decode_count_t;
      IN_READY_O        :out std_logic;

      ----------------------------------------------------------------
      -- Sortie vers DECODE_QUEUE (bloc éventuellement coupé, prédictions remplies)
      ----------------------------------------------------------------

      OUT_VALID_O       :out std_logic;
      OUT_BLOCK_O       :out decoded_block_t;
      OUT_COUNT_O       :out decode_count_t;
      OUT_READY_I       :in  std_logic;

      ----------------------------------------------------------------
      -- Redirection du chargement vers la cible prédite
      ----------------------------------------------------------------

      PREDICT_VALID_O   :out std_logic;
      PREDICT_PC_O      :out address_t;

      ----------------------------------------------------------------
      -- Apprentissage et reprise
      ----------------------------------------------------------------

      RETIRE_I          :in  retire_block_t;
      RECOVERY_I        :in  recovery_t

   );
                                --------------
end entity                      BRANCH_PREDICT;
                                --------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
