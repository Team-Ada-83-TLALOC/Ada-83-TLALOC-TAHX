--  Genere TAHX_1_isa_table.vhd (table des 256 valeurs du premier octet) a partir de la table
--  des opcodes de LLIR_hardware_support.
--
--     gen_tahx_isa SPEC TAHX_1_isa_table.vhd
--
--  La table de la specification donne le nom et le complement de chaque opcode. Ce programme
--  y ajoute les proprietes propres au materiel (classe d'unite, effet de pile, usage de lvl,
--  drapeaux), donnees ci-dessous par nom : c'est la seule connaissance qu'il apporte.
--  La longueur tiree du complement est comparee a la table des longueurs de la specification,
--  recalculee a partir des seuls bits de l'opcode (invariant de decodage).
with Text_IO;
with Args;
with Spec_LLIR; use Spec_LLIR;
procedure Gen_TAHX_ISA is

   type Classe is (NONE, INTEGER, MUL_DIV, MEMORY, BRANCH, FLOAT, COMPLEX);
   type Action is (LINEAR, DUP, OVER, DROP, KEEP_TOP);
   type Usage_Lvl is (NONE, ADDR, FRAME);

   --  pops / pushes : effet de pile pour lvl /= 1111 ; ADDR ajoute un pop si lvl = 1111.
   --  drapeaux : Serial (serialisante), Control (transfert de controle), Mem (acces
   --  memoire), Frame (DSP / DISPLAY modifies de facon non lineaire).
   type Proprietes is record
      Cl      : Classe;
      Pops    : Natural;
      Pushes  : Natural;
      Act     : Action;
      Lvl     : Usage_Lvl;
      Serial  : Boolean;
      Control : Boolean;
      Mem     : Boolean;
      Frame   : Boolean;
   end record;

   Inconnu : exception;
   Sortie  : Text_IO.File_Type;
   Table   : Table_Opcodes;
   TAB     : constant Character := Character'Val (9);

   --  Nom appartient-il a la liste de mots separes par des blancs ?
   function Dans (Nom, Liste : String) return Boolean is
      K : Natural := Liste'First;
      D : Natural;
   begin
      while K <= Liste'Last loop
         while K <= Liste'Last and then Liste (K) = ' ' loop
            K := K + 1;
         end loop;
         D := K;
         while K <= Liste'Last and then Liste (K) /= ' ' loop
            K := K + 1;
         end loop;
         if K > D and then Liste (D .. K - 1) = Nom then
            return True;
         end if;
      end loop;
      return False;
   end Dans;

   function P (Cl : Classe; Pops, Pushes : Natural; Act : Action := LINEAR;
               Lvl : Usage_Lvl := NONE; Drapeaux : String := "") return Proprietes is
   begin
      return (Cl, Pops, Pushes, Act, Lvl,
              Dans ("S", Drapeaux), Dans ("C", Drapeaux), Dans ("M", Drapeaux),
              Dans ("F", Drapeaux));
   end P;

   function Proprietes_De (N : String) return Proprietes is
   begin
      if Dans (N, "ET OU OUX SHL SHR SAR ADD SUB CGT CLT CNE CEQ CGE CLE") then
         return P (INTEGER, 2, 1);
      elsif Dans (N, "NON CLAMP0 NEG ABS INC DEC") then
         return P (INTEGER, 1, 1);
      elsif Dans (N, "MUL DIV REMI MODI") then
         return P (MUL_DIV, 2, 1);
      elsif Dans (N, "UBFX SBFX") then
         return P (INTEGER, 3, 1);
      elsif N = "BFI" then
         return P (INTEGER, 4, 1);
      elsif Dans (N, "CVTIX CVTXI") then
         return P (MUL_DIV, 3, 1);
      elsif Dans (N, "FADD FSUB FMUL FDIV FCGT FCLT FCNE FCEQ FCGE FCLE") then
         return P (FLOAT, 2, 1);
      elsif Dans (N, "CVTIF CVTFI CVTFIR FNEG FABS") then
         return P (FLOAT, 1, 1);
      elsif N = "FEXP" then                             -- boucle : unite iterative
         return P (COMPLEX, 2, 1);
      elsif N = "DROP" then
         return P (NONE, 1, 0, DROP);
      elsif N = "DUP" then
         return P (NONE, 1, 2, DUP);
      elsif N = "OVER" then
         return P (NONE, 2, 3, OVER);
      elsif N = "CALLI" then
         return P (BRANCH, 1, 0, Drapeaux => "C");
      elsif Dans (N, "BLKMOV BLKAND BLKOU BLKOUX") then
         return P (COMPLEX, 3, 0, Drapeaux => "M");
      elsif N = "BLKCMP" then
         return P (COMPLEX, 3, 1, Drapeaux => "M");
      elsif N = "BLKNOT" then
         return P (COMPLEX, 2, 0, Drapeaux => "M");
      elsif Dans (N, "CO_VAR HEAP_ALLOC") then
         return P (COMPLEX, 1, 1);
      elsif N = "LINK" then
         return P (COMPLEX, 0, 0, Lvl => FRAME, Drapeaux => "M F");
      elsif N = "EXC_MACH" then
         return P (COMPLEX, 0, 0, Lvl => FRAME, Drapeaux => "M");
      elsif N = "LVA" then
         return P (INTEGER, 0, 1, Lvl => ADDR);
      elsif Dans (N, "LB LW LD LQ ULB ULW ULD LIVA LIB LIW LID LIQ ULIB ULIW ULID") then
         return P (MEMORY, 0, 1, Lvl => ADDR, Drapeaux => "M");
      elsif Dans (N, "SB SW SD SQ SIB SIW SID SIQ") then
         return P (MEMORY, 1, 0, Lvl => ADDR, Drapeaux => "M");
      elsif Dans (N, "CHKB CHKW CHKD CHKQ CHKUB CHKUW CHKUD "
                   & "CHKIB CHKIW CHKID CHKIQ CHKUIB CHKUIW CHKUID") then
         return P (MEMORY, 1, 1, KEEP_TOP, FRAME, "M");
      elsif Dans (N, "LI LI(imm4)") then
         return P (INTEGER, 0, 1);
      elsif Dans (N, "UBFXI SBFXI") then
         return P (INTEGER, 1, 1);
      elsif N = "BFII" then
         return P (INTEGER, 2, 1);
      elsif Dans (N, "LEXCMPB LEXCMPW LEXCMPD LEXCMPQ ULEXCMPB ULEXCMPW ULEXCMPD") then
         return P (COMPLEX, 4, 1, Drapeaux => "M");
      elsif Dans (N, "BRA CALL RTD") then               -- RTD n : DSP -= n, suivi au renommage
         return P (BRANCH, 0, 0, Drapeaux => "C");
      elsif Dans (N, "BT BF") then
         return P (BRANCH, 1, 0, Drapeaux => "C");
      elsif Dans (N, "UNLINK UNLINKR") then
         return P (COMPLEX, 0, 0, Lvl => FRAME, Drapeaux => "M F");
      elsif Dans (N, "TRAP RTX") then                   -- executees par SYSTEM_UNIT
         return P (COMPLEX, 0, 0, Drapeaux => "S C");
      elsif N = "EXC_RAISE" then
         return P (COMPLEX, 0, 0, Drapeaux => "S C M");
      end if;
      Text_IO.Put_Line ("gen_tahx_isa : instruction sans proprietes materielles : " & N);
      raise Inconnu;
   end Proprietes_De;

   --  Table des longueurs de la specification, a partir des seuls bits de l'opcode
   function Longueur_Attendue (C : Natural) return Natural is
      F   : constant Natural := C / 64;
      Fmt : constant Natural := (C / 4) mod 4;
      SF  : constant Natural := (C / 16) mod 4;
      K   : constant Natural := (C / 8) mod 2;
      S   : constant Natural := (C / 4) mod 2;
      SZ  : constant Natural := C mod 4;
      Fun : constant Natural := C mod 16;
      Supplement : Natural := 0;
   begin
      if F = 0 then
         return 1;
      elsif F = 1 or F = 2 then
         if F = 2 then
            Supplement := 1;
         end if;
         case Fmt is
            when 0      => return 1;
            when 1      => return 3 + Supplement;
            when others => return 4 + Supplement;
         end case;
      end if;
      case SF is
         when 0 =>
            if K = 1 then
               return 1;                                  -- LEXCMP
            elsif S = 1 then
               return 3;                                  -- UBFXI.. D8_8
            end if;
            case SZ is                                    -- LI D8 .. D64
               when 0      => return 2;
               when 1      => return 3;
               when 2      => return 5;
               when others => return 9;
            end case;
         when 1 =>
            return 1;                                     -- LI imm4
         when 2 =>
            return 2 + SZ;                                -- branches
         when others =>
            if Fun = 0 or Fun = 8 or Fun = 9 then
               return 2;                                  -- TRAP, UNLINK, UNLINKR
            elsif Fun = 2 or Fun = 6 or Fun = 14 then
               return 4;                                  -- CALL, RTD n, EXC_RAISE
            end if;
            return 1;
      end case;
   end Longueur_Attendue;

   function Format_VHDL (E : Entree) return String is
   begin
      if E.Imm4 then
         return "FMT_IMM4";
      elsif E.Compl = Aucun then
         return "FMT_NONE";
      end if;
      return "FMT_" & Complement'Image (E.Compl);
   end Format_VHDL;

   function B (X : Boolean) return String is
   begin
      if X then
         return "true";
      end if;
      return "false";
   end B;

   function Image_Classe (X : Classe) return String is
   begin
      return Classe'Image (X);
   end Image_Classe;

   procedure L (Texte : String) is
   begin
      Text_IO.Put_Line (Sortie, Texte);
   end L;

