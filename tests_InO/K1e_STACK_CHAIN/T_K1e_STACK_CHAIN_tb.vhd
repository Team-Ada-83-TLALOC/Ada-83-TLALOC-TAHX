library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
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
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- T_K1e_STACK_CHAIN_tb : prise sur le cycle du commit (V2, étude de vitesse).
        --
        -- Les bancs K1* présentent une instruction à la fois : l'instruction suivante
        -- n'est jamais offerte au cycle d'un commit. Ce banc offre un flux continu
        -- (DECODE_QUEUE presque toujours non vide) d'un programme tiré au hasard,
        -- exécuté auparavant sur un modèle de référence (pile en mémoire, DSP) :
        --
        --   LI, ADD, SUB, OUX, CGT, NEG, INC, MUL, DUP, DROP, OVER, BRA, BT, BF,
        --   LQ / SQ directs [B16] lvl 0 vers une zone de données ou vers une
        --   cellule vivante de la pile (cohérence du cache de pile) ;
        --   (V4) LIQ / SIQ [C24] lvl 0 par une table de pointeurs, ou par une
        --   cellule pointeur vivante de la pile ; LQ / SQ / LIQ / SIQ à adresse
        --   sur la pile (lvl 15), précédés des LI qui la poussent ; LVA [B16]
        --   vers une cellule vivante ou la zone de données.
        --   (V5) chargements partiels LB / LW / LD, signés ou non, [B16] lvl 0, à
        --   tout décalage, vers une cellule vivante (servis par le cache de pile
        --   quand ils y tiennent) ou la zone de données, parfois à cheval sur deux
        --   cellules.
        --   (V5) rangements partiels SB / SW / SD / SQ [B16] lvl 0 dans une cellule
        --   vivante sous le sommet ou dans la zone de données, contenus ou à cheval ;
        --   séquence V8 « LVA a ; LI v ; SQ a ; LQ (lvl 15) ; INC » : un rangement
        --   dans une cellule exposée doit être vu par la lecture calculée.
        --   (V5) CALL / RTD imbriqués jusqu'à une profondeur de 24, pour un cache
        --   des retours de 8 entrées : l'adresse de retour reçue par chaque RTD est
        --   vérifiée, ainsi que RSP à la fin.
        -- Les accès calculés (lvl 15, pointeurs) ne visent que la zone de données
        -- (règles V8). La zone de données est faite de 48 mots de valeurs, seuls
        -- écrits, et d'une table de 16 pointeurs vers ces valeurs.
        --
        -- Cache de pile de 16 mots (configuration TAHX) et profondeur jusqu'à 40 :
        -- SPILL/FILL et collisions fréquents. ISSUE_READY, latence de COMPLETE,
        -- offre de DECODE et acceptation mémoire sont tirés au hasard ; l'entier, MUL
        -- et les branches terminent une fois sur deux dans le cycle d'émission
        -- (COMPLETE combinatoire, V3). Les mauvaises
        -- prédictions (BT/BF) sont volontaires : elles interdisent l'enchaînement.
        --
        -- Vérifications : opérandes de chaque ISSUE (ordre du programme), opcode et
        -- PC de chaque COMMIT, absence de faute, puis après WRITEBACK_ALL : DSP final
        -- et mémoire (cellules vivantes de la pile et zone de données). Le banc
        -- compte aussi les prises enchaînées (chain_s, nom externe) : il en exige.
        --------------------------------------------------------------------------------


                                -------------------
entity                          T_K1e_STACK_CHAIN_tb
is                              -------------------
end entity                      T_K1e_STACK_CHAIN_tb;
                                -------------------


                                ----
