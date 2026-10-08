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
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

                                ------------------------
entity                          T_M2_INO_MEMORY_UNIT_tb
is                              ------------------------
end entity                      T_M2_INO_MEMORY_UNIT_tb;
                                ------------------------

                                ----
architecture                    TEST
of T_M2_INO_MEMORY_UNIT_tb is  ----

   constant PERIOD : time := 10 ns;

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   signal clk           : std_logic := '0';
   signal running       : boolean := true;
   signal reset         : std_logic := '1';
   signal address       : ino_address_t := NO_INO_ADDRESS;
   signal address_ready : std_logic;
   signal mem_req       : mem_request_t;
   signal mem_ready     : std_logic := '1';
   signal mem_rsp       : mem_response_t := NO_MEM_RESPONSE;
   signal complete      : ino_complete_t;

   signal pending_valid : std_logic := '0';
   signal pending_data  : word64_t := ( others => '0' );
   signal pending_fault : std_logic := '0';
   signal req_count     : natural := 0;
   signal write_count   : natural := 0;
   signal last_write_address : address_t := ( others => '0' );
   signal last_write_size    : unsigned( 1 downto 0 ) := ( others => '0' );
   signal last_write_data    : word64_t := ( others => '0' );

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function SLOT( op : opcode_t; ofs : natural := 0 ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid     := '1';
      r.canon.op  := op;
      r.canon.ofs := to_unsigned( ofs, 8 );
      r.canon.len := to_unsigned( 1, r.canon.len'length );
      return r;
   end function;

   function READ_MAP( a : address_t ) return word64_t is
   begin
      case to_integer( a ) is
         when 16#1000# => return x"0000000000000080"; -- LB = -128
         when 16#1010# => return x"0000000000000080"; -- ULB = 128
         when 16#1020# => return x"0000000080000001"; -- LD signe
         when 16#1030# => return x"1122334455667788"; -- LQ

         when 16#2000# => return x"0000000000003000"; -- pointeur LIB +5
         when 16#3005# => return x"00000000000000FE";
         when 16#2010# => return x"0000000000005000"; -- pointeur LIVA +12

         when 16#4000# => return x"00000000000000F6"; -- CHKB : -10
         when 16#4001# => return x"000000000000000A"; --        +10
         when 16#4100# => return x"0000000000000002"; -- CHKUB : 2
         when 16#4101# => return x"00000000000000FA"; --         250

         when 16#4200# => return x"0000000000004300"; -- CHKIW pointeur +2
         when 16#4302# => return x"000000000000FF9C"; -- -100
         when 16#4304# => return x"0000000000000064"; -- +100

         when 16#6100# => return x"0000000000006200"; -- SIB pointeur +3

         when 16#7000# => return x"000000000000DEAD"; -- cible invalide
         when others   => return ( others => '0' );
      end case;
   end function READ_MAP;

   function FAULT_MAP( a : address_t ) return std_logic is
   begin
      if a = A64( 16#DEAD# ) or a = A64( 16#DEAE# ) then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.INO_MEMORY_UNIT
      port map (
         CLK_i           => clk,
         RESET_i         => reset,
         ADDRESS_i       => address,
         ADDRESS_READY_o => address_ready,
         MEM_REQ_o       => mem_req,
         MEM_READY_i     => mem_ready,
         MEM_RSP_i       => mem_rsp,
         COMPLETE_o      => complete );

   clk <= not clk after PERIOD / 2 when running;

   -- Mémoire de banc : toute requête est acceptée immédiatement et reçoit une
   -- réponse au cycle suivant. Les lectures sont déterministes par adresse ; les
   -- écritures sont observées pour les vérifications du stimulus.
   MEMORY_MODEL : process( clk )
   begin
      if rising_edge( clk ) then
         mem_rsp <= NO_MEM_RESPONSE;
         if pending_valid = '1' then
            mem_rsp <= ( valid => '1', rdata => pending_data, fault => pending_fault );
            pending_valid <= '0';
         end if;

         if reset = '1' then
            pending_valid <= '0';
            req_count <= 0;
            write_count <= 0;
         elsif mem_req.valid = '1' and mem_ready = '1' then
            req_count <= req_count + 1;
            pending_valid <= '1';
            pending_data <= READ_MAP( mem_req.address );
            pending_fault <= FAULT_MAP( mem_req.address );
            if mem_req.write = '1' then
               write_count <= write_count + 1;
               last_write_address <= mem_req.address;
               last_write_size <= mem_req.size;
               last_write_data <= mem_req.wdata;
            end if;
         end if;
      end if;
   end process MEMORY_MODEL;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure EXEC(
         constant op              : in opcode_t;
         constant cell_address    : in address_t;
         constant data            : in word64_t;
         constant ofs             : in natural;
         constant expected_result : in word64_t;
         constant result_valid    : in std_logic;
         constant fault_valid     : in std_logic;
         constant fault_code      : in trap_code_t;
         constant requests        : in natural;
         constant name            : in string ) is
         variable before_req : natural;
         variable cycles     : natural;
      begin
         while address_ready /= '1' loop
            wait until rising_edge( clk ); wait for 1 ns;
         end loop;

         before_req := req_count;
         wait until falling_edge( clk );
         address <= ( valid => '1', slot => SLOT( op, ofs ),
                      address => cell_address, data => data );
         wait until rising_edge( clk );
         wait for 1 ns;
         address <= NO_INO_ADDRESS;

         cycles := 0;
         while complete.valid /= '1' loop
            wait until rising_edge( clk );
            wait for 1 ns;
            cycles := cycles + 1;
            assert cycles < 30 report name & " : timeout COMPLETE" severity failure;
         end loop;

         CHECK( c, complete.result_valid = result_valid, name & " : result_valid" );
         if result_valid = '1' then
            CHECK( c, complete.result = expected_result,
                   name & " : resultat", HEX( expected_result ), HEX( complete.result ) );
         end if;
         CHECK( c, complete.fault.valid = fault_valid, name & " : fault.valid" );
         if fault_valid = '1' then
            CHECK( c, complete.fault.code = fault_code,
                   name & " : fault.code", HEX( fault_code ), HEX( complete.fault.code ) );
         end if;
         CHECK( c, req_count - before_req = requests,
                name & " : nombre requetes", integer'image( requests ), integer'image( req_count - before_req ) );

         wait until rising_edge( clk ); wait for 1 ns;
         CHECK( c, complete.valid = '0', name & " : impulsion COMPLETE" );
      end procedure EXEC;

      constant Z : word64_t := ( others => '0' );
      variable wb : natural;
   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      wait for 1 ns;
      CHECK( c, address_ready = '1', "ready apres reset" );
      CHECK( c, complete.valid = '0', "pas de complete apres reset" );

      -- Charges B : extension signée / non signée et tailles.
      EXEC( x"50", A64(16#1000#), Z, 0, x"FFFFFFFFFFFFFF80", '1', '0', FAULT_ACCESS, 1, "LB signe" );
      EXEC( x"70", A64(16#1010#), Z, 0, x"0000000000000080", '1', '0', FAULT_ACCESS, 1, "ULB" );
      EXEC( x"52", A64(16#1020#), Z, 0, x"FFFFFFFF80000001", '1', '0', FAULT_ACCESS, 1, "LD signe" );
      EXEC( x"53", A64(16#1030#), Z, 0, x"1122334455667788", '1', '0', FAULT_ACCESS, 1, "LQ" );

      -- Famille C : pointeur puis accès ; LIVA s'arrête après le pointeur.
      EXEC( x"94", A64(16#2000#), Z, 5, x"FFFFFFFFFFFFFFFE", '1', '0', FAULT_ACCESS, 2, "LIB + ofs" );
      EXEC( x"87", A64(16#2010#), Z, 12, x"000000000000500C", '1', '0', FAULT_ACCESS, 1, "LIVA" );

      -- CHK signé / non signé : v reste sur la pile, donc aucun résultat produit.
      EXEC( x"5C", A64(16#4000#), std_logic_vector(to_signed(5,64)), 0,
            Z, '0', '0', FAULT_CHK, 2, "CHKB dans bornes" );
      EXEC( x"5C", A64(16#4000#), std_logic_vector(to_signed(20,64)), 0,
            Z, '0', '1', FAULT_CHK, 2, "CHKB hors bornes" );
      EXEC( x"7C", A64(16#4100#), std_logic_vector(to_unsigned(200,64)), 0,
            Z, '0', '0', FAULT_CHK, 2, "CHKUB" );
      EXEC( x"9D", A64(16#4200#), std_logic_vector(to_signed(-50,64)), 2,
            Z, '0', '0', FAULT_CHK, 3, "CHKIW" );

      -- Rangement direct : taille et donnée transmises exactement au port mémoire.
      wb := write_count;
      EXEC( x"66", A64(16#6000#), x"1122334455667788", 0,
            Z, '0', '0', FAULT_ACCESS, 1, "SD direct" );
      CHECK( c, write_count = wb + 1, "SD : une ecriture" );
      CHECK( c, last_write_address = A64(16#6000#), "SD : adresse" );
      CHECK( c, last_write_size = "10", "SD : taille" );
      CHECK( c, last_write_data = x"1122334455667788", "SD : donnee" );

      -- Rangement C : lecture du pointeur puis écriture à pointeur+ofs.
      wb := write_count;
      EXEC( x"A4", A64(16#6100#), x"00000000000000A5", 3,
            Z, '0', '0', FAULT_ACCESS, 2, "SIB indirect" );
      CHECK( c, write_count = wb + 1, "SIB : une ecriture" );
      CHECK( c, last_write_address = A64(16#6203#), "SIB : adresse effective" );
      CHECK( c, last_write_size = "00", "SIB : taille" );

      -- Faute d'accès sur l'accès effectif après lecture valide du pointeur.
      EXEC( x"90", A64(16#7000#), Z, 0, Z, '0', '1', FAULT_ACCESS, 2, "LIB faute data" );

      -- Faute dès la lecture de cellule pointeur : aucun second accès.
      EXEC( x"90", A64(16#DEAD#), Z, 0, Z, '0', '1', FAULT_ACCESS, 1, "LIB faute pointeur" );

      running <= false;
      FINISH( c, "T_M2_INO_MEMORY_UNIT_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 20 us;
      assert false report "T_M2_INO_MEMORY_UNIT_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
