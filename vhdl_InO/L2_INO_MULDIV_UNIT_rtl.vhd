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
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.INO_ARITH.all;

        --------------------------------------------------------------------------------
        -- INO_MULDIV_UNIT, architecture RTL.
        --
        -- Sémantique identique à L2_MULDIV_UNIT_rtl du backend OoO, mais sans tags,
        -- fichier physique, ROB, bypass ni recovery.
        --
        -- Réalisation séquentielle, orientée synthèse : un seul multiplieur non signé
        -- 64 x 64 -> 128 (MUL et CVTIX/CVTXI) et un seul diviseur restaurant non signé
        -- (dividende 128 bits, diviseur 64 bits) produisant DIV_BITS bits de quotient
        -- par cycle. Les signes sont traités à part (valeurs absolues en entrée,
        -- correction en sortie).
        --
        -- Déroulement (étude IPC x f, 25 octobre) :
        --   émission  valeurs absolues et signes des opérandes (ancien pas ABSOLU)
        --   CHARGE    MUL : produit (128 bits) dans dq_s
        --             DIV/REMI/MODI : |a| décalé de ses quartets de tête nuls (les pas
        --                             correspondants ne produiraient que des zéros)
        --             CVTIX/CVTXI   : |a|.|b| (128 bits) comme dividende
        --   PRODUIT   MUL : contrôle de débordement, signe et résultat, rendus
        --             combinatoirement dans ce cycle (mul_out_s) ; retour en LIBRE
        --   DIVISE    un pas par quartet significatif de |a| (au plus 64 / DIV_BITS),
        --             ou 128 / DIV_BITS pour CVTIX/CVTXI
        --   FINAL     signes, arrondi, contrôle de débordement, résultat
        --
        -- Latences (émission -> COMPLETE_o.valid, en cycles) :
        --   MUL                 2   (4 avant)
        --   DIV/REMI/MODI       3 + nombre de quartets significatifs de |a| (3 à 19 ;
        --                       20 avant)
        --   CVTIX/CVTXI         3 + 128 / DIV_BITS = 35   (36 avant)
        --------------------------------------------------------------------------------

                                ---
