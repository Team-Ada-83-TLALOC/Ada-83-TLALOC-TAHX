--  SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
--  SPDX-License-Identifier: GPL-3.0-or-later
--
--  Generateur des vecteurs de FLOAT_UNIT (tests/L4_FLOAT_UNIT).
--
--  Calcule comme Machine (machine.adb de tx_run, depot eXecutor) : Long_Float (IEEE 754
--  binary64 de l'hote, arrondi au plus proche pair), Tronquer et Arrondir recopiees, puis
--  applique deux regles V8 que tx_run n'applique pas : tout resultat NaN de FADD, FSUB,
--  FMUL, FDIV est le NaN canonique 0x7FF8000000000000 ; CVTFIR accepte -2^63 (plage
--  [-2^63, 2^63), voir Executer). Contre-verification independante de
--  l'hote par contre_float.py (arithmetique rationnelle exacte).
--
--    gen_vecteurs_float <par operation> <graine> <sortie>
--
--  Une ligne par instruction (hexadecimal en majuscules) :
--    I <op:2> <sources> <s0:16> <s1:16> <faute:2, 00 sans faute> <resultat:16>
with Interfaces; use Interfaces;
with Text_IO;
with Mots; use Mots;
with Args;
procedure Gen_Vecteurs_Float is

   Canonique : constant Unsigned_64 := 16#7FF8_0000_0000_0000#;
   Signe_Bit : constant Unsigned_64 := Bit_63;
   Borne_64  : constant Long_Float := 2.0 ** 63;
   Faute_Conversion : constant := 130;

   OP_FADD  : constant := 16#20#;
   OP_FSUB  : constant := 16#21#;
   OP_FMUL  : constant := 16#22#;
   OP_FDIV  : constant := 16#23#;
   OP_CVTIF : constant := 16#25#;
   OP_CVTFI : constant := 16#26#;
   OP_CVTFIR : constant := 16#27#;
   OP_FNEG  : constant := 16#28#;
   OP_FCGT  : constant := 16#29#;
   OP_FCLE  : constant := 16#2E#;
   OP_FABS  : constant := 16#2F#;

   Usage : exception;
   Sortie : Text_IO.File_Type;
   Etat : Unsigned_64 := 16#9E37_79B9_7F4A_7C15#;
   Chiffres : constant String := "0123456789ABCDEF";
   Nb_Lignes, Nb_Fautes : Natural := 0;
   Par_Operation : Positive := 1;

   type Paire is array (0 .. 1) of Unsigned_64;

   --  valeurs remarquables (motifs binaires)
   Speciaux : constant array (0 .. 15) of Unsigned_64 :=
     (16#3FF0_0000_0000_0000#,                           --  1.0
      16#BFF0_0000_0000_0000#,                           -- -1.0
      16#4000_0000_0000_0000#,                           --  2.0
      16#3FE0_0000_0000_0000#,                           --  0.5
      16#3FF8_0000_0000_0000#,                           --  1.5
      16#4004_0000_0000_0000#,                           --  2.5
      16#C004_0000_0000_0000#,                           -- -2.5
      16#7FEF_FFFF_FFFF_FFFF#,                           --  plus grand normal
      16#0010_0000_0000_0000#,                           --  plus petit normal
      16#000F_FFFF_FFFF_FFFF#,                           --  plus grand sous-normal
      16#0000_0000_0000_0001#,                           --  plus petit sous-normal
      16#4340_0000_0000_0000#,                           --  2^53
      16#43E0_0000_0000_0000#,                           --  2^63
      16#C3E0_0000_0000_0000#,                           -- -2^63
      16#43DF_FFFF_FFFF_FFFF#,                           --  2^63 - 1024
      16#C3E0_0000_0000_0001#);                          -- -2^63 - 2048

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

   function Signe_Hasard return Unsigned_64 is
   begin
      if Tirer (2) = 0 then
         return Signe_Bit;
      end if;
      return 0;
   end Signe_Hasard;

   function Fraction return Unsigned_64 is
   begin
      return Hasard and 16#000F_FFFF_FFFF_FFFF#;
   end Fraction;

   function Avec_Exposant (E : Natural) return Unsigned_64 is       -- E : 0 .. 2047
   begin
      return Signe_Hasard or Shift_Left (Unsigned_64 (E), 52) or Fraction;
   end Avec_Exposant;

   --  un binary64 de toute classe
   function Flottant return Unsigned_64 is
   begin
      case Tirer (16) is
         when 0 => return Signe_Hasard;                                         -- +-0
         when 1 => return Signe_Hasard or Fraction;                             -- sous-normal
         when 2 => return Signe_Hasard or 16#7FF0_0000_0000_0000#;              -- +-inf
         when 3 => return Signe_Hasard or 16#7FF0_0000_0000_0000# or Fraction   -- NaN
                          or Unsigned_64 (Tirer (2));
         when 4 | 5 => return Speciaux (Tirer (Speciaux'Length)) xor Signe_Hasard;
         when 6 | 7 => return Avec_Exposant (1 + Tirer (2046));                 -- tout normal
         when others => return Avec_Exposant (1023 - 60 + Tirer (121));         -- courant
      end case;
   end Flottant;

   --------------------------------------------------------------------------------
   --  Semantique : Long_Float, comme Machine
   --------------------------------------------------------------------------------

   function Est_NaN (F : Long_Float) return Boolean is
   begin
      return F /= F;
   end Est_NaN;

   function Booleen (B : Boolean) return Unsigned_64 is
   begin
      if B then
         return 1;
      end if;
      return 0;
   end Booleen;

   procedure Executer (Op : Natural; S : Paire; Faute_Sortie : out Natural; R_Sortie : out Unsigned_64) is
      F : constant Long_Float := Vers_Reel (S (0));
      G : constant Long_Float := Vers_Reel (S (1));
      H : Long_Float;
      T : Signe;
      Faute : Natural := 0;
      R : Unsigned_64 := 0;
   begin
      case Op is
         when OP_FADD | OP_FSUB | OP_FMUL | OP_FDIV =>
            case Op is
               when OP_FADD => H := F + G;
               when OP_FSUB => H := F - G;
               when OP_FMUL => H := F * G;
               when others  => H := F / G;
            end case;
            if Est_NaN (H) then
               R := Canonique;                                     -- regle V8
            else
               R := Depuis_Reel (H);
            end if;
         when OP_FNEG => R := S (0) xor Signe_Bit;
         when OP_FABS => R := S (0) and not Signe_Bit;
         when 16#29# => R := Booleen (F > G);                      -- FCGT
         when 16#2A# => R := Booleen (F < G);                      -- FCLT
         when 16#2B# => R := Booleen (F /= G);                     -- FCNE, vrai si non ordonne
         when 16#2C# => R := Booleen (F = G);                      -- FCEQ
         when 16#2D# => R := Booleen (F >= G);                     -- FCGE
         when 16#2E# => R := Booleen (F <= G);                     -- FCLE
         when OP_CVTIF =>
            R := Depuis_Reel (Long_Float (Vers_Signe (S (0))));
         when OP_CVTFI =>                                          -- Tronquer de Machine
            if not (F >= -Borne_64 and F < Borne_64) then
               Faute := Faute_Conversion;
            else
               T := Signe (F);
               if F >= 0.0 and then Long_Float (T) > F then
                  T := T - 1;
               elsif F < 0.0 and then Long_Float (T) < F then
                  T := T + 1;
               end if;
               R := Vers_Mot (T);
            end if;
         when OP_CVTFIR =>                                         -- Arrondir de Machine,
            --  sauf la plage : Machine teste F > -2^63 - 0,5, borne qui s'arrondit a -2^63
            --  en Long_Float et refuse donc -2^63 a tort ; la V8 dit [-2^63, 2^63)
            if not (F >= -Borne_64 and F < Borne_64) then
               Faute := Faute_Conversion;
            else
               R := Vers_Mot (Signe (F));                          -- mi-chemin a l'ecart de zero
            end if;
         when others =>
            raise Program_Error;
      end case;
      Faute_Sortie := Faute;
      R_Sortie := R;
   end Executer;

   --------------------------------------------------------------------------------
   --  Ecriture et tirages
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

   procedure Ecrire (Op, Nb : Natural; S : Paire) is
      Faute : Natural;
      R : Unsigned_64;
   begin
      Executer (Op, S, Faute, R);
      Text_IO.Put_Line (Sortie, "I " & Hex (Unsigned_64 (Op), 2) & " " & Dec (Nb)
                        & " " & Hex (S (0), 16) & " " & Hex (S (1), 16)
                        & " " & Hex (Unsigned_64 (Faute), 2) & " " & Hex (R, 16));
      Nb_Lignes := Nb_Lignes + 1;
      if Faute /= 0 then
         Nb_Fautes := Nb_Fautes + 1;
      end if;
   end Ecrire;

   procedure Generer (Op : Natural) is
      S : Paire;
      E, K : Natural;
      M : Unsigned_64;
   begin
      for N in 1 .. Par_Operation loop
         S := (Flottant, Flottant);
         K := Tirer (10);
         case Op is
            when OP_FADD | OP_FSUB =>
               if K < 4 then                                       -- exposants proches
                  E := 1 + Tirer (2046);
                  S (0) := Avec_Exposant (E);
                  if E > 60 then E := E - Tirer (60); end if;
                  S (1) := Avec_Exposant (E);
               elsif K = 4 then
                  S (1) := S (0) xor Signe_Bit;                     -- annulation exacte
               end if;
            when OP_FMUL | OP_FDIV =>
               if K < 3 then                                       -- vers les sous-normaux
                  S (0) := Avec_Exposant (1 + Tirer (600));
                  S (1) := Avec_Exposant (1023 - 600 + Tirer (100));
                  if Op = OP_FDIV then
                     S (1) := Avec_Exposant (1023 + 400 + Tirer (220));
                  end if;
               end if;
            when OP_CVTIF =>                                       -- entiers
               case K is
                  when 0 | 1 | 2 =>                                -- mi-chemin au-dela de 2^53
                     E := 54 + Tirer (9);                          -- 54 .. 62 bits
                     M := Shift_Left (Shift_Right (Hasard, 11) or Shift_Left (1, 52), E - 53)
                          or Shift_Left (1, E - 54);
                     if Tirer (2) = 0 then M := M + Shift_Left (1, E - 53); end if;
                     S (0) := M;
                     if Tirer (2) = 0 then S (0) := 0 - S (0); end if;
                  when 3 => S (0) := Bit_63;                       -- -2^63
                  when 4 | 5 => S (0) := Shift_Right (Hasard, Tirer (64)) xor (0 - Unsigned_64 (Tirer (2)));
                  when others => S (0) := Hasard;
               end case;
            when OP_CVTFI | OP_CVTFIR =>
               case K is
                  when 0 | 1 | 2 =>                                -- k + 1/2, k entier
                     M := Unsigned_64 (Tirer (1_000_000));
                     S (0) := Depuis_Reel (Long_Float (Signe (M)) + 0.5);
                     S (0) := S (0) xor Signe_Hasard;
                  when 3 => S (0) := Speciaux (12 + Tirer (4));    -- bornes +-2^63
                  when 4 | 5 => S (0) := Avec_Exposant (1023 + Tirer (64));   -- 1 .. 2^64
                  when others => null;
               end case;
            when others =>                                         -- comparaisons, FNEG, FABS
               if K < 2 then
                  S (1) := S (0);                                  -- egaux
               elsif K = 2 then
                  S (1) := S (0) xor Signe_Bit;                    -- +0 / -0, x / -x
               end if;
         end case;
         case Op is
            when OP_CVTIF | OP_CVTFI | OP_CVTFIR | OP_FNEG | OP_FABS => Ecrire (Op, 1, S);
            when others => Ecrire (Op, 2, S);
         end case;
      end loop;
   end Generer;

begin
   if Args.Nombre /= 3 then
      raise Usage;
   end if;
   Par_Operation := Positive'Value (Args.Argument (1));
   Etat := Etat xor Unsigned_64 (Positive'Value (Args.Argument (2)));
   Text_IO.Create (Sortie, Text_IO.Out_File, Args.Argument (3));
   Text_IO.Put_Line (Sortie, "# FLOAT_UNIT : " & Args.Argument (1) & " instructions par operation, graine "
                     & Args.Argument (2) & " (Long_Float de l'hote, NaN canonique V8)");
   for Op in OP_FADD .. OP_FDIV loop
      Generer (Op);
   end loop;
   for Op in OP_CVTIF .. OP_FABS loop
      Generer (Op);
   end loop;
   Text_IO.Close (Sortie);
   Text_IO.Put_Line (Dec (Nb_Lignes) & " instructions, dont " & Dec (Nb_Fautes) & " en faute");
exception
   when Usage =>
      Text_IO.Put_Line ("usage : gen_vecteurs_float <par operation> <graine> <sortie>");
      Args.Code_De_Sortie (2);
end Gen_Vecteurs_Float;
