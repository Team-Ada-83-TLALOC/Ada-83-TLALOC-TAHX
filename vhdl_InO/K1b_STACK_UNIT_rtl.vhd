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
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

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
        --
        -- Prise sur le cycle du commit (V2, etude de vitesse). Une instruction prise
        -- par le chemin rapide (fast_s) a toutes ses sources presentes et aucune
        -- cellule sale vivante recouverte ; rien ne modifie le cache de pile entre sa
        -- prise et son commit (pas de FILL/SPILL, pas de maintenance, pas de SYNC).
        -- Les cellules que son commit invalide sont donc connues des la prise
        -- (cp_inv_*), et ce commit n'utilise aucun port de lecture. Au cycle de ce
        -- commit (ST_WAIT_EXEC avec COMPLETE sans faute ni mauvaise prediction, ou
        -- ST_FAST_COMMIT), l'instruction suivante est prise (chain_s) : son decodage
        -- voit l'etat d'apres le commit, DSP = new_dsp_s et cellules lues par les
        -- ports corrigees (invalidations cp_inv_*, destination ecrite). Les autres
        -- instructions gardent le cycle ST_IDLE entre leur commit et la prise
        -- suivante. INO_CORE_SYSTEM interdit l'enchainement quand une interruption
        -- est en attente : la frontiere d'instruction (STACK_IDLE) reste observable.
        --
        -- Terminaison dans le cycle d'emission (V3, etude de vitesse) : l'entier, les
        -- branchements et le fast path memoire (reponse du cache) rendent COMPLETE
        -- combinatoirement. En ST_ISSUE, une instruction du chemin rapide dont
        -- COMPLETE arrive avec ISSUE_READY commite dans ce cycle (et la suivante est
        -- prise, chain_s). Pour une autre instruction, COMPLETE est enregistre
        -- (complete_q_s) et traite en ST_WAIT_EXEC au cycle suivant, comme avant.
        --
        -- Préparation rapide des appels et cadres (V5) : CALL/CALLI, RTD, LINK et
        -- UNLINK/UNLINKR dont tout est déjà dans les caches de pile (source, cible de
        -- retour, aucune collision sale à ranger) passent de la prise à ST_ISSUE sans
        -- ST_PREPARE. Leur commit reste celui du chemin lent (ports de lecture,
        -- parcours de plage), suivi du cycle ST_IDLE : fast_s = '0'.
        --
        -- Chargements directs servis par le cache de pile (V5) : un chargement de
        -- famille B (lvl 0..14) dont les octets tiennent dans une cellule vivante
        -- présente (sale ou propre) lit cette cellule, qui tient la valeur
        -- architecturale : ni rangement de cohérence ni accès au cache de données.
        -- Il commite en ST_FAST_COMMIT, comme DUP, le résultat étant extrait à la prise.
        -- De même, un rangement de famille B (lvl 0..14) dont les octets tiennent dans
        -- une cellule vivante SALE, autre que le sommet qu'il dépile, est fusionné dans
        -- cette cellule (qui reste sale) au lieu d'être rangé en mémoire. Règle V8 : une
        -- cellule exposée par LVA est rendue propre, et ne redevient sale qu'empilée à
        -- nouveau ; une cellule sale n'a donc pas d'adresse exposée en cours, et aucun
        -- accès calculé (qui lit la mémoire sans sonder le cache) ne peut la viser. Une
        -- cellule propre garde le chemin mémoire (rangement puis invalidation).
        --
        -- Espace physique InO (INO_PADDR) : DSP, RSP, DISPLAY, adresses des cellules, des
        -- sources, de la destination, des FILL/SPILL et cibles de retour ne gardent que
        -- PA_BITS bits (CUT a chaque ecriture de registre). Elles sont realisables par
        -- construction :
        --   - un nouveau DSP / RSP non realisable faute (DSP_LIMIT / RSP_LIMIT) ;
        --   - UNLINK dont le FP sauvegarde n'est pas realisable faute (132) avant emission ;
        --   - une adresse de retour relue en memoire non realisable fait fauter RTD (132) ;
        --   - le frame d'une SYNC est controle par SYSTEM_UNIT.
        -- Les adresses d'acces direct (DISPLAY + val) restent sur 64 bits jusqu'a
        -- DATA_CACHE, qui fait fauter un acces non realisable. La plage de maintenance
        -- (maint_s) reste sur 64 bits.
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
      ST_FAST_COMMIT,
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

   -- Ports de lecture du cache de pile data. Un indice dynamique dans cells_s coûte
   -- un multiplexeur 64:1 de 130 bits ; on multiplexe donc les indices (6 bits) selon
   -- l'état et on ne lit le tableau qu'en READ_PORTS endroits fixes.
   --   ST_IDLE      : 0..3 sources du fast path (accès direct : 0 source, 1..3
   --                  cellules recouvertes), 4 destination
   --   ST_PREPARE   : 0 source ou destination, 1 ancien sommet (DROP)
   --   ST_WAIT_EXEC : 0..3 sources dépilées, 2..4 cellules d'un rangement direct
   --   autres       : 0
   constant READ_PORTS : positive := 5;
   subtype cell_index_t is natural range 0 to STACK_CACHE_WORDS_G - 1;
   type cell_index_array_t is array( 0 to READ_PORTS - 1 ) of cell_index_t;
   type mem_cell_address_array_t is array( 0 to 2 ) of address_t;

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
   signal complete_w           : ino_complete_t;      -- COMPLETE_i en adresses de 64 bits
   signal maint_done_s         : std_logic := '0';
   -- Une maintenance peut aussi être lancée après une faute précise. Dans ce cas,
   -- MAINT_DONE ne libère pas le backend : on revient attendre la SYNC d'exception.
   signal maint_return_fault_s : std_logic := '0';
   -- Maintenance lancée pendant ST_WAIT_EXEC (blocs complexes) :
   -- revenir attendre COMPLETE au lieu de libérer STACK_UNIT.
   signal maint_return_exec_s  : std_logic := '0';

   -- Prise sur le cycle du commit (V2) : commit d'une instruction du chemin rapide
   -- decide a sa prise. Emplacements j = 0..3 : sources depilees (STACK_LINEAR),
   -- cellule du sommet (DROP), cellules recouvertes par un rangement direct (1..3).
   type inv_index_array_t is array( 0 to 3 ) of cell_index_t;
   signal fast_s               : std_logic := '0';
   signal cp_inv_en_s          : std_logic_vector( 0 to 3 ) := ( others => '0' );
   signal cp_inv_idx_s         : inv_index_array_t := ( others => 0 );
   signal chain_s              : std_logic;

   -- Terminaison dans le cycle d'émission (V3) : COMPLETE reçu en ST_ISSUE pour une
   -- instruction hors chemin rapide, traité en ST_WAIT_EXEC au cycle suivant.
   -- cpl : terminaison vue par le commit (enregistrée, sinon COMPLETE_i).
   constant NO_COMPLETE_W      : ino_complete_t := (
      valid => '0', result_valid => '0', result => ( others => '0' ),
      fault => NO_FAULT, taken => '0', target => ( others => '0' ) );
   signal complete_q_s         : ino_complete_t := NO_COMPLETE_W;
   signal cpl                  : ino_complete_t;

   -- pragma translate_off
   -- Observation (simulation seulement) : etat courant (state_t'pos) et noms des
   -- etats, lus par N3_INO_PLATEFORME par noms externes. Hors synthese.
   function OBS_NOMS( s : state_t ) return string is
   begin
      if s = state_t'high then
         return state_t'image( s );
      end if;
      return state_t'image( s ) & " " & OBS_NOMS( state_t'succ( s ) );
   end function;
   constant OBS_STATE_NAMES    : string := OBS_NOMS( state_t'low );
   signal obs_state_s          : natural := 0;
   -- pragma translate_on

   -- Emission vers le port a adresses physiques. L'adresse emise est realisable
   -- (cible de retour, ou base DISPLAY(lvl) quand ofs = '1').
   function ISSUE_PORT( i : ino_issue_t; ofs : std_logic ) return issue_pa_t is
   begin
      return ( slot => TO_PA( i.slot ), issue_class => i.issue_class,
               operand_count => i.operand_count, operand => i.operand,
               address_known => i.address_known, address_ofs => ofs,
               address => TO_PA( i.address ) );
   end function;

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

   -- Fast path InO : seulement les opérations dont toute la préparation de pile
   -- peut être décidée localement au moment de la prise dans DECODE_QUEUE.
   -- Les accès mémoire, frames, appels/retours et opérations longues restent sur
   -- le chemin historique ST_PREPARE/...
   function IS_FAST_BRANCH_OP( op : opcode_t ) return boolean is
   begin
      return unsigned( op ) >= 16#E0# and unsigned( op ) <= 16#EB#;
   end function;

   function IS_FAST_STACK_OP( op : opcode_t ) return boolean is
   begin
      return op = x"30" or op = x"31" or op = x"32";  -- DROP, DUP, OVER
   end function;

   function IS_FAST_MEMORY_OP( op : opcode_t ) return boolean is
   begin
      -- Familles B et C (V4 pour C) : load signé (01), store (10), load non signé
      -- (11). fmt=11 correspond aux CHK, mode=00 aux cas spéciaux (LIVA) : ils
      -- restent sur le slow path (de même dans INO_BACKEND_MEMORY).
      return ( op( 7 downto 6 ) = "01" or op( 7 downto 6 ) = "10" )
         and op( 5 downto 4 ) /= "00"
         and op( 3 downto 2 ) /= "11";
   end function;

   function IS_LVA_OP( op : opcode_t ) return boolean is
   begin
      return op = x"47" or op = x"4B";
   end function;

   -- Cellule w dont les octets [ off, off + 2**sz ) sont remplacés par ceux de v
   -- (octets bas de v), comme un rangement du cache de données.
   function CELL_MERGE( w : word64_t; v : word64_t; off : natural; sz : natural ) return word64_t is
      variable r : word64_t := w;
   begin
      for i in 0 to 7 loop
         if i >= off and i < off + 2 ** sz then
            r( 8 * i + 7 downto 8 * i ) := v( 8 * ( i - off ) + 7 downto 8 * ( i - off ) );
         end if;
      end loop;
      return r;
   end function;

   -- Octets [ off, off + 2**sz ) de la cellule w, étendus comme par le cache de
   -- données (petit-boutiste : octet off = w( 8*off + 7 downto 8*off )).
   function CELL_EXTRACT( w : word64_t; off : natural; sz : natural; sgn : boolean ) return word64_t is
      variable v : unsigned( 63 downto 0 );
      variable r : word64_t := ( others => '0' );
   begin
      v := shift_right( unsigned( w ), 8 * off );
      case sz is
         when 0 =>
            r( 7 downto 0 ) := std_logic_vector( v( 7 downto 0 ) );
            if sgn and v( 7 ) = '1' then r( 63 downto 8 ) := ( others => '1' ); end if;
         when 1 =>
            r( 15 downto 0 ) := std_logic_vector( v( 15 downto 0 ) );
            if sgn and v( 15 ) = '1' then r( 63 downto 16 ) := ( others => '1' ); end if;
         when 2 =>
            r( 31 downto 0 ) := std_logic_vector( v( 31 downto 0 ) );
            if sgn and v( 31 ) = '1' then r( 63 downto 32 ) := ( others => '1' ); end if;
         when others =>
            r := std_logic_vector( v );
      end case;
      return r;
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

   -- r est la cellule d'indice WIDX( a ), lue par un port de lecture : sa
   -- correspondance avec a marque l'entrée à invalider (masque inv, appliqué en fin
   -- de cycle, voir ECRITURES).
   procedure INVALIDATE_CELL(
      variable m : inout std_logic_vector;
      constant r : in stack_cell_t;
      constant a : in address_t ) is
   begin
      if r.valid = '1' and r.addr = a then
         m( WIDX( a ) ) := '1';
      end if;
   end procedure;

