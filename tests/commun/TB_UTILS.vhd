library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
		--------------------------------------------------------------------------------
		--  TB_UTILS : ce que partagent les bancs de test (VHDL-2008).
		--
		--  Un banc tient un compteur (tb_counter_t), appelle CHECK pour chaque
		--  vérification et FINISH à la fin :
		--
		--      variable c : tb_counter_t;
		--      ...
		--      CHECK( c, longueur = 3, "LI D16 : longueur", "3", to_string( longueur ) );
		--      ...
		--      FINISH( c, "T_I3_DECODE_BLOC_tb" );
		--
		--  FINISH écrit la ligne de bilan et arrête la simulation (std.env.stop) avec
		--  le code 0 (OK) ou 1 (ECHEC) : c'est ce code que lit lancer_tests.sh.
		--  CHECK_PASSED compte une vérification réussie sans composer de message
		--  (boucles chaudes : le message n'est construit que pour un échec).
		--  Les MAX_REPORTED premiers échecs sont décrits ; les suivants sont seulement
		--  comptés, pour qu'un banc cassé ne noie pas le terminal.
		--------------------------------------------------------------------------------


				--------
package				TB_UTILS
is				--------

   constant MAX_REPORTED	: positive	:= 20;

   type tb_counter_t		is record
			  checks		: natural;		-- vérifications faites
			  failures	: natural;		-- dont échouées
			end record;

   constant TB_COUNTER_INIT	: tb_counter_t	:= ( checks => 0, failures => 0 );

   -- une vérification ; expected et obtained ne servent qu'au message d'échec
   procedure CHECK(
      variable counter	: inout tb_counter_t;
      condition		: boolean;
      what		: string;
      expected		: string := "";
      obtained		: string := "" );

   -- une vérification réussie, sans message à composer : dans une boucle chaude,
   --    if condition then CHECK_PASSED( c ); else CHECK( c, false, "...", ... ); end if;
   -- évite de mettre en forme le message à chaque appel
   procedure CHECK_PASSED(
      variable counter	: inout tb_counter_t );

   -- bilan, puis arrêt de la simulation avec le code 0 ou 1
   procedure FINISH(
      variable counter	: inout tb_counter_t;
      test_name		: string );

   -- représentations courtes pour les messages
   function HEX( v : std_logic_vector ) return string;
   function HEX( v : unsigned ) return string;
   function HEX( v : signed ) return string;

		--------
end package	TB_UTILS;
		--------


				--------
package body			TB_UTILS
is				--------

   procedure CHECK(
      variable counter	: inout tb_counter_t;
      condition		: boolean;
      what		: string;
      expected		: string := "";
      obtained		: string := "" ) is
   begin
      counter.checks := counter.checks + 1;
      if not condition then
         counter.failures := counter.failures + 1;
         if counter.failures <= MAX_REPORTED then
            if expected'length = 0 and obtained'length = 0 then
               report "ECHEC : " & what severity error;
            else
               report "ECHEC : " & what & " ; attendu " & expected & ", obtenu " & obtained
                  severity error;
            end if;
         elsif counter.failures = MAX_REPORTED + 1 then
            report "(échecs suivants comptés sans détail)" severity error;
         end if;
      end if;
   end procedure;

   procedure CHECK_PASSED(
      variable counter	: inout tb_counter_t ) is
   begin
      counter.checks := counter.checks + 1;
   end procedure;

   procedure FINISH(
      variable counter	: inout tb_counter_t;
      test_name		: string ) is
   begin
      if counter.checks = 0 then
         report "TEST " & test_name & " : ECHEC (aucune vérification)" severity note;
         std.env.stop( 1 );
      elsif counter.failures = 0 then
         report "TEST " & test_name & " : OK (" & integer'image( counter.checks )
            & " vérifications)" severity note;
         std.env.stop( 0 );
      else
         report "TEST " & test_name & " : ECHEC (" & integer'image( counter.failures )
            & " sur " & integer'image( counter.checks ) & ")" severity note;
         std.env.stop( 1 );
      end if;
   end procedure;

   function HEX( v : std_logic_vector ) return string is
   begin
      return to_hstring( v );
   end function;

   function HEX( v : unsigned ) return string is
   begin
      return to_hstring( std_logic_vector( v ) );
   end function;

   function HEX( v : signed ) return string is
   begin
      return to_hstring( std_logic_vector( v ) );
   end function;

		--------
end package body	TB_UTILS;
		--------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
