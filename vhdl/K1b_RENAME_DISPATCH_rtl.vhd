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
use work.TAHX_1_ISA_TABLE.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;

		--------------------------------------------------------------------------------
		--  RENAME_DISPATCH, architecture RTL : étape R1 (écriture immédiate), modèle de
		--  référence (voir le contrat de l'entité).
		--
		--  PLAN (combinatoire) : renomme le plus long préfixe possible du bloc décodé,
		--  instruction par instruction, sur une copie de l'état de frame et une
		--  surcouche des tables de cellules ; il produit les sorties (bloc renommé,
		--  allocation, échanges) et un compte rendu de ce qu'il change.
		--  ETAT (au front) : applique le compte rendu si le bloc est pris, puis les
		--  événements du cycle : réveils, retraits, invalidations, FRAME_UPDATE,
		--  maintenance, reprise, SYNC ; enfin la libération des registres (avec une
		--  quarantaine de 4 cycles).
		--
		--  Tables : cellules de la pile data (STACK_CACHE_WORDS) et de la pile des
		--  retours (32), associatives, insertion tournante (la plus ancienne est
		--  oubliée). Par registre : attribué, prêt, producteur en vol, lecteurs en vol
		--  (comptés), cellules qui le tiennent. Par entrée du ROB : numéro d'ordre,
		--  état de frame après l'instruction, registres produits et lus, point de
		--  reprise, écrivain. Numéros d'ordre croissants : jamais réutilisés.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of RENAME_DISPATCH is		---

   constant CELLS		: positive := STACK_CACHE_WORDS;
   constant RCELL_COUNT	: positive := 32;
   constant NTAGS		: positive := 2 ** PHYSICAL_TAG_BITS;
   constant NCKPT		: positive := 2 ** CHECKPOINT_BITS;
   constant NWRIT		: positive := 128;				-- pleine : le renommage attend
   constant MAXTAGS		: positive := 5;					-- registres neufs par instruction
   constant BLKTAGS		: positive := MAXTAGS * DECODE_WIDTH;
   constant UPD		: positive := 64;					-- opérations sur les cellules par bloc
   constant RUPD		: positive := 16;
   constant SHADOW_DEPTH	: positive := 16;
   constant QUARANTINE		: positive := 4;

   subtype seq_t		is natural;
   type tag_list_t		is array( 0 to MAXTAGS - 1 ) of physical_tag_t;
   type src_list_t		is array( 0 to MAX_SOURCE_COUNT - 1 ) of physical_tag_t;

   type cell_t			is record
			  valid		: boolean;
			  addr		: address_t;
			  tag		: physical_tag_t;
			  wseq		: seq_t;			-- qui a donné ce registre à la cellule
			end record;
   type cell_array_t		is array( 0 to CELLS - 1 ) of cell_t;
   type rcell_array_t		is array( 0 to RCELL_COUNT - 1 ) of cell_t;
   constant NO_CELL		: cell_t := ( valid => false, addr => ( others => '0' ), tag => ( others => '0' ), wseq => 0 );

   type map_op_t		is record
			  set		: boolean;			-- true : la cellule prend tag ; false : oubliée
			  addr		: address_t;
			  tag		: physical_tag_t;
			  wseq		: seq_t;
			end record;
   type map_ops_t		is array( 0 to UPD - 1 ) of map_op_t;
   type rmap_ops_t		is array( 0 to RUPD - 1 ) of map_op_t;

   type hist_t			is record
			  dsp, rsp	: address_t;			-- après l'instruction
			  dlvl		: integer range -1 to 14;	-- DISPLAY changé ( -1 : aucun )
			  dval		: address_t;
			end record;

   type robinfo_t		is record
			  valid		: boolean;
			  seq		: seq_t;
			  hist		: hist_t;
			  ntag		: natural range 0 to MAXTAGS;
			  tags		: tag_list_t;			-- registres produits (destination, FILL)
			  nsrc		: natural range 0 to MAX_SOURCE_COUNT;
			  srcs		: src_list_t;			-- registres lus
			  ckpt_valid	: boolean;
			  ckpt		: natural range 0 to NCKPT - 1;
			  writer		: boolean;			-- bloc qui écrit, EXC_MACH : jusqu'au retrait
			end record;
   type robinfo_array_t		is array( 0 to ROB_SIZE - 1 ) of robinfo_t;
   type robinfo_block_t		is array( 0 to DECODE_WIDTH - 1 ) of robinfo_t;

   type shadow_entry_t		is record
			  lvl		: natural range 0 to 14;
			  val		: address_t;			-- FP sauvé par LINK
			  tag		: physical_tag_t;		-- registre que LINK a donné à la cellule
			end record;
   type shadow_t		is array( 0 to SHADOW_DEPTH - 1 ) of shadow_entry_t;

   type writer_t		is record
			  valid		: boolean;
			  ptr		: boolean;			-- rangement par pointeur (sinon : bloc)
			  rob		: rob_index_t;
			  seq		: seq_t;
			end record;
   type writer_array_t		is array( 0 to NWRIT - 1 ) of writer_t;
   type writer_block_t		is array( 0 to DECODE_WIDTH - 1 ) of writer_t;

   type ckpt_t			is record
			  valid		: boolean;
			  seq		: seq_t;
			  frame		: frame_state_t;
			end record;
   type ckpt_array_t		is array( 0 to NCKPT - 1 ) of ckpt_t;
   type ckpt_alloc_t		is record
			  valid		: boolean;
			  id		: natural range 0 to NCKPT - 1;
			  seq		: seq_t;
			  frame		: frame_state_t;
			end record;
   type ckpt_alloc_block_t	is array( 0 to DECODE_WIDTH - 1 ) of ckpt_alloc_t;

   type tag_block_t		is array( 0 to BLKTAGS - 1 ) of physical_tag_t;
   type nat_tags_t		is array( 0 to NTAGS - 1 ) of natural range 0 to 1023;
   type quar_t			is array( 0 to NTAGS - 1 ) of natural range 0 to QUARANTINE;

   -- état
   signal frame_s, frame_c	: frame_state_t;
   signal shadow		: shadow_t;
   signal shadow_n		: natural range 0 to SHADOW_DEPTH;
   signal dcells		: cell_array_t;
   signal dptr			: natural range 0 to CELLS - 1;
   signal rcells		: rcell_array_t;
   signal rptr			: natural range 0 to RCELL_COUNT - 1;
   signal robinfo		: robinfo_array_t;
   signal r_head, r_tail	: rob_index_t;					-- en vol : [r_head, r_tail)
   signal writers		: writer_array_t;
   signal ckpts		: ckpt_array_t;
   signal seq_next		: seq_t;
   signal waiting		: boolean;					-- UNLINK en attente de FRAME_UPDATE_i
   signal wait_rob		: rob_index_t;
   signal wait_lvl		: natural range 0 to 14;
   signal fstall		: boolean;					-- arrêt après une faute
   signal allocated, ready	: std_logic_vector( 0 to NTAGS - 1 );
   signal producing		: std_logic_vector( 0 to NTAGS - 1 );		-- producteur en vol
   signal readers, mapcnt	: nat_tags_t;
   signal quar			: quar_t;
   signal maint_done		: std_logic;

   -- compte rendu du plan
   signal p_k			: natural range 0 to DECODE_WIDTH;
   signal p_frame		: frame_state_t;
   signal p_shadow		: shadow_t;
   signal p_shadow_n		: natural range 0 to SHADOW_DEPTH;
   signal p_dops		: map_ops_t;
   signal p_ndops		: natural range 0 to UPD;
   signal p_rops		: rmap_ops_t;
   signal p_nrops		: natural range 0 to RUPD;
   signal p_tags		: tag_block_t;
   signal p_ntags		: natural range 0 to BLKTAGS;
   signal p_info		: robinfo_block_t;
   signal p_writers		: writer_block_t;
   signal p_ckpts		: ckpt_alloc_block_t;
   signal p_wait		: boolean;
   signal p_wait_rob		: rob_index_t;
   signal p_wait_lvl		: natural range 0 to 14;
   signal p_fstall		: boolean;
   signal p_free_tags		: tag_block_t;					-- registres libres, dans l'ordre
   signal p_nfree		: natural range 0 to NTAGS;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

   function U64( v : signed ) return address_t is
   begin
      return unsigned( std_logic_vector( resize( v, 64 ) ) );
   end function;

   function OLDER( a, b : seq_t ) return boolean is				-- a plus ancien que b
   begin
      return a < b;
   end function;

   function TAG_N( n : natural ) return physical_tag_t is
   begin
      return to_unsigned( n, PHYSICAL_TAG_BITS );
   end function;

begin

		--------------------------------------------------------------------------------
		-- Registres libres (hors quarantaine), dans l'ordre : le plan y puise
		--------------------------------------------------------------------------------

   LIBRES : process( allocated, quar )
      variable lst	: tag_block_t;
      variable n	: natural;
      variable tot	: natural;
   begin
      lst := ( others => ( others => '0' ) ); n := 0; tot := 0;
      for t in 0 to NTAGS - 1 loop
         if allocated( t ) = '0' and quar( t ) = 0 then
            if n < BLKTAGS then lst( n ) := TAG_N( t ); n := n + 1; end if;
            tot := tot + 1;
         end if;
      end loop;
      p_free_tags <= lst; p_nfree <= tot;
   end process;
   FREE_PHYSICAL_COUNT_o <= to_unsigned( p_nfree, FREE_PHYSICAL_COUNT_o'length );

		--------------------------------------------------------------------------------
		-- Plan du cycle
		--------------------------------------------------------------------------------

   PLAN : process( DECODE_BLOCK_i, DECODE_COUNT_i, ROB_TAIL_i, ROB_FREE_i, RENAME_READY_i, STACK_XFER_READY_i,
                   RECOVERY_i, SYNC_VALID_i, LIMITS_i, frame_s, shadow, shadow_n, dcells, rcells, writers, ckpts,
                   seq_next, waiting, fstall, ready, p_free_tags, p_nfree )
      -- état de travail
      variable f		: frame_state_t;
      variable sh		: shadow_t;
      variable shn		: natural range 0 to SHADOW_DEPTH;
      variable dops		: map_ops_t;
      variable ndops		: natural range 0 to UPD;
      variable rops		: rmap_ops_t;
      variable nrops		: natural range 0 to RUPD;
      variable ntaken		: natural range 0 to BLKTAGS;			-- registres neufs pris
      variable nwr		: natural;					-- écrivains en vol (et du bloc)
      variable nck		: natural;					-- points de reprise libres
      variable ck_used		: std_logic_vector( 0 to NCKPT - 1 );
      variable nx		: natural range 0 to STACK_XFER_WIDTH;
      variable seq		: seq_t;
      variable fst		: boolean;
      variable wt		: boolean;
      -- une instruction (essai)
      variable t_f		: frame_state_t;
      variable t_sh		: shadow_t;
      variable t_shn		: natural range 0 to SHADOW_DEPTH;
      variable t_dops		: map_ops_t;
      variable t_ndops		: natural range 0 to UPD;
      variable t_rops		: rmap_ops_t;
      variable t_nrops		: natural range 0 to RUPD;
      variable t_ntaken		: natural range 0 to BLKTAGS;
      variable t_nx		: natural range 0 to STACK_XFER_WIDTH;
      variable t_xf		: stack_xfer_bus_t;
      variable t_wt		: boolean;
      variable ok		: boolean;
      variable stop_after	: boolean;
      -- sorties
      variable xf		: stack_xfer_bus_t;
      variable rb		: renamed_block_t;
      variable ab		: rob_alloc_block_t;
      variable info		: robinfo_block_t;
      variable wrs		: writer_block_t;
      variable cks		: ckpt_alloc_block_t;
      variable k		: natural range 0 to DECODE_WIDTH;
      -- détail
      variable slot		: decoded_slot_t;
      variable op		: opcode_t;
      variable e		: isa_entry_t;
      variable rob		: rob_index_t;
      variable lvl		: natural range 0 to 15;
      variable npop, npush	: natural range 0 to 4;
      variable top		: address_t;
      variable ri		: renamed_instruction_t;
      variable al		: rob_alloc_t;
      variable inf		: robinfo_t;
      variable fault		: natural range 0 to 255;
      variable fills_ok	: boolean;
      variable is_store, is_ptr_store, is_wblock : boolean;
      variable sz		: natural;
      variable alloc		: unsigned( 35 downto 0 );
      variable t		: physical_tag_t;
      variable found		: boolean;
      variable tg		: physical_tag_t;
      variable addr		: address_t;
      variable dl		: integer range -1 to 14;
      variable dv		: address_t;
      variable cid		: integer;
      variable n_new		: natural;

      -- registre neuf (attribution dans le bloc)
      procedure NEW_TAG( r : out physical_tag_t ) is
      begin
         if t_ntaken < p_nfree and t_ntaken < BLKTAGS then
            r := p_free_tags( t_ntaken ); t_ntaken := t_ntaken + 1;
         else
            r := ( others => '0' ); ok := false;
         end if;
      end procedure;

      -- registre d'une cellule de la pile data : surcouche du bloc, puis table
      procedure LOOKUP( a : address_t; hit : out boolean; r : out physical_tag_t ) is
      begin
         hit := false; r := ( others => '0' );
         for i in UPD - 1 downto 0 loop
            if i < t_ndops and t_dops( i ).addr = a then
               hit := t_dops( i ).set; r := t_dops( i ).tag; return;
            end if;
         end loop;
         for i in 0 to CELLS - 1 loop
            if dcells( i ).valid and dcells( i ).addr = a then hit := true; r := dcells( i ).tag; return; end if;
         end loop;
      end procedure;

      procedure RLOOKUP( a : address_t; hit : out boolean; r : out physical_tag_t ) is
      begin
         hit := false; r := ( others => '0' );
         for i in RUPD - 1 downto 0 loop
            if i < t_nrops and t_rops( i ).addr = a then
               hit := t_rops( i ).set; r := t_rops( i ).tag; return;
            end if;
         end loop;
         for i in 0 to RCELL_COUNT - 1 loop
            if rcells( i ).valid and rcells( i ).addr = a then hit := true; r := rcells( i ).tag; return; end if;
         end loop;
      end procedure;

      procedure DOP( set : boolean; a : address_t; r : physical_tag_t ) is
      begin
         if t_ndops < UPD then
            t_dops( t_ndops ) := ( set => set, addr => a, tag => r, wseq => seq ); t_ndops := t_ndops + 1;
         else
            ok := false;
         end if;
      end procedure;

      procedure ROP( set : boolean; a : address_t; r : physical_tag_t ) is
      begin
         if t_nrops < RUPD then
            t_rops( t_nrops ) := ( set => set, addr => a, tag => r, wseq => seq ); t_nrops := t_nrops + 1;
         else
            ok := false;
         end if;
      end procedure;

      procedure XFER( kind : stack_xfer_kind_t; a : address_t; r : physical_tag_t; rdy : std_logic ) is
      begin
         if t_nx < STACK_XFER_WIDTH then
            t_xf( t_nx ) := ( valid => '1', kind => kind, address => a, tag => r, rob_index => rob,
                              committed => '0', ready => rdy );
            t_nx := t_nx + 1;
         else
            ok := false;
         end if;
      end procedure;

      -- lecture d'une cellule de la pile data : son registre, ou un FILL
      procedure READ_CELL( a : address_t; keep : boolean; r : out physical_tag_t ) is
         variable hit : boolean;
         variable x   : physical_tag_t;
      begin
         LOOKUP( a, hit, x );
         if hit and not t_wt then
            r := x;
         else
            NEW_TAG( x );
            XFER( XFER_FILL, a, x, '0' );
            if inf.ntag < MAXTAGS then inf.tags( inf.ntag ) := x; inf.ntag := inf.ntag + 1; end if;
            if keep then DOP( true, a, x ); end if;				-- la cellule reste : elle le garde
            r := x;
         end if;
      end procedure;

      procedure SOURCE( r : physical_tag_t ) is
      begin
         if inf.nsrc < MAX_SOURCE_COUNT then
            ri.source( inf.nsrc ) := r;
            ri.source_ready( inf.nsrc ) := ready( to_integer( r ) );		-- (revu à la prise)
            inf.srcs( inf.nsrc ) := r; inf.nsrc := inf.nsrc + 1;
         end if;
      end procedure;

      -- empile une cellule tenue par r (SPILL)
      procedure PUSH_CELL( r : physical_tag_t; rdy : std_logic ) is
      begin
         t_f.dsp := t_f.dsp + 8;
         DOP( true, t_f.dsp, r );
         XFER( XFER_SPILL, t_f.dsp, r, rdy );
      end procedure;

      -- registre neuf comme destination (pas prêt)
      procedure DEST( r : out physical_tag_t ) is
         variable x : physical_tag_t;
      begin
         NEW_TAG( x );
         ri.destination_valid := '1'; ri.destination := x;
         if inf.ntag < MAXTAGS then inf.tags( inf.ntag ) := x; inf.ntag := inf.ntag + 1; end if;
         r := x;
      end procedure;

      -- un registre neuf de ce bloc n'est pas encore prêt
      impure function READY_OF( r : physical_tag_t ) return std_logic is
      begin
         for j in 0 to BLKTAGS - 1 loop
            if j < t_ntaken and p_free_tags( j ) = r then return '0'; end if;
         end loop;
         return ready( to_integer( r ) );
      end function;

   begin
      f := frame_s; sh := shadow; shn := shadow_n;
      dops := ( others => ( set => false, addr => ( others => '0' ), tag => ( others => '0' ), wseq => 0 ) );
      ndops := 0;
      rops := ( others => ( set => false, addr => ( others => '0' ), tag => ( others => '0' ), wseq => 0 ) );
      nrops := 0;
      ntaken := 0; nx := 0; seq := seq_next; fst := fstall;
      xf := ( others => ( valid => '0', kind => XFER_SPILL, address => ( others => '0' ), tag => ( others => '0' ),
                          rob_index => ( others => '0' ), committed => '0', ready => '0' ) );
      nwr := 0;
      for i in 0 to NWRIT - 1 loop
         if writers( i ).valid then nwr := nwr + 1; end if;
      end loop;
      nck := 0; ck_used := ( others => '0' );
      for i in 0 to NCKPT - 1 loop
         if ckpts( i ).valid then ck_used( i ) := '1'; else nck := nck + 1; end if;
      end loop;
      wt := false;
      k := 0;
      info := ( others => ( valid => false, seq => 0,
                            hist => ( dsp => ( others => '0' ), rsp => ( others => '0' ), dlvl => -1, dval => ( others => '0' ) ),
                            ntag => 0, tags => ( others => ( others => '0' ) ), nsrc => 0,
                            srcs => ( others => ( others => '0' ) ), ckpt_valid => false, ckpt => 0, writer => false ) );
      wrs := ( others => ( valid => false, ptr => false, rob => ( others => '0' ), seq => 0 ) );
      cks := ( others => ( valid => false, id => 0, seq => 0, frame => frame_s ) );
      for i in 0 to DECODE_WIDTH - 1 loop
         rb( i ) := ( slot => DECODE_BLOCK_i( i ), rob_index => ( others => '0' ), issue_class => ISSUE_NONE,
                      source_count => 0, source => ( others => ( others => '0' ) ), source_ready => ( others => '1' ),
                      destination_valid => '0', destination => ( others => '0' ), execute_required => '0',
                      address_known => '0', address => ( others => '0' ), stack_cache_hit => '0',
                      checkpoint_valid => '0', checkpoint => ( others => '0' ) );
         ab( i ) := ( valid => '0', pc => ( others => '0' ), len => ( others => '0' ), op => ( others => '0' ),
                      fault => NO_FAULT, done => '0', serializing => '0', is_store => '0', is_control => '0',
                      pred => NO_PREDICTION, checkpoint_valid => '0', checkpoint => ( others => '0' ) );
      end loop;

      if RECOVERY_i.valid = '0' and SYNC_VALID_i = '0' and RENAME_READY_i = '1' and not waiting and not fstall then
         for i in 0 to DECODE_WIDTH - 1 loop
            exit when i >= to_integer( DECODE_COUNT_i ) or i >= to_integer( ROB_FREE_i );
            slot := DECODE_BLOCK_i( i );
            op := slot.canon.op;
            e := ISA_TABLE( to_integer( unsigned( op ) ) );
            if op = UOP_LIHI then
               e := ( true, 9, FMT_NONE, ISSUE_INTEGER, 1, 1, STACK_LINEAR, LVL_NONE, false, false, false, false );
            end if;
            rob := ROB_TAIL_i + i;
            lvl := to_integer( slot.canon.lvl );
            -- essai sur des copies
            t_f := f; t_sh := sh; t_shn := shn; t_dops := dops; t_ndops := ndops; t_rops := rops; t_nrops := nrops;
            t_ntaken := ntaken; t_nx := nx; t_xf := xf; t_wt := nwr > 0;
            ok := true; stop_after := false; fault := 0;
            ri := ( slot => slot, rob_index => rob, issue_class => e.issue_class, source_count => 0,
                    source => ( others => ( others => '0' ) ), source_ready => ( others => '1' ),
                    destination_valid => '0', destination => ( others => '0' ), execute_required => '0',
                    address_known => '0', address => ( others => '0' ), stack_cache_hit => '0',
                    checkpoint_valid => '0', checkpoint => ( others => '0' ) );
            inf := ( valid => true, seq => seq,
                     hist => ( dsp => ( others => '0' ), rsp => ( others => '0' ), dlvl => -1, dval => ( others => '0' ) ),
                     ntag => 0, tags => ( others => ( others => '0' ) ), nsrc => 0,
                     srcs => ( others => ( others => '0' ) ), ckpt_valid => false, ckpt => 0, writer => false );
            is_store := e.memory and op( 5 downto 4 ) = "10";
            is_ptr_store := is_store and ( op( 7 downto 6 ) = "10" or lvl = 15 );
            is_wblock := op = x"34" or op = x"3C" or op = x"3D" or op = x"3E" or op = x"3F" or op = x"45" or op = x"49";
            dl := -1; dv := ( others => '0' );

            if op = UOP_ILLEGAL or op = UOP_FETCH_FAULT or not e.defined then
               if op = UOP_FETCH_FAULT then fault := 132; else fault := 137; end if;
            else
               -- adresse connue au renommage
               if ( e.lvl_use = LVL_ADDR or e.lvl_use = LVL_FRAME ) and lvl <= 14
                  and op /= x"44" and op /= x"48" and op /= x"F8" and op /= x"F9" then
                  ri.address_known := '1';
                  ri.address := f.display( lvl ) + U64( slot.canon.val );
               end if;

               if op = x"F2" or op = x"33" then					-- CALL, CALLI
                  if op = x"33" then
                     READ_CELL( t_f.dsp, false, t ); SOURCE( t );
                     DOP( false, t_f.dsp, t ); t_f.dsp := t_f.dsp - 8;
                  end if;
                  DEST( t );
                  t_f.rsp := t_f.rsp - 8;
                  ROP( true, t_f.rsp, t );
                  XFER( XFER_SPILL, t_f.rsp, t, '0' );
               elsif op = x"F6" or op = x"F7" then				-- RTD n, RTD 0
                  t_f.dsp := t_f.dsp - unsigned( resize( unsigned( std_logic_vector( slot.canon.val ) ), 64 ) );
                  RLOOKUP( t_f.rsp, found, t );
                  if not found then
                     NEW_TAG( t ); XFER( XFER_FILL, t_f.rsp, t, '0' );
                     if inf.ntag < MAXTAGS then inf.tags( inf.ntag ) := t; inf.ntag := inf.ntag + 1; end if;
                  end if;
                  SOURCE( t );
                  ROP( false, t_f.rsp, t );
                  t_f.rsp := t_f.rsp + 8;
               elsif op = x"44" or op = x"48" then				-- LINK lvl, alloc
                  if lvl > 0 and lvl <= 14 then
                     ri.address_known := '1'; ri.address := f.display( lvl );	-- ancien DISPLAY[lvl]
                     DEST( t ); PUSH_CELL( t, '0' );
                     if t_shn < SHADOW_DEPTH then
                        t_sh( t_shn ) := ( lvl => lvl, val => f.display( lvl ), tag => t ); t_shn := t_shn + 1;
                     else								-- pleine : la plus ancienne est perdue
                        for j in 0 to SHADOW_DEPTH - 2 loop t_sh( j ) := t_sh( j + 1 ); end loop;
                        t_sh( SHADOW_DEPTH - 1 ) := ( lvl => lvl, val => f.display( lvl ), tag => t );
                     end if;
                     t_f.display( lvl ) := t_f.dsp; dl := lvl; dv := t_f.dsp;
                  end if;
                  alloc := resize( unsigned( std_logic_vector( slot.canon.val ) ), 36 ) + 7;
                  alloc( 2 downto 0 ) := "000";
                  t_f.dsp := t_f.dsp + resize( alloc, 64 );
               elsif op = x"F8" or op = x"F9" then				-- UNLINK, UNLINKR lvl
                  t_f.dsp := f.display( lvl );
                  LOOKUP( t_f.dsp, found, tg );					-- la cellule sauvée, inchangée ?
                  READ_CELL( t_f.dsp, false, t ); SOURCE( t );
                  DOP( false, t_f.dsp, t ); t_f.dsp := t_f.dsp - 8;
                  dl := lvl;
                  -- la pile d'ombre ne vaut que si la cellule est encore tenue par le registre
                  -- que LINK lui a donné, sans écrivain en vol (spéc. : DISPLAY[lvl] := pop)
                  if t_shn > 0 and t_sh( t_shn - 1 ).lvl = lvl and found and tg = t_sh( t_shn - 1 ).tag and not t_wt then
                     dv := t_sh( t_shn - 1 ).val; t_shn := t_shn - 1;
                     t_f.display( lvl ) := dv;
                  else
                     t_shn := 0; stop_after := true;				-- attente de FRAME_UPDATE_i
                     t_f.display( lvl ) := ( others => '0' );
                  end if;
               elsif op = OP_TRAP then						-- services (option B)
                  case to_integer( unsigned( std_logic_vector( slot.canon.val( 7 downto 0 ) ) ) ) is
                     when 16 | 18 =>
                        READ_CELL( t_f.dsp, false, t ); SOURCE( t );
                        DOP( false, t_f.dsp, t ); t_f.dsp := t_f.dsp - 8;
                        DEST( t ); PUSH_CELL( t, '0' );
                     when 0 | 17 =>
                        READ_CELL( t_f.dsp, true, t ); SOURCE( t );
                     when others => null;
                  end case;
               else									-- effets de la table
                  npop := e.pops; npush := e.pushes;
                  if e.lvl_use = LVL_ADDR and lvl = 15 then npop := npop + 1; end if;
                  case e.stack_action is
                     when STACK_LINEAR =>
                        for j in 0 to 3 loop						-- du plus profond au sommet
                           if j < npop then
                              READ_CELL( t_f.dsp - 8 * ( npop - 1 - j ), false, t ); SOURCE( t );
                           end if;
                        end loop;
                        for j in 0 to 3 loop
                           if j < npop then DOP( false, t_f.dsp - 8 * j, t ); end if;
                        end loop;
                        t_f.dsp := t_f.dsp - 8 * npop;
                        if npush > 0 then DEST( t ); PUSH_CELL( t, '0' ); end if;
                     when STACK_KEEP_TOP =>
                        READ_CELL( t_f.dsp, true, t ); SOURCE( t );
                     when STACK_DROP =>
                        DOP( false, t_f.dsp, t ); t_f.dsp := t_f.dsp - 8;
                     when STACK_DUP =>							-- ( a -- a a )
                        READ_CELL( t_f.dsp, true, t );
                        PUSH_CELL( t, READY_OF( t ) );
                     when STACK_OVER =>							-- ( a b -- a b a )
                        READ_CELL( t_f.dsp - 8, true, t );
                        PUSH_CELL( t, READY_OF( t ) );
                  end case;
               end if;

               -- rangement direct : la cellule recouverte prend la donnée, ou est oubliée
               if is_store and not is_ptr_store and ri.address_known = '1' and ok then
                  sz := 2 ** to_integer( unsigned( op( 1 downto 0 ) ) );
                  addr := ri.address( 63 downto 3 ) & "000";
                  if sz = 8 and ri.address( 2 downto 0 ) = "000" then
                     LOOKUP( ri.address, found, tg );
                     if found then DOP( true, ri.address, ri.source( inf.nsrc - 1 ) ); end if;
                  else
                     LOOKUP( addr, found, tg );
                     if found then DOP( false, addr, tg ); end if;
                     LOOKUP( addr + 8, found, tg );				-- à cheval sur deux cellules
                     if found and ri.address( 2 downto 0 ) /= "000" and to_integer( ri.address( 2 downto 0 ) ) + sz > 8 then
                        DOP( false, addr + 8, tg );
                     end if;
                  end if;
               end if;

               -- fautes 133, 134 (valeurs finales ; les dépilements précèdent les empilements)
               if t_f.dsp > LIMITS_i.lim_dsp and t_f.dsp > f.dsp then fault := 133;
               elsif t_f.rsp < LIMITS_i.lim_rsp and t_f.rsp < f.rsp then fault := 134;
               end if;
            end if;

            exit when not ok;							-- registres ou échanges épuisés
            if fault = 0 and e.control and nck = 0 then exit; end if;		-- pas de point de reprise libre
            if fault = 0 and ( is_ptr_store or is_wblock ) and nwr >= NWRIT then exit; end if;
            exit when t_nx > nx and STACK_XFER_READY_i = '0';

            -- l'instruction est prise
            al := ( valid => '1', pc => slot.pc, len => slot.canon.len, op => op, fault => NO_FAULT, done => '0',
                    serializing => B( e.serializing ), is_store => B( is_store ), is_control => B( e.control ),
                    pred => slot.pred, checkpoint_valid => '0', checkpoint => ( others => '0' ) );
            if fault /= 0 then
               al.fault := ( valid => '1', code => to_unsigned( fault, 8 ) ); al.done := '1';
               ri.issue_class := ISSUE_NONE; ri.execute_required := '0';
               ri.source_count := 0; ri.destination_valid := '0';
               inf.ntag := 0; inf.nsrc := 0;
               inf.hist := ( dsp => f.dsp, rsp => f.rsp, dlvl => -1, dval => ( others => '0' ) );
               fst := true;
            else
               f := t_f; sh := t_sh; shn := t_shn; dops := t_dops; ndops := t_ndops; rops := t_rops; nrops := t_nrops;
               ntaken := t_ntaken; nx := t_nx; xf := t_xf;
               ri.source_count := inf.nsrc;
               for j in 0 to MAX_SOURCE_COUNT - 1 loop
                  if j < inf.nsrc then ri.source_ready( j ) := READY_OF( ri.source( j ) ); end if;
               end loop;
               if e.issue_class = ISSUE_NONE then al.done := '1'; else ri.execute_required := '1'; end if;
               inf.hist := ( dsp => f.dsp, rsp => f.rsp, dlvl => dl, dval => dv );
               inf.writer := is_wblock;
               if is_ptr_store or is_wblock then
                  wrs( i ) := ( valid => true, ptr => is_ptr_store, rob => rob, seq => seq ); nwr := nwr + 1;
               end if;
               if e.control then							-- point de reprise
                  cid := -1;
                  for c in 0 to NCKPT - 1 loop
                     if cid < 0 and ck_used( c ) = '0' then cid := c; end if;
                  end loop;
                  ck_used( cid ) := '1'; nck := nck - 1;
                  cks( i ) := ( valid => true, id => cid, seq => seq, frame => f );
                  inf.ckpt_valid := true; inf.ckpt := cid;
                  al.checkpoint_valid := '1'; al.checkpoint := to_unsigned( cid, CHECKPOINT_BITS );
                  ri.checkpoint_valid := '1'; ri.checkpoint := to_unsigned( cid, CHECKPOINT_BITS );
               end if;
               if stop_after then
                  wt := true;
                  p_wait_rob <= rob; p_wait_lvl <= lvl;
               end if;
            end if;
            rb( i ) := ri; ab( i ) := al; info( i ) := inf;
            seq := seq + 1;
            k := i + 1;
            exit when fault /= 0 or stop_after;
         end loop;
      end if;

      p_k <= k;
      p_frame <= f; p_shadow <= sh; p_shadow_n <= shn;
      p_dops <= dops; p_ndops <= ndops; p_rops <= rops; p_nrops <= nrops;
      p_tags <= p_free_tags; p_ntags <= ntaken;
      p_info <= info; p_writers <= wrs; p_ckpts <= cks;
      p_wait <= wt; p_fstall <= fst;
      if not wt then p_wait_rob <= ( others => '0' ); p_wait_lvl <= 0; end if;

      DECODE_TAKE_o <= to_unsigned( k, DECODE_TAKE_o'length );
      RENAME_VALID_o <= B( k > 0 ); RENAME_BLOCK_o <= rb; RENAME_COUNT_o <= to_unsigned( k, RENAME_COUNT_o'length );
      ROB_ALLOC_VALID_o <= B( k > 0 ); ROB_ALLOC_BLOCK_o <= ab; ROB_ALLOC_COUNT_o <= to_unsigned( k, ROB_ALLOC_COUNT_o'length );
      STACK_XFER_o <= xf;
      STALLED_o <= B( k = 0 and DECODE_COUNT_i /= 0 );
   end process;

   COMMITTED_FRAME_o	<= frame_c;
   STACK_MAINT_DONE_o	<= maint_done;
   R2_INACTIF : process								-- STACK_LOOKUP : étape R2
   begin
      for l in STACK_LOOKUP_o'range loop
         STACK_LOOKUP_o( l ) <= ( valid => '0', hit => '0', tag => ( others => '0' ) );
      end loop;
      wait;
   end process;

		--------------------------------------------------------------------------------
		-- Au front
		--------------------------------------------------------------------------------

   ETAT : process( CLK_i )
      variable fs, fc		: frame_state_t;
      variable dc		: cell_array_t;
      variable dp		: natural range 0 to CELLS - 1;
      variable rc		: rcell_array_t;
      variable rp		: natural range 0 to RCELL_COUNT - 1;
      variable inf		: robinfo_array_t;
      variable hd, tl		: rob_index_t;
      variable wr		: writer_array_t;
      variable ck		: ckpt_array_t;
      variable al, rd, pr	: std_logic_vector( 0 to NTAGS - 1 );
      variable rdr, mc		: nat_tags_t;
      variable qu		: quar_t;
      variable r		: rob_index_t;
      variable n, ti		: natural;
      variable keep_seq	: seq_t;
      variable abandon		: boolean;
      variable oldest		: integer;
      variable ws		: seq_t;

      procedure UNMAP_TAG( x : physical_tag_t ) is
      begin
         if mc( to_integer( x ) ) > 0 then mc( to_integer( x ) ) := mc( to_integer( x ) ) - 1; end if;
      end procedure;

      procedure FORGET_D( a : address_t ) is
      begin
         for i in 0 to CELLS - 1 loop
            if dc( i ).valid and dc( i ).addr = a then dc( i ).valid := false; UNMAP_TAG( dc( i ).tag ); end if;
         end loop;
      end procedure;

      procedure SET_D( a : address_t; x : physical_tag_t; s : seq_t ) is
      begin
         FORGET_D( a );
         if dc( dp ).valid then UNMAP_TAG( dc( dp ).tag ); end if;		-- la plus ancienne, oubliée
         dc( dp ) := ( valid => true, addr => a, tag => x, wseq => s );
         mc( to_integer( x ) ) := mc( to_integer( x ) ) + 1;
         dp := ( dp + 1 ) mod CELLS;
      end procedure;

      procedure FORGET_R( a : address_t ) is
      begin
         for i in 0 to RCELL_COUNT - 1 loop
            if rc( i ).valid and rc( i ).addr = a then rc( i ).valid := false; UNMAP_TAG( rc( i ).tag ); end if;
         end loop;
      end procedure;

      procedure SET_R( a : address_t; x : physical_tag_t; s : seq_t ) is
      begin
         FORGET_R( a );
         if rc( rp ).valid then UNMAP_TAG( rc( rp ).tag ); end if;
         rc( rp ) := ( valid => true, addr => a, tag => x, wseq => s );
         mc( to_integer( x ) ) := mc( to_integer( x ) ) + 1;
         rp := ( rp + 1 ) mod RCELL_COUNT;
      end procedure;

      -- une instruction quitte la machine (retrait ou abandon)
      procedure LEAVE( rr : rob_index_t ) is
      begin
         for j in 0 to MAXTAGS - 1 loop
            if j < inf( to_integer( rr ) ).ntag then pr( to_integer( inf( to_integer( rr ) ).tags( j ) ) ) := '0'; end if;
         end loop;
         for j in 0 to MAX_SOURCE_COUNT - 1 loop
            if j < inf( to_integer( rr ) ).nsrc then
               ti := to_integer( inf( to_integer( rr ) ).srcs( j ) );
               if rdr( ti ) > 0 then rdr( ti ) := rdr( ti ) - 1; end if;
            end if;
         end loop;
         if inf( to_integer( rr ) ).ckpt_valid then ck( inf( to_integer( rr ) ).ckpt ).valid := false; end if;
         if inf( to_integer( rr ) ).writer then
            for w in 0 to NWRIT - 1 loop
               if wr( w ).valid and not wr( w ).ptr and wr( w ).seq = inf( to_integer( rr ) ).seq then wr( w ).valid := false; end if;
            end loop;
         end if;
         inf( to_integer( rr ) ).valid := false;
      end procedure;

      procedure CLEAR_MAPS is
      begin
         dc := ( others => NO_CELL ); rc := ( others => NO_CELL );
         mc := ( others => 0 );
      end procedure;

   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            frame_s <= ( dsp => ( others => '0' ), rsp => ( others => '0' ), display => ( others => ( others => '0' ) ) );
            frame_c <= ( dsp => ( others => '0' ), rsp => ( others => '0' ), display => ( others => ( others => '0' ) ) );
            shadow_n <= 0; dcells <= ( others => NO_CELL ); rcells <= ( others => NO_CELL ); dptr <= 0; rptr <= 0;
            for i in 0 to ROB_SIZE - 1 loop
               robinfo( i ).valid <= false;
            end loop;
            r_head <= ( others => '0' ); r_tail <= ( others => '0' );
            writers <= ( others => ( valid => false, ptr => false, rob => ( others => '0' ), seq => 0 ) );
            for i in 0 to NCKPT - 1 loop ckpts( i ).valid <= false; end loop;
            seq_next <= 0; waiting <= false; fstall <= false;
            allocated <= ( others => '0' ); ready <= ( others => '1' ); producing <= ( others => '0' );
            readers <= ( others => 0 ); mapcnt <= ( others => 0 ); quar <= ( others => 0 );
            maint_done <= '0';
         else
            fs := frame_s; fc := frame_c; dc := dcells; dp := dptr; rc := rcells; rp := rptr; inf := robinfo;
            hd := r_head; tl := r_tail; wr := writers; ck := ckpts;
            al := allocated; rd := ready; pr := producing; rdr := readers; mc := mapcnt; qu := quar;

            -- le bloc renommé (pris : le plan ne propose rien sans pouvoir le donner)
            if p_k > 0 then
               fs := p_frame; shadow <= p_shadow; shadow_n <= p_shadow_n;
               for j in 0 to UPD - 1 loop
                  if j < p_ndops then
                     if p_dops( j ).set then SET_D( p_dops( j ).addr, p_dops( j ).tag, p_dops( j ).wseq );
                     else FORGET_D( p_dops( j ).addr ); end if;
                  end if;
               end loop;
               for j in 0 to RUPD - 1 loop
                  if j < p_nrops then
                     if p_rops( j ).set then SET_R( p_rops( j ).addr, p_rops( j ).tag, p_rops( j ).wseq );
                     else FORGET_R( p_rops( j ).addr ); end if;
                  end if;
               end loop;
               for j in 0 to BLKTAGS - 1 loop						-- registres neufs
                  if j < p_ntags then
                     ti := to_integer( p_tags( j ) );
                     al( ti ) := '1'; rd( ti ) := '0'; pr( ti ) := '1'; rdr( ti ) := 0;
                  end if;
               end loop;
               for i in 0 to DECODE_WIDTH - 1 loop
                  if i < p_k then
                     r := ROB_TAIL_i + i;
                     inf( to_integer( r ) ) := p_info( i );
                     for j in 0 to MAX_SOURCE_COUNT - 1 loop
                        if j < p_info( i ).nsrc then
                           ti := to_integer( p_info( i ).srcs( j ) ); rdr( ti ) := rdr( ti ) + 1;
                        end if;
                     end loop;
                     if p_writers( i ).valid then
                        for w in 0 to NWRIT - 1 loop
                           if not wr( w ).valid then wr( w ) := p_writers( i ); exit; end if;
                        end loop;
                     end if;
                     if p_ckpts( i ).valid then
                        ck( p_ckpts( i ).id ) := ( valid => true, seq => p_ckpts( i ).seq, frame => p_ckpts( i ).frame );
                     end if;
                  end if;
               end loop;
               tl := ROB_TAIL_i + p_k;
               seq_next <= seq_next + p_k;
               waiting <= p_wait; wait_rob <= p_wait_rob; wait_lvl <= p_wait_lvl;
               fstall <= p_fstall;
            end if;

            -- réveils
            for w in WAKEUP_i'range loop
               if WAKEUP_i( w ).valid = '1' then rd( to_integer( WAKEUP_i( w ).tag ) ) := '1'; end if;
            end loop;

            -- FRAME_UPDATE : DISPLAY[lvl] restauré par UNLINK (avant les retraits du cycle)
            if waiting and FRAME_UPDATE_i.valid = '1' and FRAME_UPDATE_i.rob_index = wait_rob then
               fs.display( wait_lvl ) := FRAME_UPDATE_i.value;
               inf( to_integer( wait_rob ) ).hist.dval := FRAME_UPDATE_i.value;
               waiting <= false;
            end if;

            -- retraits : l'état retiré avance
            for j in 0 to RETIRE_WIDTH - 1 loop
               if j < to_integer( RETIRE_COUNT_i ) then
                  r := hd;
                  fc.dsp := inf( to_integer( r ) ).hist.dsp; fc.rsp := inf( to_integer( r ) ).hist.rsp;
                  if inf( to_integer( r ) ).hist.dlvl >= 0 then
                     fc.display( inf( to_integer( r ) ).hist.dlvl ) := inf( to_integer( r ) ).hist.dval;
                  end if;
                  LEAVE( r );
                  hd := hd + 1;
               end if;
            end loop;

            -- invalidations (rangements par pointeur écrits) : l'écrivain le plus ancien de ce rob
            for l in STACK_INVALIDATE_i'range loop
               if STACK_INVALIDATE_i( l ).valid = '1' then
                  oldest := -1; ws := 0;
                  for w in 0 to NWRIT - 1 loop
                     if wr( w ).valid and wr( w ).ptr and wr( w ).rob = STACK_INVALIDATE_i( l ).rob_index
                        and ( oldest < 0 or wr( w ).seq < ws ) then
                        oldest := w; ws := wr( w ).seq;
                     end if;
                  end loop;
                  if oldest >= 0 then
                     wr( oldest ).valid := false;
                     for i in 0 to CELLS - 1 loop					-- la cellule, si son registre est plus ancien
                        if dc( i ).valid and dc( i ).addr( 63 downto 3 ) = STACK_INVALIDATE_i( l ).address( 63 downto 3 )
                           and OLDER( dc( i ).wseq, ws ) then
                           dc( i ).valid := false; UNMAP_TAG( dc( i ).tag );
                        end if;
                     end loop;
                  end if;
               end if;
            end loop;

            -- maintenance : la mémoire est à jour ; l'invalidation oublie les cellules
            maint_done <= STACK_MAINT_i.valid;
            if STACK_MAINT_i.valid = '1' and STACK_MAINT_i.kind = MAINT_INVALIDATE_RANGE then
               for i in 0 to CELLS - 1 loop
                  if dc( i ).valid and dc( i ).addr + 8 > STACK_MAINT_i.base
                     and dc( i ).addr < STACK_MAINT_i.base + STACK_MAINT_i.length then
                     dc( i ).valid := false; UNMAP_TAG( dc( i ).tag );
                  end if;
               end loop;
            end if;

            -- reprise : frame du point de reprise ou retirée ; tout le reste est oublié
            if RECOVERY_i.valid = '1' then
               if RECOVERY_i.kind = RECOVER_CHECKPOINT then
                  keep_seq := inf( to_integer( RECOVERY_i.keep_last ) ).seq;
                  fs := ck( to_integer( RECOVERY_i.checkpoint ) ).frame;
               else
                  keep_seq := 0;
                  fs := fc;
               end if;
               -- rangements par pointeur abandonnés (encore en vol) ; ceux qui sont déjà
               -- retirés attendent leur invalidation et restent
               for w in 0 to NWRIT - 1 loop
                  if wr( w ).valid and wr( w ).ptr and ( RECOVERY_i.kind = RECOVER_COMMITTED or wr( w ).seq > keep_seq )
                     and inf( to_integer( wr( w ).rob ) ).valid and inf( to_integer( wr( w ).rob ) ).seq = wr( w ).seq then
                     wr( w ).valid := false;
                  end if;
               end loop;
               r := hd;
               for j in 0 to ROB_SIZE - 1 loop						-- les abandonnées
                  exit when r = tl;
                  abandon := RECOVERY_i.kind = RECOVER_COMMITTED or inf( to_integer( r ) ).seq > keep_seq;
                  if abandon and inf( to_integer( r ) ).valid then LEAVE( r ); end if;	-- (blocs : leurs écrivains)
                  r := r + 1;
               end loop;
               if RECOVERY_i.kind = RECOVER_COMMITTED then tl := hd; else tl := RECOVERY_i.keep_last + 1; end if;
               CLEAR_MAPS;
               shadow_n <= 0; waiting <= false; fstall <= false;
            end if;

            -- SYNC (au cycle d'une reprise) : l'état imposé, spéculatif et retiré
            if SYNC_VALID_i = '1' then
               fs := SYNC_FRAME_i; fc := SYNC_FRAME_i;
               CLEAR_MAPS;
               shadow_n <= 0; waiting <= false;
            end if;

            -- libération des registres, avec quarantaine
            for t in 0 to NTAGS - 1 loop
               if qu( t ) > 0 then
                  qu( t ) := qu( t ) - 1;
               elsif al( t ) = '1' and pr( t ) = '0' and rdr( t ) = 0 and mc( t ) = 0 then
                  al( t ) := '0'; qu( t ) := QUARANTINE;
               end if;
            end loop;

            frame_s <= fs; frame_c <= fc; dcells <= dc; dptr <= dp; rcells <= rc; rptr <= rp; robinfo <= inf;
            r_head <= hd; r_tail <= tl; writers <= wr; ckpts <= ck;
            allocated <= al; ready <= rd; producing <= pr; readers <= rdr; mapcnt <= mc; quar <= qu;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