begin

   -- pragma translate_off
   obs_state_s <= state_t'pos( state_s );
   -- pragma translate_on

   -- Ports a adresses physiques : frame_s et commit_s sont realisables (CUT).
   FRAME_DSP_o  <= TO_PA( frame_s.dsp );
   FRAME_RSP_o  <= TO_PA( frame_s.rsp );
   DISP_o       <= TO_PA( frame_s.display( to_integer( DISP_SEL_i ) ) ) when DISP_SEL_i <= 14
                   else ( others => '0' );
   COMMIT_o     <= TO_PA( commit_s );
   complete_w   <= TO_VA( COMPLETE_i );
   cpl          <= complete_q_s when complete_q_s.valid = '1' else complete_w;
   MAINT_DONE_o <= maint_done_s;

   IDLE_o <= '1' when state_s = ST_IDLE or state_s = ST_FAULT_HOLD else '0';

        --------------------------------------------------------------------------------
        -- Commit avec prise de l'instruction suivante dans le même cycle (V2) :
        -- commit local du chemin rapide (ST_FAST_COMMIT), ou COMPLETE sans faute ni
        -- mauvaise prédiction d'une instruction prise par le chemin rapide.
        --------------------------------------------------------------------------------

   CHAIN : process( all )
   begin
      chain_s <= '0';
      if state_s = ST_FAST_COMMIT then
         chain_s <= '1';
      elsif ( state_s = ST_WAIT_EXEC or ( state_s = ST_ISSUE and ISSUE_READY_i = '1' ) )
         and fast_s = '1' and cpl.valid = '1' and cpl.fault.valid = '0'
         and not ( entry_s.control and MISPREDICTED( slot_s, cpl ) ) then
         -- ST_ISSUE : terminaison dans le cycle d'émission (V3).
         chain_s <= '1';
      end if;
   end process CHAIN;

        --------------------------------------------------------------------------------
        -- Sorties combinatoires : prise de DECODE_QUEUE, émission et port mémoire.
        --------------------------------------------------------------------------------

   OUTPUTS : process( all )
      variable issue_v : ino_issue_t;
      variable ofs_v   : std_logic;
      variable mem_v   : mem_request_t;
   begin
      DECODE_TAKE_o <= '0';

      issue_v.slot          := ( valid => '0', canon => CANON_NOP,
                                 pc => ( others => '0' ), pred => NO_PREDICTION );
      issue_v.issue_class   := ISSUE_NONE;
      issue_v.operand_count := 0;
      issue_v.operand       := ( others => ( others => '0' ) );
      ofs_v := '0';
      issue_v.address_known := '0';
      issue_v.address       := ( others => '0' );
      ISSUE_o               <= ISSUE_PORT( issue_v, '0' );
      ISSUE_VALID_o         <= '0';

      mem_v := NO_MEM_REQUEST;

      -- Une instruction est retirée de DECODE_QUEUE dès qu'elle devient l'unique
      -- instruction interne de STACK_UNIT. Les FILL éventuels sont ensuite privés.
      -- Même condition que la prise de SEQUENTIAL (take_v).
      if ( state_s = ST_IDLE or chain_s = '1' ) and RESET_i = '0' and SYNC_VALID_i = '0'
         and MAINT_i.valid = '0' and DECODE_VALID_i = '1' then
         DECODE_TAKE_o <= '1';
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
            -- Le port transporte la base DISPLAY(lvl) ; le decalage canon.val est
            -- ajoute en 64 bits par TO_VA (INO_PORTS_PA).
            issue_v.address := frame_s.display( to_integer( slot_s.canon.lvl ) );
            ofs_v := '1';
         end if;

         ISSUE_o       <= ISSUE_PORT( issue_v, ofs_v );
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

      MEM_REQ_o <= TO_PA( mem_v );
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
      -- Niveau de l'instruction qui commite (LINK, UNLINK). Distinct de lvl, celui
      -- de la prise : une variable commune ferait dépendre tout le décodage de la
      -- prise de COMPLETE (multiplexeur commandé par cpl.valid en tête du cône).
      variable clvl            : natural range 0 to 15;
      variable alloc65         : unsigned( 64 downto 0 );
      variable ndsp65          : unsigned( 64 downto 0 );
      -- Préparation accélérée des instructions ordinaires. Les variables sont
      -- calculées à partir de l'état courant du cache ; si une source manque ou
      -- si la future destination exige un SPILL, on retombe sur ST_PREPARE.
      variable fast_ok          : boolean;
      variable fast_values      : ino_operand_array_t;
      variable fast_addr        : address_t;
      variable fast_dst_addr    : address_t;
      variable fast_dst_valid   : boolean;
      variable fast_mem_base    : address_t;
      variable fast_mem_len     : address_t;
      -- Ports de lecture des deux caches de pile.
      variable fast_src         : source_address_array_t;
      variable fast_mem         : mem_cell_address_array_t;
      variable ri               : cell_index_array_t;
      variable rd               : stack_cell_array_t( 0 to READ_PORTS - 1 );
      variable rri              : natural range 0 to RETURN_CACHE_WORDS_G - 1;
      variable rrd              : stack_cell_t;
      -- Parcours de plage commun à LINK, UNLINK/UNLINKR et RTD.
      variable range_lo         : address_t;
      variable range_hi         : address_t;
      variable range_keep       : boolean;
      -- Prise sur le cycle du commit (V2).
      variable chain_view       : boolean;           -- commit possible : vue d'apres commit
      variable tdsp             : address_t;         -- DSP vu par la prise
      variable take_v           : boolean;
      variable dst_data         : word64_t;
      variable cp_en            : std_logic_vector( 0 to 3 );
      variable cp_idx           : inv_index_array_t;
      variable fast_dst_idx     : natural;
      variable fast_commit_v    : boolean;           -- commit du chemin rapide (après le case)
      variable prep_ok          : boolean;           -- préparation rapide d'un appel / cadre (V5)
      variable local_ld         : boolean;           -- chargement servi par le cache de pile (V5)
      variable local_st         : boolean;           -- rangement fusionné dans une cellule sale (V5)
      variable ld_off           : natural range 0 to 7;
      -- Écritures des caches de pile (V6, étude de vitesse § 8.14) : un seul port
      -- d'écriture de cellule entière par cache et par cycle, et des masques
      -- d'invalidation (valid, dirty) et de nettoyage (dirty), appliqués en fin de
      -- cycle. L'écriture l'emporte sur les masques, comme la dernière affectation
      -- de l'écriture précédente (destination écrite après les invalidations).
      variable inv_m            : std_logic_vector( 0 to STACK_CACHE_WORDS_G - 1 );
      variable cln_m            : std_logic_vector( 0 to STACK_CACHE_WORDS_G - 1 );
      variable wr_en            : boolean;
      variable wr_idx           : natural range 0 to STACK_CACHE_WORDS_G - 1;
      variable wr_cell          : stack_cell_t;
      variable rinv_m           : std_logic_vector( 0 to RETURN_CACHE_WORDS_G - 1 );
      variable rcln_m           : std_logic_vector( 0 to RETURN_CACHE_WORDS_G - 1 );
      variable rwr_en           : boolean;
      variable rwr_idx          : natural range 0 to RETURN_CACHE_WORDS_G - 1;
      variable rwr_cell         : stack_cell_t;
   begin
      if rising_edge( CLK_i ) then

         ------------------------------------------------------------------------------
         -- Etat vu par la prise. En ST_FAST_COMMIT, et en ST_WAIT_EXEC pour une
         -- instruction du chemin rapide, la prise eventuelle a lieu au cycle du
         -- commit : elle voit le DSP d'apres commit. DISPLAY et RSP ne changent pas
         -- au commit d'une instruction du chemin rapide.
         ------------------------------------------------------------------------------
         chain_view := state_s = ST_FAST_COMMIT
                       or ( ( state_s = ST_WAIT_EXEC or state_s = ST_ISSUE ) and fast_s = '1' );
         tdsp := frame_s.dsp;
         if chain_view then
            tdsp := new_dsp_s;
         end if;

         ------------------------------------------------------------------------------
         -- Décodage de l'instruction offerte par DECODE_QUEUE (utilisé en ST_IDLE).
         ------------------------------------------------------------------------------
            s := TO_VA( DECODE_SLOT_i );
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

            ndsp := tdsp;
            lvl := to_integer( s.canon.lvl );
            case e.stack_action is
               when STACK_LINEAR =>
                  if npop > e.pushes then
                     ndsp := tdsp - 8 * ( npop - e.pushes );
                  elsif e.pushes > npop then
                     ndsp := tdsp + 8 * ( e.pushes - npop );
                  end if;
               when STACK_DROP =>
                  ndsp := tdsp - 8;
               when STACK_DUP | STACK_OVER =>
                  ndsp := tdsp + 8;
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
               ndsp65 := resize( tdsp, 65 ) + alloc65;
               if lvl > 0 then
                  ndsp65 := ndsp65 + 8;
               end if;
               ndsp := ndsp65( 63 downto 0 );
               if ndsp65( 64 ) = '1' then
                  f := ( valid => '1', code => FAULT_DSP_LIMIT );
               end if;
            elsif IS_UNLINK_OP( s.canon.op ) and lvl <= 14 then
               -- Décodage évalué à chaque cycle : protéger l'indice de DISPLAY.
               ndsp := frame_s.display( lvl ) - 8;
            elsif IS_RTD_OP( s.canon.op ) then
               -- RTD n : n est un nombre d'octets à abandonner.
               ndsp := tdsp - U64( s.canon.val );
            end if;

            nrsp := frame_s.rsp;
            if IS_CALL_OP( s.canon.op ) then
               nrsp := frame_s.rsp - 8;
            end if;

            if f.valid = '0' and ndsp > LIM_DSP_i and ndsp > tdsp then
               f := ( valid => '1', code => FAULT_DSP_LIMIT );
            elsif f.valid = '0' and nrsp < LIM_RSP_i and nrsp < frame_s.rsp then
               f := ( valid => '1', code => FAULT_RSP_LIMIT );
            elsif f.valid = '0' and not PA_OK( ndsp ) then
               -- Espace physique InO : DSP hors de l'espace realise.
               f := ( valid => '1', code => FAULT_DSP_LIMIT );
            elsif f.valid = '0' and not PA_OK( nrsp ) then
               f := ( valid => '1', code => FAULT_RSP_LIMIT );
            end if;

         -- Sources et cellules mémoire examinées par le fast path de ST_IDLE : même
         -- nombre de sources que ST_IDLE (nsrc), mêmes adresses que fast_addr.
         nsrc := 0;
         if IS_LINK_OP( s.canon.op ) then
            nsrc := 0;
         elsif IS_UNLINK_OP( s.canon.op ) then
            nsrc := 1;
         else
            case e.stack_action is
               when STACK_LINEAR                => nsrc := npop;
               when STACK_KEEP_TOP | STACK_DUP  => nsrc := 1;
               when STACK_OVER                  => nsrc := 1;
               when STACK_DROP                  => nsrc := 0;
            end case;
         end if;
         fast_src := ( others => ( others => '0' ) );
         for j in 0 to 3 loop
            case e.stack_action is
               when STACK_LINEAR =>
                  if j < npop then
                     fast_src( j ) := tdsp - 8 * ( npop - 1 - j );
                  end if;
               when STACK_KEEP_TOP | STACK_DUP =>
                  fast_src( j ) := tdsp;
               when STACK_OVER =>
                  fast_src( j ) := tdsp - 8;
               when STACK_DROP =>
                  fast_src( j ) := tdsp;
            end case;
         end loop;
         -- DISPLAY n'a que 15 niveaux (0..14) ; lvl = 15 désigne la pile.
         fast_mem_base := ( others => '0' );
         fast_mem_len  := ( others => '0' );
         if lvl <= 14 then
            fast_mem_base := frame_s.display( lvl ) + U64( s.canon.val );
         end if;
         for k in 0 to 2 loop
            fast_mem( k ) := ( fast_mem_base( 63 downto 3 ) & "000" ) + to_unsigned( 8 * k, 64 );
         end loop;

         ------------------------------------------------------------------------------
         -- Indices des ports de lecture selon l'état, puis lectures (seuls accès à
         -- cells_s / return_cells_s par indice dynamique en lecture).
         ------------------------------------------------------------------------------
         ri  := ( others => 0 );
         rri := 0;
         if state_s = ST_IDLE or chain_view then
            -- Prise : sources du fast path, cellule du sommet (DROP), cellules
            -- recouvertes par un accès direct, destination.
            for j in 0 to 3 loop
               if j < nsrc then
                  ri( j ) := WIDX( fast_src( j ) );
               end if;
            end loop;
            if e.stack_action = STACK_DROP then
               ri( 0 ) := WIDX( fast_src( 0 ) );
            end if;
            -- Préparation rapide (V5) : LINK lvl > 0, cellule qui recevra l'ancien
            -- DISPLAY(lvl) ; UNLINK, FP sauvegardé en DISPLAY(lvl) ; CALL, cellule du
            -- futur RSP ; RTD, cible au RSP courant.
            if IS_LINK_OP( s.canon.op ) then
               ri( 0 ) := WIDX( tdsp + 8 );
            elsif IS_UNLINK_OP( s.canon.op ) and lvl <= 14 then
               ri( 0 ) := WIDX( frame_s.display( lvl ) );
            end if;
            if IS_CALL_OP( s.canon.op ) then
               rri := RWIDX( nrsp );
            elsif IS_RTD_OP( s.canon.op ) then
               rri := RWIDX( frame_s.rsp );
            end if;
            -- Cellules recouvertes par un accès à DISPLAY(lvl) + val (lvl 0..14) :
            -- accès direct, cellule pointeur (famille C) ou cellule exposée (LVA).
            -- Un accès calculé (lvl = 15) n'a pas à sonder le cache (V8) : ses
            -- ports servent aux sources.
            if ( e.issue_class = ISSUE_MEMORY or IS_LVA_OP( s.canon.op ) ) and lvl <= 14 then
               for k in 0 to 2 loop
                  ri( 1 + k ) := WIDX( fast_mem( k ) );
               end loop;
            end if;
            ri( 4 ) := WIDX( ndsp );
         else
         case state_s is
            when ST_PREPARE =>
               if source_index_s < source_count_s then
                  ri( 0 ) := WIDX( source_address_s( source_index_s ) );
               else
                  ri( 0 ) := WIDX( destination_address_s );
               end if;
               ri( 1 ) := WIDX( old_dsp_s );
               if IS_CALL_OP( slot_s.canon.op ) then
                  rri := RWIDX( new_rsp_s );
               else
                  rri := RWIDX( frame_s.rsp );
               end if;

            when ST_COH_SCAN =>
               ri( 0 ) := WIDX( ( coh_base_s( 63 downto 3 ) & "000" ) + to_unsigned( 8 * coh_index_s, 64 ) );

            when ST_WAIT_EXEC =>
               for j in 0 to 3 loop
                  ri( j ) := WIDX( source_address_s( j ) );
               end loop;
               if coh_invalidate_s = '1' then
                  for k in 0 to 2 loop
                     ri( 2 + k ) := WIDX( ( coh_base_s( 63 downto 3 ) & "000" ) + to_unsigned( 8 * k, 64 ) );
                  end loop;
               end if;
               rri := RWIDX( frame_s.rsp );

            when ST_MAINT_SCAN =>
               if maint_index_s < STACK_CACHE_WORDS_G then
                  ri( 0 ) := maint_index_s;
               end if;

            when ST_MAINT_SPILL_RSP =>
               ri( 0 ) := mem_cell_index_s;

            when ST_MAINT_RET_SCAN =>
               if ret_maint_index_s < RETURN_CACHE_WORDS_G then
                  rri := ret_maint_index_s;
               end if;

            when ST_MAINT_RET_SPILL_RSP =>
               rri := ret_mem_cell_index_s;

            when others =>
               null;
         end case;
         end if;

         for k in 0 to READ_PORTS - 1 loop
            rd( k ) := cells_s( ri( k ) );
         end loop;
         rrd := return_cells_s( rri );

         -- Contournement (V2) : au cycle d'un commit du chemin rapide, les ports
         -- rendent les cellules d'après ce commit (invalidations, puis destination ;
         -- la destination l'emporte, comme dans le commit). Sans commit dans ce
         -- cycle, aucune prise n'a lieu et les valeurs ne servent pas.
         if chain_view then
            if state_s = ST_FAST_COMMIT then
               dst_data := source_value_s( 0 );           -- DUP / OVER
            else
               dst_data := cpl.result;
            end if;
            for k in 0 to READ_PORTS - 1 loop
               for j in 0 to 3 loop
                  if cp_inv_en_s( j ) = '1' and ri( k ) = cp_inv_idx_s( j ) then
                     rd( k ).valid := '0';
                     rd( k ).dirty := '0';
                  end if;
               end loop;
               if destination_valid_s = '1' and ri( k ) = WIDX( destination_address_s ) then
                  rd( k ) := ( valid => '1', dirty => '1', addr => destination_address_s,
                               data => dst_data );
               end if;
            end loop;
         end if;

         -- pragma translate_off
         -- Les cellules 2..4 d'un rangement direct partagent les ports des sources 2..3.
         if state_s = ST_WAIT_EXEC and coh_invalidate_s = '1' then
            assert source_count_s <= 2
               report "STACK_UNIT: rangement direct avec plus de deux sources"
               severity failure;
         end if;
         -- pragma translate_on

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
            fast_s           <= '0';
            cp_inv_en_s      <= ( others => '0' );
            complete_q_s     <= NO_COMPLETE_W;
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
            frame_s.dsp     <= CUT( TO_VA( SYNC_DSP_i ) );
            frame_s.rsp     <= CUT( TO_VA( SYNC_RSP_i ) );
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
            fast_s           <= '0';
            cp_inv_en_s      <= ( others => '0' );
            complete_q_s     <= NO_COMPLETE_W;

         else
            fast_commit_v := false;
            inv_m  := ( others => '0' );
            cln_m  := ( others => '0' );
            wr_en  := false;
            wr_idx := 0;
            wr_cell := NO_CELL;
            rinv_m := ( others => '0' );
            rcln_m := ( others => '0' );
            rwr_en := false;
            rwr_idx := 0;
            rwr_cell := NO_CELL;
            take_v := MAINT_i.valid = '0' and DECODE_VALID_i = '1'
                      and ( state_s = ST_IDLE or chain_s = '1' );

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
                  end if;
                  -- Sinon, prise éventuelle après le case (take_v).

               -------------------------------------------------------------------------
               -- Commit local du fast path DROP/DUP/OVER. Les opérandes ont été lus
               -- en parallèle lors de la prise et sont maintenant enregistrés dans
               -- source_value_s. Aucun backend n'est impliqué.
               -------------------------------------------------------------------------

               when ST_FAST_COMMIT =>
                  -- pragma translate_off
                  assert entry_s.stack_action = STACK_DROP or entry_s.stack_action = STACK_DUP
                         or entry_s.stack_action = STACK_OVER
                         or ( entry_s.issue_class = ISSUE_MEMORY and destination_valid_s = '1'
                              and source_count_s <= 1 )
                     report "STACK_UNIT: ST_FAST_COMMIT sur operation non locale"
                     severity failure;
                  assert MAINT_i.valid = '0'
                     report "STACK_UNIT: maintenance pendant ST_FAST_COMMIT"
                     severity failure;
                  -- pragma translate_on
                  -- DROP : cellule du sommet (cp_inv_*, décidé à la prise) ;
                  -- DUP/OVER : copie à la destination ; chargement servi par le cache
                  -- de pile : valeur extraite à la prise (source_value_s( 0 )) ; rangement
                  -- fusionné : cellule rangée, fusionnée à la prise, et valeur dépilée
                  -- invalidée (cp_inv_*).
                  for j in 0 to 3 loop
                     if cp_inv_en_s( j ) = '1' then
                        inv_m( cp_inv_idx_s( j ) ) := '1';
                     end if;
                  end loop;
                  if destination_valid_s = '1' then
                     idx := WIDX( destination_address_s );
                     -- pragma translate_off
                     assert not wr_en report "STACK_UNIT: deux ecritures de cellule dans un cycle" severity failure;
                     -- pragma translate_on
                     wr_en   := true;
                     wr_idx  := idx;
                     wr_cell := ( valid => '1', dirty => '1',
                                         addr => CUT( destination_address_s ),
                                         data => source_value_s( 0 ) );
                  end if;
                  frame_s.dsp <= new_dsp_s;

                  commit_s <= ( valid => '1', slot => slot_s, fault => NO_FAULT,
                                taken => '0', target => ( others => '0' ) );
                  state_s <= ST_IDLE;

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
                     -- Port 0 : cellule idx.
                     if rd( 0 ).valid = '1' and rd( 0 ).addr = a then
                        source_value_s( source_index_s ) <= rd( 0 ).data;
                        source_index_s <= source_index_s + 1;
                     else
                        -- Avant de prendre l'entrée, sauver son occupant sale s'il est
                        -- encore une cellule vivante de la pile architecturale.
                        live_collision := rd( 0 ).valid = '1'
                                          and rd( 0 ).dirty = '1'
                                          and rd( 0 ).addr <= old_dsp_s;
                        mem_cell_index_s <= idx;
                        if live_collision then
                           mem_address_s <= CUT( rd( 0 ).addr );
                           mem_data_s    <= rd( 0 ).data;
                           state_s       <= ST_SRC_SPILL_REQ;
                        else
                           mem_address_s <= CUT( a );
                           state_s       <= ST_SRC_FILL_REQ;
                        end if;
                     end if;

                  elsif destination_valid_s = '1' then
                     dst_idx := WIDX( destination_address_s );
                     -- Port 0 : cellule dst_idx.
                     if rd( 0 ).valid = '1'
                        and rd( 0 ).addr /= destination_address_s
                        and rd( 0 ).dirty = '1'
                        and rd( 0 ).addr <= old_dsp_s then
                        mem_cell_index_s <= dst_idx;
                        mem_address_s    <= CUT( rd( 0 ).addr );
                        mem_data_s       <= rd( 0 ).data;
                        state_s          <= ST_DST_SPILL_REQ;
                     else
                        -- L'entrée pourra être remplacée au commit.
                        if entry_s.issue_class = ISSUE_NONE then
                           case entry_s.stack_action is
                              when STACK_DROP =>
                                 INVALIDATE_CELL( inv_m, rd( 1 ), old_dsp_s );
                                 frame_s.dsp <= new_dsp_s;

                              when STACK_DUP | STACK_OVER =>
                                 idx := WIDX( destination_address_s );
                                 -- pragma translate_off
                                 assert not wr_en report "STACK_UNIT: deux ecritures de cellule dans un cycle" severity failure;
                                 -- pragma translate_on
                                 wr_en   := true;
                                 wr_idx  := idx;
                                 wr_cell := ( valid => '1', dirty => '1',
                                                     addr => CUT( destination_address_s ),
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
                     if IS_UNLINK_OP( slot_s.canon.op )
                        and not PA_OK( unsigned( source_value_s( 0 ) ) ) then
                        -- FP sauvegardé non réalisable (INO_PADDR) : UNLINK faute avant
                        -- toute émission, donc avant l'effet de co-pile de COMPLEX_UNIT.
                        commit_s <= ( valid => '1', slot => slot_s,
                                      fault => ( valid => '1', code => FAULT_ACCESS ),
                                      taken => '0', target => ( others => '0' ) );
                        state_s <= ST_FAULT_HOLD;

                     elsif IS_CALL_OP( slot_s.canon.op ) then
                        ridx := RWIDX( new_rsp_s );
                        if rrd.valid = '1'
                           and rrd.addr /= new_rsp_s
                           and rrd.dirty = '1' then
                           ret_mem_cell_index_s   <= ridx;
                           mem_address_s          <= CUT( rrd.addr );
                           mem_data_s             <= rrd.data;
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
                        if rrd.valid = '1'
                           and rrd.addr = frame_s.rsp then
                           return_target_s <= CUT( unsigned( rrd.data ) );
                           if coh_required_s = '1' then
                              coh_index_s <= 0;
                              state_s <= ST_COH_SCAN;
                           else
                              state_s <= ST_ISSUE;
                           end if;
                        elsif rrd.valid = '1'
                           and rrd.dirty = '1' then
                           ret_mem_cell_index_s   <= ridx;
                           mem_address_s          <= CUT( rrd.addr );
                           mem_data_s             <= rrd.data;
                           ret_after_spill_fill_s <= '1';
                           state_s                <= ST_RET_SPILL_REQ;
                        else
                           ret_mem_cell_index_s   <= ridx;
                           mem_address_s          <= CUT( frame_s.rsp );
                           state_s                <= ST_RET_FILL_REQ;
                        end if;

                     elsif entry_s.issue_class = ISSUE_NONE then
                        case entry_s.stack_action is
                           when STACK_DROP =>
                              INVALIDATE_CELL( inv_m, rd( 1 ), old_dsp_s );
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
                        inv_m( mem_cell_index_s ) := '1';
                        mem_address_s <= CUT( source_address_s( source_index_s ) );
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
                        -- pragma translate_off
                        assert not wr_en report "STACK_UNIT: deux ecritures de cellule dans un cycle" severity failure;
                        -- pragma translate_on
                        wr_en   := true;
                        wr_idx  := idx;
                        wr_cell := ( valid => '1', dirty => '0',
                                            addr => CUT( source_address_s( source_index_s ) ),
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
                        inv_m( mem_cell_index_s ) := '1';
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
                        rinv_m( ret_mem_cell_index_s ) := '1';
                        if ret_after_spill_fill_s = '1' then
                           mem_address_s <= CUT( frame_s.rsp );
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
                     -- Adresse de retour non realisable (INO_PADDR) : RTD faute (132).
                     if MEM_RSP_i.fault = '1' or not PA_OK( unsigned( MEM_RSP_i.rdata ) ) then
                        commit_s <= ( valid => '1', slot => slot_s,
                                      fault => ( valid => '1', code => FAULT_ACCESS ),
                                      taken => '0', target => ( others => '0' ) );
                        state_s <= ST_FAULT_HOLD;
                     else
                        ridx := RWIDX( frame_s.rsp );
                        -- pragma translate_off
                        assert not rwr_en report "STACK_UNIT: deux ecritures de cellule dans un cycle" severity failure;
                        -- pragma translate_on
                        rwr_en   := true;
                        rwr_idx  := ridx;
                        rwr_cell := ( valid => '1', dirty => '0', addr => CUT( frame_s.rsp ),
                             data => std_logic_vector( CUT( unsigned( MEM_RSP_i.rdata ) ) ) );
                        return_target_s <= CUT( unsigned( MEM_RSP_i.rdata ) );
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
                     -- Port 0 : cellule idx.
                     if rd( 0 ).valid = '1'
                        and rd( 0 ).addr = a
                        and rd( 0 ).dirty = '1'
                        and rd( 0 ).addr <= old_dsp_s then
                        mem_cell_index_s <= idx;
                        mem_address_s    <= CUT( a );
                        mem_data_s       <= rd( 0 ).data;
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
                        cln_m( mem_cell_index_s ) := '1';
                        coh_index_s <= coh_index_s + 1;
                        state_s <= ST_COH_SCAN;
                     end if;
                  end if;

               -------------------------------------------------------------------------
               -- Exécution. L'état architectural reste inchangé jusqu'à COMPLETE.
               -------------------------------------------------------------------------

               when ST_ISSUE =>
                  -- pragma translate_off
                  assert not ( ISSUE_READY_i = '0' and complete_w.valid = '1' )
                     report "STACK_UNIT: COMPLETE avant l'acceptation de l'émission"
                     severity failure;
                  -- pragma translate_on
                  if ISSUE_READY_i = '1' then
                     state_s <= ST_WAIT_EXEC;
                     if complete_w.valid = '1' then
                        -- Terminaison dans le cycle d'émission (V3).
                        if fast_s = '0' then
                           -- Chemin lent : commit (ports de lecture) en ST_WAIT_EXEC.
                           complete_q_s <= complete_w;
                        elsif complete_w.fault.valid = '1' then
                           commit_s <= ( valid => '1', slot => slot_s, fault => complete_w.fault,
                                         taken => complete_w.taken, target => complete_w.target );
                           state_s <= ST_FAULT_HOLD;
                        else
                           fast_commit_v := true;
                        end if;
                     end if;
                  end if;

               when ST_WAIT_EXEC =>
                  -- pragma translate_off
                  assert not ( fast_s = '1' and MAINT_i.valid = '1' )
                     report "STACK_UNIT: maintenance pendant une instruction du chemin rapide"
                     severity failure;
                  -- pragma translate_on
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

                  elsif cpl.valid = '1' then
                     complete_q_s.valid <= '0';
                     if cpl.fault.valid = '1' then
                        commit_s <= ( valid => '1', slot => slot_s, fault => cpl.fault,
                                      taken => cpl.taken, target => cpl.target );
                        state_s <= ST_FAULT_HOLD;
                     elsif fast_s = '1' then
                        -- Commit du chemin rapide : après le case (fast_commit_v).
                        fast_commit_v := true;

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
                                 INVALIDATE_CELL( inv_m, rd( 2 + k ), a );
                              end if;
                           end loop;
                        end if;

                        -- Parcours unique des cellules pour LINK, UNLINK/UNLINKR et RTD :
                        -- les correspondances d'une plage ( range_lo, range_hi ] deviennent
                        -- invalides.
                        --   LINK       : ( old_dsp, new_dsp ], sauf pour lvl > 0 la cellule
                        --                old_dsp + 8, dans laquelle on installe juste après
                        --                l'ancien DISPLAY[lvl]. Ne pas programmer à la fois son
                        --                invalidation et son remplacement : avec un index de
                        --                tableau dynamique, ces affectations partielles
                        --                concurrentes peuvent laisser la cellule invalidée
                        --                après le delta-cycle.
                        --   UNLINK     : ( new_dsp, old_dsp ], cellule du FP sauvé comprise.
                        --   RTD n      : ( new_dsp, old_dsp ] ; ces cellules mortes ne doivent
                        --                surtout pas être rangées.
                        if IS_LINK_OP( slot_s.canon.op ) or IS_UNLINK_OP( slot_s.canon.op )
                           or IS_RTD_OP( slot_s.canon.op ) then
                           if IS_LINK_OP( slot_s.canon.op ) then
                              range_lo   := old_dsp_s;
                              range_hi   := new_dsp_s;
                              range_keep := to_integer( slot_s.canon.lvl ) > 0;
                           else
                              range_lo   := new_dsp_s;
                              range_hi   := old_dsp_s;
                              range_keep := false;
                           end if;
                           for j in 0 to STACK_CACHE_WORDS_G - 1 loop
                              if cells_s( j ).valid = '1'
                                 and cells_s( j ).addr > range_lo
                                 and cells_s( j ).addr <= range_hi
                                 and not ( range_keep and cells_s( j ).addr = old_dsp_s + 8 ) then
                                 inv_m( j ) := '1';
                              end if;
                           end loop;
                        end if;

                        -- LINK/UNLINK/UNLINKR modifient DSP/DISPLAY de façon non linéaire.
                        -- L'effet de co-pile a déjà été rendu atomiquement par COMPLEX_UNIT ;
                        -- l'état de frame ne devient visible qu'ici, après succès complet.
                        if IS_LINK_OP( slot_s.canon.op ) then
                           clvl := to_integer( slot_s.canon.lvl );
                           -- Zone locale invalidée par le parcours commun ci-dessus. La
                           -- cellule du FP sauvegardé est réinstallée ici.
                           if clvl > 0 then
                              a := old_dsp_s + 8;
                              idx := WIDX( a );
                              -- pragma translate_off
                              assert not wr_en report "STACK_UNIT: deux ecritures de cellule dans un cycle" severity failure;
                              -- pragma translate_on
                              wr_en   := true;
                              wr_idx  := idx;
                              wr_cell := ( valid => '1', dirty => '1', addr => CUT( a ),
                                                  data => std_logic_vector( frame_s.display( clvl ) ) );
                              frame_s.display( clvl ) <= CUT( a );
                           end if;
                           frame_s.dsp <= new_dsp_s;

                        elsif IS_UNLINK_OP( slot_s.canon.op ) then
                           clvl := to_integer( slot_s.canon.lvl );
                           -- Tout le frame courant est mort : parcours commun ci-dessus.
                           frame_s.dsp <= new_dsp_s;
                           frame_s.display( clvl ) <= CUT( unsigned( source_value_s( 0 ) ) );

                        -- CALL/CALLI et RTD ont un effet architectural supplémentaire
                        -- sur RSP et sur la pile de retours. Rien n'a été modifié avant
                        -- cette terminaison sans faute.
                        elsif IS_CALL_OP( slot_s.canon.op ) then
                           -- CALLI dépile sa cible de la pile data ; CALL direct n'y
                           -- touche pas. L'adresse de retour est le PC suivant.
                           for j in 0 to 3 loop
                              if j < source_count_s then
                                 INVALIDATE_CELL( inv_m, rd( j ), source_address_s( j ) );
                              end if;
                           end loop;
                           frame_s.dsp <= new_dsp_s;
                           frame_s.rsp <= new_rsp_s;
                           ridx := RWIDX( new_rsp_s );
                           -- pragma translate_off
                           assert not rwr_en report "STACK_UNIT: deux ecritures de cellule dans un cycle" severity failure;
                           -- pragma translate_on
                           rwr_en   := true;
                           rwr_idx  := ridx;
                           rwr_cell := ( valid => '1', dirty => '1', addr => CUT( new_rsp_s ),
                                data => std_logic_vector( CUT(
                                   slot_s.pc + resize( slot_s.canon.len, 64 ) ) ) );

                        elsif IS_RTD_OP( slot_s.canon.op ) then
                           -- RTD n abandonne n octets de pile data : cellules mortes
                           -- invalidées par le parcours commun ci-dessus.
                           frame_s.dsp <= new_dsp_s;
                           ridx := RWIDX( frame_s.rsp );
                           if rrd.valid = '1'
                              and rrd.addr = frame_s.rsp then
                              rinv_m( ridx ) := '1';
                           end if;
                           frame_s.rsp <= CUT( frame_s.rsp + 8 );

                        -- Les cellules réellement dépilées deviennent mortes. Le résultat,
                        -- s'il existe, est ensuite installé à sa nouvelle adresse.
                        elsif entry_s.stack_action = STACK_LINEAR then
                           for j in 0 to 3 loop
                              if j < source_count_s then
                                 INVALIDATE_CELL( inv_m, rd( j ), source_address_s( j ) );
                              end if;
                           end loop;
                           frame_s.dsp <= new_dsp_s;

                           if entry_s.pushes = 1 then
                              -- pragma translate_off
                              assert cpl.result_valid = '1'
                                 report "STACK_UNIT: resultat attendu mais absent"
                                 severity failure;
                              -- pragma translate_on
                              idx := WIDX( destination_address_s );
                              -- pragma translate_off
                              assert not wr_en report "STACK_UNIT: deux ecritures de cellule dans un cycle" severity failure;
                              -- pragma translate_on
                              wr_en   := true;
                              wr_idx  := idx;
                              wr_cell := ( valid => '1', dirty => '1',
                                                  addr => CUT( destination_address_s ),
                                                  data => cpl.result );
                           end if;

                        elsif entry_s.stack_action = STACK_KEEP_TOP then
                           -- CHK : lecture seulement, aucune modification de pile.
                           null;
                        end if;

                        commit_s <= ( valid => '1', slot => slot_s, fault => NO_FAULT,
                                      taken => cpl.taken, target => cpl.target );
                        if entry_s.control and MISPREDICTED( slot_s, cpl ) then
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
                     -- Port 0 : cellule idx.
                     if rd( 0 ).valid = '1'
                        and ( maint_s.kind = MAINT_WRITEBACK_ALL
                              or IN_RANGE( rd( 0 ).addr, maint_s.base, maint_s.length ) ) then

                        if maint_s.kind = MAINT_INVALIDATE_RANGE then
                           inv_m( idx ) := '1';
                           maint_index_s <= maint_index_s + 1;

                        elsif rd( 0 ).dirty = '1' and rd( 0 ).addr <= frame_s.dsp then
                           mem_cell_index_s <= idx;
                           mem_address_s    <= CUT( rd( 0 ).addr );
                           mem_data_s       <= rd( 0 ).data;
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
                        if rd( 0 ).valid = '1'
                           and rd( 0 ).addr = mem_address_s then
                           cln_m( mem_cell_index_s ) := '1';
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
                     if rrd.valid = '1'
                        and rrd.dirty = '1' then
                        ret_mem_cell_index_s <= ridx;
                        mem_address_s        <= CUT( rrd.addr );
                        mem_data_s           <= rrd.data;
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
                        if rrd.valid = '1'
                           and rrd.addr = mem_address_s then
                           rcln_m( ret_mem_cell_index_s ) := '1';
                        end if;
                     end if;
                     ret_maint_index_s <= ret_maint_index_s + 1;
                     state_s <= ST_MAINT_RET_SCAN;
                  end if;

            end case;

            -------------------------------------------------------------------------
            -- Commit d'une instruction du chemin rapide (STACK_LINEAR), en
            -- ST_WAIT_EXEC ou dès ST_ISSUE (V3) : invalidations décidées à la prise
            -- (sources dépilées, copies recouvertes par un rangement direct), puis
            -- résultat. Aucun port de lecture : ils servent à la prise suivante
            -- (chain_s), qui suit ce bloc et en remplace state_s.
            -------------------------------------------------------------------------

            if fast_commit_v then
               for j in 0 to 3 loop
                  if cp_inv_en_s( j ) = '1' then
                     inv_m( cp_inv_idx_s( j ) ) := '1';
                  end if;
               end loop;
               frame_s.dsp <= new_dsp_s;
               if destination_valid_s = '1' then
                  -- pragma translate_off
                  assert cpl.result_valid = '1'
                     report "STACK_UNIT: resultat attendu mais absent"
                     severity failure;
                  -- pragma translate_on
                  idx := WIDX( destination_address_s );
                  -- pragma translate_off
                  assert not wr_en report "STACK_UNIT: deux ecritures de cellule dans un cycle" severity failure;
                  -- pragma translate_on
                  wr_en   := true;
                  wr_idx  := idx;
                  wr_cell := ( valid => '1', dirty => '1',
                                      addr => CUT( destination_address_s ),
                                      data => cpl.result );
               end if;
               commit_s <= ( valid => '1', slot => slot_s, fault => NO_FAULT,
                             taken => cpl.taken, target => cpl.target );
               if entry_s.control and MISPREDICTED( slot_s, cpl ) then
                  state_s <= ST_MISPRED_HOLD;
               else
                  state_s <= ST_IDLE;
               end if;
            end if;

            -------------------------------------------------------------------------
            -- Prise d'une instruction : en ST_IDLE, ou au cycle d'un commit du
            -- chemin rapide (chain_s, V2). Dans ce dernier cas les affectations
            -- ci-dessous (state_s, slot_s...) remplacent celles du commit, qui ne
            -- concernent que l'instruction sortante ; le décodage (s, e, f, ndsp...)
            -- et les ports de lecture voient l'état d'après le commit (tdsp, rd).
            -------------------------------------------------------------------------

            if take_v then
               -- s, e, f, npop, lvl, ndsp, nrsp : décodage de la prise, calculé
               -- avant le case (il sert aussi aux indices des ports de lecture).

               slot_s              <= s;
               entry_s             <= e;
               old_dsp_s           <= CUT( tdsp );
               new_dsp_s           <= CUT( ndsp );
               new_rsp_s           <= CUT( nrsp );
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
                  coh_base_s     <= CUT( a( 63 downto 3 ) & "000" );
                  coh_length_s   <= to_unsigned( 8, 64 );

               elsif e.memory and not e.frame and not IS_SYSTEM_OP( s.canon.op )
                  and to_integer( s.canon.lvl ) <= 14 then
                  -- LINK/UNLINK portent memory=true parce que COMPLEX_UNIT accède
                  -- à la co-pile. Ce ne sont pas des accès mémoire adressés par
                  -- lvl/val dans la pile data : ne pas déclencher ici la cohérence
                  -- générique du cache de pile.
                  a := frame_s.display( to_integer( s.canon.lvl ) ) + U64( s.canon.val );
                  coh_required_s <= '1';
                  coh_base_s     <= CUT( a );

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
                     destination_address_s <= CUT( tdsp + 8 );
                  end if;
               elsif IS_UNLINK_OP( s.canon.op ) then
                  -- FP sauvegardé par LINK, restauré au commit si la lecture de co-pile réussit.
                  nsrc := 1;
                  source_address_s( 0 ) <= CUT( frame_s.display( lvl ) );
               else
                  case e.stack_action is
                     when STACK_LINEAR =>
                        nsrc := npop;
                        for j in 0 to 3 loop
                           if j < npop then
                              source_address_s( j ) <= CUT( tdsp - 8 * ( npop - 1 - j ) );
                           end if;
                        end loop;
                        if e.pushes = 1 then
                           destination_valid_s   <= '1';
                           destination_address_s <= CUT( ndsp );
                        end if;

                     when STACK_KEEP_TOP =>
                        nsrc := 1;
                        source_address_s( 0 ) <= CUT( tdsp );

                     when STACK_DUP =>
                        nsrc := 1;
                        source_address_s( 0 ) <= CUT( tdsp );
                        destination_valid_s   <= '1';
                        destination_address_s <= CUT( ndsp );

                     when STACK_OVER =>
                        nsrc := 1;
                        source_address_s( 0 ) <= CUT( tdsp - 8 );
                        destination_valid_s   <= '1';
                        destination_address_s <= CUT( ndsp );

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

               ------------------------------------------------------------------
               -- FAST PATH de préparation.
               --
               -- Le chemin initial lisait une source de pile par cycle dans
               -- ST_PREPARE, puis passait seulement à ST_ISSUE. Pour les
               -- opérations ordinaires, toutes les cellules nécessaires sont
               -- dans un petit tableau de registres ; les lire en parallèle ne
               -- demande aucun mécanisme OoO.
               --
               -- Si toutes les sources sont des hits et si la destination peut
               -- être remplacée sans SPILL, on saute directement à ST_ISSUE.
               -- DROP/DUP/OVER peuvent même committer ici. Tout cas douteux
               -- retombe exactement sur le chemin lent déjà validé.
               ------------------------------------------------------------------
               fast_ok        := false;
               local_ld       := false;
               local_st       := false;
               fast_values    := ( others => ( others => '0' ) );
               fast_dst_addr  := ndsp;
               fast_dst_valid := false;

               if f.valid = '0' then
                  if IS_FAST_STACK_OP( s.canon.op ) then
                     fast_ok := true;
                  elsif e.issue_class = ISSUE_INTEGER
                     and e.lvl_use = LVL_NONE
                     and not e.memory and not e.frame
                     and not e.serializing and not e.control then
                     fast_ok := true;
                  elsif ( e.issue_class = ISSUE_MUL_DIV or e.issue_class = ISSUE_FLOAT )
                     and e.lvl_use = LVL_NONE
                     and not e.memory and not e.frame
                     and not e.serializing and not e.control then
                     -- MUL/DIV (V2), flottant (étude IPC x f) : STACK_LINEAR, un
                     -- résultat, comme l'entier.
                     fast_ok := true;
                  elsif e.issue_class = ISSUE_BRANCH
                     and IS_FAST_BRANCH_OP( s.canon.op ) then
                     fast_ok := true;
                  elsif e.issue_class = ISSUE_MEMORY
                     and e.lvl_use = LVL_ADDR
                     and IS_FAST_MEMORY_OP( s.canon.op )
                     -- lvl 0..14 : les ports 1..3 servent aux cellules recouvertes.
                     and ( ( lvl <= 14 and nsrc <= 1 ) or lvl = 15 ) then
                     -- Familles B et C. lvl 0..14 : l'adresse (accès, ou cellule
                     -- pointeur en famille C) est DISPLAY[lvl]+val ; seuls les hits
                     -- de pile et l'absence de cellule sale recouverte permettent de
                     -- sauter PREPARE/COH. lvl = 15 (V4) : adresse sur la pile, accès
                     -- calculé, aucun sondage (V8).
                     fast_ok := true;
                  elsif IS_LVA_OP( s.canon.op ) then
                     -- LVA (V4) : entier ; la cellule exposée (lvl 0..14) ne doit pas
                     -- être une cellule sale vivante (sinon ST_COH_SCAN la range).
                     fast_ok := true;
                  end if;
               end if;

               if fast_ok then
                  -- Toutes les sources doivent déjà être dans le cache.
                  -- L'ordre est le même que source_address_s / RENAME_DISPATCH.
                  for j in 0 to 3 loop
                     if j < nsrc then
                        case e.stack_action is
                           when STACK_LINEAR =>
                              fast_addr := tdsp - 8 * ( npop - 1 - j );
                           when STACK_KEEP_TOP | STACK_DUP =>
                              fast_addr := tdsp;
                           when STACK_OVER =>
                              fast_addr := tdsp - 8;
                           when STACK_DROP =>
                              fast_addr := tdsp; -- non utilisé (nsrc=0)
                        end case;

                        -- Port j : cellule WIDX( fast_src( j ) ), fast_src( j ) = fast_addr.
                        if rd( j ).valid = '1'
                           and rd( j ).addr = fast_addr then
                           fast_values( j ) := rd( j ).data;
                        else
                           fast_ok := false;
                        end if;
                     end if;
                  end loop;

                  -- Même critère de collision que ST_PREPARE : une ancienne
                  -- cellule sale encore vivante doit être rangée avant réemploi.
                  if e.stack_action = STACK_DUP or e.stack_action = STACK_OVER then
                     fast_dst_valid := true;
                     fast_dst_addr  := ndsp;
                  elsif e.stack_action = STACK_LINEAR and e.pushes = 1 then
                     fast_dst_valid := true;
                     fast_dst_addr  := ndsp;
                  end if;

                  if fast_dst_valid then
                     -- Port 4 : cellule WIDX( ndsp ), et fast_dst_addr = ndsp.
                     if rd( 4 ).valid = '1'
                        and rd( 4 ).addr /= fast_dst_addr
                        and rd( 4 ).dirty = '1'
                        and rd( 4 ).addr <= tdsp then
                        fast_ok := false;
                     end if;
                  end if;

                  -- Un accès direct simple peut éviter ST_COH_SCAN uniquement si
                  -- aucune cellule de pile sale recouverte n'a besoin d'être
                  -- réécrite. Trois cellules de 8 octets suffisent pour une plage
                  -- d'au plus 8 octets, même non alignée. Le store conservera
                  -- l'invalidation postérieure via coh_invalidate_s au COMMIT.
                  -- Mêmes plages que ST_COH_SCAN : LVA, la cellule alignée qui contient
                  -- l'adresse ; famille C, la cellule pointeur (8 octets) ; famille B,
                  -- les octets de l'accès.
                  if fast_ok and lvl <= 14
                     and ( e.issue_class = ISSUE_MEMORY or IS_LVA_OP( s.canon.op ) ) then
                     fast_mem_base := frame_s.display( lvl ) + U64( s.canon.val );
                     if IS_LVA_OP( s.canon.op ) then
                        fast_mem_base := fast_mem_base( 63 downto 3 ) & "000";
                        fast_mem_len  := to_unsigned( 8, 64 );
                     elsif s.canon.op( 7 downto 6 ) = "10" then
                        fast_mem_len  := to_unsigned( 8, 64 );
                     else
                        fast_mem_len  := to_unsigned(
                           2 ** to_integer( unsigned( s.canon.op( 1 downto 0 ) ) ), 64 );
                     end if;
                     -- Chargement direct de famille B contenu dans une cellule vivante
                     -- présente (port 1 : cellule fast_mem( 0 )) : servi localement.
                     ld_off := to_integer( fast_mem_base( 2 downto 0 ) );
                     if e.issue_class = ISSUE_MEMORY and s.canon.op( 7 downto 6 ) = "01"
                        and s.canon.op( 5 downto 4 ) /= "10"
                        and ld_off + to_integer( fast_mem_len( 3 downto 0 ) ) <= 8
                        and rd( 1 ).valid = '1' and rd( 1 ).addr = fast_mem( 0 )
                        and rd( 1 ).addr <= tdsp then
                        local_ld := true;
                        fast_values( 0 ) := CELL_EXTRACT( rd( 1 ).data, ld_off,
                           to_integer( unsigned( s.canon.op( 1 downto 0 ) ) ),
                           s.canon.op( 5 downto 4 ) = "01" );
                     elsif e.issue_class = ISSUE_MEMORY and s.canon.op( 7 downto 6 ) = "01"
                        and s.canon.op( 5 downto 4 ) = "10"
                        and ld_off + to_integer( fast_mem_len( 3 downto 0 ) ) <= 8
                        and nsrc = 1
                        and rd( 1 ).valid = '1' and rd( 1 ).addr = fast_mem( 0 )
                        and rd( 1 ).dirty = '1' and rd( 1 ).addr < tdsp then
                        -- Rangement direct dans une cellule vivante sale, sous le sommet
                        -- (port 0 : la valeur rangée, au sommet).
                        local_st := true;
                        fast_values( 0 ) := CELL_MERGE( rd( 1 ).data, fast_values( 0 ), ld_off,
                           to_integer( unsigned( s.canon.op( 1 downto 0 ) ) ) );
                     else
                        for k in 0 to 2 loop
                           a := ( fast_mem_base( 63 downto 3 ) & "000" )
                                + to_unsigned( 8 * k, 64 );
                           if a < fast_mem_base + fast_mem_len then
                              -- Port 1 + k : cellule WIDX( fast_mem( k ) ), fast_mem( k ) = a.
                              if rd( 1 + k ).valid = '1'
                                 and rd( 1 + k ).addr = a
                                 and rd( 1 + k ).dirty = '1'
                                 and rd( 1 + k ).addr <= tdsp then
                                 fast_ok := false;
                              end if;
                           end if;
                        end loop;
                     end if;
                  end if;
               end if;

               -- Commit du chemin rapide décidé à la prise (V2) : cellules qu'il
               -- invalidera. Aucune ne change d'ici au commit ; la destination, écrite
               -- après, n'est pas invalidée.
               cp_en  := ( others => '0' );
               cp_idx := ( others => 0 );
               fast_dst_idx := WIDX( ndsp );
               if fast_ok then
                  if e.stack_action = STACK_LINEAR then
                     -- Sources dépilées : présentes (fast path).
                     for j in 0 to 3 loop
                        if j < nsrc and not ( fast_dst_valid
                                              and WIDX( fast_src( j ) ) = fast_dst_idx ) then
                           cp_en( j )  := '1';
                           cp_idx( j ) := WIDX( fast_src( j ) );
                        end if;
                     end loop;
                  elsif e.stack_action = STACK_DROP then
                     -- Port 0 : cellule du sommet.
                     if rd( 0 ).valid = '1' and rd( 0 ).addr = tdsp then
                        cp_en( 0 )  := '1';
                        cp_idx( 0 ) := WIDX( tdsp );
                     end if;
                  end if;
                  if e.issue_class = ISSUE_MEMORY and lvl <= 14 and not local_st
                     and s.canon.op( 7 downto 6 ) = "01" and s.canon.op( 5 downto 4 ) = "10" then
                     -- Rangement direct (famille B, lvl 0..14) : copies du cache de pile
                     -- qui intersectent les octets rangés (même règle que
                     -- coh_invalidate_s ; un rangement calculé n'en a pas, V8).
                     for k in 0 to 2 loop
                        a := ( fast_mem_base( 63 downto 3 ) & "000" ) + to_unsigned( 8 * k, 64 );
                        if a < fast_mem_base + fast_mem_len
                           and rd( 1 + k ).valid = '1' and rd( 1 + k ).addr = a then
                           cp_en( 1 + k )  := '1';
                           cp_idx( 1 + k ) := WIDX( a );
                        end if;
                     end loop;
                  end if;
               end if;
               cp_inv_en_s  <= cp_en;
               cp_inv_idx_s <= cp_idx;

               -- Préparation rapide d'un appel ou d'un cadre (V5) : mêmes critères
               -- que ST_PREPARE, évalués sur les ports de la prise. RSP, DISPLAY et
               -- le cache des retours ne changent pas au commit d'une instruction du
               -- chemin rapide : rrd et frame_s sont ceux d'après commit.
               prep_ok := false;
               if not fast_ok and f.valid = '0' then
                  if IS_LINK_OP( s.canon.op ) then
                     -- Port 0 : cellule WIDX( tdsp + 8 ).
                     prep_ok := lvl = 0
                                or not ( rd( 0 ).valid = '1' and rd( 0 ).addr /= tdsp + 8
                                         and rd( 0 ).dirty = '1' and rd( 0 ).addr <= tdsp );
                  elsif IS_UNLINK_OP( s.canon.op ) then
                     -- Port 0 : cellule WIDX( DISPLAY( lvl ) ). FP sauvegardé non
                     -- réalisable : chemin lent (faute avant émission).
                     if lvl <= 14 and rd( 0 ).valid = '1' and rd( 0 ).addr = frame_s.display( lvl )
                        and PA_OK( unsigned( rd( 0 ).data ) ) then
                        prep_ok := true;
                        fast_values( 0 ) := rd( 0 ).data;
                     end if;
                  elsif IS_CALL_OP( s.canon.op ) then
                     -- CALLI : sa cible au sommet (port 0) ; cellule du futur RSP sans
                     -- autre occupant sale.
                     prep_ok := not ( rrd.valid = '1' and rrd.addr /= nrsp and rrd.dirty = '1' );
                     for j in 0 to 3 loop
                        if j < nsrc then
                           if rd( j ).valid = '1' and rd( j ).addr = fast_src( j ) then
                              fast_values( j ) := rd( j ).data;
                           else
                              prep_ok := false;
                           end if;
                        end if;
                     end loop;
                  elsif IS_RTD_OP( s.canon.op ) then
                     prep_ok := nsrc = 0 and rrd.valid = '1' and rrd.addr = frame_s.rsp;
                  end if;
               end if;

               if fast_ok then
                  fast_s <= '1';
                  source_value_s <= fast_values;
                  source_index_s <= nsrc;

                  if local_st then
                     -- La cellule rangée devient la « destination » du commit local :
                     -- ST_FAST_COMMIT l'écrit (sale) avec source_value_s( 0 ), fusionnée.
                     destination_valid_s   <= '1';
                     destination_address_s <= CUT( fast_mem( 0 ) );
                  end if;
                  if e.issue_class = ISSUE_NONE or local_ld or local_st then
                     -- Les trois manipulations de pile, et les chargements servis
                     -- par le cache de pile (V5), sont entièrement locales,
                     -- mais ne doivent pas COMMITTER sur le même front que
                     -- DECODE_TAKE. Les consommateurs de STACK_UNIT utilisent le
                     -- contrat historique : prise au cycle N, terminaison au plus
                     -- tôt au cycle N+1. ST_FAST_COMMIT conserve ce contrat tout
                     -- en évitant ST_PREPARE et toute émission backend.
                     state_s <= ST_FAST_COMMIT;
                  else
                     -- INTEGER, MUL/DIV, FLOAT, BRA/BT/BF et accès : l'émission
                     -- devient visible dès le cycle suivant la prise.
                     state_s <= ST_ISSUE;
                  end if;
               elsif prep_ok then
                  fast_s <= '0';
                  source_value_s <= fast_values;
                  source_index_s <= nsrc;
                  if IS_RTD_OP( s.canon.op ) then
                     return_target_s <= CUT( unsigned( rrd.data ) );
                  end if;
                  state_s <= ST_ISSUE;
               else
                  fast_s  <= '0';
                  state_s <= ST_PREPARE;
               end if;
            end if;
            ------------------------------------------------------------------
            -- ECRITURES des caches de pile : masques, puis port d'écriture.
            ------------------------------------------------------------------
            for j in 0 to STACK_CACHE_WORDS_G - 1 loop
               if wr_en and wr_idx = j then
                  cells_s( j ) <= wr_cell;
               elsif inv_m( j ) = '1' then
                  cells_s( j ).valid <= '0';
                  cells_s( j ).dirty <= '0';
               elsif cln_m( j ) = '1' then
                  cells_s( j ).dirty <= '0';
               end if;
            end loop;
            for j in 0 to RETURN_CACHE_WORDS_G - 1 loop
               if rwr_en and rwr_idx = j then
                  return_cells_s( j ) <= rwr_cell;
               elsif rinv_m( j ) = '1' then
                  return_cells_s( j ).valid <= '0';
                  return_cells_s( j ).dirty <= '0';
               elsif rcln_m( j ) = '1' then
                  return_cells_s( j ).dirty <= '0';
               end if;
            end loop;
         end if;

         -- Ecriture d'une entrée de DISPLAY par SYSTEM_UNIT, avant une SYNC
         -- (même contrat que SYNC : aucune instruction ni maintenance en cours).
         if RESET_i = '0' and DISP_WE_i = '1' and DISP_WSEL_i <= 14 then
            -- pragma translate_off
            assert state_s = ST_IDLE or state_s = ST_FAULT_HOLD
               report "STACK_UNIT: ecriture de DISPLAY pendant une instruction ou une maintenance"
               severity failure;
            -- pragma translate_on
            frame_s.display( to_integer( DISP_WSEL_i ) ) <= CUT( TO_VA( DISP_WDATA_i ) );
         end if;
      end if;
   end process SEQUENTIAL;

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