architecture                    RTL
of INO_MULDIV_UNIT is           ---

   constant OP_MUL              : opcode_t := x"14";
   constant OP_DIV              : opcode_t := x"15";
   constant OP_REMI             : opcode_t := x"16";
   constant OP_MODI             : opcode_t := x"17";
   constant OP_CVTIX            : opcode_t := x"1C";
   constant OP_CVTXI            : opcode_t := x"1D";

   -- Bits de quotient par cycle (DIV_BITS soustracteurs de 65 bits en série). Le
   -- saut des quartets de tête nuls (ZERO_NIBBLES) suppose 4.
   constant DIV_BITS            : positive := 4;

   constant MIN_64              : signed( 63 downto 0 ) := ( 63 => '1', others => '0' );
   constant MINUS_ONE           : signed( 63 downto 0 ) := ( others => '1' );

   constant NO_COMPLETE : ino_complete_t := (
      valid        => '0',
      result_valid => '0',
      result       => ( others => '0' ),
      fault        => NO_FAULT,
      taken        => '0',
      target       => ( others => '0' ) );

   type state_t is ( LIBRE, ATTENTE, RESULTAT );
   type step_t  is ( ABSOLU, CHARGE, PRODUIT, DIVISE, FINAL );

   signal state_s               : state_t := LIBRE;
   signal step_s                : step_t  := ABSOLU;
   signal result_s              : ino_complete_t := NO_COMPLETE;

   -- Opération et opérandes capturés à l'émission.
   signal op_s                  : opcode_t := ( others => '0' );
   signal a_s, b_s, c_s         : signed( 63 downto 0 ) := ( others => '0' );

   -- Valeurs absolues et signes.
   signal ua_s, ub_s, uc_s      : unsigned( 63 downto 0 ) := ( others => '0' );
   signal sa_s, sb_s, sc_s      : std_logic := '0';

   -- Diviseur restaurant : dq_s contient le dividende, qui sort par le haut,
   -- et reçoit le quotient par le bas. rem_s est le reste partiel.
   signal dq_s                  : unsigned( 127 downto 0 ) := ( others => '0' );
   signal rem_s                 : unsigned( 63 downto 0 ) := ( others => '0' );
   signal dvs_s                 : unsigned( 63 downto 0 ) := ( others => '0' );
   signal iter_s                : natural range 0 to 128 / DIV_BITS := 0;

   -- Unique multiplieur de l'unité.
   signal prod                  : unsigned( 127 downto 0 );

   -- MUL rendu dans le cycle du pas PRODUIT (combinatoire, étude IPC x f).
   signal mul_out_s             : ino_complete_t;

   function IS_MULDIV_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_MUL or op = OP_DIV or op = OP_REMI or op = OP_MODI
          or op = OP_CVTIX or op = OP_CVTXI;
   end function;

   function IS_CVT_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_CVTIX or op = OP_CVTXI;
   end function;

   function FITS_64( q : signed( 127 downto 0 ) ) return boolean is
   begin
      return q = resize( q( 63 downto 0 ), 128 );
   end function;

   -- ADD_PFX, MUL_CSA : paquet INO_ARITH (A1_INO_ARITH.vhd).

   -- -v si n = '1' : not v + 1, en préfixe parallèle.
   function NEG_IF( v : signed; n : std_logic ) return signed is
      variable z : unsigned( v'length - 1 downto 0 ) := ( others => '0' );
   begin
      if n = '1' then
         return signed( ADD_PFX( unsigned( not v ), z, '1' ) );
      else
         return v;
      end if;
   end function;

   function OK_RESULT( v : signed( 63 downto 0 ) ) return ino_complete_t is
      variable r : ino_complete_t := NO_COMPLETE;
   begin
      r.valid        := '1';
      r.result_valid := '1';
      r.result       := std_logic_vector( v );
      return r;
   end function;

   function FAULT_RESULT( code : trap_code_t ) return ino_complete_t is
      variable r : ino_complete_t := NO_COMPLETE;
   begin
      r.valid        := '1';
      r.result_valid := '0';
      r.fault        := ( valid => '1', code => code );
      return r;
   end function;

   -- Nombre de quartets de tête nuls de v (0 à 16).
   function ZERO_NIBBLES( v : unsigned( 63 downto 0 ) ) return natural is
   begin
      for k in 0 to 15 loop
         if v( 63 - 4 * k downto 60 - 4 * k ) /= 0 then
            return k;
         end if;
      end loop;
      return 16;
   end function;

   -- Résultat de MUL à partir du produit non signé |a|.|b|.
   function MUL_RESULT( p : unsigned( 127 downto 0 ); neg : std_logic ) return ino_complete_t is
   begin
      if p( 127 downto 63 ) = 0
         or ( neg = '1' and p( 127 downto 64 ) = 0 and p( 62 downto 0 ) = 0 ) then
         return OK_RESULT( NEG_IF( signed( p( 63 downto 0 ) ), neg ) );
      else
         return FAULT_RESULT( FAULT_OVERFLOW );
      end if;
   end function;

   -- DIV_BITS pas de division restaurante.
   procedure DIVISE_PAS(
      variable dq  : inout unsigned( 127 downto 0 );
      variable rm  : inout unsigned( 63 downto 0 );
      constant dvs : in    unsigned( 63 downto 0 ) ) is
      variable t : unsigned( 64 downto 0 );
   begin
      for i in 1 to DIV_BITS loop
         t  := rm & dq( 127 );
         dq := dq( 126 downto 0 ) & '0';
         if t >= ( '0' & dvs ) then
            t     := t - ( '0' & dvs );
            dq(0) := '1';
         end if;
         rm := t( 63 downto 0 );
      end loop;
   end procedure;

begin

   assert DIV_BITS = 4
      report "INO_MULDIV_UNIT : DIV_BITS doit valoir 4 (saut des quartets de tete nuls)" severity failure;

   ISSUE_READY_o <= '1' when state_s = LIBRE else '0';

   mul_out_s <= MUL_RESULT( dq_s, sa_s xor sb_s );

   OUTPUT : process( all )
   begin
      if state_s = ATTENTE and step_s = PRODUIT then
         COMPLETE_o <= mul_out_s;
      else
         COMPLETE_o <= result_s;
         if state_s /= RESULTAT then
            COMPLETE_o.valid <= '0';
         end if;
      end if;
   end process OUTPUT;

   prod <= MUL_CSA( ua_s, ub_s );

   -- pragma translate_off
   -- Même règle que pour les autres unités du backend : le protocole est
   -- synchrone, donc les assertions portent sur l'émission réellement
   -- échantillonnée au front montant et non sur des delta-cycles de routage.
   CHECK_OPCODE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ISSUE_VALID_i = '1' and state_s = LIBRE then
            assert ISSUE_i.issue_class = ISSUE_MUL_DIV and IS_MULDIV_OP( ISSUE_i.slot.canon.op )
               report "INO_MULDIV_UNIT : instruction hors de l'unite"
               severity failure;
         end if;
      end if;
   end process CHECK_OPCODE;
   -- pragma translate_on

   AUTOMATE : process( CLK_i )
      variable dq     : unsigned( 127 downto 0 );
      variable rm     : unsigned( 63 downto 0 );
      variable neg    : std_logic;
      variable q      : signed( 127 downto 0 );
      variable v      : signed( 63 downto 0 );
      variable fits   : boolean;
      variable d64    : unsigned( 63 downto 0 );
      variable s66    : unsigned( 65 downto 0 );
      variable nz     : natural range 0 to 16;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            state_s  <= LIBRE;
            step_s   <= ABSOLU;
            result_s <= NO_COMPLETE;
            iter_s   <= 0;
         else
            case state_s is

               when LIBRE =>
                  if ISSUE_VALID_i = '1' then
                     op_s    <= ISSUE_i.slot.canon.op;
                     a_s     <= signed( ISSUE_i.operand( 0 ) );
                     b_s     <= signed( ISSUE_i.operand( 1 ) );
                     c_s     <= signed( ISSUE_i.operand( 2 ) );
                     -- Valeurs absolues dès l'émission (ancien pas ABSOLU).
                     ua_s <= unsigned( NEG_IF( signed( ISSUE_i.operand( 0 ) ), ISSUE_i.operand( 0 )( 63 ) ) );
                     ub_s <= unsigned( NEG_IF( signed( ISSUE_i.operand( 1 ) ), ISSUE_i.operand( 1 )( 63 ) ) );
                     uc_s <= unsigned( NEG_IF( signed( ISSUE_i.operand( 2 ) ), ISSUE_i.operand( 2 )( 63 ) ) );
                     sa_s <= ISSUE_i.operand( 0 )( 63 );
                     sb_s <= ISSUE_i.operand( 1 )( 63 );
                     sc_s <= ISSUE_i.operand( 2 )( 63 );
                     step_s  <= CHARGE;
                     state_s <= ATTENTE;
                  end if;

               when ATTENTE =>
                  case step_s is

                     when ABSOLU =>
                        -- |MIN_64| = MIN_64 (négation modulo 2**64) : son motif non signé vaut bien 2**63.
                        ua_s <= unsigned( NEG_IF( a_s, a_s( 63 ) ) );
                        ub_s <= unsigned( NEG_IF( b_s, b_s( 63 ) ) );
                        uc_s <= unsigned( NEG_IF( c_s, c_s( 63 ) ) );
                        sa_s <= a_s( 63 );
                        sb_s <= b_s( 63 );
                        sc_s <= c_s( 63 );
                        step_s <= CHARGE;

                     when CHARGE =>
                        rem_s <= ( others => '0' );
                        if op_s = OP_MUL then
                           -- Produit enregistré dans dq_s ; contrôle et signe au pas
                           -- suivant (le produit, puis la négation, dans un même cycle
                           -- formaient le chemin critique de l'unité).
                           dq_s   <= prod;
                           step_s <= PRODUIT;
                        elsif IS_CVT_OP( op_s ) then
                           dq_s   <= prod;
                           dvs_s  <= uc_s;
                           iter_s <= 128 / DIV_BITS;
                           step_s <= DIVISE;
                        else
                           -- Quartets de tête nuls du dividende : les pas correspondants
                           -- ne produiraient que des zéros (reste partiel nul).
                           nz     := ZERO_NIBBLES( ua_s );
                           dq_s   <= shift_left( ua_s, 4 * nz ) & to_unsigned( 0, 64 );
                           dvs_s  <= ub_s;
                           if nz = 16 then
                              step_s <= FINAL;
                           else
                              iter_s <= 16 - nz;
                              step_s <= DIVISE;
                           end if;
                        end if;

                     when PRODUIT =>
                        -- Résultat rendu dans ce cycle (mul_out_s, combinatoire).
                        state_s <= LIBRE;

                     when DIVISE =>
                        dq := dq_s;
                        rm := rem_s;
                        DIVISE_PAS( dq, rm, dvs_s );
                        dq_s  <= dq;
                        rem_s <= rm;
                        if iter_s = 1 then
                           step_s <= FINAL;
                        end if;
                        iter_s <= iter_s - 1;

                     when FINAL =>
                        -- Quotient non signé : dq_s ; reste non signé : rem_s.
                        if IS_CVT_OP( op_s ) then
                           -- p = a.b est négatif si sa /= sb (p = 0 : Q = R = 0,
                           -- le signe est alors sans effet).
                           neg := sa_s xor sb_s xor sc_s;
                           q := NEG_IF( signed( dq_s ), neg );
                           -- Arrondi de CVTXI si rem_s >= uc_s - rem_s (modulo 2**64,
                           -- comme le "-" de numeric_std) : différence, puis
                           -- comparaison par la retenue d'une soustraction sur 66 bits.
                           d64 := ADD_PFX( uc_s, not rem_s, '1' );
                           s66 := ADD_PFX( "00" & rem_s, "01" & not d64, '1' );
                           if op_s = OP_CVTXI and s66( 65 ) = '1' then
                              -- q - 1 : q + (-1) ; q + 1 : q + 0 + 1.
                              q := signed( ADD_PFX( unsigned( q ), ( 127 downto 0 => neg ), not neg ) );
                           end if;
                           fits := FITS_64( q );
                           if c_s = 0 then
                              result_s <= FAULT_RESULT( FAULT_DIV_ZERO );
                           elsif fits then
                              result_s <= OK_RESULT( q( 63 downto 0 ) );
                           else
                              result_s <= FAULT_RESULT( FAULT_OVERFLOW );
                           end if;

                        elsif op_s = OP_DIV or op_s = OP_REMI or op_s = OP_MODI then
                           if b_s = 0 then
                              result_s <= FAULT_RESULT( FAULT_DIV_ZERO );
                           elsif a_s = MIN_64 and b_s = MINUS_ONE then
                              if op_s = OP_DIV then
                                 result_s <= FAULT_RESULT( FAULT_OVERFLOW );
                              else
                                 result_s <= OK_RESULT( ( others => '0' ) );
                              end if;
                           elsif op_s = OP_DIV then
                              -- Troncature vers zéro, comme "/" de numeric_std.
                              result_s <= OK_RESULT( NEG_IF( signed( dq_s( 63 downto 0 ) ), sa_s xor sb_s ) );
                           else
                              -- rem : signe du dividende.
                              v := NEG_IF( signed( rem_s ), sa_s );
                              -- mod : signe du diviseur.
                              if op_s = OP_MODI and v /= 0 and v( 63 ) /= b_s( 63 ) then
                                 v := signed( ADD_PFX( unsigned( v ), unsigned( b_s ), '0' ) );
                              end if;
                              result_s <= OK_RESULT( v );
                           end if;

                        else
                           result_s <= FAULT_RESULT( FAULT_UNDEFINED );
                        end if;
                        state_s <= RESULTAT;

                  end case;

               when RESULTAT =>
                  state_s <= LIBRE;
            end case;
         end if;
      end if;
   end process AUTOMATE;

                                ---
end architecture                RTL;