begin
   if Args.Nombre /= 2 then
      Text_IO.Put_Line ("usage : gen_tahx_isa SPEC TAHX_1_isa_table.vhd");
      Args.Code_De_Sortie (2);
      return;
   end if;
   Lire (Args.Argument (1), Table);
   if Nombre_Opcodes (Table) /= 180 then
      Text_IO.Put_Line ("gen_tahx_isa : 180 opcodes attendus, " & Decimal (Nombre_Opcodes (Table), 1)
                        & " trouves");
      Args.Code_De_Sortie (1);
      return;
   end if;
   Text_IO.Create (Sortie, Text_IO.Out_File, Args.Argument (2));

   L ("------------------------------------------------------------------------------------------------------------------------");
   L ("-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO");
   L ("-- SPDX-License-Identifier: GPL-3.0-or-later");
   L ("------------------------------------------------------------------------------------------------------------------------");
   L ("--  Table des opcodes HX : GENEREE par outils/gen_tahx_isa a partir de la table des opcodes");
   L ("--  de LLIR_hardware_support. Ne pas modifier a la main.");
   L ("--  Une entree par valeur du premier octet : longueur (invariant de decodage), format du");
   L ("--  complement, classe d'unite, effet de pile, usage de lvl, drapeaux.");
   L ("------------------------------------------------------------------------------------------------------------------------");
   L ("");
   L ("use work.TAHX_1_ISA.all;");
   L ("");
   L (TAB & TAB & TAB & TAB & "-------------------");
   L ("package" & TAB & TAB & TAB & TAB & "TAHX_1_ISA_TABLE");
   L ("is" & TAB & TAB & TAB & TAB & "-------------------");
   L ("");
   L ("   constant ISA_TABLE" & TAB & ": isa_table_t := (");
   for C in 0 .. 255 loop
      declare
         E   : Entree renames Table (C);
         Sep : Character := ',';
      begin
         if C = 255 then
            Sep := ' ';
         end if;
         if not E.Defini then
            L ("      16#" & Hexa_2 (C) & "# => ISA_RESERVE" & Sep
               & TAB & TAB & TAB & TAB & TAB & TAB & TAB & TAB & TAB & TAB & "-- reserve");
         else
            declare
               Lg : constant Natural := 1 + Octets_Complement (E.Compl);
               Pr : constant Proprietes := Proprietes_De (Nom (E));
            begin
               if Lg /= Longueur_Attendue (C) then
                  Text_IO.Put_Line ("gen_tahx_isa : " & Hexa_2 (C) & " " & Nom (E) & " : longueur"
                                    & Natural'Image (Lg) & ", la table des longueurs donne"
                                    & Natural'Image (Longueur_Attendue (C)));
                  Args.Code_De_Sortie (1);
                  Text_IO.Close (Sortie);
                  return;
               end if;
               L ("      16#" & Hexa_2 (C) & "# => (true, " & Decimal (Lg, 1) & ", "
                  & Format_VHDL (E) & ", ISSUE_" & Image_Classe (Pr.Cl) & ", "
                  & Decimal (Pr.Pops, 1) & ", " & Decimal (Pr.Pushes, 1)
                  & ", STACK_" & Action'Image (Pr.Act) & ", LVL_" & Usage_Lvl'Image (Pr.Lvl)
                  & ", " & B (Pr.Serial) & ", " & B (Pr.Control) & ", " & B (Pr.Mem)
                  & ", " & B (Pr.Frame) & ")" & Sep & TAB & "-- "
                  & Decimal (E.Numero, 3) & " " & Nom (E));
            end;
         end if;
      end;
   end loop;
   L ("   );");
   L ("");
   L (TAB & TAB & "-------------------");
   L ("end package" & TAB & "TAHX_1_ISA_TABLE;");
   L (TAB & TAB & "-------------------");
   Text_IO.Close (Sortie);
   declare
      N : Natural := 0;
   begin
      for C in Table'Range loop
         if Table (C).Defini then
            N := N + 1;
         end if;
      end loop;
      Text_IO.Put_Line ("gen_tahx_isa : 180 opcodes," & Natural'Image (N)
                        & " valeurs du premier octet definies");
   end;
exception
   when Spec_LLIR.Erreur =>
      Text_IO.Put_Line ("gen_tahx_isa : " & Spec_LLIR.Message);
      Args.Code_De_Sortie (1);
   when Inconnu =>
      Args.Code_De_Sortie (1);
end Gen_TAHX_ISA;
