library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  Ce que la spécification LLIR_hardware_support (V8) impose à toute réalisation, indépendamment de la
--  micro-architecture : types des champs, propriétés des opcodes, codes des fautes et des services.
--  La table des 256 opcodes est dans TAHX_1_ISA_TABLE, générée depuis la spécification.
------------------------------------------------------------------------------------------------------------------------

                                ----------
package                         TAHX_1_ISA
is                              ----------

   --------------------------------------------------------------------
   -- Types élémentaires
   --------------------------------------------------------------------

   subtype byte_t               is std_logic_vector(  7 downto 0 );
   subtype opcode_t             is std_logic_vector(  7 downto 0 );     -- premier octet de l'instruction
   subtype word64_t             is std_logic_vector( 63 downto 0 );     -- mot machine, cellule de pile
   subtype address_t            is unsigned( 63 downto 0 );

   subtype level_t              is unsigned( 3 downto 0 );              -- 0..14 display, 1111 adresse sur pile
   constant LEVEL_STACK         : level_t := "1111";

   subtype insn_length_t        is unsigned( 3 downto 0 );              -- 1..9 octets (0 : voir forme canonique)
   constant MAX_INSN_BYTES      : positive := 9;                        -- LI imm64

   --------------------------------------------------------------------
   -- Propriétés d'un opcode (une entrée de TAHX_1_ISA_TABLE)
   --------------------------------------------------------------------

   -- Format du complément : il fixe la longueur, qui ne dépend que de l'opcode (invariant de décodage).
   type format_t                is ( FMT_NONE, FMT_IMM4,                -- 1 octet
                                     FMT_B16, FMT_B24, FMT_C24, FMT_C32,
                                     FMT_D8, FMT_D16, FMT_D24, FMT_D32, FMT_D64, FMT_D8_8,
                                     FMT_BR8, FMT_BR16, FMT_BR24, FMT_BR32 );

   -- Groupe d'unités fonctionnelles qui exécute l'instruction.
   -- ISSUE_NONE : le renommage suffit (DROP, DUP, OVER).
   type issue_class_t           is ( ISSUE_NONE, ISSUE_INTEGER, ISSUE_MUL_DIV, ISSUE_MEMORY,
                                     ISSUE_BRANCH, ISSUE_FLOAT, ISSUE_COMPLEX );

   -- Action sur la pile logique, pour le renommage.
   -- LINEAR : dépile POPS cellules, empile PUSHES résultats neufs.
   -- DUP, OVER : duplication d'étiquettes, sans registre neuf ni copie de 64 bits.
   -- DROP : abandon d'une étiquette.
   -- KEEP_TOP : le sommet est lu et reste en place (CHK).
   type stack_action_t          is ( STACK_LINEAR, STACK_DUP, STACK_OVER, STACK_DROP, STACK_KEEP_TOP );

   -- Usage du champ lvl.
   -- LVL_NONE  : pas de champ lvl.
   -- LVL_ADDR  : 0..14 niveau display ; 1111 adresse prise sur la pile (un pop de plus).
   -- LVL_FRAME : 0..14 seulement (LINK, EXC_MACH, CHK, UNLINK) ; 1111 est la faute 137.
   type lvl_use_t               is ( LVL_NONE, LVL_ADDR, LVL_FRAME );

   subtype stack_count_t        is natural range 0 to 4;

   type isa_entry_t             is record
         defined        : boolean;              -- false : opcode réservé, faute 137
         length         : natural range 1 to MAX_INSN_BYTES;
         format         : format_t;
         issue_class    : issue_class_t;
         pops           : stack_count_t;        -- pour lvl /= 1111
         pushes         : stack_count_t;
         stack_action   : stack_action_t;
         lvl_use        : lvl_use_t;
         serializing    : boolean;              -- attend que tout ce qui précède soit retiré (TRAP, EXC_RAISE, RTX)
         control        : boolean;              -- peut changer le cours du PC
         memory         : boolean;              -- accède à la mémoire de données
         frame          : boolean;              -- modifie DSP / DISPLAY de façon non linéaire (LINK, UNLINK)
      end record;

   type isa_table_t             is array( 0 to 255 ) of isa_entry_t;

   constant ISA_RESERVE         : isa_entry_t := ( false, 1, FMT_NONE, ISSUE_NONE, 0, 0, STACK_LINEAR,
                                                   LVL_NONE, false, false, false, false );

   --------------------------------------------------------------------
   -- Quelques opcodes nommés (valeurs de la table de la spécification)
   --------------------------------------------------------------------

   constant OP_LI_D32           : opcode_t := x"C2";
   constant OP_LI_D64           : opcode_t := x"C3";
   constant OP_TRAP             : opcode_t := x"F0";
   constant OP_CALL             : opcode_t := x"F2";
   constant OP_RTD_N            : opcode_t := x"F6";
   constant OP_RTD_0            : opcode_t := x"F7";
   constant OP_UNLINK           : opcode_t := x"F8";
   constant OP_UNLINKR          : opcode_t := x"F9";
   constant OP_EXC_RAISE        : opcode_t := x"FE";
   constant OP_RTX              : opcode_t := x"FF";

   --------------------------------------------------------------------
   -- Micro-opérations internes
   --
   -- Elles n'existent que dans la forme canonique, jamais dans le code : elles réutilisent des
   -- opcodes RÉSERVÉS de la spécification, qu'un opcode réservé du code ne peut pas atteindre
   -- (le décodeur le remplace par UOP_ILLEGAL). Si la spécification attribue un jour l'un de
   -- ces codes, il faudra déplacer la micro-opération.
   --------------------------------------------------------------------

   -- LI imm64 éclaté : LI D32 (32 bits de poids faible) puis UOP_LIHI (poids fort, sommet modifié).
   --   sommet := val << 32  or  (sommet and 0xFFFF_FFFF)
   constant UOP_LIHI            : opcode_t := x"C7";                    -- réservé : b11_00_0_1_11
   -- Opcode réservé rencontré dans le code : faute 137 au retrait ; val = opcode d'origine.
   constant UOP_ILLEGAL         : opcode_t := x"EC";                    -- réservé : b11_10_11_00
   -- Lecture d'instruction en faute : faute 132 au retrait.
   constant UOP_FETCH_FAULT     : opcode_t := x"ED";                    -- réservé : b11_10_11_01

   --------------------------------------------------------------------
   -- Arithmétique flottante (section « Arithmétique flottante ») : tout résultat NaN de FADD,
   -- FSUB, FMUL, FDIV et FEXP est ce NaN canonique.
   --------------------------------------------------------------------

   constant CANONICAL_NAN       : word64_t := x"7FF8000000000000";

   --------------------------------------------------------------------
   -- Codes de déroutement (section « Fautes, déroutements et interruptions »)
   --------------------------------------------------------------------

   subtype trap_code_t          is unsigned( 7 downto 0 );              -- 0..255, vecteur M64[VTB + 8*n]

   -- services TRAP exécutés par la machine, jamais vectorisés
   constant SVC_EXIT            : trap_code_t := to_unsigned(   0, 8 );
   constant SVC_CTX_SAVE        : trap_code_t := to_unsigned(  16, 8 );
   constant SVC_CTX_RESTORE     : trap_code_t := to_unsigned(  17, 8 );
   constant SVC_SET_IMASK       : trap_code_t := to_unsigned(  18, 8 );

   -- interruptions externes : 32..63
   constant IRQ_FIRST           : natural := 32;
   constant IRQ_COUNT           : natural := 32;
   subtype irq_mask_t           is std_logic_vector( IRQ_COUNT - 1 downto 0 );  -- IMASK, bit i : code 32+i masqué
   subtype irq_vector_t         is std_logic_vector( IRQ_COUNT - 1 downto 0 );  -- requêtes pendantes, bit i : code 32+i

   -- fautes
   constant FAULT_DIV_ZERO      : trap_code_t := to_unsigned( 128, 8 ); -- NUMERIC_ERROR
   constant FAULT_OVERFLOW      : trap_code_t := to_unsigned( 129, 8 ); -- NUMERIC_ERROR (DIV -2^63/-1, CVTIX, CVTXI)
   constant FAULT_FLOAT_CONV    : trap_code_t := to_unsigned( 130, 8 ); -- NUMERIC_ERROR (CVTFI, CVTFIR)
   constant FAULT_CHK           : trap_code_t := to_unsigned( 131, 8 ); -- CONSTRAINT_ERROR, vecteur = ce_raise_
   constant FAULT_ACCESS        : trap_code_t := to_unsigned( 132, 8 ); -- CONSTRAINT_ERROR, lecture d'instruction comprise
   constant FAULT_DSP_LIMIT     : trap_code_t := to_unsigned( 133, 8 ); -- STORAGE_ERROR
   constant FAULT_RSP_LIMIT     : trap_code_t := to_unsigned( 134, 8 ); -- STORAGE_ERROR
   constant FAULT_CSP_LIMIT     : trap_code_t := to_unsigned( 135, 8 ); -- STORAGE_ERROR
   constant FAULT_HEAP          : trap_code_t := to_unsigned( 136, 8 ); -- STORAGE_ERROR
   constant FAULT_UNDEFINED     : trap_code_t := to_unsigned( 137, 8 ); -- PROGRAM_ERROR

   --------------------------------------------------------------------
   -- État des déroutements (section « Fautes », §2)
   --------------------------------------------------------------------

   type limits_t                is record                               -- limites des piles et du tas
         lim_dsp        : address_t;
         lim_rsp        : address_t;
         lim_csp        : address_t;
         lim_hp         : address_t;
      end record;

   -- réserves au-delà des limites quand DR = 1 (valeurs provisoires de la spécification)
   constant RESERVE_DSP         : natural := 1024;                      -- octets
   constant RESERVE_RSP         : natural := 32 * 8;                    -- 32 adresses
   constant RESERVE_CSP         : natural := 1024;

   --------------------------------------------------------------------
   -- Causes d'arrêt de la machine (sortie HALT_CAUSE du sommet)
   --------------------------------------------------------------------

   subtype halt_cause_t         is unsigned( 2 downto 0 );
   constant HALT_NONE           : halt_cause_t := "000";                -- en marche
   constant HALT_REQUEST        : halt_cause_t := "001";                -- HALT_REQ_I (mise au point)
   constant HALT_EXIT           : halt_cause_t := "010";                -- TRAP 0 (EXIT) de vecteur nul
   constant HALT_DOUBLE_FAULT   : halt_cause_t := "011";                -- faute ou service vectorisé avec DR = 1
   constant HALT_NULL_VECTOR    : halt_cause_t := "100";                -- faute ou interruption de vecteur nul
   constant HALT_DELIVERY       : halt_cause_t := "101";                -- livraison impossible (VTB, FSCR,
                                                                        --  réserve de RSP, bloc de démarrage)

   --------------------------------------------------------------------
   -- Bloc de démarrage (spéc., « Plateforme TAHX ») : format du bloc de CTX_RESTORE, suivi de
   -- HP, LIM_HP, VTB, FSCR et IMASK. Déplacements en octets.
   --------------------------------------------------------------------

   constant BOOT_PC             : natural :=   0;
   constant BOOT_DSP            : natural :=   8;
   constant BOOT_RSP            : natural :=  16;
   constant BOOT_CFP            : natural :=  24;
   constant BOOT_CSP            : natural :=  32;
   constant BOOT_DR             : natural :=  40;
   constant BOOT_LIM_DSP        : natural :=  48;
   constant BOOT_LIM_RSP        : natural :=  56;
   constant BOOT_LIM_CSP        : natural :=  64;
   constant BOOT_DISPLAY        : natural :=  72;                       -- + 8*i, i = 0..14
   constant BOOT_HP             : natural := 192;
   constant BOOT_LIM_HP         : natural := 200;
   constant BOOT_VTB            : natural := 208;
   constant BOOT_FSCR           : natural := 216;
   constant BOOT_IMASK          : natural := 224;
   constant BOOT_BLOCK_BYTES    : natural := 232;

                                ----------
end package                     TAHX_1_ISA;
                                ----------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
