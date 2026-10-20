library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.fixed_float_types.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.FLOAT64_PKG.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- T_L4b_INO_FDIV_tb : FDIV sequentiel de INO_FLOAT_UNIT (etape 21).
        --
        -- Reference : l'ancien calcul, divide( x, y, round_nearest, guard => 3,
        -- check_error => true, denormalize => true ) de FLOAT64_PKG, NaN canonises
        -- avant et apres. Tirages (graine fixe) : bits quelconques, normaux
        -- d'exposants proches (quotient pres de 1, arrondis), denormaux, zeros,
        -- infinis, NaN, exposants extremes (depassement, sous-depassement vers les
        -- denormaux). Chaque FDIV rend son resultat apres exactement 20 cycles,
        -- sans faute.
        --------------------------------------------------------------------------------

entity T_L4b_INO_FDIV_tb is
end entity T_L4b_INO_FDIV_tb;

architecture TEST of T_L4b_INO_FDIV_tb is

   constant PERIOD      : time := 10 ns;
   constant N_DIV       : positive := 6000;
   constant OP_FDIV_T   : opcode_t := x"23";
   constant EXP_W       : natural := 11;
   constant FRAC_W      : natural := 52;

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   constant NO_ISSUE : ino_issue_t := (
      slot          => NO_SLOT,
      issue_class   => ISSUE_FLOAT,
      operand_count => 0,
      operand       => ( others => ( others => '0' ) ),
      address_known => '0',
      address       => ( others => '0' ) );

   signal clk          : std_logic := '0';
   signal running      : boolean := true;
   signal reset        : std_logic := '1';
   signal issue_valid  : std_logic := '0';
   signal issue        : ino_issue_t := NO_ISSUE;
   signal issue_ready  : std_logic;
   signal complete     : ino_complete_t;

   function IS_NAN64( x : word64_t ) return boolean is
   begin
      return x( 62 downto 52 ) = "11111111111" and unsigned( x( 51 downto 0 ) ) /= 0;
   end function;

   function REF_DIV( x, y : word64_t ) return word64_t is
      variable fr : float( EXP_W downto -FRAC_W );
      variable v  : word64_t;
   begin
      if IS_NAN64( x ) or IS_NAN64( y ) then
         return CANONICAL_NAN;
      end if;
      fr := divide( to_float( x, EXP_W, FRAC_W ), to_float( y, EXP_W, FRAC_W ),
                    round_style => round_nearest, guard => 3,
                    check_error => true, denormalize => true );
      v := to_slv( fr );
      if IS_NAN64( v ) then
         v := CANONICAL_NAN;
      end if;
      return v;
   end function;

