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
use work.TAHX_1_ISA_TABLE.all;
use work.FETCH_DECODE_TYPES.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.IN_ORDER_TYPES.all;

        --------------------------------------------------------------------------------
        -- STACK_UNIT, architecture RTL -- première étape du backend InO.
        --
        -- Une seule instruction est en vol. DECODE_QUEUE est dépilée quand STACK_UNIT
        -- prend l'instruction ; l'état architectural (DSP et cache de pile) n'est
        -- modifié qu'à sa terminaison sans faute.
        --
        -- Le cache de pile est indexé par l'adresse architecturale de la cellule :
        --      index = ( adresse / 8 ) mod STACK_CACHE_WORDS_G
        -- Chaque entrée garde son adresse complète. Une cellule poussée est sale ; une
        -- cellule absente nécessaire comme source est relue par MEM (FILL). Avant de
        -- remplacer une cellule sale encore vivante, elle est rangée par MEM (SPILL).
        --
        -- Cette architecture couvre les effets génériques non mémoire de ISA_TABLE et
        -- une pile de retours architecturale séparée : CALL/CALLI poussent pc+len,
        -- RTD lit/dépile RSP et RTD n décrémente DSP de n octets. Le RAS du frontal
        -- reste purement spéculatif ; cette pile est l'état architectural réel.
        --
        -- Les instructions mémoire simples sont admises. Pour les accès directs lvl=0..14,
        -- les cellules sales recouvertes sont réécrites avant l'accès ; un rangement direct
        -- réussi invalide les copies cache recouvertes. LVA connu réécrit la cellule exposée.
        -- Les accès calculés suivent les invariants V8 des cellules de calcul et n'ont pas à
        -- sonder le cache. LINK/UNLINK et les opérations système sérialisantes restent à faire.
        --------------------------------------------------------------------------------

                                ---
architecture                    RTL
of STACK_UNIT is                ---

   type state_t is (
      ST_IDLE,
      ST_PREPARE,
      ST_SRC_SPILL_REQ,
      ST_SRC_SPILL_RSP,
      ST_SRC_FILL_REQ,
      ST_SRC_FILL_RSP,
      ST_DST_SPILL_REQ,
      ST_DST_SPILL_RSP,
      ST_RET_SPILL_REQ,
      ST_RET_SPILL_RSP,
      ST_RET_FILL_REQ,
      ST_RET_FILL_RSP,
      ST_COH_SCAN,
      ST_COH_SPILL_REQ,
      ST_COH_SPILL_RSP,
      ST_ISSUE,
      ST_WAIT_EXEC,
      ST_MISPRED_HOLD,
      ST_FAULT_HOLD,
      ST_MAINT_SCAN,
      ST_MAINT_SPILL_REQ,
      ST_MAINT_SPILL_RSP,
      ST_MAINT_RET_SCAN,
      ST_MAINT_RET_SPILL_REQ,
      ST_MAINT_RET_SPILL_RSP
   );

   type stack_cell_t is record
      valid  : std_logic;
      dirty  : std_logic;
      addr   : address_t;
      data   : word64_t;
   end record;

   type stack_cell_array_t is array( natural range <> ) of stack_cell_t;

   constant NO_CELL : stack_cell_t := (
      valid => '0', dirty => '0', addr => ( others => '0' ), data => ( others => '0' ) );

   subtype operand_index_t is natural range 0 to 4;
   type source_address_array_t is array( 0 to 3 ) of address_t;

   signal state_s              : state_t := ST_IDLE;
   signal frame_s              : frame_state_t;
   signal cells_s              : stack_cell_array_t( 0 to STACK_CACHE_WORDS_G - 1 );
   signal return_cells_s       : stack_cell_array_t( 0 to RETURN_CACHE_WORDS_G - 1 );

   signal slot_s               : decoded_slot_t;
   signal entry_s              : isa_entry_t := ISA_RESERVE;
   signal source_count_s       : stack_count_t := 0;
   signal source_index_s       : operand_index_t := 0;
   signal source_address_s     : source_address_array_t;
   signal source_value_s       : ino_operand_array_t;
   signal old_dsp_s            : address_t := ( others => '0' );
   signal new_dsp_s            : address_t := ( others => '0' );
   signal new_rsp_s            : address_t := ( others => '0' );
   signal return_target_s      : address_t := ( others => '0' );
   signal destination_valid_s  : std_logic := '0';
   signal destination_address_s: address_t := ( others => '0' );
   signal initial_fault_s      : fault_t := NO_FAULT;

   -- Transaction mémoire interne en cours (FILL/SPILL/maintenance).
   signal mem_address_s        : address_t := ( others => '0' );
   signal mem_data_s           : word64_t := ( others => '0' );
   signal mem_cell_index_s     : natural range 0 to STACK_CACHE_WORDS_G - 1 := 0;
   signal ret_mem_cell_index_s : natural range 0 to RETURN_CACHE_WORDS_G - 1 := 0;
   signal ret_after_spill_fill_s : std_logic := '0';

   -- Cohérence entre les accès directs du programme et le cache de pile data.
   -- Avant un accès direct lvl=0..14 (ou un LVA connu), toute cellule sale
   -- intersectée est réécrite. Après un rangement direct réussi, les copies
   -- cache intersectées sont invalidées : une lecture de pile les rechargera.
   signal coh_required_s        : std_logic := '0';
   signal coh_invalidate_s      : std_logic := '0';
   signal coh_base_s            : address_t := ( others => '0' );
   signal coh_length_s          : address_t := ( others => '0' );
   signal coh_index_s           : natural range 0 to 3 := 0;

   signal maint_s              : stack_maint_t;
   signal maint_index_s        : natural range 0 to STACK_CACHE_WORDS_G := 0;
   signal ret_maint_index_s    : natural range 0 to RETURN_CACHE_WORDS_G := 0;

   signal commit_s             : ino_commit_t;
   signal maint_done_s         : std_logic := '0';
   -- Une maintenance peut aussi être lancée après une faute précise. Dans ce cas,
   -- MAINT_DONE ne libère pas le backend : on revient attendre la SYNC d'exception.
   signal maint_return_fault_s : std_logic := '0';
   -- Maintenance lancée pendant ST_WAIT_EXEC (blocs complexes) :
   -- revenir attendre COMPLETE au lieu de libérer STACK_UNIT.
   signal maint_return_exec_s  : std_logic := '0';

   function U64( v : signed ) return address_t is
   begin
      return unsigned( std_logic_vector( resize( v, 64 ) ) );
   end function;

   function WIDX( a : address_t ) return natural is
   begin
      -- Même convention que le cache de pile du renommage OoO. Le générique est
      -- destiné à une puissance de deux ; garder l'adresse complète dans l'entrée
      -- protège dans tous les cas contre une fausse correspondance.
      return to_integer( a( 30 downto 3 ) ) mod STACK_CACHE_WORDS_G;
   end function;

   function RWIDX( a : address_t ) return natural is
   begin
      return to_integer( a( 30 downto 3 ) ) mod RETURN_CACHE_WORDS_G;
   end function;

   constant OP_LVA_B16 : opcode_t := x"47";
   constant OP_LVA_B24 : opcode_t := x"4B";
   constant OP_LINK16  : opcode_t := x"44";
   constant OP_LINK24  : opcode_t := x"48";
   constant OP_EXCM16  : opcode_t := x"45";
   constant OP_EXCM24  : opcode_t := x"49";

   function IS_LINK_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_LINK16 or op = OP_LINK24;
   end function;

   function IS_UNLINK_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_UNLINK or op = OP_UNLINKR;
   end function;

   function IS_EXCM_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_EXCM16 or op = OP_EXCM24;
   end function;

   function IS_CALL_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_CALL or op = x"33";      -- CALL, CALLI
   end function;

   function IS_RTD_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_RTD_N or op = OP_RTD_0;
   end function;

   function IN_RANGE( a : address_t; base : address_t; length : address_t ) return boolean is
   begin
      if length = 0 then
         return false;
      end if;
      -- Une cellule de 8 octets intersecte [base, base + length).
      return a + 8 > base and a < base + length;
   end function;

   function IS_SYSTEM_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_TRAP or op = OP_EXC_RAISE or op = OP_RTX;
   end function;

   function IS_SPECIAL_NOT_YET_SUPPORTED( s : decoded_slot_t; e : isa_entry_t ) return boolean is
      variable op : opcode_t;
   begin
      op := s.canon.op;
      return e.frame and not IS_LINK_OP( op ) and not IS_UNLINK_OP( op ) and not IS_EXCM_OP( op );
   end function;

   function MISPREDICTED( s : decoded_slot_t; c : ino_complete_t ) return boolean is
   begin
      if s.pred.taken /= c.taken then
         return true;
      elsif c.taken = '1' and s.pred.target /= c.target then
         return true;
      else
         return false;
      end if;
   end function;

   procedure INVALIDATE_CELL(
      signal c : inout stack_cell_array_t;
      constant a : in address_t ) is
      variable i : natural;
   begin
      i := WIDX( a );
      if c( i ).valid = '1' and c( i ).addr = a then
         c( i ).valid <= '0';
         c( i ).dirty <= '0';
      end if;
   end procedure;