architecture                    TEST
of T_K1e_STACK_CHAIN_tb is      ----

   constant PERIOD      : time := 10 ns;
   constant N_INSN      : positive := 6000;
   constant DMAX        : positive := 40;                  -- profondeur maximale de pile
   constant S0          : natural := 16#100000#;           -- DSP initial : pile vide
   constant MBASE       : natural := S0 - 512;             -- DISPLAY(0) : zone de données
   constant DATA_WORDS  : positive := 64;                  -- [ MBASE, S0 )
   constant RET_WORDS   : positive := 32;                  -- pile des retours (V5)
   constant RDMAX       : positive := 24;                  -- profondeur d'appel maximale
   constant MEM_WORDS   : positive := DATA_WORDS + DMAX + 8 + RET_WORDS;
   constant RSP0        : natural := MBASE + 8 * MEM_WORDS; -- RSP initial (pile vide)
   constant P0          : natural := 16#400000#;
   constant SEED_1      : positive := 2026;
   constant SEED_2      : positive := 1022;

   constant OP_OUX_T    : opcode_t := x"02";
   constant OP_NEG_T    : opcode_t := x"08";
   constant OP_CGT_T    : opcode_t := x"09";
   constant OP_ADD_T    : opcode_t := x"10";
   constant OP_INC_T    : opcode_t := x"11";
   constant OP_SUB_T    : opcode_t := x"12";
   constant OP_MUL_T    : opcode_t := x"14";
   constant OP_DROP_T   : opcode_t := x"30";
   constant OP_DUP_T    : opcode_t := x"31";
   constant OP_OVER_T   : opcode_t := x"32";
   constant OP_LQ_T     : opcode_t := x"57";
   constant OP_SQ_T     : opcode_t := x"67";
   constant OP_LI_T     : opcode_t := x"C2";
   constant OP_BRA_T    : opcode_t := x"E1";
   constant OP_BT_T     : opcode_t := x"E5";
   constant OP_BF_T     : opcode_t := x"E9";
   constant OP_CALL_T   : opcode_t := x"F2";
   constant OP_RTD0_T   : opcode_t := x"F7";
   constant OP_LVA_T    : opcode_t := x"47";               -- LVA [B16]
   constant OP_LQ0_T    : opcode_t := x"53";               -- LQ, adresse sur la pile
   constant OP_SQ0_T    : opcode_t := x"63";               -- SQ, adresse sur la pile
   constant OP_LIQ0_T   : opcode_t := x"93";               -- LIQ, cellule pointeur sur la pile
   constant OP_LIQ_T    : opcode_t := x"97";               -- LIQ [C24]
   constant OP_SIQ0_T   : opcode_t := x"A3";               -- SIQ, cellule pointeur sur la pile
   constant OP_SIQ_T    : opcode_t := x"A7";               -- SIQ [C24]
   constant VAL_WORDS   : positive := 48;                  -- valeurs ; puis 16 pointeurs

   type mem_t           is array( 0 to MEM_WORDS - 1 ) of word64_t;
   type prog_t          is array( 0 to N_INSN - 1 ) of decoded_slot_t;
   type operands_t      is array( 0 to 3 ) of word64_t;
   -- Opérandes attendus à l'émission, par instruction (indice (pc - P0) / 16) :
   -- un chargement servi par le cache de pile (V5) n'est pas émis.
   type exp_t           is record
                           e  : boolean;              -- émission possible
                           n  : natural range 0 to 4;
                           op : operands_t;
                           ret : address_t;           -- RTD : adresse de retour attendue
                        end record;
   type exp_array_t     is array( 0 to N_INSN - 1 ) of exp_t;

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   constant NO_COMPLETE : ino_complete_t := (
      valid => '0', result_valid => '0', result => ( others => '0' ),
      fault => NO_FAULT, taken => '0', target => ( others => '0' ) );

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function INIT_WORD( i : natural ) return word64_t is
   begin
      if i >= VAL_WORDS and i < DATA_WORDS then
         -- Table de pointeurs : vers les valeurs 0 .. 39 (pointeur + ofs <= 39 + 7).
         return std_logic_vector( to_unsigned( MBASE + 8 * ( ( i * 7 ) mod 40 ), 64 ) );
      elsif i < DATA_WORDS then
         return std_logic_vector( to_unsigned( ( i * 7919 + 13 ) mod 65536, 32 ) )
                & std_logic_vector( to_unsigned( ( i * 104729 + 7 ) mod 65536, 32 ) );
      end if;
      return ( others => '0' );
   end function;

   function INIT_MEM return mem_t is
      variable m : mem_t;
   begin
      for i in m'range loop m( i ) := INIT_WORD( i ); end loop;
      return m;
   end function;

   function WIDX( a : address_t ) return natural is
   begin
      return to_integer( ( a - A64( MBASE ) ) / 8 );
   end function;

   -- Écriture des 2**sz octets bas de v à l'adresse a (petit-boutiste, à cheval sur
   -- deux mots possible).
   procedure MWRITE( m : inout mem_t; a : natural; sz : natural; v : word64_t ) is
      variable w : word64_t;
      variable b : natural;
   begin
      for i in 0 to 7 loop
         if i < 2 ** sz then
            w := m( ( a + i - MBASE ) / 8 );
            b := ( a + i ) mod 8;
            w( 8 * b + 7 downto 8 * b ) := v( 8 * i + 7 downto 8 * i );
            m( ( a + i - MBASE ) / 8 ) := w;
         end if;
      end loop;
   end procedure;

   -- Lecture de 2**sz octets à l'adresse a (petit-boutiste, à cheval sur deux mots
   -- possible), étendue comme par le cache de données.
   function MREAD( m : mem_t; a : natural; sz : natural; sgn : boolean ) return word64_t is
      variable r : word64_t := ( others => '0' );
      variable n : natural := 2 ** sz;
      variable w : word64_t;
      variable b : natural;
   begin
      for i in 0 to 7 loop
         if i < n then
            w := m( ( a + i - MBASE ) / 8 );
            b := ( a + i ) mod 8;
            r( 8 * i + 7 downto 8 * i ) := w( 8 * b + 7 downto 8 * b );
         end if;
      end loop;
      if sgn and n < 8 and r( 8 * n - 1 ) = '1' then
         for i in 0 to 63 loop
            if i >= 8 * n then r( i ) := '1'; end if;
         end loop;
      end if;
      return r;
   end function;

   -- Résultat d'une opération (référence et exécuteur) ; a : le plus profond.
   function RESULT( op : opcode_t; val : signed; a, b : word64_t ) return word64_t is
      variable p : signed( 127 downto 0 );
   begin
      case op is
         when x"02" => return a xor b;
         when x"08" => return std_logic_vector( - signed( a ) );
         when x"09" => if signed( a ) > signed( b ) then return x"0000000000000001";
                       else return ( others => '0' ); end if;
         when x"10" => return std_logic_vector( signed( a ) + signed( b ) );
         when x"11" => return std_logic_vector( signed( a ) + 1 );
         when x"12" => return std_logic_vector( signed( a ) - signed( b ) );
         when x"14" => p := signed( a ) * signed( b ); return std_logic_vector( p( 63 downto 0 ) );
         when x"C2" => return std_logic_vector( resize( val, 64 ) );
         when others => return ( others => '0' );
      end case;
   end function;

   function TARGET_OF( pc : address_t ) return address_t is
   begin
      return pc + 64;
   end function;

   -- Terminaison d'une instruction hors mémoire (entier, MUL, branches).
   function COMPLETION( i : ino_issue_t ) return ino_complete_t is
      constant op : opcode_t := i.slot.canon.op;
      variable r  : ino_complete_t := NO_COMPLETE;
      variable va : word64_t := i.operand( 0 );
   begin
      r.valid := '1';
      if op = OP_CALL_T then
         r.taken  := '1';
         r.target := TARGET_OF( i.slot.pc );
      elsif op = OP_RTD0_T then
         -- Cible : adresse de retour fournie par STACK_UNIT.
         r.taken  := '1';
         r.target := i.address;
      elsif op = OP_BRA_T or op = OP_BT_T or op = OP_BF_T then
         r.taken := '1';
         if ( op = OP_BT_T and va = x"0000000000000000" )
            or ( op = OP_BF_T and va /= x"0000000000000000" ) then
            r.taken := '0';
         end if;
         if r.taken = '1' then
            r.target := TARGET_OF( i.slot.pc );
         else
            r.target := i.slot.pc + resize( i.slot.canon.len, 64 );
         end if;
      elsif op = OP_LVA_T then
         -- Comme INO_INTEGER_UNIT : DISPLAY(lvl) + val, ou sommet + val (lvl 15).
         r.result_valid := '1';
         if i.address_known = '1' then
            r.result := std_logic_vector( i.address );
         else
            r.result := std_logic_vector( unsigned( va ) + unsigned( resize( i.slot.canon.val, 64 ) ) );
         end if;
      else
         r.result_valid := '1';
         r.result := RESULT( op, i.slot.canon.val, va, i.operand( 1 ) );
      end if;
      return r;
   end function;

   signal clk           : std_logic := '0';
   signal running       : boolean := true;
   signal reset         : std_logic := '1';

   -- Programme et attentes (écrits par GENERATE avant le départ).
   signal prog          : prog_t := ( others => NO_SLOT );
   signal expect        : exp_array_t;
   signal n_expect      : natural := 0;
   signal nop_ld        : natural := 0;              -- accès directs (chargements, rangements)
   signal final_d       : natural := 0;
   signal final_rd      : natural := 0;              -- profondeur d'appel finale
   signal final_mem     : mem_t;
   signal gen_done      : boolean := false;
   signal go            : boolean := false;

   -- DECODE_QUEUE du banc.
   signal ptr           : natural := 0;
   signal offer         : std_logic := '0';
   signal decode_valid  : std_logic;
   signal decode_slot   : decoded_slot_t := NO_SLOT;
   signal decode_take   : std_logic;

   signal issue_valid   : std_logic;
   signal issue         : ino_issue_t;
   signal issue_ready   : std_logic := '0';
   signal complete      : ino_complete_t := NO_COMPLETE;
   -- Terminaison enregistrée (latence 1 à 3) ou, une fois sur deux pour l'entier,
   -- MUL et les branches, combinatoire dans le cycle d'émission (comme V3).
   signal complete_reg  : ino_complete_t := NO_COMPLETE;
   signal complete_comb : ino_complete_t := NO_COMPLETE;
   signal same_cycle    : std_logic := '0';
   signal same_count    : natural := 0;
   signal commit        : ino_commit_t;
   signal frame         : frame_state_t;

   signal sync_valid    : std_logic := '0';
   signal sync_frame    : frame_state_t := ( dsp => ( others => '0' ), rsp => ( others => '0' ),
                                             display => ( others => ( others => '0' ) ) );
   signal maint         : stack_maint_t := ( valid => '0', kind => MAINT_WRITEBACK_ALL,
                                             base => ( others => '0' ), length => ( others => '0' ) );
   signal maint_done    : std_logic;
   signal mem_req       : mem_request_t;
   signal mem_ready     : std_logic := '0';
   signal mem_rsp       : mem_response_t := NO_MEM_RESPONSE;
   signal idle          : std_logic;

   -- Mémoire du banc, publiée pour la vérification finale.
   signal mem_copy      : mem_t;
   signal exec_errors   : natural := 0;
   signal exec_checks   : natural := 0;
   signal issued        : natural := 0;
   signal spills, fills : natural := 0;

