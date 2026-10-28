library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- Banc differentiel d'INO_ARITH_UNIT (L8) contre les trois unites qu'elle
        -- remplace : INO_MULDIV_UNIT (L2), INO_FLOAT_UNIT (L4) et INO_COMPLEX_UNIT (L5,
        -- seulement FEXP). Chaque cycle : meme ISSUE_READY quand une emission est
        -- presentee, meme COMPLETE (valid, puis tout l'enregistrement).
        --
        -- L'emetteur imite STACK_UNIT : une instruction en vol, la suivante presentee
        -- au plus tot dans le cycle meme du retour de la precedente (chainage :
        -- ISSUE_VALID combinatoire depuis COMPLETE.valid). SYNC_VALID (rare) abandonne
        -- une FEXP en cours ; RESET (rare) aussi.
        --
        -- Operandes : entiers aux cas limites (0, -1, MIN_64, MAX_64, petites valeurs,
        -- decalages), flottants aux cas limites (±0, ±inf, NaN, denormaux, exposants
        -- extremes, entiers et demi-entiers pour CVTFI/R, x - y voisins pour FADD),
        -- FEXP avec n petit, ou grand quand x converge vite (0, ±1, ±2, 0,5, inf, NaN).
        --------------------------------------------------------------------------------

                                ----------------------
entity                          T_L8_INO_ARITH_UNIT_tb
is                              ----------------------
end entity                      T_L8_INO_ARITH_UNIT_tb;
                                ----------------------

                                ----
architecture                    TEST
of T_L8_INO_ARITH_UNIT_tb is    ----

   constant PERIOD              : time := 10 ns;
   constant N_OPS               : positive := 60000;

   type op_list_t is array( natural range <> ) of opcode_t;
   constant MD_OPS : op_list_t := ( x"14", x"14", x"14", x"15", x"16", x"17", x"1C", x"1D" );
   constant FL_OPS : op_list_t := ( x"20", x"21", x"22", x"23", x"25", x"26", x"27", x"28",
                                    x"29", x"2A", x"2B", x"2C", x"2D", x"2E", x"2F", x"20", x"22", x"23" );
   constant OP_FEXP_T           : opcode_t := x"24";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );
   constant NO_ISSUE : ino_issue_t := (
      slot => NO_SLOT, issue_class => ISSUE_NONE, operand_count => 0,
      operand => ( others => ( others => '0' ) ), address_known => '0', address => ( others => '0' ) );

   signal clk                   : std_logic := '0';
   signal reset                 : std_logic := '1';
   signal stop                  : boolean := false;

   signal iss                   : ino_issue_t := NO_ISSUE;
   signal pend                  : boolean := false;          -- instruction prete a emettre
   signal inflight              : boolean := false;          -- une instruction en vol
   signal inflight_fexp         : boolean := false;
   signal iv                    : std_logic;
   signal sync                  : std_logic := '0';

   signal iv_md, iv_fl, iv_cx   : std_logic;
   signal rdy_md, rdy_fl, rdy_cx: std_logic;
   signal cmp_md, cmp_fl, cmp_cx: ino_complete_t;
   signal rdy_ref, rdy_new      : std_logic;
   signal cmp_ref, cmp_new      : ino_complete_t;

   signal copile                : copile_state_t;
   signal mem_req               : mem_request_t;

   constant LIMITS : limits_t := ( others => ( others => '1' ) );
   constant SYNC_COPILE : copile_state_t := (
      cfp => ( others => '0' ), csp => ( others => '0' ), hp => ( others => '0' ), hp_valid => '0' );

   signal n_issued              : natural := 0;
   signal n_cycles              : natural := 0;

