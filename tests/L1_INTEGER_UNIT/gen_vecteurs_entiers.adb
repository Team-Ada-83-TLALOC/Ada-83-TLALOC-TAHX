--  SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
--  SPDX-License-Identifier: GPL-3.0-or-later
--
--  Generateur des vecteurs d'INTEGER_UNIT (tests/L1_INTEGER_UNIT).
--
--  La semantique est celle de Machine (machine.adb de tx_run, depot eXecutor), dont les
--  expressions sont reprises telles quelles : Masque, Controler_Champ, Compte_Decalage,
--  tests de debordement de NEG, ABS, ADD, SUB, INC, DEC (V7), champs de bits. Machine ne
--  les expose pas operation par operation : elles sont dans la grande instruction case
--  de l'execution. Seule la forme canonique (opcode HX, val, ofs, address) est propre au
--  materiel ; elle suit l'en-tete de L1_INTEGER_UNIT.vhd.
--
--    gen_vecteurs_entiers <par operation> <graine> <sortie>
--
--  Une ligne par instruction (hexadecimal en majuscules) :
--    I <op:2> <lvl:1> <ofs:2> <val:8> <address_known 0/1> <address:16> <sources>
--      <s0:16> <s1:16> <s2:16> <s3:16> <faute:2, 00 sans faute> <resultat:16>
with Interfaces; use Interfaces;
with Text_IO;
with Args;
procedure Gen_Vecteurs_Entiers is

   Bit_63 : constant Unsigned_64 := 16#8000_0000_0000_0000#;
   Sans_Faute    : constant := 0;
   Faute_Debordement : constant := 129;
   Faute_Indefinie   : constant := 137;

   Usage : exception;
   Sortie : Text_IO.File_Type;
   Etat : Unsigned_64 := 16#9E37_79B9_7F4A_7C15#;
   Chiffres : constant String := "0123456789ABCDEF";
   Par_Operation : Positive := 1;
   Nb_Lignes, Nb_Fautes : Natural := 0;

   type Mots is array (0 .. 3) of Unsigned_64;

   type Instruction is record
      Op, Lvl, Ofs : Natural;
      Val : Unsigned_64;                 -- 32 bits (canon.val), signe dans le bit 31
      Connue : Boolean;                  -- address_known
      Adresse : Unsigned_64;
      Nb : Natural;                      -- sources
      S : Mots;
   end record;

   --  valeurs remarquables
   Bords : constant array (0 .. 13) of Unsigned_64 :=
     (0, 1, 2, 16#FFFF_FFFF_FFFF_FFFF#, 16#FFFF_FFFF_FFFF_FFFE#,
      16#7FFF_FFFF_FFFF_FFFF#, 16#7FFF_FFFF_FFFF_FFFE#, Bit_63, Bit_63 + 1,
      16#8000_0000#, 16#7FFF_FFFF#, 16#FFFF_FFFF#, 16#1_0000_0000#, 16#FF#);

   --------------------------------------------------------------------------------
   --  Hasard reproductible
   --------------------------------------------------------------------------------

   function Hasard return Unsigned_64 is
   begin
      Etat := Etat xor Shift_Right (Etat, 12);
      Etat := Etat xor Shift_Left (Etat, 25);
      Etat := Etat xor Shift_Right (Etat, 27);
      return Etat * 16#2545_F491_4F6C_DD1D#;
   end Hasard;

   function Tirer (N : Positive) return Natural is
   begin
      return Natural (Shift_Right (Hasard, 16) mod Unsigned_64 (N));
   end Tirer;

   function Mot return Unsigned_64 is                    -- bords ou quelconque
   begin
      case Tirer (4) is
         when 0 => return Bords (Tirer (Bords'Length));
         when 1 => return Hasard and 16#FFFF#;                 -- petit
         when 2 => return 0 - (Hasard and 16#FFFF#);           -- petit negatif
         when others => return Hasard;
      end case;
   end Mot;

   function Compte return Unsigned_64 is                 -- compte de decalage
   begin
      case Tirer (10) is
         when 0 => return Hasard;
         when 1 => return 63 + Unsigned_64 (Tirer (3));          -- 63, 64, 65
         when others => return Unsigned_64 (Tirer (71));         -- 0 .. 70
      end case;
   end Compte;

   --------------------------------------------------------------------------------
   --  Semantique de Machine (machine.adb), expressions reprises
   --------------------------------------------------------------------------------

   function Masque (Largeur : Unsigned_64) return Unsigned_64 is
   begin
      if Largeur = 0 then
         return 0;
      elsif Largeur >= 64 then
         return 16#FFFF_FFFF_FFFF_FFFF#;
      end if;
      return Shift_Left (1, Natural (Largeur)) - 1;
   end Masque;

   function Champ_Illegal (Lsb, Largeur : Unsigned_64) return Boolean is   -- Controler_Champ
   begin
      return Largeur = 0 or else Largeur > 64 or else Lsb > 64 - Largeur;
   end Champ_Illegal;

   function Signe_32 (V : Unsigned_64) return Unsigned_64 is      -- canon.val etendu
   begin
      if (V and 16#8000_0000#) /= 0 then
         return V or 16#FFFF_FFFF_0000_0000#;
      end if;
      return V and 16#FFFF_FFFF#;
   end Signe_32;

   function Plus_Petit (A, B : Unsigned_64) return Boolean is     -- signe
   begin
      return (A xor Bit_63) < (B xor Bit_63);
   end Plus_Petit;

   function Booleen (B : Boolean) return Unsigned_64 is
   begin
      if B then
         return 1;
      end if;
      return 0;
   end Booleen;

   procedure Executer (I : Instruction; Faute_Sortie : out Natural; R_Sortie : out Unsigned_64) is
      A : constant Unsigned_64 := I.S (0);
      B : constant Unsigned_64 := I.S (1);
      V, L, W, Ins : Unsigned_64;
      Faute : Natural := Sans_Faute;                -- Ada 83 : un parametre out ne se relit pas
      R : Unsigned_64 := 0;
   begin
      case I.Op is
         when 16#00# => R := A and B;
         when 16#01# => R := A or B;
         when 16#02# => R := A xor B;
         when 16#03# => R := not A;
         when 16#04# | 16#05# | 16#06# =>
            if B >= 64 then                                         -- Compte_Decalage
               Faute := Faute_Indefinie;
            elsif I.Op = 16#04# then
               R := Shift_Left (A, Natural (B));
            elsif I.Op = 16#05# then
               R := Shift_Right (A, Natural (B));
            else
               R := Shift_Right_Arithmetic (A, Natural (B));
            end if;
         when 16#07# =>                                             -- CLAMP0
            if (A and Bit_63) /= 0 then
               R := 0;
            else
               R := A;
            end if;
         when 16#08# =>                                             -- NEG
            if A = Bit_63 then
               Faute := Faute_Debordement;
            end if;
            R := 0 - A;
         when 16#0F# =>                                             -- ABS
            if A = Bit_63 then
               Faute := Faute_Debordement;
            end if;
            V := Shift_Right_Arithmetic (A, 63);
            R := (A xor V) - V;
         when 16#09# => R := Booleen (Plus_Petit (B, A));           -- CGT
         when 16#0A# => R := Booleen (Plus_Petit (A, B));           -- CLT
         when 16#0B# => R := Booleen (A /= B);                      -- CNE
         when 16#0C# => R := Booleen (A = B);                       -- CEQ
         when 16#0D# => R := Booleen (not Plus_Petit (A, B));       -- CGE
         when 16#0E# => R := Booleen (not Plus_Petit (B, A));       -- CLE
         when 16#10# =>                                             -- ADD
            V := A + B;
            if ((A xor V) and (B xor V) and Bit_63) /= 0 then
               Faute := Faute_Debordement;
            end if;
            R := V;
         when 16#12# =>                                             -- SUB
            V := A - B;
            if ((A xor B) and (A xor V) and Bit_63) /= 0 then
               Faute := Faute_Debordement;
            end if;
            R := V;
         when 16#11# =>                                             -- INC
            if A = Bit_63 - 1 then
               Faute := Faute_Debordement;
            end if;
            R := A + 1;
         when 16#13# =>                                             -- DEC
            if A = Bit_63 then
               Faute := Faute_Debordement;
            end if;
            R := A - 1;
         when 16#18# | 16#19# | 16#1A# | 16#C4# | 16#C5# | 16#C6# =>
            if I.Op = 16#18# or I.Op = 16#19# then                  -- ( v lsb w )
               L := I.S (1); W := I.S (2);
            elsif I.Op = 16#1A# then                                -- ( old ins lsb w )
               L := I.S (2); W := I.S (3);
            else                                                    -- immediats
               L := Unsigned_64 (I.Val); W := Unsigned_64 (I.Ofs);
            end if;
            if Champ_Illegal (L, W) then
               Faute := Faute_Indefinie;
            elsif I.Op = 16#18# or I.Op = 16#C4# then               -- UBFX
               R := Shift_Right (A, Natural (L)) and Masque (W);
            elsif I.Op = 16#19# or I.Op = 16#C5# then               -- SBFX
               V := Shift_Right (A, Natural (L));
               if W < 64 then
                  V := Shift_Right_Arithmetic (Shift_Left (V, Natural (64 - W)), Natural (64 - W));
               end if;
               R := V;
            else                                                    -- BFI
               Ins := I.S (1);
               V := Masque (W);
               R := (A and not Shift_Left (V, Natural (L))) or Shift_Left (Ins and V, Natural (L));
            end if;
         when 16#47# | 16#4B# =>                                    -- LVA
            if I.Connue then
               R := I.Adresse;
            else
               R := A + Signe_32 (I.Val);
            end if;
         when 16#C0# | 16#C1# | 16#C2# | 16#D0# .. 16#DF# =>       -- LI
            R := Signe_32 (I.Val);
         when 16#C7# =>                                             -- UOP_LIHI
            R := Shift_Left (I.Val and 16#FFFF_FFFF#, 32) or (A and 16#FFFF_FFFF#);
         when others =>
            raise Program_Error;
      end case;
      if Faute /= Sans_Faute then
         R := 0;
      end if;
      Faute_Sortie := Faute;
      R_Sortie := R;
   end Executer;

   --------------------------------------------------------------------------------
   --  Formes canoniques tirees
   --------------------------------------------------------------------------------

   function Hex (V : Unsigned_64; N : Positive) return String is
      S : String (1 .. N);
      X : Unsigned_64 := V;
   begin
      for K in reverse S'Range loop
         S (K) := Chiffres (Natural (X mod 16) + 1);
         X := X / 16;
      end loop;
      return S;
   end Hex;

   function Dec (N : Natural) return String is
      S : constant String := Natural'Image (N);
   begin
      return S (S'First + 1 .. S'Last);
   end Dec;

   procedure Ecrire (I : Instruction) is
      Faute : Natural;
      R : Unsigned_64;
      C : Character := '0';
   begin
      Executer (I, Faute, R);
      if I.Connue then
         C := '1';
      end if;
      Text_IO.Put_Line (Sortie, "I " & Hex (Unsigned_64 (I.Op), 2) & " " & Hex (Unsigned_64 (I.Lvl), 1)
                        & " " & Hex (Unsigned_64 (I.Ofs), 2) & " " & Hex (I.Val, 8) & " " & C
                        & " " & Hex (I.Adresse, 16) & " " & Dec (I.Nb)
                        & " " & Hex (I.S (0), 16) & " " & Hex (I.S (1), 16)
                        & " " & Hex (I.S (2), 16) & " " & Hex (I.S (3), 16)
                        & " " & Hex (Unsigned_64 (Faute), 2) & " " & Hex (R, 16));
      Nb_Lignes := Nb_Lignes + 1;
      if Faute /= Sans_Faute then
         Nb_Fautes := Nb_Fautes + 1;
      end if;
   end Ecrire;

   --  lsb, w : legaux le plus souvent, sinon pres des bornes ou quelconques
   procedure Champ (Lsb_Sortie, W_Sortie : out Unsigned_64) is
      Lsb, W : Unsigned_64;
   begin
      case Tirer (10) is
         when 0 => W := 0; Lsb := Unsigned_64 (Tirer (65));
         when 1 => W := 65 + Unsigned_64 (Tirer (3)); Lsb := Unsigned_64 (Tirer (3));
         when 2 => W := 1 + Unsigned_64 (Tirer (64)); Lsb := 65 - W;    -- d'un cran trop haut
         when 3 => W := Hasard; Lsb := Hasard;
         when 4 => W := 2; Lsb := 16#FFFF_FFFF_FFFF_FFFF#;               -- lsb + w enveloppe
         when others =>
            W := 1 + Unsigned_64 (Tirer (64));
            Lsb := Unsigned_64 (Tirer (Natural (65 - W)));
      end case;
      Lsb_Sortie := Lsb;
      W_Sortie := W;
   end Champ;

   procedure Generer (Op : Natural) is
      I : Instruction;
      L, W : Unsigned_64;
   begin
      for K in 1 .. Par_Operation loop
         I := (Op => Op, Lvl => 0, Ofs => 0, Val => 0, Connue => False, Adresse => 0, Nb => 0,
               S => (Mot, Mot, Mot, Mot));
         case Op is
            when 16#03# | 16#07# | 16#08# | 16#0F# | 16#11# | 16#13# =>
               I.Nb := 1;
            when 16#04# | 16#05# | 16#06# =>
               I.Nb := 2; I.S (1) := Compte;
            when 16#18# | 16#19# =>
               I.Nb := 3; Champ (L, W); I.S (1) := L; I.S (2) := W;
            when 16#1A# =>
               I.Nb := 4; Champ (L, W); I.S (2) := L; I.S (3) := W;
            when 16#C4# | 16#C5# | 16#C6# =>                         -- legaux (decodeur)
               loop
                  Champ (L, W);
                  exit when not Champ_Illegal (L, W);
               end loop;
               I.Val := L; I.Ofs := Natural (W);
               if Op = 16#C6# then
                  I.Nb := 2;
               else
                  I.Nb := 1;
               end if;
            when 16#47# | 16#4B# =>
               if Tirer (2) = 0 then                                 -- lvl 0 .. 14
                  I.Connue := True; I.Lvl := Tirer (15); I.Adresse := Hasard;
                  I.Val := Hasard and 16#FFFF_FFFF#;                 -- a ignorer
               else                                                  -- lvl = 1111
                  I.Lvl := 15; I.Nb := 1;
                  if Op = 16#47# then                                -- disp B16, 12 bits
                     I.Val := Hasard and 16#FFF#;
                     if (I.Val and 16#800#) /= 0 then
                        I.Val := I.Val or 16#FFFF_F000#;
                     end if;
                  else                                               -- disp B24, 20 bits
                     I.Val := Hasard and 16#F_FFFF#;
                     if (I.Val and 16#8_0000#) /= 0 then
                        I.Val := I.Val or 16#FFF0_0000#;
                     end if;
                  end if;
               end if;
            when 16#C0# =>
               I.Val := Hasard and 16#FF#;
               if (I.Val and 16#80#) /= 0 then I.Val := I.Val or 16#FFFF_FF00#; end if;
            when 16#C1# =>
               I.Val := Hasard and 16#FFFF#;
               if (I.Val and 16#8000#) /= 0 then I.Val := I.Val or 16#FFFF_0000#; end if;
            when 16#C2# =>
               I.Val := Hasard and 16#FFFF_FFFF#;
            when 16#D0# .. 16#DF# =>
               I.Val := Unsigned_64 (Op - 16#D0#);
            when 16#C7# =>
               I.Nb := 1; I.Val := Hasard and 16#FFFF_FFFF#;
            when 16#09# .. 16#0E# | 16#10# | 16#12# =>               -- comparaisons, ADD, SUB
               I.Nb := 2;
               case Tirer (10) is                                    -- egaux ou voisins
                  when 0 | 1 => I.S (1) := I.S (0);
                  when 2 => I.S (1) := I.S (0) + 1;
                  when 3 => I.S (1) := I.S (0) - 1;
                  when others => null;
               end case;
            when others =>
               I.Nb := 2;
         end case;
         --  sources au-dela de Nb : quelconques, l'unite doit les ignorer
         Ecrire (I);
      end loop;
   end Generer;

begin
   if Args.Nombre /= 3 then
      raise Usage;
   end if;
   Par_Operation := Positive'Value (Args.Argument (1));
   Etat := Etat xor Unsigned_64 (Positive'Value (Args.Argument (2)));
   Text_IO.Create (Sortie, Text_IO.Out_File, Args.Argument (3));
   Text_IO.Put_Line (Sortie, "# INTEGER_UNIT : " & Args.Argument (1) & " instructions par operation, graine "
                     & Args.Argument (2));
   for Op in 16#00# .. 16#13# loop
      Generer (Op);
   end loop;
   for Op in 16#18# .. 16#1A# loop
      Generer (Op);
   end loop;
   Generer (16#47#);
   Generer (16#4B#);
   for Op in 16#C0# .. 16#C2# loop
      Generer (Op);
   end loop;
   for Op in 16#C4# .. 16#C7# loop
      Generer (Op);
   end loop;
   for Op in 16#D0# .. 16#DF# loop
      Par_Operation := Positive'Value (Args.Argument (1)) / 16 + 1;
      Generer (Op);
   end loop;
   Text_IO.Close (Sortie);
   Text_IO.Put_Line (Dec (Nb_Lignes) & " instructions, dont " & Dec (Nb_Fautes) & " en faute");
exception
   when Usage =>
      Text_IO.Put_Line ("usage : gen_vecteurs_entiers <par operation> <graine> <sortie>");
      Args.Code_De_Sortie (2);
end Gen_Vecteurs_Entiers;
