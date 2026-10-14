library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

entity T_EQUIV_tb is end entity;

architecture TEST of T_EQUIV_tb is
   constant N_OPS : positive := 200000;
   type op_list_t is array( 0 to 6 ) of opcode_t;
   constant OPS : op_list_t := ( x"14", x"15", x"16", x"17", x"1C", x"1D", x"14" );

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );
   constant NO_ISSUE : ino_issue_t := (
      slot => NO_SLOT, issue_class => ISSUE_MUL_DIV, operand_count => 0,
      operand => ( others => ( others => '0' ) ), address_known => '0', address => ( others => '0' ) );

   signal clk, running : std_logic := '0';
   signal reset        : std_logic := '1';
   signal iv           : std_logic := '0';
   signal iss          : ino_issue_t := NO_ISSUE;
   signal rdy_r, rdy_n : std_logic;
   signal cmp_r, cmp_n : ino_complete_t;
   signal stop         : boolean := false;
begin
   R : entity work.INO_MULDIV_UNIT(RTL_REF)
      port map ( clk, reset, iv, iss, rdy_r, cmp_r );
   N : entity work.INO_MULDIV_UNIT(RTL)
      port map ( clk, reset, iv, iss, rdy_n, cmp_n );

   clk <= not clk after 5 ns when not stop;

   VERIF : process( clk )
      variable errs : natural := 0;
      variable nres : natural := 0;
   begin
      if falling_edge( clk ) and reset = '0' then
         if cmp_r.valid = '1' then nres := nres + 1; end if;
         if cmp_r.valid = '1' and nres mod 50000 = 1 then report "resultats compares : " & integer'image( nres ) & ", ecarts : " & integer'image( errs ); end if;
         if rdy_r /= rdy_n or cmp_r.valid /= cmp_n.valid or ( cmp_r.valid = '1' and cmp_r /= cmp_n ) then
            errs := errs + 1;
            if errs < 20 then
               report "DIFF op=" & to_hstring( iss.slot.canon.op )
                  & " a=" & to_hstring( iss.operand(0) ) & " b=" & to_hstring( iss.operand(1) )
                  & " c=" & to_hstring( iss.operand(2) )
                  & " ref v/rv/res/f=" & std_logic'image( cmp_r.valid ) & std_logic'image( cmp_r.result_valid )
                  & to_hstring( cmp_r.result ) & "/" & std_logic'image( cmp_r.fault.valid )
                  & " new=" & std_logic'image( cmp_n.valid ) & std_logic'image( cmp_n.result_valid )
                  & to_hstring( cmp_n.result ) & "/" & std_logic'image( cmp_n.fault.valid ) severity error;
            end if;
         end if;
      end if;
   end process;

   STIM : process
      variable s1 : positive := 1789;
      variable s2 : positive := 1665;
      variable x  : real;
      variable n_done, n_res : natural := 0;
      impure function RND( n : natural ) return natural is
      begin
         uniform( s1, s2, x );
         return integer( floor( x * real( n ) ) );
      end function;
      impure function OPERAND return word64_t is
         variable w : word64_t;
         variable k : natural;
      begin
         for i in 0 to 7 loop
            w( 8*i+7 downto 8*i ) := std_logic_vector( to_unsigned( RND( 256 ), 8 ) );
         end loop;
         case RND( 12 ) is
            when 0 => w := ( others => '0' );
            when 1 => w := x"8000000000000000";
            when 2 => w := x"7FFFFFFFFFFFFFFF";
            when 3 => w := ( others => '1' );
            when 4 => w := std_logic_vector( to_signed( RND( 7 ) - 3, 64 ) );
            when 5 => k := RND( 60 ); w := std_logic_vector( shift_right( signed( w ), k + 2 ) );
            when 6 => k := RND( 32 ); w := std_logic_vector( resize( signed( w( 31 downto 0 ) ), 64 ) srl 0 );
                      w := std_logic_vector( shift_right( signed( w ), k ) );
            when 7 => w := std_logic_vector( to_signed( 65536, 64 ) );   -- Q16 : 1.0
            when 8 => w := std_logic_vector( to_signed( -65536, 64 ) );
            when others => null;
         end case;
         return w;
      end function;
      variable op : opcode_t;
   begin
      wait for 22 ns;
      wait until falling_edge( clk );
      reset <= '0';
      while n_done < N_OPS loop
         if rdy_r = '1' and RND( 4 ) /= 0 then
            op := OPS( RND( 7 ) );
            iss <= NO_ISSUE;
            iss.slot.valid <= '1';
            iss.slot.canon.op <= op;
            iss.operand( 0 ) <= OPERAND;
            iss.operand( 1 ) <= OPERAND;
            iss.operand( 2 ) <= OPERAND;
            iv <= '1';
            n_done := n_done + 1;
         else
            iv <= '0';
         end if;
         wait until falling_edge( clk );
         if RND( 5000 ) = 0 then             -- RESET en cours d'operation
            reset <= '1'; iv <= '0';
            wait until falling_edge( clk );
            reset <= '0';
         end if;
      end loop;
      iv <= '0';
      for i in 1 to 50 loop wait until falling_edge( clk ); end loop;
      report "EQUIV : fin, " & integer'image( n_done ) & " operations" severity note;
      stop <= true;
      wait;
   end process;
end architecture;