begin

   FRAME_o      <= frame_s;
   COMMIT_o     <= commit_s;
   MAINT_DONE_o <= maint_done_s;

   IDLE_o <= '1' when state_s = ST_IDLE or state_s = ST_FAULT_HOLD else '0';

        --------------------------------------------------------------------------------
        -- Sorties combinatoires : prise de DECODE_QUEUE, émission et port mémoire.
        --------------------------------------------------------------------------------

   OUTPUTS : process( all )
      variable issue_v : ino_issue_t;
      variable mem_v   : mem_request_t;
   begin
      DECODE_TAKE_o <= ( others => '0' );

      issue_v.slot          := ( valid => '0', canon => CANON_NOP,
                                 pc => ( others => '0' ), pred => NO_PREDICTION );
      issue_v.issue_class   := ISSUE_NONE;
      issue_v.operand_count := 0;
      issue_v.operand       := ( others => ( others => '0' ) );
      issue_v.address_known := '0';
      issue_v.address       := ( others => '0' );
      ISSUE_o               <= issue_v;
      ISSUE_VALID_o         <= '0';

      mem_v := NO_MEM_REQUEST;

      -- Une instruction est retirée de DECODE_QUEUE dès qu'elle devient l'unique
      -- instruction interne de STACK_UNIT. Les FILL éventuels sont ensuite privés.
      if state_s = ST_IDLE and RESET_i = '0' and SYNC_VALID_i = '0'
         and MAINT_i.valid = '0' and DECODE_COUNT_i /= 0 and DECODE_BLOCK_i( 0 ).valid = '1' then
         DECODE_TAKE_o <= to_unsigned( 1, DECODE_TAKE_o'length );
      end if;

      if state_s = ST_ISSUE then
         issue_v.slot          := slot_s;
         issue_v.issue_class   := entry_s.issue_class;
         issue_v.operand_count := source_count_s;
         issue_v.operand       := source_value_s;

         if IS_RTD_OP( slot_s.canon.op ) then
            -- La cible de RTD vient de la pile de retours architecturale, pas de la
            -- pile data. Elle a été obtenue (cache ou FILL) avant ST_ISSUE.
            issue_v.address_known := '1';
            issue_v.address       := return_target_s;
         elsif ( entry_s.lvl_use = LVL_ADDR or entry_s.lvl_use = LVL_FRAME )
            and to_integer( slot_s.canon.lvl ) <= 14 then
            issue_v.address_known := '1';
            issue_v.address := frame_s.display( to_integer( slot_s.canon.lvl ) ) + U64( slot_s.canon.val );
         end if;

         ISSUE_o       <= issue_v;
         ISSUE_VALID_o <= '1';
      end if;

      case state_s is
         when ST_SRC_SPILL_REQ | ST_DST_SPILL_REQ | ST_RET_SPILL_REQ |
              ST_COH_SPILL_REQ | ST_MAINT_SPILL_REQ | ST_MAINT_RET_SPILL_REQ =>
            mem_v.valid   := '1';
            mem_v.write   := '1';
            mem_v.probe   := '0';
            mem_v.address := mem_address_s;
            mem_v.size    := "11";
            mem_v.wdata   := mem_data_s;

         when ST_SRC_FILL_REQ | ST_RET_FILL_REQ =>
            mem_v.valid   := '1';
            mem_v.write   := '0';
            mem_v.probe   := '0';
            mem_v.address := mem_address_s;
            mem_v.size    := "11";
            mem_v.wdata   := ( others => '0' );

         when others =>
            null;
      end case;

      MEM_REQ_o <= mem_v;
   end process OUTPUTS;

        --------------------------------------------------------------------------------
        -- État séquentiel.
        --------------------------------------------------------------------------------

   SEQUENTIAL : process( CLK_i )
      variable s               : decoded_slot_t;
      variable e               : isa_entry_t;
      variable npop            : natural range 0 to 4;
      variable nsrc            : natural range 0 to 4;
      variable ndsp            : address_t;
      variable nrsp            : address_t;
      variable a               : address_t;
      variable idx             : natural;
      variable dst_idx         : natural;
      variable ridx            : natural;
      variable f               : fault_t;
      variable live_collision  : boolean;
      variable lvl             : natural range 0 to 15;
      variable alloc65         : unsigned( 64 downto 0 );
      variable ndsp65          : unsigned( 64 downto 0 );
   begin
      if rising_edge( CLK_i ) then

         -- Impulsions par défaut.
         commit_s.valid     <= '0';
         maint_done_s       <= '0';

         if RESET_i = '1' then
            state_s          <= ST_IDLE;
            frame_s.dsp      <= ( others => '0' );
            frame_s.rsp      <= ( others => '0' );
            frame_s.display  <= ( others => ( others => '0' ) );
            cells_s          <= ( others => NO_CELL );
            return_cells_s   <= ( others => NO_CELL );
            source_index_s   <= 0;
            source_count_s   <= 0;
            source_value_s   <= ( others => ( others => '0' ) );
            initial_fault_s  <= NO_FAULT;
            ret_after_spill_fill_s <= '0';
            return_target_s   <= ( others => '0' );
            coh_required_s    <= '0';
            coh_invalidate_s  <= '0';
            coh_base_s        <= ( others => '0' );
            coh_length_s      <= ( others => '0' );
            coh_index_s       <= 0;
            maint_return_fault_s <= '0';
            maint_return_exec_s  <= '0';
            commit_s         <= ( valid => '0', slot => ( valid => '0', canon => CANON_NOP,
                                  pc => ( others => '0' ), pred => NO_PREDICTION ),
                                  fault => NO_FAULT, taken => '0', target => ( others => '0' ) );

         elsif SYNC_VALID_i = '1' then
            -- Contrat : la maintenance requise a été terminée auparavant et aucune
            -- instruction n'est en vol. Une SYNC invalide donc simplement le cache.
            -- pragma translate_off
            assert state_s = ST_IDLE or state_s = ST_FAULT_HOLD
               report "STACK_UNIT: SYNC pendant une instruction ou une maintenance"
               severity failure;
            -- pragma translate_on
            frame_s         <= SYNC_FRAME_i;
            cells_s         <= ( others => NO_CELL );
            return_cells_s  <= ( others => NO_CELL );
            state_s         <= ST_IDLE;
            source_index_s  <= 0;
            source_count_s  <= 0;
            coh_required_s   <= '0';
            coh_invalidate_s <= '0';
            coh_index_s      <= 0;
            maint_return_fault_s <= '0';
            maint_return_exec_s  <= '0';

         else
            case state_s is

               -------------------------------------------------------------------------
               -- Prise d'une instruction ou d'une maintenance.
               -------------------------------------------------------------------------

               when ST_IDLE =>
                  if MAINT_i.valid = '1' then
                     maint_s              <= MAINT_i;
                     maint_index_s        <= 0;
                     ret_maint_index_s    <= 0;
                     maint_return_fault_s <= '0';
                     maint_return_exec_s  <= '0';
                     state_s              <= ST_MAINT_SCAN;

                  elsif DECODE_COUNT_i /= 0 and DECODE_BLOCK_i( 0 ).valid = '1' then
                     s := DECODE_BLOCK_i( 0 );
                     e := ISA_TABLE( to_integer( unsigned( s.canon.op ) ) );
                     if s.canon.op = UOP_LIHI then
                        e := ( true, 9, FMT_NONE, ISSUE_INTEGER, 1, 1, STACK_LINEAR,
                               LVL_NONE, false, false, false, false );
                     elsif s.canon.op = OP_TRAP then
                        -- Les services système ont un effet de pile dynamique qui n'est
                        -- pas encodé dans ISA_TABLE :
                        --   0 EXIT et 17 CTX_RESTORE lisent le sommet sans le dépiler ;
                        --   16 CTX_SAVE et 18 SET_IMASK font ( x -- r ) ;
                        --   les autres services n'ont pas d'effet propre sur la pile.
                        case to_integer( s.canon.val ) is
                           when 0 | 17 =>
                              e.pops := 1; e.pushes := 1; e.stack_action := STACK_KEEP_TOP;
                           when 16 | 18 =>
                              e.pops := 1; e.pushes := 1; e.stack_action := STACK_LINEAR;
                           when others =>
                              e.pops := 0; e.pushes := 0; e.stack_action := STACK_LINEAR;
                        end case;
                     end if;

                     f := NO_FAULT;
                     if s.canon.op = UOP_FETCH_FAULT then
                        f := ( valid => '1', code => FAULT_ACCESS );
                     elsif s.canon.op = UOP_ILLEGAL or not e.defined then
                        f := ( valid => '1', code => FAULT_UNDEFINED );
                     elsif e.lvl_use = LVL_FRAME and s.canon.lvl = LEVEL_STACK then
                        f := ( valid => '1', code => FAULT_UNDEFINED );
                     end if;

                     npop := e.pops;
                     if e.lvl_use = LVL_ADDR and s.canon.lvl = LEVEL_STACK then
                        npop := npop + 1;
                     end if;

                     ndsp := frame_s.dsp;
                     lvl := to_integer( s.canon.lvl );
                     case e.stack_action is
                        when STACK_LINEAR =>
                           if npop > e.pushes then
                              ndsp := frame_s.dsp - 8 * ( npop - e.pushes );
                           elsif e.pushes > npop then
                              ndsp := frame_s.dsp + 8 * ( e.pushes - npop );
                           end if;
                        when STACK_DROP =>
                           ndsp := frame_s.dsp - 8;
                        when STACK_DUP | STACK_OVER =>
                           ndsp := frame_s.dsp + 8;
                        when STACK_KEEP_TOP =>
                           null;
                     end case;

                     -- Effet de frame, non décrit par pops/pushes dans ISA_TABLE.
                     -- LINK lvl>0 pousse l'ancien DISPLAY[lvl], puis réserve alloc octets ;
                     -- lvl=0 ne pousse rien. UNLINK/UNLINKR reviennent à DISPLAY[lvl],
                     -- dépilent le FP sauvé et laissent DSP juste en dessous.
                     if IS_LINK_OP( s.canon.op ) then
                        alloc65 := resize( unsigned( std_logic_vector( s.canon.val ) ), 65 ) + 7;
                        alloc65( 2 downto 0 ) := "000";
                        ndsp65 := resize( frame_s.dsp, 65 ) + alloc65;
                        if lvl > 0 then
                           ndsp65 := ndsp65 + 8;
                        end if;
                        ndsp := ndsp65( 63 downto 0 );
                        if ndsp65( 64 ) = '1' then
                           f := ( valid => '1', code => FAULT_DSP_LIMIT );
                        end if;
                     elsif IS_UNLINK_OP( s.canon.op ) then
                        ndsp := frame_s.display( lvl ) - 8;
                     elsif IS_RTD_OP( s.canon.op ) then
                        -- RTD n : n est un nombre d'octets à abandonner.
                        ndsp := frame_s.dsp - U64( s.canon.val );
                     end if;

                     nrsp := frame_s.rsp;
                     if IS_CALL_OP( s.canon.op ) then
                        nrsp := frame_s.rsp - 8;
                     end if;

                     if f.valid = '0' and ndsp > LIMITS_i.lim_dsp and ndsp > frame_s.dsp then
                        f := ( valid => '1', code => FAULT_DSP_LIMIT );
                     elsif f.valid = '0' and nrsp < LIMITS_i.lim_rsp and nrsp < frame_s.rsp then
                        f := ( valid => '1', code => FAULT_RSP_LIMIT );
                     end if;

                     slot_s              <= s;
                     entry_s             <= e;
                     old_dsp_s           <= frame_s.dsp;
                     new_dsp_s           <= ndsp;
                     new_rsp_s           <= nrsp;
                     return_target_s     <= ( others => '0' );
                     ret_after_spill_fill_s <= '0';
                     initial_fault_s     <= f;
                     source_index_s      <= 0;
                     source_value_s      <= ( others => ( others => '0' ) );
                     destination_valid_s <= '0';

                     -- Cohérence du cache de pile pour les accès visibles en mémoire.
                     -- Les accès calculés n'ont pas à sonder le cache : V8 impose qu'une
                     -- cellule de calcul lue par adresse calculée ait été exposée auparavant
                     -- par un LVA connu, et interdit de l'écrire par un accès calculé.
                     coh_required_s   <= '0';
                     coh_invalidate_s <= '0';
                     coh_base_s       <= ( others => '0' );
                     coh_length_s     <= ( others => '0' );
                     coh_index_s      <= 0;

                     if ( s.canon.op = OP_LVA_B16 or s.canon.op = OP_LVA_B24 )
                        and to_integer( s.canon.lvl ) <= 14 then
                        -- LVA expose la cellule qui contient l'adresse rendue : une
                        -- implantation à écriture différée doit la rendre propre.
                        a := frame_s.display( to_integer( s.canon.lvl ) ) + U64( s.canon.val );
                        coh_required_s <= '1';
                        coh_base_s     <= a( 63 downto 3 ) & "000";
                        coh_length_s   <= to_unsigned( 8, 64 );

                     elsif e.memory and not e.frame and not IS_SYSTEM_OP( s.canon.op )
                        and to_integer( s.canon.lvl ) <= 14 then
                        -- LINK/UNLINK portent memory=true parce que COMPLEX_UNIT accède
                        -- à la co-pile. Ce ne sont pas des accès mémoire adressés par
                        -- lvl/val dans la pile data : ne pas déclencher ici la cohérence
                        -- générique du cache de pile.
                        a := frame_s.display( to_integer( s.canon.lvl ) ) + U64( s.canon.val );
                        coh_required_s <= '1';
                        coh_base_s     <= a;

                        if s.canon.op( 7 downto 6 ) = "10" then
                           -- Famille C : avant toute chose l'unité mémoire lit la
                           -- cellule pointeur M64[a].
                           coh_length_s <= to_unsigned( 8, 64 );
                        elsif s.canon.op( 3 downto 2 ) = "11"
                           and ( s.canon.op( 5 downto 4 ) = "01"
                                 or s.canon.op( 5 downto 4 ) = "11" ) then
                           -- CHK direct : deux bornes contiguës de même taille.
                           coh_length_s <= to_unsigned(
                              2 * ( 2 ** to_integer( unsigned( s.canon.op( 1 downto 0 ) ) ) ), 64 );
                        else
                           coh_length_s <= to_unsigned(
                              2 ** to_integer( unsigned( s.canon.op( 1 downto 0 ) ) ), 64 );
                           if s.canon.op( 5 downto 4 ) = "10" then
                              coh_invalidate_s <= '1';
                           end if;
                        end if;
                     end if;

                     -- Sources dans l'ordre de la notation de pile : la plus profonde
                     -- d'abord, comme dans RENAME_DISPATCH. Les opérations de frame ont
                     -- leur propre convention.
                     nsrc := 0;
                     source_address_s <= ( others => ( others => '0' ) );
                     if IS_LINK_OP( s.canon.op ) then
                        if lvl > 0 then
                           -- Réserver la cellule qui sauvera l'ancien DISPLAY[lvl].
                           destination_valid_s   <= '1';
                           destination_address_s <= frame_s.dsp + 8;
                        end if;
                     elsif IS_UNLINK_OP( s.canon.op ) then
                        -- FP sauvegardé par LINK, restauré au commit si la lecture de co-pile réussit.
                        nsrc := 1;
                        source_address_s( 0 ) <= frame_s.display( lvl );
                     else
                        case e.stack_action is
                           when STACK_LINEAR =>
                              nsrc := npop;
                              for j in 0 to 3 loop
                                 if j < npop then
                                    source_address_s( j ) <= frame_s.dsp - 8 * ( npop - 1 - j );
                                 end if;
                              end loop;
                              if e.pushes = 1 then
                                 destination_valid_s   <= '1';
                                 destination_address_s <= ndsp;
                              end if;

                           when STACK_KEEP_TOP =>
                              nsrc := 1;
                              source_address_s( 0 ) <= frame_s.dsp;

                           when STACK_DUP =>
                              nsrc := 1;
                              source_address_s( 0 ) <= frame_s.dsp;
                              destination_valid_s   <= '1';
                              destination_address_s <= ndsp;

                           when STACK_OVER =>
                              nsrc := 1;
                              source_address_s( 0 ) <= frame_s.dsp - 8;
                              destination_valid_s   <= '1';
                              destination_address_s <= ndsp;

                           when STACK_DROP =>
                              nsrc := 0;
                        end case;
                     end if;
                     source_count_s <= nsrc;

                     -- pragma translate_off
                     assert not IS_SPECIAL_NOT_YET_SUPPORTED( s, e )
                        report "STACK_UNIT: instruction speciale non encore implementee"
                        severity failure;
                     -- pragma translate_on

                     state_s <= ST_PREPARE;
                  end if;

               -------------------------------------------------------------------------
               -- Obtenir toutes les sources dans le cache puis réserver la future
               -- cellule destination. Aucun changement architectural n'a encore lieu.
               -------------------------------------------------------------------------

               when ST_PREPARE =>
                  if initial_fault_s.valid = '1' then
                     commit_s <= ( valid => '1', slot => slot_s, fault => initial_fault_s,
                                   taken => '0', target => ( others => '0' ) );
                     state_s <= ST_FAULT_HOLD;

                  elsif source_index_s < source_count_s then
                     a   := source_address_s( source_index_s );
                     idx := WIDX( a );
                     if cells_s( idx ).valid = '1' and cells_s( idx ).addr = a then
                        source_value_s( source_index_s ) <= cells_s( idx ).data;
                        source_index_s <= source_index_s + 1;
                     else
                        -- Avant de prendre l'entrée, sauver son occupant sale s'il est
                        -- encore une cellule vivante de la pile architecturale.
                        live_collision := cells_s( idx ).valid = '1'
                                          and cells_s( idx ).dirty = '1'
                                          and cells_s( idx ).addr <= old_dsp_s;
                        mem_cell_index_s <= idx;
                        if live_collision then
                           mem_address_s <= cells_s( idx ).addr;
                           mem_data_s    <= cells_s( idx ).data;
                           state_s       <= ST_SRC_SPILL_REQ;
                        else
                           mem_address_s <= a;
                           state_s       <= ST_SRC_FILL_REQ;
                        end if;
                     end if;

                  elsif destination_valid_s = '1' then
                     dst_idx := WIDX( destination_address_s );
                     if cells_s( dst_idx ).valid = '1'
                        and cells_s( dst_idx ).addr /= destination_address_s
                        and cells_s( dst_idx ).dirty = '1'
                        and cells_s( dst_idx ).addr <= old_dsp_s then
                        mem_cell_index_s <= dst_idx;
                        mem_address_s    <= cells_s( dst_idx ).addr;
                        mem_data_s       <= cells_s( dst_idx ).data;
                        state_s          <= ST_DST_SPILL_REQ;
                     else
                        -- L'entrée pourra être remplacée au commit.
                        if entry_s.issue_class = ISSUE_NONE then
                           case entry_s.stack_action is
                              when STACK_DROP =>
                                 INVALIDATE_CELL( cells_s, old_dsp_s );
                                 frame_s.dsp <= new_dsp_s;

                              when STACK_DUP | STACK_OVER =>
                                 idx := WIDX( destination_address_s );
                                 cells_s( idx ) <= ( valid => '1', dirty => '1',
                                                     addr => destination_address_s,
                                                     data => source_value_s( 0 ) );
                                 frame_s.dsp <= new_dsp_s;

                              when others =>
                                 null;
                           end case;
                           commit_s <= ( valid => '1', slot => slot_s, fault => NO_FAULT,
                                         taken => '0', target => ( others => '0' ) );
                           state_s <= ST_IDLE;
                        else
                           if coh_required_s = '1' then
                              coh_index_s <= 0;
                              state_s <= ST_COH_SCAN;
                           else
                              state_s <= ST_ISSUE;
                           end if;
                        end if;
                     end if;

                  else
                     -- Pile de retours séparée. CALL/CALLI réservent la cellule du
                     -- futur RSP ; RTD obtient la cible au RSP courant. Une collision
                     -- sale est rangée avant remplacement.
                     if IS_CALL_OP( slot_s.canon.op ) then
                        ridx := RWIDX( new_rsp_s );
                        if return_cells_s( ridx ).valid = '1'
                           and return_cells_s( ridx ).addr /= new_rsp_s
                           and return_cells_s( ridx ).dirty = '1' then
                           ret_mem_cell_index_s   <= ridx;
                           mem_address_s          <= return_cells_s( ridx ).addr;
                           mem_data_s             <= return_cells_s( ridx ).data;
                           ret_after_spill_fill_s <= '0';
                           state_s                <= ST_RET_SPILL_REQ;
                        else
                           if coh_required_s = '1' then
                              coh_index_s <= 0;
                              state_s <= ST_COH_SCAN;
                           else
                              state_s <= ST_ISSUE;
                           end if;
                        end if;

                     elsif IS_RTD_OP( slot_s.canon.op ) then
                        ridx := RWIDX( frame_s.rsp );
                        if return_cells_s( ridx ).valid = '1'
                           and return_cells_s( ridx ).addr = frame_s.rsp then
                           return_target_s <= unsigned( return_cells_s( ridx ).data );
                           if coh_required_s = '1' then
                              coh_index_s <= 0;
                              state_s <= ST_COH_SCAN;
                           else
                              state_s <= ST_ISSUE;
                           end if;
                        elsif return_cells_s( ridx ).valid = '1'
                           and return_cells_s( ridx ).dirty = '1' then
                           ret_mem_cell_index_s   <= ridx;
                           mem_address_s          <= return_cells_s( ridx ).addr;
                           mem_data_s             <= return_cells_s( ridx ).data;
                           ret_after_spill_fill_s <= '1';
                           state_s                <= ST_RET_SPILL_REQ;
                        else
                           ret_mem_cell_index_s   <= ridx;
                           mem_address_s          <= frame_s.rsp;
                           state_s                <= ST_RET_FILL_REQ;
                        end if;

                     elsif entry_s.issue_class = ISSUE_NONE then
                        case entry_s.stack_action is
                           when STACK_DROP =>
                              INVALIDATE_CELL( cells_s, old_dsp_s );
                              frame_s.dsp <= new_dsp_s;
                           when others =>
                              null;
                        end case;
                        commit_s <= ( valid => '1', slot => slot_s, fault => NO_FAULT,
                                      taken => '0', target => ( others => '0' ) );
                        state_s <= ST_IDLE;
                     else
                        if coh_required_s = '1' then
                              coh_index_s <= 0;
                              state_s <= ST_COH_SCAN;
                           else
                              state_s <= ST_ISSUE;
                           end if;
                     end if;
                  end if;

               -------------------------------------------------------------------------
               -- SPILL d'une entrée qui doit être remplacée pour charger une source.
               -------------------------------------------------------------------------

               when ST_SRC_SPILL_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_SRC_SPILL_RSP;
                  end if;

               when ST_SRC_SPILL_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        commit_s <= ( valid => '1', slot => slot_s,
                                      fault => ( valid => '1', code => FAULT_ACCESS ),
                                      taken => '0', target => ( others => '0' ) );
                        state_s <= ST_FAULT_HOLD;
                     else
                        cells_s( mem_cell_index_s ).valid <= '0';
                        cells_s( mem_cell_index_s ).dirty <= '0';
                        mem_address_s <= source_address_s( source_index_s );
                        state_s <= ST_SRC_FILL_REQ;
                     end if;
                  end if;

               when ST_SRC_FILL_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_SRC_FILL_RSP;
                  end if;

               when ST_SRC_FILL_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        commit_s <= ( valid => '1', slot => slot_s,
                                      fault => ( valid => '1', code => FAULT_ACCESS ),
                                      taken => '0', target => ( others => '0' ) );
                        state_s <= ST_FAULT_HOLD;
                     else
                        idx := WIDX( source_address_s( source_index_s ) );
                        cells_s( idx ) <= ( valid => '1', dirty => '0',
                                            addr => source_address_s( source_index_s ),
                                            data => MEM_RSP_i.rdata );
                        source_value_s( source_index_s ) <= MEM_RSP_i.rdata;
                        source_index_s <= source_index_s + 1;
                        state_s <= ST_PREPARE;
                     end if;
                  end if;

               -------------------------------------------------------------------------
               -- SPILL nécessaire avant la future destination.
               -------------------------------------------------------------------------

               when ST_DST_SPILL_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_DST_SPILL_RSP;
                  end if;

               when ST_DST_SPILL_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        commit_s <= ( valid => '1', slot => slot_s,
                                      fault => ( valid => '1', code => FAULT_ACCESS ),
                                      taken => '0', target => ( others => '0' ) );
                        state_s <= ST_FAULT_HOLD;
                     else
                        cells_s( mem_cell_index_s ).valid <= '0';
                        cells_s( mem_cell_index_s ).dirty <= '0';
                        state_s <= ST_PREPARE;
                     end if;
                  end if;

               -------------------------------------------------------------------------
               -- Pile des retours : collision à ranger / cible RTD à relire.
               -------------------------------------------------------------------------

               when ST_RET_SPILL_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_RET_SPILL_RSP;
                  end if;

               when ST_RET_SPILL_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        commit_s <= ( valid => '1', slot => slot_s,
                                      fault => ( valid => '1', code => FAULT_ACCESS ),
                                      taken => '0', target => ( others => '0' ) );
                        state_s <= ST_FAULT_HOLD;
                     else
                        return_cells_s( ret_mem_cell_index_s ).valid <= '0';
                        return_cells_s( ret_mem_cell_index_s ).dirty <= '0';
                        if ret_after_spill_fill_s = '1' then
                           mem_address_s <= frame_s.rsp;
                           state_s <= ST_RET_FILL_REQ;
                        else
                           state_s <= ST_PREPARE;
                        end if;
                     end if;
                  end if;

               when ST_RET_FILL_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_RET_FILL_RSP;
                  end if;

               when ST_RET_FILL_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        commit_s <= ( valid => '1', slot => slot_s,
                                      fault => ( valid => '1', code => FAULT_ACCESS ),
                                      taken => '0', target => ( others => '0' ) );
                        state_s <= ST_FAULT_HOLD;
                     else
                        ridx := RWIDX( frame_s.rsp );
                        return_cells_s( ridx ) <=
                           ( valid => '1', dirty => '0', addr => frame_s.rsp,
                             data => MEM_RSP_i.rdata );
                        return_target_s <= unsigned( MEM_RSP_i.rdata );
                        state_s <= ST_PREPARE;
                     end if;
                  end if;

               -------------------------------------------------------------------------
               -- Cohérence d'un accès direct / LVA avec le cache de pile data.
               -- Une plage d'instruction ne couvre au plus que 16 octets ; avec un
               -- départ non aligné, trois cellules de 8 octets suffisent donc.
               -------------------------------------------------------------------------

               when ST_COH_SCAN =>
                  a := ( coh_base_s( 63 downto 3 ) & "000" ) + to_unsigned( 8 * coh_index_s, 64 );
                  if coh_required_s = '0' or coh_index_s = 3
                     or a >= coh_base_s + coh_length_s then
                     state_s <= ST_ISSUE;
                  else
                     idx := WIDX( a );
                     if cells_s( idx ).valid = '1'
                        and cells_s( idx ).addr = a
                        and cells_s( idx ).dirty = '1'
                        and cells_s( idx ).addr <= old_dsp_s then
                        mem_cell_index_s <= idx;
                        mem_address_s    <= a;
                        mem_data_s       <= cells_s( idx ).data;
                        state_s          <= ST_COH_SPILL_REQ;
                     else
                        coh_index_s <= coh_index_s + 1;
                     end if;
                  end if;

               when ST_COH_SPILL_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_COH_SPILL_RSP;
                  end if;

               when ST_COH_SPILL_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        commit_s <= ( valid => '1', slot => slot_s,
                                      fault => ( valid => '1', code => FAULT_ACCESS ),
                                      taken => '0', target => ( others => '0' ) );
                        state_s <= ST_FAULT_HOLD;
                     else
                        -- La cellule reste valide : sa copie mémoire est désormais
                        -- conforme à la valeur architecturale tenue dans le cache.
                        cells_s( mem_cell_index_s ).dirty <= '0';
                        coh_index_s <= coh_index_s + 1;
                        state_s <= ST_COH_SCAN;
                     end if;
                  end if;

               -------------------------------------------------------------------------
               -- Exécution. L'état architectural reste inchangé jusqu'à COMPLETE.
               -------------------------------------------------------------------------

               when ST_ISSUE =>
                  if ISSUE_READY_i = '1' then
                     state_s <= ST_WAIT_EXEC;
                  end if;

               when ST_WAIT_EXEC =>
                  -- Les opérations de bloc peuvent demander une maintenance du cache
                  -- pendant leur exécution. La requête MAINT_i est une impulsion ; le
                  -- backend attend MAINT_DONE_o avant de poursuivre ses accès mémoire.
                  if MAINT_i.valid = '1' then
                     maint_s              <= MAINT_i;
                     maint_index_s        <= 0;
                     ret_maint_index_s    <= 0;
                     maint_return_fault_s <= '0';
                     maint_return_exec_s  <= '1';
                     state_s              <= ST_MAINT_SCAN;

                  elsif COMPLETE_i.valid = '1' then
                     if COMPLETE_i.fault.valid = '1' then
                        commit_s <= ( valid => '1', slot => slot_s, fault => COMPLETE_i.fault,
                                      taken => COMPLETE_i.taken, target => COMPLETE_i.target );
                        state_s <= ST_FAULT_HOLD;
                     else
                        -- Un rangement direct lvl=0..14 est le seul accès mémoire du
                        -- programme autorisé à modifier une cellule de calcul. La mémoire
                        -- vient d'être écrite avec succès : oublier toute copie cache qui
                        -- intersecte les octets rangés, afin qu'une utilisation ultérieure
                        -- recharge la nouvelle valeur.
                        if coh_invalidate_s = '1' then
                           for k in 0 to 2 loop
                              a := ( coh_base_s( 63 downto 3 ) & "000" ) + to_unsigned( 8 * k, 64 );
                              if a < coh_base_s + coh_length_s then
                                 INVALIDATE_CELL( cells_s, a );
                              end if;
                           end loop;
                        end if;

                        -- LINK/UNLINK/UNLINKR modifient DSP/DISPLAY de façon non linéaire.
                        -- L'effet de co-pile a déjà été rendu atomiquement par COMPLEX_UNIT ;
                        -- l'état de frame ne devient visible qu'ici, après succès complet.
                        if IS_LINK_OP( slot_s.canon.op ) then
                           lvl := to_integer( slot_s.canon.lvl );
                           -- Les anciennes correspondances de la zone locale nouvellement allouée
                           -- ne sont plus valides. La cellule du FP sauvegardé est réinstallée ensuite.
                           for j in 0 to STACK_CACHE_WORDS_G - 1 loop
                              if cells_s( j ).valid = '1'
                                 and cells_s( j ).addr > old_dsp_s
                                 and cells_s( j ).addr <= new_dsp_s
                                 -- Pour LINK lvl>0, old_dsp+8 est précisément la cellule
                                 -- dans laquelle on installe juste après l'ancien DISPLAY[lvl].
                                 -- Ne pas programmer simultanément son invalidation et son
                                 -- remplacement : avec un index de tableau dynamique, ces
                                 -- affectations partielles concurrentes peuvent laisser la
                                 -- cellule invalidée après le delta-cycle.
                                 and not ( lvl > 0 and cells_s( j ).addr = old_dsp_s + 8 ) then
                                 cells_s( j ).valid <= '0';
                                 cells_s( j ).dirty <= '0';
                              end if;
                           end loop;
                           if lvl > 0 then
                              a := old_dsp_s + 8;
                              idx := WIDX( a );
                              cells_s( idx ) <= ( valid => '1', dirty => '1', addr => a,
                                                  data => std_logic_vector( frame_s.display( lvl ) ) );
                              frame_s.display( lvl ) <= a;
                           end if;
                           frame_s.dsp <= new_dsp_s;

                        elsif IS_UNLINK_OP( slot_s.canon.op ) then
                           lvl := to_integer( slot_s.canon.lvl );
                           -- Tout le frame courant devient mort, cellule du FP sauvé comprise.
                           for j in 0 to STACK_CACHE_WORDS_G - 1 loop
                              if cells_s( j ).valid = '1'
                                 and cells_s( j ).addr > new_dsp_s
                                 and cells_s( j ).addr <= old_dsp_s then
                                 cells_s( j ).valid <= '0';
                                 cells_s( j ).dirty <= '0';
                              end if;
                           end loop;
                           frame_s.dsp <= new_dsp_s;
                           frame_s.display( lvl ) <= unsigned( source_value_s( 0 ) );

                        -- CALL/CALLI et RTD ont un effet architectural supplémentaire
                        -- sur RSP et sur la pile de retours. Rien n'a été modifié avant
                        -- cette terminaison sans faute.
                        elsif IS_CALL_OP( slot_s.canon.op ) then
                           -- CALLI dépile sa cible de la pile data ; CALL direct n'y
                           -- touche pas. L'adresse de retour est le PC suivant.
                           for j in 0 to 3 loop
                              if j < source_count_s then
                                 INVALIDATE_CELL( cells_s, source_address_s( j ) );
                              end if;
                           end loop;
                           frame_s.dsp <= new_dsp_s;
                           frame_s.rsp <= new_rsp_s;
                           ridx := RWIDX( new_rsp_s );
                           return_cells_s( ridx ) <=
                              ( valid => '1', dirty => '1', addr => new_rsp_s,
                                data => std_logic_vector(
                                   slot_s.pc + resize( slot_s.canon.len, 64 ) ) );

                        elsif IS_RTD_OP( slot_s.canon.op ) then
                           -- RTD n abandonne n octets de pile data : les cellules
                           -- cachées devenues mortes ne doivent surtout pas être rangées.
                           for j in 0 to STACK_CACHE_WORDS_G - 1 loop
                              if cells_s( j ).valid = '1'
                                 and cells_s( j ).addr > new_dsp_s
                                 and cells_s( j ).addr <= old_dsp_s then
                                 cells_s( j ).valid <= '0';
                                 cells_s( j ).dirty <= '0';
                              end if;
                           end loop;
                           frame_s.dsp <= new_dsp_s;
                           ridx := RWIDX( frame_s.rsp );
                           if return_cells_s( ridx ).valid = '1'
                              and return_cells_s( ridx ).addr = frame_s.rsp then
                              return_cells_s( ridx ).valid <= '0';
                              return_cells_s( ridx ).dirty <= '0';
                           end if;
                           frame_s.rsp <= frame_s.rsp + 8;

                        -- Les cellules réellement dépilées deviennent mortes. Le résultat,
                        -- s'il existe, est ensuite installé à sa nouvelle adresse.
                        elsif entry_s.stack_action = STACK_LINEAR then
                           for j in 0 to 3 loop
                              if j < source_count_s then
                                 INVALIDATE_CELL( cells_s, source_address_s( j ) );
                              end if;
                           end loop;
                           frame_s.dsp <= new_dsp_s;

                           if entry_s.pushes = 1 then
                              -- pragma translate_off
                              assert COMPLETE_i.result_valid = '1'
                                 report "STACK_UNIT: resultat attendu mais absent"
                                 severity failure;
                              -- pragma translate_on
                              idx := WIDX( destination_address_s );
                              cells_s( idx ) <= ( valid => '1', dirty => '1',
                                                  addr => destination_address_s,
                                                  data => COMPLETE_i.result );
                           end if;

                        elsif entry_s.stack_action = STACK_KEEP_TOP then
                           -- CHK : lecture seulement, aucune modification de pile.
                           null;
                        end if;

                        commit_s <= ( valid => '1', slot => slot_s, fault => NO_FAULT,
                                      taken => COMPLETE_i.taken, target => COMPLETE_i.target );
                        if entry_s.control and MISPREDICTED( slot_s, COMPLETE_i ) then
                           state_s <= ST_MISPRED_HOLD;
                        else
                           state_s <= ST_IDLE;
                        end if;
                     end if;
                  end if;

               -- Un cycle sans prise après une mauvaise prédiction : COMMIT_o permet
               -- au contrôleur de vider/rediriger le frontal au front suivant.
               when ST_MISPRED_HOLD =>
                  state_s <= ST_IDLE;

               -- Une faute est devenue précise. Aucun état architectural de
               -- l'instruction fautive n'a été appliqué ; attendre la SYNC du
               -- mécanisme de livraison avant de reprendre le décodage.
               when ST_FAULT_HOLD =>
                  -- Les instructions déjà committées peuvent encore résider comme
                  -- cellules sales dans le cache. Le mécanisme d'exception doit donc
                  -- pouvoir demander WRITEBACK_ALL avant la SYNC qui invalidera le
                  -- cache. Une maintenance lancée ici revient ensuite en FAULT_HOLD.
                  if MAINT_i.valid = '1' then
                     maint_s              <= MAINT_i;
                     maint_index_s        <= 0;
                     ret_maint_index_s    <= 0;
                     maint_return_fault_s <= '1';
                     maint_return_exec_s  <= '0';
                     state_s              <= ST_MAINT_SCAN;
                  end if;

               -------------------------------------------------------------------------
               -- Maintenance du cache de pile. Une entrée par cycle ; un mot sale
               -- sélectionné est écrit avant de poursuivre le balayage.
               -------------------------------------------------------------------------

               when ST_MAINT_SCAN =>
                  if maint_index_s = STACK_CACHE_WORDS_G then
                     if maint_s.kind = MAINT_WRITEBACK_ALL then
                        ret_maint_index_s <= 0;
                        state_s <= ST_MAINT_RET_SCAN;
                     else
                        maint_done_s <= '1';
                        if maint_return_fault_s = '1' then
                           state_s <= ST_FAULT_HOLD;
                        elsif maint_return_exec_s = '1' then
                           maint_return_exec_s <= '0';
                           state_s <= ST_WAIT_EXEC;
                        else
                           state_s <= ST_IDLE;
                        end if;
                     end if;
                  else
                     idx := maint_index_s;
                     if cells_s( idx ).valid = '1'
                        and ( maint_s.kind = MAINT_WRITEBACK_ALL
                              or IN_RANGE( cells_s( idx ).addr, maint_s.base, maint_s.length ) ) then

                        if maint_s.kind = MAINT_INVALIDATE_RANGE then
                           cells_s( idx ).valid <= '0';
                           cells_s( idx ).dirty <= '0';
                           maint_index_s <= maint_index_s + 1;

                        elsif cells_s( idx ).dirty = '1' and cells_s( idx ).addr <= frame_s.dsp then
                           mem_cell_index_s <= idx;
                           mem_address_s    <= cells_s( idx ).addr;
                           mem_data_s       <= cells_s( idx ).data;
                           state_s          <= ST_MAINT_SPILL_REQ;

                        else
                           maint_index_s <= maint_index_s + 1;
                        end if;
                     else
                        maint_index_s <= maint_index_s + 1;
                     end if;
                  end if;

               when ST_MAINT_SPILL_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_MAINT_SPILL_RSP;
                  end if;

               when ST_MAINT_SPILL_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     -- Une faute de writeback ne devrait pas être possible pour une
                     -- cellule précédemment valide. On la signale fortement en simulation.
                     -- pragma translate_off
                     assert MEM_RSP_i.fault = '0'
                        report "STACK_UNIT: faute pendant un writeback de maintenance"
                        severity failure;
                     -- pragma translate_on
                     if MEM_RSP_i.fault = '0' then
                        if cells_s( mem_cell_index_s ).valid = '1'
                           and cells_s( mem_cell_index_s ).addr = mem_address_s then
                           cells_s( mem_cell_index_s ).dirty <= '0';
                        end if;
                     end if;
                     maint_index_s <= maint_index_s + 1;
                     state_s <= ST_MAINT_SCAN;
                  end if;

               -- WRITEBACK_ALL inclut la pile de retours (ARCH_TYPES). Les maintenances
               -- de tranche ne la concernent pas : elle n'est pas adressable par le
               -- programme ordinaire.
               when ST_MAINT_RET_SCAN =>
                  if ret_maint_index_s = RETURN_CACHE_WORDS_G then
                     maint_done_s <= '1';
                     if maint_return_fault_s = '1' then
                        state_s <= ST_FAULT_HOLD;
                     elsif maint_return_exec_s = '1' then
                        maint_return_exec_s <= '0';
                        state_s <= ST_WAIT_EXEC;
                     else
                        state_s <= ST_IDLE;
                     end if;
                  else
                     ridx := ret_maint_index_s;
                     if return_cells_s( ridx ).valid = '1'
                        and return_cells_s( ridx ).dirty = '1' then
                        ret_mem_cell_index_s <= ridx;
                        mem_address_s        <= return_cells_s( ridx ).addr;
                        mem_data_s           <= return_cells_s( ridx ).data;
                        state_s              <= ST_MAINT_RET_SPILL_REQ;
                     else
                        ret_maint_index_s <= ret_maint_index_s + 1;
                     end if;
                  end if;

               when ST_MAINT_RET_SPILL_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= ST_MAINT_RET_SPILL_RSP;
                  end if;

               when ST_MAINT_RET_SPILL_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     -- pragma translate_off
                     assert MEM_RSP_i.fault = '0'
                        report "STACK_UNIT: faute pendant le writeback de la pile retours"
                        severity failure;
                     -- pragma translate_on
                     if MEM_RSP_i.fault = '0' then
                        if return_cells_s( ret_mem_cell_index_s ).valid = '1'
                           and return_cells_s( ret_mem_cell_index_s ).addr = mem_address_s then
                           return_cells_s( ret_mem_cell_index_s ).dirty <= '0';
                        end if;
                     end if;
                     ret_maint_index_s <= ret_maint_index_s + 1;
                     state_s <= ST_MAINT_RET_SCAN;
                  end if;

            end case;
         end if;
      end if;
   end process SEQUENTIAL;

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
