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
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  LOAD_STORE_QUEUE, architecture RTL : modèle de référence, première étape
		--  (le cœur ; voir le contrat de l'entité).
		--
		--  Entrées sans ordre (l'âge se lit dans rob_index ; un rangement validé est
		--  plus ancien que toute entrée non validée, et les validés sont ordonnés par
		--  leur numéro de validation). Chaque entrée avance par étapes : cellule
		--  pointeur (famille C), puis selon son genre : lecture (chargement), sondage
		--  (rangement), deux bornes (CHK) ; LIVA s'arrête après le pointeur.
		--
		--  Plan du cycle (combinatoire, sur l'état) : pour chaque entrée, sa prochaine
		--  action. Une lecture (donnée, cellule pointeur, borne) suit l'ordre prudent
		--  (READ_STEP) : attendre, transférer depuis un rangement plus ancien, ou lire
		--  le cache. Requêtes : le port 0 écrit d'abord le plus ancien rangement validé ;
		--  les autres places vont aux actions les plus anciennes. Résultats : les
		--  MEMORY_LANES plus anciens prêts.
		--  Au front : requêtes acceptées (file de chaque port), réponses, transferts,
		--  EXEC_i, retraits, résultats envoyés, reprise, réservations.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of LOAD_STORE_QUEUE is		---

   constant PORTS		: positive := MEMORY_LANES;
   constant FIFO_DEPTH		: positive := 16;

   type kind_t			is ( K_LOAD, K_STORE, K_LIVA, K_CHK, K_SPILL, K_FILL, K_BARRIER );
   type purpose_t		is ( P_NONE, P_PTR, P_DATA, P_FST, P_LST, P_PROBE, P_WRITE );

   type entry_t		is record
			  valid		: std_logic;
			  rob_index	: rob_index_t;
			  kind		: kind_t;
			  fam_c		: boolean;
			  sz		: natural range 0 to 3;		-- taille 2^sz octets
			  sgn		: boolean;			-- extension de signe (MODE 01)
			  ofs		: natural range 0 to 255;
			  tag		: physical_tag_t;
			  cell_known	: boolean;			-- famille C : cellule pointeur
			  cell		: address_t;
			  ptr_done	: boolean;			-- famille C : pointeur lu
			  ea_known	: boolean;
			  ea		: address_t;
			  data_known	: boolean;
			  data		: word64_t;
			  fst_done	: boolean;
			  fst		: word64_t;
			  lst_done	: boolean;
			  lst		: word64_t;
			  probed		: boolean;
			  busy		: boolean;			-- une requête en vol
			  ready		: boolean;			-- résultat prêt
			  value		: word64_t;
			  fault		: natural range 0 to 255;	-- 0, 131, 132
			  reported	: boolean;			-- rangement : fin d'exécution envoyée
			  committed	: boolean;			-- rangement retiré
			  cseq		: natural;			-- ordre de validation
			  gen		: natural range 0 to 255;	-- génération de l'entrée
			  data_tag	: physical_tag_t;		-- SPILL, rangement : registre de la donnée
			  data_ready	: boolean;			-- SPILL, rangement : registre réveillé
			  wlen		: address_t;			-- barrière : longueur écrite (ea : base)
			  ptr_store	: boolean;			-- rangement par pointeur : STACK_INVALIDATE
			  completes	: boolean;			-- FILL : termine son instruction
			  cx		: boolean;			-- réservé par COMPLEX : LINK (rangement),
								--  UNLINK, UNLINKR (chargement)
			end record;
   type entry_array_t		is array( 0 to DEPTH_G - 1 ) of entry_t;

   type fifo_item_t		is record
			  entry		: natural range 0 to DEPTH_G - 1;
			  rob_index	: rob_index_t;
			  purpose		: purpose_t;
			  gen		: natural range 0 to 255;	-- une réponse périmée (entrée
			end record;						--  réattribuée, même rob_index)
   type fifo_t			is array( 0 to FIFO_DEPTH - 1 ) of fifo_item_t;
   type fifo_array_t		is array( 0 to PORTS - 1 ) of fifo_t;
   type nat_ports_t		is array( 0 to PORTS - 1 ) of natural range 0 to FIFO_DEPTH;

   -- plan du cycle
   type step_t			is ( S_WAIT, S_FORWARD, S_ISSUE );
   type plan_entry_t		is record
			  step		: step_t;
			  purpose		: purpose_t;
			  address		: address_t;
			  sz		: natural range 0 to 3;
			  fwd		: word64_t;			-- S_FORWARD : octets lus, non étendus
			end record;
   type plan_array_t		is array( 0 to DEPTH_G - 1 ) of plan_entry_t;
   type port_pick_t		is array( 0 to PORTS - 1 ) of integer range -1 to DEPTH_G - 1;
   type lane_pick_t		is array( 0 to MEMORY_LANES - 1 ) of integer range -1 to DEPTH_G - 1;

   signal e			: entry_array_t;
   signal fifo			: fifo_array_t;
   signal fhead, fcount	: nat_ports_t;
   signal next_cseq		: natural;
   signal plan			: plan_array_t;
   signal port_pick		: port_pick_t;				-- entrée servie par chaque port
   signal port_purpose		: purpose_t;				-- (port 0 : écriture validée)
   signal lane_pick		: lane_pick_t;				-- résultats présentés
   signal free_count		: natural range 0 to DEPTH_G;
   constant CAPTURES		: positive := MEMORY_LANES * MAX_SOURCE_COUNT;	-- lectures de SPILL par cycle
   type capture_pick_t		is array( 0 to CAPTURES - 1 ) of integer range -1 to DEPTH_G - 1;
   signal capture_pick		: capture_pick_t;

		--------------------------------------------------------------------------------
		-- Outils
		--------------------------------------------------------------------------------

   -- clé d'âge : plus petite = plus ancienne ; validés d'abord, par validation
   function AGE_KEY( x : entry_t; head : rob_index_t ) return natural is
   begin
      if x.committed then
         return x.cseq mod 2 ** 20;
      end if;
      return 2 ** 20 + ( to_integer( x.rob_index ) - to_integer( head ) ) mod ROB_SIZE;
   end function;

   function MIN( a, b : natural ) return natural is			-- minimum : VHDL-2008 seulement
   begin
      if a < b then return a; else return b; end if;
   end function;

   function EXTEND( w : word64_t; sz : natural; sgn : boolean ) return word64_t is
      variable r : word64_t := ( others => '0' );
      constant n : natural := 8 * 2 ** sz;
   begin
      r( n - 1 downto 0 ) := w( n - 1 downto 0 );
      if sgn and n < 64 and w( n - 1 ) = '1' then
         r( 63 downto n ) := ( others => '1' );
      end if;
      return r;
   end function;

   -- [a, a + na) et [b, b + nb) se recouvrent / le second couvre le premier
   function OVERLAP( a : address_t; na : natural; b : address_t; nb : natural ) return boolean is
   begin
      return a < b + nb and b < a + na;
   end function;

   function COVERS( b : address_t; nb : natural; a : address_t; na : natural ) return boolean is
   begin
      return b <= a and a + na <= b + nb;
   end function;

   -- la donnée vient d'un registre (réveil, capture) : SPILL, rangement ordinaire
   -- (celle d'un rangement de LINK vient de COMPLEX_UNIT, par EXEC_i)
   function HAS_DATA_TAG( x : entry_t ) return boolean is
   begin
      return x.kind = K_SPILL or ( x.kind = K_STORE and not x.cx );
   end function;

   -- la règle de validité de DATA_CACHE (mêmes génériques) : les rangements sans sondage
   function VALID_ACCESS( a : address_t; n : natural ) return boolean is
   begin
      return a >= VALID_BASE_G and a <= VALID_LIMIT_G - n and VALID_LIMIT_G >= n;
   end function;

   -- pragma translate_off
   -- mesure (bancs N3) : lectures en attente, par raison, à ce cycle
   signal dbg_wait_addr		: natural := 0;				-- un rangement plus ancien sans adresse
   signal dbg_wait_part		: natural := 0;				-- recouvrement partiel : attente de l'écriture
   signal dbg_wait_bar		: natural := 0;				-- barrière plus ancienne
   signal dbg_unk_norm		: natural := 0;				-- rangements sans adresse : ordinaires
   signal dbg_unk_cx		: natural := 0;				--  de LINK (adresse par COMPLEX_UNIT)
   signal dbg_unk_cptr		: natural := 0;				--  famille C, cellule connue, pointeur non lu
   signal dbg_unk_ccell		: natural := 0;				--  famille C, cellule inconnue
   -- pragma translate_on
begin

		--------------------------------------------------------------------------------
		-- Plan du cycle
		--------------------------------------------------------------------------------

   PLANIFIER : process( e, ROB_HEAD_i )
      -- pragma translate_off
      variable wa, wp, wb	: natural;
      variable un, ux, uc, ucc	: natural;
      variable unk		: boolean;
      -- pragma translate_on
      variable p		: plan_array_t;
      variable addr		: address_t;
      variable pur		: purpose_t;
      variable szr		: natural range 0 to 3;
      variable key, best_key, k	: natural;
      variable decider		: integer;
      variable blocked		: boolean;
      variable taken		: std_logic_vector( 0 to DEPTH_G - 1 );
      variable pp		: port_pick_t;
      variable lp		: lane_pick_t;
      variable best		: integer;
      variable first_port	: natural;
      variable off		: natural;
      variable cnt		: natural;
      variable cp		: capture_pick_t;
   begin
      -- pragma translate_off
      wa := 0; wp := 0; wb := 0;
      un := 0; ux := 0; uc := 0; ucc := 0;
      for i in 0 to DEPTH_G - 1 loop
         if e( i ).valid = '1' and e( i ).kind = K_STORE and not e( i ).ea_known then
            if e( i ).cx then ux := ux + 1;
            elsif e( i ).fam_c and e( i ).cell_known then uc := uc + 1;
            elsif e( i ).fam_c then ucc := ucc + 1;
            else un := un + 1; end if;
         end if;
      end loop;
      dbg_unk_norm <= un; dbg_unk_cx <= ux; dbg_unk_cptr <= uc; dbg_unk_ccell <= ucc;
      -- pragma translate_on
      for i in 0 to DEPTH_G - 1 loop
         p( i ) := ( step => S_WAIT, purpose => P_NONE, address => ( others => '0' ), sz => 0, fwd => ( others => '0' ) );
         if e( i ).valid = '1' and not e( i ).busy and not e( i ).ready and not e( i ).committed then
            -- prochaine action de l'entrée
            pur := P_NONE; addr := ( others => '0' ); szr := e( i ).sz;
            if e( i ).fam_c and not e( i ).ptr_done then
               if e( i ).cell_known then pur := P_PTR; addr := e( i ).cell; szr := 3; end if;
            elsif e( i ).ea_known then
               case e( i ).kind is
                  when K_LOAD  => pur := P_DATA; addr := e( i ).ea;
                  when K_STORE => if not e( i ).probed then pur := P_PROBE; addr := e( i ).ea; end if;
                  when K_CHK   => if not e( i ).fst_done then pur := P_FST; addr := e( i ).ea;
                                  elsif not e( i ).lst_done then pur := P_LST; addr := e( i ).ea + 2 ** e( i ).sz;
                                  end if;
                  when K_FILL  => pur := P_DATA; addr := e( i ).ea; szr := 3;
                  when others  => null;						-- LIVA, SPILL, barrière
               end case;
            end if;

            if pur = P_PROBE then						-- validité seule : pas d'ordre
               p( i ) := ( step => S_ISSUE, purpose => pur, address => addr, sz => szr, fwd => ( others => '0' ) );
            elsif pur /= P_NONE then						-- lecture : ordre prudent
               key := AGE_KEY( e( i ), ROB_HEAD_i );
               blocked := false;
               -- pragma translate_off
               unk := false;
               -- pragma translate_on
               decider := -1; best_key := 0;
               for j in 0 to DEPTH_G - 1 loop
                  if j /= i and e( j ).valid = '1' and e( j ).kind = K_BARRIER then
                     k := AGE_KEY( e( j ), ROB_HEAD_i );
                     if k < key and ( not e( j ).ea_known			-- barrière plus ancienne
                                      or ( e( j ).wlen /= 0 and addr < e( j ).ea + e( j ).wlen
                                           and e( j ).ea < addr + 2 ** szr ) ) then
                        blocked := true;					-- intervalle inconnu, ou recouvert
                     end if;
                  elsif j /= i and e( j ).valid = '1' and ( e( j ).kind = K_STORE or e( j ).kind = K_SPILL ) then
                     k := AGE_KEY( e( j ), ROB_HEAD_i );
                     if k < key then						-- rangement plus ancien
                        if not e( j ).ea_known then
                           blocked := true;
                           -- pragma translate_off
                           unk := true;
                           -- pragma translate_on
                        elsif OVERLAP( addr, 2 ** szr, e( j ).ea, 2 ** e( j ).sz ) and ( decider < 0 or k > best_key ) then
                           decider := j; best_key := k;			-- le plus jeune qui recouvre
                        end if;
                     end if;
                  end if;
               end loop;
               -- pragma translate_off
               if blocked and unk then wa := wa + 1; elsif blocked then wb := wb + 1;
               elsif decider >= 0 and not ( COVERS( e( decider ).ea, 2 ** e( decider ).sz, addr, 2 ** szr )
                                            and e( decider ).data_known ) then
                  if COVERS( e( decider ).ea, 2 ** e( decider ).sz, addr, 2 ** szr ) then wa := wa + 1; else wp := wp + 1; end if;
               end if;
               -- pragma translate_on
               if not blocked then
                  if decider < 0 then
                     p( i ) := ( step => S_ISSUE, purpose => pur, address => addr, sz => szr, fwd => ( others => '0' ) );
                  elsif COVERS( e( decider ).ea, 2 ** e( decider ).sz, addr, 2 ** szr ) and e( decider ).data_known then
                     off := to_integer( addr - e( decider ).ea );
                     p( i ) := ( step => S_FORWARD, purpose => pur, address => addr, sz => szr,
                                 fwd => std_logic_vector( shift_right( unsigned( e( decider ).data ), 8 * off ) ) );
                  end if;							-- sinon : attendre
               end if;
            end if;
         end if;
      end loop;
      plan <= p;
      -- pragma translate_off
      dbg_wait_addr <= wa; dbg_wait_part <= wp; dbg_wait_bar <= wb;
      -- pragma translate_on

      -- requêtes : port 0 pour l'écriture validée la plus ancienne, sinon comme les autres
      pp := ( others => -1 );
      port_purpose <= P_NONE;
      taken := ( others => '0' );
      best := -1; best_key := 0;
      for i in 0 to DEPTH_G - 1 loop
         if e( i ).valid = '1' and e( i ).committed and not e( i ).busy and e( i ).data_known
            and ( best < 0 or e( i ).cseq < best_key ) then
            best := i; best_key := e( i ).cseq;
         end if;
      end loop;
      first_port := 0;
      if best >= 0 then
         pp( 0 ) := best; taken( best ) := '1';
         port_purpose <= P_WRITE;
         first_port := 1;
      end if;
      for pt in 0 to PORTS - 1 loop
         if pt >= first_port then
            best := -1; best_key := 0;
            for i in 0 to DEPTH_G - 1 loop
               if p( i ).step = S_ISSUE and taken( i ) = '0' then
                  key := AGE_KEY( e( i ), ROB_HEAD_i );
                  if best < 0 or key < best_key then best := i; best_key := key; end if;
               end if;
            end loop;
            pp( pt ) := best;
            if best >= 0 then taken( best ) := '1'; end if;
         end if;
      end loop;
      port_pick <= pp;

      -- résultats : les plus anciens prêts
      lp := ( others => -1 );
      taken := ( others => '0' );
      for l in 0 to MEMORY_LANES - 1 loop
         best := -1; best_key := 0;
         for i in 0 to DEPTH_G - 1 loop
            if e( i ).valid = '1' and e( i ).ready and taken( i ) = '0' then
               key := AGE_KEY( e( i ), ROB_HEAD_i );
               if best < 0 or key < best_key then best := i; best_key := key; end if;
            end if;
         end loop;
         lp( l ) := best;
         if best >= 0 then taken( best ) := '1'; end if;
      end loop;
      lane_pick <= lp;

      cp := ( others => -1 );
      cnt := 0;
      for i in 0 to DEPTH_G - 1 loop
         if cnt < CAPTURES and e( i ).valid = '1' and HAS_DATA_TAG( e( i ) ) and e( i ).data_ready
            and not e( i ).data_known then
            cp( cnt ) := i; cnt := cnt + 1;
         end if;
      end loop;
      capture_pick <= cp;

      cnt := 0;
      for i in 0 to DEPTH_G - 1 loop
         if e( i ).valid = '0' then cnt := cnt + 1; end if;
      end loop;
      free_count <= cnt;
   end process;

		--------------------------------------------------------------------------------
		-- Sorties
		--------------------------------------------------------------------------------

   SORTIES : process( e, plan, port_pick, port_purpose, lane_pick, free_count, RECOVERY_i, ROB_HEAD_i, capture_pick,
                      DCACHE_READY_i )
      variable rq	: mem_request_t;
      variable rs	: exec_result_t;
      variable i	: natural;
      variable mc	: natural;
      variable drained : std_logic;
   begin
      for pt in 0 to PORTS - 1 loop
         rq := NO_MEM_REQUEST;
         if port_pick( pt ) >= 0 then
            i := port_pick( pt );
            rq.valid := '1';
            if pt = 0 and port_purpose = P_WRITE then
               rq.write := '1'; rq.address := e( i ).ea;
               rq.size := to_unsigned( e( i ).sz, 2 ); rq.wdata := e( i ).data;
            else
               rq.address := plan( i ).address;
               rq.size := to_unsigned( plan( i ).sz, 2 );
               if plan( i ).purpose = P_PROBE then rq.probe := '1'; end if;
            end if;
         end if;
         DCACHE_REQ_o( pt ) <= rq;
      end loop;

      for l in 0 to MEMORY_LANES - 1 loop
         rs := ( valid => '0', destination_valid => '0', destination => ( others => '0' ), value => ( others => '0' ),
                 completion => ( valid => '0', rob_index => ( others => '0' ), fault => NO_FAULT,
                                 taken => '0', target => ( others => '0' ), mispredicted => '0' ) );
         if lane_pick( l ) >= 0 then
            i := lane_pick( l );
            if not ABANDONED( e( i ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
               rs.valid := '1';
               rs.destination := e( i ).tag;
               rs.value := e( i ).value;
               rs.completion.valid := '1';
               rs.completion.rob_index := e( i ).rob_index;
               if e( i ).kind = K_FILL then					-- FILL : valeur ; fin si completes
                  rs.destination_valid := '1';
                  if not e( i ).completes then rs.completion.valid := '0'; end if;
               elsif e( i ).fault /= 0 then
                  rs.completion.fault := ( valid => '1', code => to_unsigned( e( i ).fault, 8 ) );
               elsif e( i ).kind = K_LOAD or e( i ).kind = K_LIVA then
                  rs.destination_valid := '1';
               end if;
            end if;
         end if;
         RESULT_o( l ) <= rs;
      end loop;

      -- STACK_XFER_WIDTH entrées réservées aux échanges, et une de plus aux SPILL validés
      -- de la réécriture de la fenêtre (sans elle : étreinte fatale, la tête attendant
      -- la réécriture et les plus jeunes tenant toute la file)
      if free_count >= STACK_XFER_WIDTH + 1 then mc := MIN( 8, free_count - STACK_XFER_WIDTH - 1 ); else mc := 0; end if;
      MEMORY_CAPACITY_o <= to_unsigned( mc, MEMORY_CAPACITY_o'length );
      if free_count >= STACK_XFER_WIDTH + 1 + mc then
         COMPLEX_CAPACITY_o <= to_unsigned( MIN( 8, free_count - STACK_XFER_WIDTH - 1 - mc ), COMPLEX_CAPACITY_o'length );
      else
         COMPLEX_CAPACITY_o <= ( others => '0' );
      end if;
      if free_count >= STACK_XFER_WIDTH + 1 then STACK_XFER_READY_o <= '1'; else STACK_XFER_READY_o <= '0'; end if;
      STACK_XFER_FREE_o <= free_count;
      for c in 0 to CAPTURES - 1 loop						-- données de SPILL
         if capture_pick( c ) >= 0 then
            READ_TAGS_o( c / MAX_SOURCE_COUNT )( c mod MAX_SOURCE_COUNT ) <= e( capture_pick( c ) ).data_tag;
         else
            READ_TAGS_o( c / MAX_SOURCE_COUNT )( c mod MAX_SOURCE_COUNT ) <= ( others => '0' );
         end if;
      end loop;
      -- rangement par pointeur écrit ce cycle : STACK_INVALIDATE_o( 0 )
      STACK_INVALIDATE_o <= ( others => ( valid => '0', address => ( others => '0' ), rob_index => ( others => '0' ) ) );
      if port_pick( 0 ) >= 0 and port_purpose = P_WRITE and DCACHE_READY_i( 0 ) = '1'
         and e( port_pick( 0 ) ).ptr_store then
         STACK_INVALIDATE_o( 0 ) <= ( valid => '1', address => e( port_pick( 0 ) ).ea,
                                      rob_index => e( port_pick( 0 ) ).rob_index );
      end if;
      ENTRY_COUNT_o <= DEPTH_G - free_count;
      drained := '1';
      for j in 0 to DEPTH_G - 1 loop
         if e( j ).valid = '1' and e( j ).committed then drained := '0'; end if;
      end loop;
      DRAINED_o <= drained;
   end process;

   -- étape R2 du renommage : cache de pile en écriture différée
   WRITERS_IN_FLIGHT_o	<= '0';
   STACK_LOOKUP_o	<= ( others => ( valid => '0', address => ( others => '0' ), rob_index => ( others => '0' ) ) );

		--------------------------------------------------------------------------------
		-- Au front
		--------------------------------------------------------------------------------

   ETAT : process( CLK_i )
      variable v		: entry_array_t;
      variable f		: fifo_array_t;
      variable fh, fc		: nat_ports_t;
      variable it		: fifo_item_t;
      variable i, slot		: natural;
      variable w		: word64_t;
      variable cs		: natural;
      variable op		: opcode_t;
      variable ins		: renamed_instruction_t;
      variable free		: std_logic_vector( 0 to DEPTH_G - 1 );

      -- une entrée neuve, champs remis à zéro
      procedure NEW_ENTRY( idx : natural; rob : rob_index_t ) is
      begin
         v( idx ) := e( idx );
         v( idx ).valid := '1';
         v( idx ).gen := ( e( idx ).gen + 1 ) mod 256;
         v( idx ).rob_index := rob;
         v( idx ).kind := K_LOAD; v( idx ).fam_c := false; v( idx ).sz := 3; v( idx ).sgn := false;
         v( idx ).ofs := 0; v( idx ).tag := ( others => '0' );
         v( idx ).cell_known := false; v( idx ).ea_known := false; v( idx ).ptr_done := false;
         v( idx ).data_known := false; v( idx ).fst_done := false; v( idx ).lst_done := false;
         v( idx ).probed := false; v( idx ).busy := false; v( idx ).ready := false; v( idx ).fault := 0;
         v( idx ).reported := false; v( idx ).committed := false; v( idx ).cseq := 0;
         v( idx ).data_ready := false; v( idx ).wlen := ( others => '0' ); v( idx ).ptr_store := false;
         v( idx ).completes := false; v( idx ).cx := false;
      end procedure;

      -- une valeur lue (cache ou transfert) fait avancer l'entrée
      procedure TAKE_READ( idx : natural; pur : purpose_t; raw : word64_t; flt : boolean ) is
      begin
         if flt and v( idx ).kind = K_FILL then
            v( idx ).value := ( others => '0' ); v( idx ).ready := true;	-- FILL : 0, sans faute
            return;
         end if;
         if flt then
            v( idx ).fault := 132; v( idx ).ready := true;
            return;
         end if;
         case pur is
            when P_PTR =>
               v( idx ).ptr_done := true;
               v( idx ).ea := unsigned( raw ) + v( idx ).ofs;
               v( idx ).ea_known := true;
               if v( idx ).kind = K_LIVA then
                  v( idx ).value := std_logic_vector( v( idx ).ea ); v( idx ).ready := true;
               end if;
            when P_DATA =>
               v( idx ).value := EXTEND( raw, v( idx ).sz, v( idx ).sgn ); v( idx ).ready := true;
            when P_FST =>
               v( idx ).fst := EXTEND( raw, v( idx ).sz, v( idx ).sgn ); v( idx ).fst_done := true;
            when P_LST =>
               v( idx ).lst := EXTEND( raw, v( idx ).sz, v( idx ).sgn ); v( idx ).lst_done := true;
            when others => null;
         end case;
      end procedure;

   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            for j in 0 to DEPTH_G - 1 loop
               e( j ).valid <= '0';
               e( j ).gen <= 0;
            end loop;
            fhead <= ( others => 0 ); fcount <= ( others => 0 );
            next_cseq <= 0;
         else
            v := e; f := fifo; fh := fhead; fc := fcount; cs := next_cseq;

            -- réponses du cache, dans l'ordre de chaque port
            for pt in 0 to PORTS - 1 loop
               if DCACHE_RSP_i( pt ).valid = '1' then
                  -- pragma translate_off
                  assert fc( pt ) > 0 report "LSQ : réponse sans requête" severity failure;
                  -- pragma translate_on
                  it := f( pt )( fh( pt ) );
                  fh( pt ) := ( fh( pt ) + 1 ) mod FIFO_DEPTH; fc( pt ) := fc( pt ) - 1;
                  i := it.entry;
                  if it.purpose = P_WRITE then
                     null;							-- écriture : entrée déjà libérée
                  elsif v( i ).valid = '1' and v( i ).busy and v( i ).rob_index = it.rob_index
                        and v( i ).gen = it.gen then
                     v( i ).busy := false;
                     if it.purpose = P_PROBE then
                        v( i ).probed := true;
                        if DCACHE_RSP_i( pt ).fault = '1' then v( i ).fault := 132; v( i ).ready := true; end if;
                     else
                        TAKE_READ( i, it.purpose, DCACHE_RSP_i( pt ).rdata, DCACHE_RSP_i( pt ).fault = '1' );
                     end if;
                  end if;								-- sinon : entrée abandonnée, ignorée
               end if;
            end loop;

            -- requêtes acceptées
            for pt in 0 to PORTS - 1 loop
               if port_pick( pt ) >= 0 and DCACHE_READY_i( pt ) = '1' then
                  i := port_pick( pt );
                  -- pragma translate_off
                  assert fc( pt ) < FIFO_DEPTH report "LSQ : file de port pleine" severity failure;
                  -- pragma translate_on
                  if pt = 0 and port_purpose = P_WRITE then
                     f( pt )( ( fh( pt ) + fc( pt ) ) mod FIFO_DEPTH ) := ( entry => i, rob_index => v( i ).rob_index,
                                                                         purpose => P_WRITE, gen => v( i ).gen );
                     v( i ).valid := '0';						-- écrite : libérée
                  else
                     f( pt )( ( fh( pt ) + fc( pt ) ) mod FIFO_DEPTH ) := ( entry => i, rob_index => v( i ).rob_index,
                                                                         purpose => plan( i ).purpose, gen => v( i ).gen );
                     v( i ).busy := true;
                  end if;
                  fc( pt ) := fc( pt ) + 1;
               end if;
            end loop;

            -- transferts
            for j in 0 to DEPTH_G - 1 loop
               if plan( j ).step = S_FORWARD and v( j ).valid = '1' then
                  TAKE_READ( j, plan( j ).purpose, plan( j ).fwd, false );
               end if;
            end loop;

            -- adresses et données (ADDRESS_UNIT)
            for l in EXEC_i'range loop						-- ADDRESS_UNIT, et COMPLEX
               if EXEC_i( l ).valid = '1' then
                  for j in 0 to DEPTH_G - 1 loop
                     if v( j ).valid = '1' and not v( j ).committed and v( j ).rob_index = EXEC_i( l ).rob_index
                        and v( j ).kind /= K_SPILL and v( j ).kind /= K_FILL and v( j ).kind /= K_BARRIER then
                        if v( j ).fam_c then
                           v( j ).cell := EXEC_i( l ).address; v( j ).cell_known := true;
                        else
                           v( j ).ea := EXEC_i( l ).address; v( j ).ea_known := true;
                        end if;
                        if v( j ).kind = K_CHK or ( v( j ).kind = K_STORE and v( j ).cx ) then
                           v( j ).data := EXEC_i( l ).data; v( j ).data_known := true;
                        end if;							-- (rangement : donnée capturée)
                     end if;
                  end loop;
               end if;
            end loop;

            -- SPILL, rangements : données capturées, réveils
            for cpt in 0 to CAPTURES - 1 loop
               if capture_pick( cpt ) >= 0 then
                  i := capture_pick( cpt );
                  if v( i ).valid = '1' and HAS_DATA_TAG( v( i ) ) then
                     v( i ).data := READ_DATA_i( cpt / MAX_SOURCE_COUNT )( cpt mod MAX_SOURCE_COUNT );
                     v( i ).data_known := true;
                  end if;
               end if;
            end loop;
            for j in 0 to DEPTH_G - 1 loop
               if v( j ).valid = '1' and HAS_DATA_TAG( v( j ) ) and not v( j ).data_ready then
                  for wi in WAKEUP_i'range loop
                     if WAKEUP_i( wi ).valid = '1' and WAKEUP_i( wi ).tag = v( j ).data_tag then v( j ).data_ready := true; end if;
                  end loop;
               end if;
            end loop;

            -- barrières : intervalle écrit
            if RANGE_i.valid = '1' then
               for j in 0 to DEPTH_G - 1 loop
                  if v( j ).valid = '1' and v( j ).kind = K_BARRIER and v( j ).rob_index = RANGE_i.rob_index then
                     v( j ).ea := RANGE_i.write_base; v( j ).ea_known := true;
                     if RANGE_i.write_valid = '1' then v( j ).wlen := RANGE_i.write_length;
                     else v( j ).wlen := ( others => '0' ); end if;
                  end if;
               end loop;
            end if;

            -- fins acquises : rangement, CHK
            for j in 0 to DEPTH_G - 1 loop
               if v( j ).valid = '1' and not v( j ).ready and not v( j ).reported then
                  -- rangement : validité décidée dès l'adresse connue (règle de DATA_CACHE)
                  if v( j ).kind = K_STORE and v( j ).ea_known and not v( j ).probed then
                     v( j ).probed := true;
                     if not VALID_ACCESS( v( j ).ea, 2 ** v( j ).sz ) then v( j ).fault := 132; v( j ).ready := true; end if;
                  end if;
                  if v( j ).kind = K_STORE and v( j ).probed and v( j ).data_known and v( j ).fault = 0 then
                     v( j ).ready := true;
                  elsif v( j ).kind = K_CHK and v( j ).fst_done and v( j ).lst_done and v( j ).data_known then
                     if signed( v( j ).data ) < signed( v( j ).fst ) or signed( v( j ).data ) > signed( v( j ).lst ) then
                        v( j ).fault := 131;
                     end if;
                     v( j ).ready := true;
                  end if;
               end if;
            end loop;

            -- résultats envoyés (s'ils ne sont pas abandonnés)
            for l in 0 to MEMORY_LANES - 1 loop
               if lane_pick( l ) >= 0 then
                  i := lane_pick( l );
                  if not ABANDONED( e( i ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                     v( i ).ready := false;
                     if v( i ).kind = K_STORE and v( i ).fault = 0 then
                        v( i ).reported := true;				-- attend son retrait
                     else
                        v( i ).valid := '0';
                     end if;
                  end if;
               end if;
            end loop;

            -- retrait des rangements : validés
            for r in 0 to RETIRE_WIDTH - 1 loop
               if RETIRE_i( r ).valid = '1' then
                  for j in 0 to DEPTH_G - 1 loop
                     if v( j ).valid = '1' and not v( j ).committed and v( j ).rob_index = RETIRE_i( r ).rob_index then
                        if ( v( j ).kind = K_STORE and ( RETIRE_i( r ).is_store = '1' or v( j ).cx ) )
                           or v( j ).kind = K_SPILL then
                           v( j ).committed := true; v( j ).cseq := cs; cs := cs + 1;
                        elsif v( j ).kind = K_BARRIER then
                           v( j ).valid := '0';					-- fin de la barrière
                        end if;
                     end if;
                  end loop;
               end if;
            end loop;

            -- reprise : les entrées abandonnées disparaissent, sauf les validées
            if RECOVERY_i.valid = '1' then
               for j in 0 to DEPTH_G - 1 loop
                  if v( j ).valid = '1' and not v( j ).committed
                     and ABANDONED( v( j ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                     v( j ).valid := '0';
                  end if;
               end loop;
            end if;

            -- réservations, barrières et échanges, dans les entrées libres au début du cycle
            for j in 0 to DEPTH_G - 1 loop
               free( j ) := not e( j ).valid;
            end loop;
            slot := 0;
            if MEMORY_INSERT_VALID_i = '1' then
               for b in 0 to RENAME_WIDTH - 1 loop
                  if b < MEMORY_INSERT_COUNT_i then
                     ins := MEMORY_INSERT_BLOCK_i( b );
                     while slot < DEPTH_G and free( slot ) = '0' loop slot := slot + 1; end loop;
                     -- pragma translate_off
                     assert slot < DEPTH_G report "LSQ : réservation au-delà de la capacité" severity failure;
                     -- pragma translate_on
                     if not ABANDONED( ins.rob_index, RECOVERY_i, ROB_HEAD_i ) then
                        op := ins.slot.canon.op;
                        NEW_ENTRY( slot, ins.rob_index );
                        v( slot ).fam_c := op( 7 downto 6 ) = "10";
                        v( slot ).sz := to_integer( unsigned( op( 1 downto 0 ) ) );
                        v( slot ).sgn := op( 5 downto 4 ) = "01";
                        v( slot ).ofs := to_integer( ins.slot.canon.ofs );
                        v( slot ).tag := ins.destination;
                        if op( 5 downto 4 ) = "10" then v( slot ).kind := K_STORE;
                        elsif op( 5 downto 4 ) = "00" then v( slot ).kind := K_LIVA;
                        elsif op( 3 downto 2 ) = "11" then v( slot ).kind := K_CHK;
                        else v( slot ).kind := K_LOAD;
                        end if;
                        v( slot ).ptr_store := v( slot ).kind = K_STORE and ( v( slot ).fam_c or ins.address_known = '0' );
                        if v( slot ).kind = K_STORE and ins.source_count > 0 then	-- donnée : la dernière source
                           v( slot ).data_tag := ins.source( ins.source_count - 1 );
                           v( slot ).data_ready := ins.source_ready( ins.source_count - 1 ) = '1';
                           for wi in WAKEUP_i'range loop
                              if WAKEUP_i( wi ).valid = '1' and WAKEUP_i( wi ).tag = v( slot ).data_tag then
                                 v( slot ).data_ready := true;
                              end if;
                           end loop;
                        end if;
                        if ins.address_known = '1' then
                           if v( slot ).fam_c then
                              v( slot ).cell := ins.address; v( slot ).cell_known := true;
                           else
                              v( slot ).ea := ins.address; v( slot ).ea_known := true;
                           end if;
                        end if;
                     end if;
                     free( slot ) := '0';
                  end if;
               end loop;
            end if;
            if COMPLEX_INSERT_VALID_i = '1' then					-- barrières : COMPLEX qui écrit
               for b in 0 to RENAME_WIDTH - 1 loop
                  if b < COMPLEX_INSERT_COUNT_i then
                     ins := COMPLEX_INSERT_BLOCK_i( b );
                     op := ins.slot.canon.op;
                     if ( op = x"34" or op = x"3C" or op = x"3D" or op = x"3E" or op = x"3F" or op = x"44"
                          or op = x"48" or op = x"45" or op = x"49" or op = OP_UNLINK or op = OP_UNLINKR )
                        and not ABANDONED( ins.rob_index, RECOVERY_i, ROB_HEAD_i ) then
                        while slot < DEPTH_G and free( slot ) = '0' loop slot := slot + 1; end loop;
                        -- pragma translate_off
                        assert slot < DEPTH_G report "LSQ : réservation COMPLEX au-delà de la capacité" severity failure;
                        -- pragma translate_on
                        NEW_ENTRY( slot, ins.rob_index );
                        if op = x"44" or op = x"48" then				-- LINK : M64[CSP] := CFP
                           v( slot ).kind := K_STORE; v( slot ).sz := 3; v( slot ).cx := true;
                        elsif op = OP_UNLINK or op = OP_UNLINKR then			-- M64[CFP], vers le registre caché
                           v( slot ).kind := K_LOAD; v( slot ).sz := 3; v( slot ).cx := true;
                           v( slot ).tag := ins.destination;
                        else
                           v( slot ).kind := K_BARRIER;				-- blocs qui écrivent, EXC_MACH
                        end if;
                        free( slot ) := '0';
                     end if;
                  end if;
               end loop;
            end if;
            for x in 0 to STACK_XFER_WIDTH - 1 loop					-- échanges
               if STACK_XFER_i( x ).valid = '1' and not ABANDONED( STACK_XFER_i( x ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                  while slot < DEPTH_G and free( slot ) = '0' loop slot := slot + 1; end loop;
                  -- pragma translate_off
                  assert slot < DEPTH_G report "LSQ : échange au-delà de la capacité" severity failure;
                  -- pragma translate_on
                  NEW_ENTRY( slot, STACK_XFER_i( x ).rob_index );
                  v( slot ).sz := 3;
                  v( slot ).ea := STACK_XFER_i( x ).address; v( slot ).ea_known := true;
                  if STACK_XFER_i( x ).kind = XFER_SPILL then
                     v( slot ).kind := K_SPILL;
                     v( slot ).data_tag := STACK_XFER_i( x ).tag;
                     v( slot ).data_ready := STACK_XFER_i( x ).ready = '1';
                     for wi in WAKEUP_i'range loop
                        if WAKEUP_i( wi ).valid = '1' and WAKEUP_i( wi ).tag = STACK_XFER_i( x ).tag then
                           v( slot ).data_ready := true;
                        end if;
                     end loop;
                     if STACK_XFER_i( x ).committed = '1' then
                        v( slot ).committed := true; v( slot ).cseq := cs; cs := cs + 1;
                     end if;
                  else
                     v( slot ).kind := K_FILL;
                     v( slot ).tag := STACK_XFER_i( x ).tag;
                     v( slot ).completes := STACK_XFER_i( x ).completes = '1';
                  end if;
                  free( slot ) := '0';
               end if;
            end loop;

            e <= v; fifo <= f; fhead <= fh; fcount <= fc; next_cseq <= cs;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
