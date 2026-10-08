TAHX InO - correction LEXCMP longueur non positive

Correction unique dans vhdl_InO/L6_INO_BLOCK_UNIT_rtl.vhd :
si lg <= 0 ou ld <= 0, LEXCMP termine immédiatement avec le résultat
signé de comparaison des longueurs, avant toute maintenance ou accès mémoire.

Aucun banc n'est modifié.