begin

   decode_valid <= offer when ptr < N_INSN and go else '0';
   decode_slot  <= prog( ptr ) when ptr < N_INSN else NO_SLOT;

   DUT : entity work.STACK_UNIT_WIDE
      generic map ( STACK_CACHE_WORDS_G => 16, RETURN_CACHE_WORDS_G => 8 )
      port map (
         CLK_i => clk, RESET_i => reset,
         DECODE_VALID_i => decode_valid, DECODE_SLOT_i => decode_slot, DECODE_TAKE_o => decode_take,
         ISSUE_VALID_o => issue_valid, ISSUE_o => issue, ISSUE_READY_i => issue_ready,
         COMPLETE_i => complete, COMMIT_o => commit,
         FRAME_o => frame, LIM_DSP_i => ( others => '1' ), LIM_RSP_i => ( others => '0' ),
         SYNC_VALID_i => sync_valid, SYNC_FRAME_i => sync_frame, SYNC_BUSY_o => open,
         MAINT_i => maint, MAINT_DONE_o => maint_done,
         MEM_REQ_o => mem_req, MEM_READY_i => mem_ready, MEM_RSP_i => mem_rsp,
         IDLE_o => idle );

   clk <= not clk after PERIOD / 2 when running;

   complete <= complete_comb when complete_comb.valid = '1' else complete_reg;

   COMB : process( all )
   begin
      complete_comb <= NO_COMPLETE;
      if reset = '0' and same_cycle = '1' and issue_valid = '1' and issue_ready = '1'
         and issue.issue_class /= ISSUE_MEMORY then
         complete_comb <= COMPLETION( issue );
      end if;
   end process COMB;

        --------------------------------------------------------------------------------
        -- Programme tiré au hasard, exécuté sur la référence : pile = mémoire aux
        -- adresses ( S0, S0 + 8 d ], DSP = S0 + 8 d.
        --------------------------------------------------------------------------------

   GENERATE_PROG : process
      variable s1, s2 : positive := SEED_1;
      variable r      : real;
      variable m      : mem_t := INIT_MEM;
      variable d      : natural := 0;
      variable p      : prog_t;
      variable x      : exp_array_t := ( others => ( e => false, n => 0,
                                                    op => ( others => ( others => '0' ) ),
                                                    ret => ( others => '0' ) ) );
      type ret_stack_t is array( 0 to RDMAX ) of natural;
      variable rs     : ret_stack_t := ( others => 0 );
      variable rd_n   : natural := 0;                  -- profondeur d'appel
      variable rd_max : natural := 0;
      variable cur_i  : natural := 0;
      variable nx     : natural := 0;
      variable sl     : decoded_slot_t;
      variable op     : opcode_t;
      variable k, a, v : integer;
      variable va, vb : word64_t;
      variable tk     : std_logic;
      variable dmaxv  : natural := 0;
      variable force_inc, top_store : boolean := false;
      -- Séquences de plusieurs instructions (V4) : LI d'une adresse, puis l'accès.
      variable seq      : natural := 0;                -- étape suivante, 0 : aucune
      variable seq_op   : opcode_t := x"00";           -- accès qui termine la séquence
      variable seq_lvl  : std_logic_vector( 3 downto 0 ) := "0000";
      variable seq_val  : integer := 0;
      variable seq_ofs  : natural := 0;
      variable seq_li   : integer := 0;                -- valeur du LI suivant
      variable ia, ptr  : natural;
      variable nkind    : natural := 0;
      variable seq_start : boolean := false;
      variable lva_a     : natural := 0;            -- LVA d'une séquence : cellule exposée
      variable sq_a      : natural := 0;            -- SQ d'une séquence : même cellule
      variable seq_inc   : boolean := false;        -- INC consommateur après la séquence
      type count_t is array( 0 to 255 ) of natural;
      variable nop      : count_t := ( others => 0 );

      impure function RAND_INT( n : natural ) return natural is   -- 0 .. n - 1
      begin
         uniform( s1, s2, r );
         return integer( trunc( r * real( n ) ) ) mod n;
      end function;

      impure function TOP( j : natural ) return word64_t is       -- j = 0 : sommet
      begin
         return m( WIDX( A64( S0 + 8 * ( d - j ) ) ) );
      end function;

      procedure PUSH( w : word64_t ) is
      begin
         d := d + 1;
         m( WIDX( A64( S0 + 8 * d ) ) ) := w;
      end procedure;

      procedure EXPECT_OPS( n : natural ) is              -- n sources, la plus profonde d'abord
      begin
         x( cur_i ).e := true;
         x( cur_i ).n := n;
         x( cur_i ).op := ( others => ( others => '0' ) );
         for j in 0 to 3 loop
            if j < n then x( cur_i ).op( j ) := TOP( n - 1 - j ); end if;
         end loop;
         nx := nx + 1;
      end procedure;

   begin
      s2 := SEED_2;
      for i in 0 to N_INSN - 1 loop
         cur_i := i;
         -- Tirage d'une opération possible à la profondeur d. Par phases de 150
         -- instructions, la pile monte (empilements favorisés) ou descend : les
         -- excursions jusqu'à DMAX font déborder le cache de pile de 16 mots.
         loop
            k := RAND_INT( 36 );
            top_store := false;
            seq_start := false;
            if seq = 1 or seq = 3 then
               -- LI (adresse, cellule pointeur, ou valeur) d'une séquence.
               op := OP_LI_T;
               exit;
            elsif seq = 4 then
               op := OP_SQ_T;
               exit;
            elsif seq = 2 then
               op := seq_op;
               exit;
            elsif force_inc and d >= 1 then
               -- Consommateur immédiat de la cellule rangée par le SQ précédent.
               op := OP_INC_T;
               exit;
            elsif ( i / 150 ) mod 2 = 1 and d >= 2 and RAND_INT( 8 ) = 0 then
               -- SQ vers la cellule qui devient le sommet (souvent propre après un
               -- FILL dans une phase de descente), puis INC : l'invalidation de la
               -- copie du cache de pile doit être vue par la prise enchaînée.
               op := OP_SQ_T;
               top_store := true;
               exit;
            elsif ( i / 150 ) mod 2 = 0 and RAND_INT( 3 ) = 0 then
               k := 0;                                    -- LI
            elsif ( i / 150 ) mod 2 = 1 and RAND_INT( 3 ) = 0 then
               k := 12;                                   -- DROP
            end if;
            case k is
               when 0 | 1 | 2 => op := OP_LI_T;   exit when d < DMAX;
               when 3      => op := OP_ADD_T;  exit when d >= 2;
               when 4      => op := OP_SUB_T;  exit when d >= 2;
               when 5      => op := OP_OUX_T;  exit when d >= 2;
               when 6      => op := OP_CGT_T;  exit when d >= 2;
               when 7      => op := OP_NEG_T;  exit when d >= 1;
               when 8      => op := OP_INC_T;  exit when d >= 1;
               when 9      => op := OP_MUL_T;  exit when d >= 2;
               when 10     => op := OP_DUP_T;  exit when d >= 1 and d < DMAX;
               when 11     => op := OP_OVER_T; exit when d >= 2 and d < DMAX;
               when 12 | 13 => op := OP_DROP_T; exit when d >= 1;
               when 14 | 32 | 33 | 34 | 35 =>
                  -- BRA, ou CALL / RTD (V5) : appels imbriqués, un peu plus d'appels
                  -- que de retours dans les phases montantes.
                  case RAND_INT( 4 ) is
                     when 0 => op := OP_BRA_T; exit;
                     when 1 | 2 =>
                        -- Phases d'appel de 600 instructions : profondeur jusqu'à RDMAX.
                        if ( ( i / 600 ) mod 2 = 0 and rd_n < RDMAX ) or rd_n = 0 then
                           op := OP_CALL_T; exit;
                        end if;
                        op := OP_RTD0_T; exit;
                     when others =>
                        if rd_n > 0 then op := OP_RTD0_T; exit; end if;
                        op := OP_CALL_T; exit;
                  end case;
               when 15     => op := OP_BT_T;   exit when d >= 1;
               when 16     => op := OP_BF_T;   exit when d >= 1;
               when 17 | 18 => op := OP_LQ_T;  exit when d < DMAX;
               when 19 => op := OP_SQ_T;   exit when d >= 1;
               when 20 => op := OP_LIQ_T;  exit when d < DMAX;
               when 21 => op := OP_SIQ_T;  exit when d >= 1;
               when 22 => op := OP_LVA_T;  exit when d < DMAX;
               when 23 | 24 => op := x"56"; exit when d < DMAX;   -- chargement partiel (V5)
               when 25 | 26 => op := x"66"; exit when d >= 1;     -- rangement partiel (V5)
               when others =>
                  -- Début d'une séquence (V4) : quelques LI, puis l'accès.
                  seq_start := true;
                  exit when d + 2 < DMAX;
            end case;
         end loop;

         if seq_start then
            -- Choix de la séquence ; la première instruction est un LI.
            nkind := RAND_INT( 7 );
            seq_ofs := RAND_INT( 8 );
            ptr := VAL_WORDS + RAND_INT( DATA_WORDS - VAL_WORDS );     -- cellule pointeur
            case nkind is
               when 0 =>                                   -- LI a ; LQ (lvl 15)
                  seq_op := OP_LQ0_T; seq_lvl := "1111"; seq_val := 0;
                  seq_li := MBASE + 8 * RAND_INT( DATA_WORDS ); seq := 2;
               when 1 =>                                   -- LI a ; LI v ; SQ (lvl 15)
                  seq_op := OP_SQ0_T; seq_lvl := "1111"; seq_val := 0;
                  seq_li := MBASE + 8 * RAND_INT( VAL_WORDS ); seq := 1;
               when 2 =>                                   -- LI p ; LIQ (lvl 15)
                  seq_op := OP_LIQ0_T; seq_lvl := "1111"; seq_val := 0;
                  seq_li := MBASE + 8 * ptr; seq := 2;
               when 3 =>                                   -- LI p ; LI v ; SIQ (lvl 15)
                  seq_op := OP_SIQ0_T; seq_lvl := "1111"; seq_val := 0;
                  seq_li := MBASE + 8 * ptr; seq := 1;
               when 4 =>                                   -- LI q ; LIQ [C24] sur cette cellule
                  seq_op := OP_LIQ_T; seq_lvl := "0000";
                  seq_val := S0 + 8 * ( d + 1 ) - MBASE;   -- le LI est le nouveau sommet
                  seq_li := MBASE + 8 * RAND_INT( 40 ); seq := 2;
               when 6 =>                                   -- LVA a ; LI v ; SQ a ; LQ (lvl 15) ; INC
                  seq_op := OP_LQ0_T; seq_lvl := "1111"; seq_val := 0; seq := 3;
                  if d >= 1 then
                     lva_a := S0 + 8 * ( 1 + RAND_INT( d ) );
                  else
                     lva_a := MBASE + 8 * RAND_INT( VAL_WORDS );
                  end if;
                  sq_a := lva_a;
               when others =>                              -- LVA d'une cellule vivante ; LQ (lvl 15)
                  -- V8 : une cellule de calcul lue par adresse calculée a été exposée
                  -- par LVA, qui doit la rendre propre si elle est sale.
                  seq_op := OP_LQ0_T; seq_lvl := "1111"; seq_val := 0; seq := 2;
                  if d >= 1 then
                     lva_a := S0 + 8 * ( 1 + RAND_INT( d ) );
                  else
                     lva_a := MBASE + 8 * RAND_INT( DATA_WORDS );
                  end if;
            end case;
            if lva_a /= 0 then
               op := OP_LVA_T;
            else
               op := OP_LI_T;
               v := seq_li;
            end if;
         elsif seq = 1 then
            -- Second LI d'un rangement : la valeur, puis l'accès.
            op := OP_LI_T;
            v := RAND_INT( 2001 ) - 1000;
            seq := 2;
         elsif seq = 3 then
            -- LI v, puis SQ dans la cellule exposée.
            op := OP_LI_T;
            v := RAND_INT( 2001 ) - 1000;
            seq := 4;
         elsif seq = 4 then
            seq := 2;
            seq_inc := true;
         elsif seq = 2 and op = seq_op then
            seq := 0;
         elsif op = OP_LI_T then
            v := RAND_INT( 2001 ) - 1000;
         end if;
         -- Un LI de séquence choisi en tête de boucle a déjà son v ; si seq = 2 vient
         -- d'être fixé par ce LI, l'accès suit au tour suivant.

         sl := NO_SLOT;
         sl.valid := '1';
         sl.canon.op := op;
         sl.canon.lvl := ( others => '0' );
         sl.canon.len := to_unsigned( ISA_TABLE( to_integer( unsigned( op ) ) ).length, sl.canon.len'length );
         sl.pc := A64( P0 + 16 * i );
         sl.pred := NO_PREDICTION;
         sl.pred.target := TARGET_OF( sl.pc );

         case op is
            when OP_LI_T =>
               sl.canon.val := to_signed( v, sl.canon.val'length );
               EXPECT_OPS( 0 );
               PUSH( RESULT( op, sl.canon.val, ( others => '0' ), ( others => '0' ) ) );

            when OP_ADD_T | OP_SUB_T | OP_OUX_T | OP_CGT_T | OP_MUL_T =>
               EXPECT_OPS( 2 );
               va := TOP( 1 ); vb := TOP( 0 );
               d := d - 2;
               PUSH( RESULT( op, sl.canon.val, va, vb ) );

            when OP_NEG_T | OP_INC_T =>
               EXPECT_OPS( 1 );
               va := TOP( 0 );
               d := d - 1;
               PUSH( RESULT( op, sl.canon.val, va, va ) );

            when OP_DUP_T =>
               PUSH( TOP( 0 ) );
            when OP_OVER_T =>
               PUSH( TOP( 1 ) );
            when OP_DROP_T =>
               d := d - 1;

            when OP_BRA_T =>
               sl.pred.taken := '1';
               EXPECT_OPS( 0 );

            when OP_CALL_T =>
               sl.pred.taken := '1';
               EXPECT_OPS( 0 );
               rs( rd_n ) := to_integer( sl.pc ) + ISA_TABLE( 16#F2# ).length;
               rd_n := rd_n + 1;
               if rd_n > rd_max then rd_max := rd_n; end if;

            when OP_RTD0_T =>
               rd_n := rd_n - 1;
               sl.pred.taken  := '1';
               sl.pred.target := A64( rs( rd_n ) );
               EXPECT_OPS( 0 );
               x( cur_i ).ret := A64( rs( rd_n ) );

            when OP_BT_T | OP_BF_T =>
               EXPECT_OPS( 1 );
               tk := '0';
               if ( op = OP_BT_T and TOP( 0 ) /= x"0000000000000000" )
                  or ( op = OP_BF_T and TOP( 0 ) = x"0000000000000000" ) then
                  tk := '1';
               end if;
               -- Prédiction juste 4 fois sur 5.
               if RAND_INT( 5 ) = 0 then sl.pred.taken := not tk; else sl.pred.taken := tk; end if;
               d := d - 1;

            when OP_LQ_T =>
               -- Zone de données, ou cellule vivante de la pile (1 .. d).
               if d >= 1 and RAND_INT( 2 ) = 0 then
                  a := S0 + 8 * ( 1 + RAND_INT( d ) );
               else
                  a := MBASE + 8 * RAND_INT( DATA_WORDS );
               end if;
               sl.canon.val := to_signed( a - MBASE, sl.canon.val'length );
               EXPECT_OPS( 0 );
               PUSH( m( WIDX( A64( a ) ) ) );

            when OP_LIQ_T | OP_LIQ0_T =>
               -- Cellule pointeur : DISPLAY(0) + val (table, ou cellule de pile
               -- d'une séquence), ou sommet (lvl 15, dépilé).
               if op = OP_LIQ0_T then
                  sl.canon.lvl := "1111";
                  sl.canon.val := to_signed( 0, sl.canon.val'length );
                  EXPECT_OPS( 1 );
                  a := to_integer( unsigned( TOP( 0 ) ) );
                  d := d - 1;
               else
                  if seq_op = OP_LIQ_T and seq_lvl = "0000" and seq_val /= 0 and seq = 0 then
                     a := MBASE + seq_val;                -- séquence : cellule de pile
                     seq_val := 0;
                  else
                     a := MBASE + 8 * ( VAL_WORDS + RAND_INT( DATA_WORDS - VAL_WORDS ) );
                  end if;
                  sl.canon.val := to_signed( a - MBASE, sl.canon.val'length );
                  EXPECT_OPS( 0 );
               end if;
               sl.canon.ofs := to_unsigned( 8 * seq_ofs, sl.canon.ofs'length );
               ia := to_integer( unsigned( m( WIDX( A64( a ) ) ) ) ) + 8 * seq_ofs;
               PUSH( m( WIDX( A64( ia ) ) ) );
               seq_ofs := RAND_INT( 8 );

            when OP_SIQ_T | OP_SIQ0_T =>
               if op = OP_SIQ0_T then
                  sl.canon.lvl := "1111";
                  sl.canon.val := to_signed( 0, sl.canon.val'length );
                  EXPECT_OPS( 2 );
                  a := to_integer( unsigned( TOP( 1 ) ) );
                  va := TOP( 0 );
                  d := d - 2;
               else
                  a := MBASE + 8 * ( VAL_WORDS + RAND_INT( DATA_WORDS - VAL_WORDS ) );
                  sl.canon.val := to_signed( a - MBASE, sl.canon.val'length );
                  EXPECT_OPS( 1 );
                  va := TOP( 0 );
                  d := d - 1;
               end if;
               sl.canon.ofs := to_unsigned( 8 * seq_ofs, sl.canon.ofs'length );
               ia := to_integer( unsigned( m( WIDX( A64( a ) ) ) ) ) + 8 * seq_ofs;
               m( WIDX( A64( ia ) ) ) := va;
               seq_ofs := RAND_INT( 8 );

            when OP_LQ0_T =>
               sl.canon.lvl := "1111";
               sl.canon.val := to_signed( 0, sl.canon.val'length );
               EXPECT_OPS( 1 );
               a := to_integer( unsigned( TOP( 0 ) ) );
               d := d - 1;
               PUSH( m( WIDX( A64( a ) ) ) );

            when OP_SQ0_T =>
               sl.canon.lvl := "1111";
               sl.canon.val := to_signed( 0, sl.canon.val'length );
               EXPECT_OPS( 2 );
               a := to_integer( unsigned( TOP( 1 ) ) );
               va := TOP( 0 );
               d := d - 2;
               m( WIDX( A64( a ) ) ) := va;

            when x"56" =>
               -- Chargement partiel : taille 1, 2 ou 4 octets, signé ou non, à un
               -- décalage quelconque d'une cellule vivante ou de la zone de données ;
               -- une fois sur quatre l'accès déborde sur la cellule suivante.
               ia := RAND_INT( 3 );                                -- taille 2**ia
               if RAND_INT( 2 ) = 0 then
                  sl.canon.op := std_logic_vector( to_unsigned( 16#54# + ia, 8 ) );   -- LB/LW/LD
               else
                  sl.canon.op := std_logic_vector( to_unsigned( 16#74# + ia, 8 ) );   -- ULB/ULW/ULD
               end if;
               if RAND_INT( 4 ) = 0 then
                  ptr := 8 - 2 ** ia + 1 + RAND_INT( 2 ** ia - 1 + 1 );          -- déborde (si > 8 - n)
                  if ptr > 7 then ptr := 7; end if;
               else
                  ptr := RAND_INT( 8 - 2 ** ia + 1 );                            -- contenu
               end if;
               if d >= 2 and RAND_INT( 3 ) /= 0 then
                  -- Cellule vivante (la suivante aussi), le plus souvent près du sommet,
                  -- donc présente dans le cache de pile.
                  if RAND_INT( 4 ) /= 0 then
                     a := S0 + 8 * ( d - 1 - RAND_INT( minimum( d - 1, 5 ) ) ) + ptr;
                  else
                     a := S0 + 8 * ( 1 + RAND_INT( d - 1 ) ) + ptr;
                  end if;
               else
                  a := MBASE + 8 * RAND_INT( DATA_WORDS - 1 ) + ptr;
               end if;
               sl.canon.val := to_signed( a - MBASE, sl.canon.val'length );
               EXPECT_OPS( 0 );
               PUSH( MREAD( m, a, ia, sl.canon.op( 5 downto 4 ) = "01" ) );

            when OP_LVA_T =>
               -- Cellule vivante de la pile (exposée) ou zone de données.
               if lva_a /= 0 then
                  a := lva_a;
                  lva_a := 0;
               elsif d >= 1 and RAND_INT( 2 ) = 0 then
                  a := S0 + 8 * ( 1 + RAND_INT( d ) );
               else
                  a := MBASE + 8 * RAND_INT( DATA_WORDS );
               end if;
               sl.canon.val := to_signed( a - MBASE, sl.canon.val'length );
               EXPECT_OPS( 0 );
               PUSH( std_logic_vector( to_unsigned( a, 64 ) ) );

            when x"66" =>
               -- Rangement partiel : taille 1, 2, 4 ou 8 octets, dans une cellule
               -- vivante sous le sommet (dépilé par l'instruction) ou dans la zone
               -- de valeurs ; une fois sur quatre à cheval sur la cellule suivante.
               ia := RAND_INT( 4 );
               sl.canon.op := std_logic_vector( to_unsigned( 16#64# + ia, 8 ) );   -- SB/SW/SD/SQ
               if ia > 0 and ia < 3 and RAND_INT( 4 ) = 0 then
                  ptr := 9 - 2 ** ia + RAND_INT( 2 ** ia - 1 );                  -- à cheval
               else
                  ptr := RAND_INT( 8 - 2 ** ia + 1 );                            -- contenu
               end if;
               EXPECT_OPS( 1 );
               va := TOP( 0 );
               if d >= 3 and RAND_INT( 3 ) /= 0 then
                  -- Cellules 1 .. d - 2 : la cellule suivante reste vivante après le
                  -- dépilement ; souvent près du sommet (présente, sale).
                  if RAND_INT( 4 ) /= 0 then
                     a := S0 + 8 * ( d - 2 - RAND_INT( minimum( d - 2, 5 ) ) ) + ptr;
                  else
                     a := S0 + 8 * ( 1 + RAND_INT( d - 2 ) ) + ptr;
                  end if;
               else
                  a := MBASE + 8 * RAND_INT( VAL_WORDS - 1 ) + ptr;
               end if;
               sl.canon.val := to_signed( a - MBASE, sl.canon.val'length );
               d := d - 1;
               MWRITE( m, a, ia, va );

            when others =>                                -- OP_SQ_T
               if sq_a /= 0 then
                  a := sq_a;                              -- séquence : cellule exposée
                  sq_a := 0;
               elsif top_store then
                  a := S0 + 8 * ( d - 1 );
               elsif RAND_INT( 2 ) = 0 then
                  a := S0 + 8 * ( 1 + RAND_INT( d ) );    -- cellule vivante, sommet compris
               else
                  a := MBASE + 8 * RAND_INT( VAL_WORDS );
               end if;
               sl.canon.val := to_signed( a - MBASE, sl.canon.val'length );
               EXPECT_OPS( 1 );
               va := TOP( 0 );
               d := d - 1;
               m( WIDX( A64( a ) ) ) := va;
         end case;
         p( i ) := sl;
         nop( to_integer( unsigned( op ) ) ) := nop( to_integer( unsigned( op ) ) ) + 1;
         force_inc := top_store or ( seq_inc and op = OP_LQ0_T );
         if op = OP_LQ0_T then seq_inc := false; end if;
         if d > dmaxv then dmaxv := d; end if;
      end loop;

      nop_ld    <= nop( 16#56# ) + nop( 16#57# ) + nop( 16#66# ) + nop( 16#67# );
      prog      <= p;
      expect    <= x;
      n_expect  <= nx;
      final_d   <= d;
      final_rd  <= rd_n;
      final_mem <= m;
      gen_done  <= true;
      report "programme : " & integer'image( N_INSN ) & " instructions, " & integer'image( nx )
             & " émissions, profondeur finale " & integer'image( d ) & ", maximale "
             & integer'image( dmaxv ) & " ; LIQ " & integer'image( nop( 16#97# ) ) & ", SIQ "
             & integer'image( nop( 16#A7# ) ) & ", LQ/SQ/LIQ/SIQ lvl 15 "
             & integer'image( nop( 16#53# ) ) & "/" & integer'image( nop( 16#63# ) ) & "/"
             & integer'image( nop( 16#93# ) ) & "/" & integer'image( nop( 16#A3# ) ) & ", LVA "
             & integer'image( nop( 16#47# ) ) & ", chargements partiels "
             & integer'image( nop( 16#56# ) ) & ", rangements partiels "
             & integer'image( nop( 16#66# ) ) & ", CALL/RTD " & integer'image( nop( 16#F2# ) ) & "/"
             & integer'image( nop( 16#F7# ) ) & " (profondeur maximale " & integer'image( rd_max )
             & ")" severity note;
      assert nop( 16#97# ) > 100 and nop( 16#A7# ) > 100 and nop( 16#53# ) > 30 and nop( 16#63# ) > 30
             and nop( 16#93# ) > 30 and nop( 16#A3# ) > 30 and nop( 16#47# ) > 100
             and nop( 16#56# ) > 150 and nop( 16#F2# ) > 100 and nop( 16#F7# ) > 100
             and rd_max > 12 and nop( 16#66# ) > 150
         report "K1e : tirage insuffisant des acces V4" severity failure;
      wait;
   end process GENERATE_PROG;

        --------------------------------------------------------------------------------
        -- DECODE_QUEUE : flux continu, avec des trous tirés au hasard.
        --------------------------------------------------------------------------------

   FEED : process( clk )
      variable s1, s2 : positive := 31;
      variable r      : real;
   begin
      if rising_edge( clk ) then
         if decode_take = '1' then
            ptr <= ptr + 1;
         end if;
         uniform( s1, s2, r );
         if r < 0.9 then offer <= '1'; else offer <= '0'; end if;
      end if;
   end process FEED;

        --------------------------------------------------------------------------------
        -- Mémoire (FILL/SPILL de STACK_UNIT) et exécuteur (LI, entier, MUL, branches,
        -- LQ/SQ directs dans la même mémoire).
        --------------------------------------------------------------------------------

   MACHINE : process( clk )
      variable s1, s2   : positive := 77;
      variable r        : real;
      variable m        : mem_t := INIT_MEM;
      variable ne       : natural := 0;
      variable nerr, nchk : natural := 0;
      variable busy     : boolean := false;
      variable wait_n   : natural := 0;
      variable pend     : ino_complete_t := NO_COMPLETE;
      variable e        : exp_t;
      variable op       : opcode_t;
      variable va, vb   : word64_t;
      variable w        : word64_t;
      variable addr     : address_t;
      variable tk       : std_logic;
      variable nrd, nwr : natural := 0;
      variable nsame    : natural := 0;
   begin
      if rising_edge( clk ) then
         mem_rsp      <= NO_MEM_RESPONSE;
         complete_reg <= NO_COMPLETE;

         if reset = '0' then
            -- Port mémoire de STACK_UNIT : réponse au cycle suivant l'acceptation.
            if mem_req.valid = '1' and mem_ready = '1' then
               assert mem_req.size = "11" and mem_req.probe = '0'
                  report "K1e : requete STACK inattendue" severity failure;
               if mem_req.write = '1' then
                  nwr := nwr + 1;
                  m( WIDX( mem_req.address ) ) := mem_req.wdata;
                  mem_rsp <= ( valid => '1', rdata => ( others => '0' ), fault => '0' );
               else
                  nrd := nrd + 1;
                  mem_rsp <= ( valid => '1', rdata => m( WIDX( mem_req.address ) ), fault => '0' );
               end if;
            end if;

            -- Terminaison en attente.
            if busy then
               if wait_n = 0 then
                  complete_reg <= pend;
                  busy := false;
               else
                  wait_n := wait_n - 1;
               end if;
            end if;

            -- Émission acceptée à ce front.
            if issue_valid = '1' and issue_ready = '1' then
               assert not busy report "K1e : emission pendant une execution" severity failure;
               op := issue.slot.canon.op;
               e := expect( ( to_integer( issue.slot.pc ) - P0 ) / 16 );
               nchk := nchk + 1;
               if not e.e then
                  nerr := nerr + 1;
                  report "K1e : emission inattendue (" & HEX( op ) & ", pc " & HEX( issue.slot.pc ) & ")"
                         severity error;
               elsif op = OP_RTD0_T and ( issue.address_known /= '1' or issue.address /= e.ret ) then
                  nerr := nerr + 1;
                  report "K1e : RTD (pc " & HEX( issue.slot.pc ) & ") : retour " & HEX( issue.address )
                         & ", attendu " & HEX( e.ret ) severity error;
               elsif issue.operand_count /= e.n then
                  nerr := nerr + 1;
                  report "K1e : emission " & integer'image( ne ) & " (" & HEX( op ) & ") : "
                         & integer'image( issue.operand_count ) & " operandes, attendu "
                         & integer'image( e.n ) severity error;
               else
                  for j in 0 to 3 loop
                     if j < e.n and issue.operand( j ) /= e.op( j ) then
                        nerr := nerr + 1;
                        report "K1e : emission " & integer'image( ne ) & " (" & HEX( op ) & ", pc "
                               & HEX( issue.slot.pc ) & ") : operande " & integer'image( j ) & " "
                               & HEX( issue.operand( j ) ) & ", attendu " & HEX( e.op( j ) )
                               severity error;
                     end if;
                  end loop;
               end if;
               ne := ne + 1;

               va := issue.operand( 0 );
               vb := issue.operand( 1 );
               pend := NO_COMPLETE;
               pend.valid := '1';
               if issue.issue_class = ISSUE_MEMORY then
                  -- Comme INO_ADDRESS_UNIT / INO_MEMORY_UNIT (accès de 8 octets).
                  if issue.address_known = '1' then
                     addr := issue.address;
                  else
                     addr := unsigned( va ) + unsigned( resize( issue.slot.canon.val, 64 ) );
                  end if;
                  if op( 7 downto 6 ) = "10" then
                     addr := unsigned( m( WIDX( addr ) ) ) + resize( unsigned( issue.slot.canon.ofs ), 64 );
                  end if;
                  if op( 5 downto 4 ) = "10" then
                     MWRITE( m, to_integer( addr ), to_integer( unsigned( op( 1 downto 0 ) ) ),
                             issue.operand( issue.operand_count - 1 ) );
                  else
                     pend.result_valid := '1';
                     pend.result := MREAD( m, to_integer( addr ),
                                           to_integer( unsigned( op( 1 downto 0 ) ) ), op( 5 downto 4 ) = "01" );
                  end if;
               else
                  pend := COMPLETION( issue );
               end if;

               if complete_comb.valid = '1' then
                  -- Déjà terminée dans le cycle d'émission (COMB).
                  nsame := nsame + 1;
               else
                  -- Latence : 0 (60 %), 1 ou 2 cycles de plus.
                  uniform( s1, s2, r );
                  if r < 0.6 then wait_n := 0; elsif r < 0.85 then wait_n := 1; else wait_n := 2; end if;
                  busy := true;
               end if;
            end if;

            uniform( s1, s2, r );
            if r < 0.5 then same_cycle <= '1'; else same_cycle <= '0'; end if;

            uniform( s1, s2, r );
            if r < 0.8 then issue_ready <= '1'; else issue_ready <= '0'; end if;
            uniform( s1, s2, r );
            if r < 0.75 then mem_ready <= '1'; else mem_ready <= '0'; end if;
         end if;

         mem_copy    <= m;
         spills      <= nwr;
         fills       <= nrd;
         exec_errors <= nerr;
         exec_checks <= nchk;
         issued      <= ne;
         same_count  <= nsame;
      end if;
   end process MACHINE;

        --------------------------------------------------------------------------------
        -- Commits, enchaînements, bilan.
        --------------------------------------------------------------------------------

   STIMULI : process
      alias chain is << signal .T_K1e_STACK_CHAIN_tb.DUT.U_DUT.chain_s : std_logic >>;
      variable c        : tb_counter_t := TB_COUNTER_INIT;
      variable ncommit  : natural := 0;
      variable nchain   : natural := 0;
      variable nmispred : natural := 0;
      variable cycles   : natural := 0;
      variable bad      : natural := 0;
      variable w        : word64_t;
   begin
      wait until gen_done;
      wait for 3 * PERIOD;
      wait until rising_edge( clk );
      reset <= '0';

      sync_frame.dsp          <= A64( S0 );
      sync_frame.rsp          <= A64( RSP0 );
      sync_frame.display      <= ( others => ( others => '0' ) );
      sync_frame.display( 0 ) <= A64( MBASE );
      sync_valid              <= '1';
      wait until rising_edge( clk );
      sync_valid <= '0';
      loop
         wait until rising_edge( clk );
         exit when frame.dsp = A64( S0 ) and frame.display( 0 ) = A64( MBASE );
      end loop;
      wait until rising_edge( clk );
      go <= true;

      while ncommit < N_INSN loop
         wait until rising_edge( clk );
         cycles := cycles + 1;
         if chain = '1' and decode_take = '1' then
            nchain := nchain + 1;
         end if;
         if commit.valid = '1' then
            if commit.fault.valid = '1' then
               CHECK( c, false, "commit " & integer'image( ncommit ) & " sans faute",
                      "aucune", HEX( commit.fault.code ) );
            elsif commit.slot.pc /= prog( ncommit ).pc
                  or commit.slot.canon.op /= prog( ncommit ).canon.op then
               CHECK( c, false, "commit " & integer'image( ncommit ) & " dans l'ordre du programme",
                      HEX( prog( ncommit ).pc ), HEX( commit.slot.pc ) );
            else
               CHECK_PASSED( c );
            end if;
            if commit.slot.pred.taken /= commit.taken then
               nmispred := nmispred + 1;
            end if;
            ncommit := ncommit + 1;
         end if;
         if cycles > 40 * N_INSN then
            CHECK( c, false, "programme termine dans le budget de cycles" );
            exit;
         end if;
      end loop;

      -- Repos, puis écriture de tout le cache de pile (attentes bornées).
      for k in 1 to 1000 loop
         wait until rising_edge( clk );
         exit when idle = '1';
      end loop;
      if idle /= '1' then
         CHECK( c, false, "STACK_UNIT au repos en fin de programme" );
         running <= false;
         FINISH( c, "T_K1e_STACK_CHAIN_tb" );
      end if;
      maint <= ( valid => '1', kind => MAINT_WRITEBACK_ALL, base => ( others => '0' ), length => ( others => '0' ) );
      wait until rising_edge( clk );
      maint.valid <= '0';
      for k in 1 to 1000 loop
         wait until rising_edge( clk );
         exit when maint_done = '1';
      end loop;
      wait until rising_edge( clk );
      wait until rising_edge( clk );

      -- Les accès servis par le cache de pile ne sont pas émis.
      CHECK( c, issued <= n_expect and issued >= n_expect - nop_ld, "nombre d'emissions",
             integer'image( n_expect - nop_ld ) & " .. " & integer'image( n_expect ), integer'image( issued ) );
      CHECK( c, exec_errors = 0, "operandes des emissions (" & integer'image( exec_checks ) & " emissions)",
             "0 erreur", integer'image( exec_errors ) & " erreur(s)" );
      CHECK( c, frame.rsp = A64( RSP0 - 8 * final_rd ), "RSP final",
             HEX( A64( RSP0 - 8 * final_rd ) ), HEX( frame.rsp ) );
      CHECK( c, frame.dsp = A64( S0 + 8 * final_d ), "DSP final",
             HEX( A64( S0 + 8 * final_d ) ), HEX( frame.dsp ) );
      for i in 0 to DATA_WORDS + final_d loop
         if mem_copy( i ) /= final_mem( i ) then
            bad := bad + 1;
            if bad <= 5 then
               report "K1e : memoire " & HEX( A64( MBASE + 8 * i ) ) & " : " & HEX( mem_copy( i ) )
                      & ", attendu " & HEX( final_mem( i ) ) severity error;
            end if;
         end if;
      end loop;
      CHECK( c, bad = 0, "memoire finale (donnees et pile vivante)", "0", integer'image( bad ) );
      CHECK( c, nchain > N_INSN / 5, "prises au cycle du commit",
             "> " & integer'image( N_INSN / 5 ), integer'image( nchain ) );
      CHECK( c, nmispred > 15, "mauvaises predictions exercees", "> 15", integer'image( nmispred ) );
      CHECK( c, n_expect - issued > 60, "acces servis par le cache de pile",
             "> 60", integer'image( n_expect - issued ) );
      CHECK( c, same_count > N_INSN / 5, "terminaisons dans le cycle d'emission",
             "> " & integer'image( N_INSN / 5 ), integer'image( same_count ) );
      CHECK( c, spills > 200 and fills > 200, "SPILL et FILL exerces", "> 200",
             integer'image( spills ) & " / " & integer'image( fills ) );

      report "K1e : " & integer'image( ncommit ) & " commits en " & integer'image( cycles ) & " cycles, "
             & integer'image( nchain ) & " prises enchainees, " & integer'image( nmispred )
             & " mauvaises predictions, SPILL " & integer'image( spills ) & ", FILL "
             & integer'image( fills ) & ", terminaisons dans le cycle d'emission "
             & integer'image( same_count ) & ", acces servis par le cache de pile "
             & integer'image( n_expect - issued ) severity note;
      running <= false;
      FINISH( c, "T_K1e_STACK_CHAIN_tb" );
      wait;
   end process STIMULI;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