begin

   DUT : entity work.INO_FLOAT_UNIT
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         COMPLETE_o => complete );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( N_DIV * 30 + 1000 );
      if running then
         report "TEST T_L4b_INO_FDIV_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c       : tb_counter_t := TB_COUNTER_INIT;
      variable s1      : positive := 1789;
      variable s2      : positive := 2026;
      variable u       : real;
      variable x, y    : word64_t;
      variable want    : word64_t;
      variable n       : natural;
      variable n_denorm, n_special, n_round : natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, u );
         return u;
      end function;

      impure function RBITS( w : positive ) return std_logic_vector is
         variable r : std_logic_vector( w - 1 downto 0 );
      begin
         for i in r'range loop
            if RAND < 0.5 then r( i ) := '0'; else r( i ) := '1'; end if;
         end loop;
         return r;
      end function;

      -- Operande d'une classe tiree ; e0 : exposant de reference pour les normaux.
      impure function OPERAND( e0 : natural ) return word64_t is
         variable k : real := RAND;
         variable v : word64_t := RBITS( 64 );
         variable e : integer;
      begin
         if k < 0.45 then
            e := e0 + integer( RAND * 6.0 ) - 3;            -- exposants voisins
            if e < 1 then e := 1; end if;
            if e > 2046 then e := 2046; end if;
            v( 62 downto 52 ) := std_logic_vector( to_unsigned( e, 11 ) );
         elsif k < 0.60 then
            null;                                           -- bits quelconques
         elsif k < 0.75 then
            v( 62 downto 52 ) := ( others => '0' );         -- denormal
            if RAND < 0.5 then v( 51 downto 30 ) := ( others => '0' ); end if;
         elsif k < 0.82 then
            v( 62 downto 0 ) := ( others => '0' );          -- zero
         elsif k < 0.88 then
            v( 62 downto 52 ) := ( others => '1' );         -- infini
            v( 51 downto 0 ) := ( others => '0' );
         elsif k < 0.92 then
            v( 62 downto 52 ) := ( others => '1' );         -- NaN (ou infini)
         elsif k < 0.96 then
            v( 62 downto 52 ) := std_logic_vector( to_unsigned( 2000 + integer( RAND * 46.0 ), 11 ) );
         else
            v( 62 downto 52 ) := std_logic_vector( to_unsigned( 1 + integer( RAND * 40.0 ), 11 ) );
         end if;
         if RAND < 0.1 then
            v( 51 downto 0 ) := ( others => '0' );          -- mantisse exacte
         end if;
         return v;
      end function;

   begin
      wait for 3 * PERIOD;
      reset <= '0';

      for i in 1 to N_DIV loop
         x := OPERAND( 1023 + integer( RAND * 200.0 ) - 100 );
         if RAND < 0.5 then
            y := OPERAND( to_integer( unsigned( x( 62 downto 52 ) ) ) );
         else
            y := OPERAND( 1023 + integer( RAND * 1600.0 ) - 800 );
         end if;
         want := REF_DIV( x, y );

         if x( 62 downto 52 ) = "00000000000" or y( 62 downto 52 ) = "00000000000"
            or want( 62 downto 52 ) = "00000000000" then
            n_denorm := n_denorm + 1;
         end if;
         if want( 62 downto 52 ) = "11111111111" or unsigned( want( 62 downto 0 ) ) = 0 then
            n_special := n_special + 1;
         end if;
         if want( 0 ) = '1' then n_round := n_round + 1; end if;

         loop
            wait until falling_edge( clk );
            exit when issue_ready = '1';
         end loop;
         issue <= NO_ISSUE;
         issue.slot.valid <= '1';
         issue.slot.canon.op <= OP_FDIV_T;
         issue.issue_class <= ISSUE_FLOAT;
         issue.operand_count <= 2;
         issue.operand( 0 ) <= x;
         issue.operand( 1 ) <= y;
         issue_valid <= '1';
         wait until rising_edge( clk );
         CHECK( c, issue_ready = '1', "FDIV " & integer'image( i ) & " : ready" );
         issue_valid <= '0';
         issue <= NO_ISSUE;

         n := 0;
         loop
            wait until rising_edge( clk );
            wait for 1 ns;
            n := n + 1;
            exit when complete.valid = '1' or n > 40;
         end loop;
         CHECK( c, n = 19, "FDIV " & integer'image( i ) & " : latence 20",
                integer'image( 19 ), integer'image( n ) );
         CHECK( c, complete.result_valid = '1' and complete.fault.valid = '0',
                "FDIV " & integer'image( i ) & " : resultat sans faute" );
         CHECK( c, complete.result = want,
                "FDIV " & integer'image( i ) & " : " & HEX( x ) & " / " & HEX( y ),
                HEX( want ), HEX( complete.result ) );
      end loop;

      report "divisions " & integer'image( N_DIV ) & ", denormaux " & integer'image( n_denorm )
           & ", speciaux " & integer'image( n_special ) & ", resultats impairs " & integer'image( n_round )
           severity note;
      CHECK( c, n_denorm > 500 and n_special > 500 and n_round > 1000,
             "le tirage couvre denormaux, cas speciaux et arrondis" );
      FINISH( c, "T_L4b_INO_FDIV_tb" );
      running <= false;
      wait;
   end process;

end architecture TEST;