begin

   clk <= not clk after PERIOD / 2 when not stop;

        --------------------------------------------------------------------------------
        -- Reference : les trois unites d'origine, routees par classe comme dans
        -- INO_BACKEND, INO_BACKEND_FLOAT et INO_BACKEND_COMPLEX.
        --------------------------------------------------------------------------------

   iv <= '1' when pend and ( not inflight or cmp_ref.valid = '1' ) else '0';

   iv_md <= iv when iss.issue_class = ISSUE_MUL_DIV else '0';
   iv_fl <= iv when iss.issue_class = ISSUE_FLOAT   else '0';
   iv_cx <= iv when iss.issue_class = ISSUE_COMPLEX else '0';

   R_MD : entity work.INO_MULDIV_UNIT( RTL )
      port map ( CLK_i => clk, RESET_i => reset, ISSUE_VALID_i => iv_md, ISSUE_i => iss,
                 ISSUE_READY_o => rdy_md, COMPLETE_o => cmp_md );

   R_FL : entity work.INO_FLOAT_UNIT( RTL )
      port map ( CLK_i => clk, RESET_i => reset, ISSUE_VALID_i => iv_fl, ISSUE_i => iss,
                 ISSUE_READY_o => rdy_fl, COMPLETE_o => cmp_fl );

   R_CX : entity work.INO_COMPLEX_UNIT( RTL )
      port map ( CLK_i => clk, RESET_i => reset, ISSUE_VALID_i => iv_cx, ISSUE_i => iss,
                 ISSUE_READY_o => rdy_cx, LIMITS_i => LIMITS,
                 SYNC_VALID_i => sync, SYNC_COPILE_i => SYNC_COPILE, COPILE_o => copile,
                 MEM_REQ_o => mem_req, MEM_READY_i => '1', MEM_RSP_i => NO_MEM_RESPONSE,
                 COMPLETE_o => cmp_cx );

   rdy_ref <= rdy_md when iss.issue_class = ISSUE_MUL_DIV
              else rdy_fl when iss.issue_class = ISSUE_FLOAT
              else rdy_cx;

   cmp_ref <= cmp_md when cmp_md.valid = '1'
              else cmp_fl when cmp_fl.valid = '1'
              else cmp_cx;

        --------------------------------------------------------------------------------
        -- Unite testee.
        --------------------------------------------------------------------------------

   N : entity work.INO_ARITH_UNIT( RTL )
      port map ( CLK_i => clk, RESET_i => reset, ISSUE_VALID_i => iv, ISSUE_i => iss,
                 ISSUE_READY_o => rdy_new, SYNC_VALID_i => sync, COMPLETE_o => cmp_new );

        --------------------------------------------------------------------------------
        -- Emetteur.
        --------------------------------------------------------------------------------

   EMETTEUR : process( clk )
      variable s1 : positive := 2026;
      variable s2 : positive := 1028;
      variable x  : real;
      variable op : opcode_t;
      variable k  : natural;
      variable i  : ino_issue_t;

      impure function RND( n : positive ) return natural is
      begin
         uniform( s1, s2, x );
         return integer( floor( x * real( n ) ) ) mod n;
      end function;

      impure function RBITS return word64_t is
         variable w : word64_t;
      begin
         for b in 0 to 7 loop
            w( 8 * b + 7 downto 8 * b ) := std_logic_vector( to_unsigned( RND( 256 ), 8 ) );
         end loop;
         return w;
      end function;

      impure function INT_OPERAND return word64_t is
         variable w : word64_t := RBITS;
      begin
         case RND( 12 ) is
            when 0 => w := ( others => '0' );
            when 1 => w := x"8000000000000000";
            when 2 => w := x"7FFFFFFFFFFFFFFF";
            when 3 => w := ( others => '1' );
            when 4 => w := std_logic_vector( to_signed( RND( 7 ) - 3, 64 ) );
            when 5 => w := std_logic_vector( shift_right( signed( w ), RND( 60 ) + 2 ) );
            when 6 => w := std_logic_vector( shift_right( signed( w ), RND( 63 ) ) );
            when 7 => w := std_logic_vector( to_signed( 65536, 64 ) );
            when 8 => w := std_logic_vector( to_signed( -65536, 64 ) );
            when others => null;
         end case;
         return w;
      end function;

      impure function FLOAT_OPERAND return word64_t is
         variable w : word64_t := RBITS;
         variable e : natural;
      begin
         case RND( 16 ) is
            when 0 => w( 62 downto 0 ) := ( others => '0' );                       -- ±0
            when 1 => w( 62 downto 52 ) := ( others => '1' );                       -- ±inf
                      w( 51 downto 0 ) := ( others => '0' );
            when 2 => w( 62 downto 52 ) := ( others => '1' );                       -- NaN
                      if unsigned( w( 51 downto 0 ) ) = 0 then w( 0 ) := '1'; end if;
            when 3 => w( 62 downto 52 ) := ( others => '0' );                       -- denormal
            when 4 => w( 62 downto 52 ) := std_logic_vector( to_unsigned( 1 + RND( 3 ), 11 ) );
            when 5 => w( 62 downto 52 ) := std_logic_vector( to_unsigned( 2046 - RND( 3 ), 11 ) );
            when 6 | 7 | 8 =>                                                     -- |x| entre 2^-8 et 2^70
                      e := 1015 + RND( 78 );
                      w( 62 downto 52 ) := std_logic_vector( to_unsigned( e, 11 ) );
                      if RND( 2 ) = 0 then w( 40 downto 0 ) := ( others => '0' ); end if;  -- entier probable
            when 9 => w := x"3FF0000000000000"; w( 63 ) := std_logic( to_unsigned( RND( 2 ), 1 )( 0 ) );
            when 10 => w := x"43E0000000000000"; w( 63 ) := std_logic( to_unsigned( RND( 2 ), 1 )( 0 ) );
                      if RND( 2 ) = 0 then w( 0 ) := '1'; end if;                     -- ±2^63 (+1 ulp)
            when 11 => w( 62 downto 52 ) := std_logic_vector( to_unsigned( 1021 + RND( 4 ), 11 ) );
                      w( 50 downto 0 ) := ( others => '0' );                          -- ±0,5 .. ±4, demi
            when others => null;
         end case;
         return w;
      end function;

      -- y voisin de x (annulations de FADD/FSUB, egalites des comparaisons).
      impure function NEAR( xv : word64_t ) return word64_t is
         variable w : word64_t := xv;
      begin
         case RND( 4 ) is
            when 0 => null;
            when 1 => w( 63 ) := not w( 63 );
            when 2 => w := std_logic_vector( unsigned( w ) + RND( 5 ) );
            when others => w( 62 downto 52 ) := std_logic_vector( unsigned( w( 62 downto 52 ) ) - RND( 60 ) );
         end case;
         return w;
      end function;

      impure function FEXP_X( big : boolean ) return word64_t is
         variable w : word64_t;
      begin
         if big then
            case RND( 8 ) is
               when 0 => w := x"0000000000000000";
               when 1 => w := x"3FF0000000000000";
               when 2 => w := x"BFF0000000000000";
               when 3 => w := x"4000000000000000";
               when 4 => w := x"C000000000000000";
               when 5 => w := x"3FE0000000000000";
               when 6 => w := x"7FF0000000000000";
               when others => w := x"7FF8000000000001";
            end case;
            return w;
         end if;
         if RND( 3 ) = 0 then
            return FLOAT_OPERAND;
         end if;
         w := x"3FF0000000000000";                                                 -- 1 + petit, ou exposant moyen
         w( 51 downto 0 ) := RBITS( 51 downto 0 );
         w( 62 downto 52 ) := std_logic_vector( to_unsigned( 1013 + RND( 21 ), 11 ) );
         w( 63 ) := std_logic( to_unsigned( RND( 2 ), 1 )( 0 ) );
         return w;
      end function;

   begin
      if rising_edge( clk ) then
         n_cycles <= n_cycles + 1;
         sync <= '0';

         if reset = '1' then
            pend          <= false;
            inflight      <= false;
            inflight_fexp <= false;
            iss           <= NO_ISSUE;
            if n_cycles > 3 then
               reset <= '0';
            end if;

         else
            if iv = '1' and rdy_ref = '1' then
               -- Emission acceptee (eventuellement dans le cycle de retour).
               inflight      <= true;
               inflight_fexp <= iss.issue_class = ISSUE_COMPLEX;
               pend          <= false;
               n_issued      <= n_issued + 1;
            elsif cmp_ref.valid = '1' then
               inflight      <= false;
               inflight_fexp <= false;
            elsif sync = '1' and inflight_fexp then
               -- FEXP abandonnee par SYNC au front precedent.
               inflight      <= false;
               inflight_fexp <= false;
            end if;

            -- Prochaine instruction.
            if ( not pend or ( iv = '1' and rdy_ref = '1' ) ) and RND( 3 ) /= 0
               and n_issued < N_OPS then
               i := NO_ISSUE;
               i.slot.valid := '1';
               k := RND( 20 );
               if k < 7 then
                  op := MD_OPS( RND( MD_OPS'length ) );
                  i.issue_class := ISSUE_MUL_DIV;
                  i.operand( 0 ) := INT_OPERAND;
                  i.operand( 1 ) := INT_OPERAND;
                  i.operand( 2 ) := INT_OPERAND;
                  i.operand_count := 2;
                  if op = x"1C" or op = x"1D" then i.operand_count := 3; end if;
               elsif k < 18 then
                  op := FL_OPS( RND( FL_OPS'length ) );
                  i.issue_class := ISSUE_FLOAT;
                  if op = x"25" then
                     i.operand( 0 ) := INT_OPERAND;
                  else
                     i.operand( 0 ) := FLOAT_OPERAND;
                  end if;
                  if RND( 3 ) = 0 then
                     i.operand( 1 ) := NEAR( i.operand( 0 ) );
                  else
                     i.operand( 1 ) := FLOAT_OPERAND;
                  end if;
                  i.operand_count := 2;
               else
                  op := OP_FEXP_T;
                  i.issue_class := ISSUE_COMPLEX;
                  if RND( 6 ) = 0 then
                     i.operand( 0 ) := FEXP_X( true );
                     i.operand( 1 ) := RBITS;
                     if RND( 2 ) = 0 then i.operand( 1 )( 63 downto 62 ) := "10"; end if;
                     if RND( 4 ) = 0 then i.operand( 1 ) := x"8000000000000000"; end if;
                  else
                     i.operand( 0 ) := FEXP_X( false );
                     i.operand( 1 ) := std_logic_vector( to_signed( RND( 61 ) - 20, 64 ) );
                  end if;
                  i.operand_count := 2;
               end if;
               i.slot.canon.op := op;
               iss  <= i;
               pend <= true;
            end if;

            if RND( 3000 ) = 0 then
               sync <= '1';
            end if;
            if RND( 40000 ) = 0 then
               reset <= '1';
            end if;
         end if;
      end if;
   end process EMETTEUR;

        --------------------------------------------------------------------------------
        -- Comparaison, au milieu de chaque cycle.
        --------------------------------------------------------------------------------

   VERIF : process( clk )
      variable c     : tb_counter_t := TB_COUNTER_INIT;
      variable nres  : natural := 0;
      variable nfexp : natural := 0;
      variable done  : boolean := false;

      function DESC( i : ino_issue_t ) return string is
      begin
         return "op " & HEX( i.slot.canon.op ) & " a " & HEX( i.operand( 0 ) )
              & " b " & HEX( i.operand( 1 ) ) & " c " & HEX( i.operand( 2 ) );
      end function;

      function CDESC( r : ino_complete_t ) return string is
      begin
         return std_logic'image( r.valid ) & std_logic'image( r.result_valid ) & " "
              & HEX( r.result ) & " f" & std_logic'image( r.fault.valid ) & HEX( r.fault.code );
      end function;
   begin
      if falling_edge( clk ) and reset = '0' and not done then
         if iv = '1' then
            if rdy_ref = rdy_new then
               CHECK_PASSED( c );
            else
               CHECK( c, false, "ISSUE_READY " & DESC( iss ),
                      std_logic'image( rdy_ref ), std_logic'image( rdy_new ) );
            end if;
         end if;

         assert n_cycles < 20000000
            report "T_L8_INO_ARITH_UNIT_tb : TIMEOUT" severity failure;

         assert ( cmp_md.valid = '1' ) nand ( cmp_fl.valid = '1' or cmp_cx.valid = '1' )
            report "references : deux retours dans le meme cycle" severity failure;

         if cmp_ref.valid = '1' or cmp_new.valid = '1' then
            nres := nres + 1;
            if cmp_ref = cmp_new then
               CHECK_PASSED( c );
            else
               CHECK( c, false, "COMPLETE (derniere emission " & DESC( iss ) & ")",
                      CDESC( cmp_ref ), CDESC( cmp_new ) );
            end if;
            if cmp_cx.valid = '1' then
               nfexp := nfexp + 1;
            end if;
         end if;

         if n_issued >= N_OPS and not inflight and not pend then
            report "T_L8_INO_ARITH_UNIT_tb : " & integer'image( n_issued ) & " emissions, "
                 & integer'image( nres ) & " retours compares (dont " & integer'image( nfexp )
                 & " FEXP), " & integer'image( n_cycles ) & " cycles";
            done := true;
            FINISH( c, "T_L8_INO_ARITH_UNIT_tb" );
         end if;
      end if;
   end process VERIF;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
