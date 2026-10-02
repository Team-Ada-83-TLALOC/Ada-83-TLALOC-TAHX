--  SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
--  SPDX-License-Identifier: GPL-3.0-or-later
--
--  Generateur des vecteurs de MULDIV_UNIT (tests/L2_MULDIV_UNIT).
--
--  Reprend de Machine (machine.adb de tx_run, depot eXecutor) Abs_Mot, Deborde_Mul, Mul_128
--  et Div_128, et applique les regles de LLIR_hardware_support V8, qui est normatif ; tx_run
--  s'en ecarte sur trois points, releves dans la liste de verification de la V8 :
--    - REMI et MODI de -2^63 par -1 rendent 0 (tx_run : faute) ;
--    - CVTXI arrondit le quotient exact quel que soit le signe de denom (tx_run compare
--      |reste| a ceil(denom / 2) en non signe : pas d'arrondi pour denom < 0) ;
--    - CVTXI controle le debordement apres l'arrondi (tx_run : 2^63 - 1 arrondi enveloppe).
--
--    gen_vecteurs_muldiv <par operation> <graine> <sortie>
--
--  Une ligne par instruction (hexadecimal en majuscules) :
--    I <op:2> <sources> <s0:16> <s1:16> <s2:16> <faute:2, 00 sans faute> <resultat:16>
with Interfaces; use Interfaces;
with Text_IO;
with Mots; use Mots;
with Args;
procedure Gen_Vecteurs_Muldiv is

   Masque_32 : constant Unsigned_64 := 16#FFFF_FFFF#;
   Sans_Faute : constant := 0;
   Faute_Division : constant := 128;
   Faute_Debordement : constant := 129;
   OP_MUL   : constant := 16#14#;
   OP_DIV   : constant := 16#15#;
   OP_REMI  : constant := 16#16#;
   OP_MODI  : constant := 16#17#;
   OP_CVTIX : constant := 16#1C#;
   OP_CVTXI : constant := 16#1D#;

   Usage : exception;
   Sortie : Text_IO.File_Type;
   Etat : Unsigned_64 := 16#9E37_79B9_7F4A_7C15#;
   Chiffres : constant String := "0123456789ABCDEF";
   Nb_Lignes, Nb_Fautes : Natural := 0;
   Par_Operation : Positive := 1;

   type Sources is array (0 .. 2) of Unsigned_64;

   Bords : constant array (0 .. 11) of Unsigned_64 :=
     (0, 1, 2, 16#FFFF_FFFF_FFFF_FFFF#, 16#FFFF_FFFF_FFFF_FFFE#,
      16#7FFF_FFFF_FFFF_FFFF#, Bit_63, Bit_63 + 1,
      16#8000_0000#, 16#7FFF_FFFF#, 16#FFFF_FFFF#, 16#1_0000_0000#);

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

   function Mot return Unsigned_64 is
   begin
      case Tirer (5) is
         when 0 => return Bords (Tirer (Bords'Length));
         when 1 => return Hasard and 16#FFFF#;
         when 2 => return 0 - (Hasard and 16#FFFF#);
         when 3 => return Shift_Right (Hasard, Tirer (64));            -- grandeur quelconque
         when others => return Hasard;
      end case;
   end Mot;

   function Petit_Signe return Unsigned_64 is                         -- -1000 .. 1000, sauf 0
      V : Unsigned_64 := 1 + Unsigned_64 (Tirer (1000));
   begin
      if Tirer (2) = 0 then
         return 0 - V;
      end if;
      return V;
   end Petit_Signe;

   --------------------------------------------------------------------------------
   --  Repris de Machine (machine.adb)
   --------------------------------------------------------------------------------

   function Abs_Mot (S : Signe) return Unsigned_64 is
   begin
      if S < 0 then
         return 0 - Vers_Mot (S);
      end if;
      return Vers_Mot (S);
   end Abs_Mot;

   function Deborde_Mul (A, B : Unsigned_64) return Boolean is
      MA, MB, Limite : Unsigned_64;
   begin
      if ((A + 16#8000_0000#) or (B + 16#8000_0000#)) < 16#1_0000_0000# then
         return False;
      end if;
      if A = 0 or B = 0 then
         return False;
      end if;
      MA := Abs_Mot (Vers_Signe (A));
      MB := Abs_Mot (Vers_Signe (B));
      if ((A xor B) and Bit_63) /= 0 then
         Limite := Bit_63;
      else
         Limite := Bit_63 - 1;
      end if;
      return MA > Limite / MB;
   end Deborde_Mul;

   procedure Mul_128 (X, Y : Unsigned_64; Haut, Bas : out Unsigned_64) is
      X0 : constant Unsigned_64 := X and Masque_32;
      X1 : constant Unsigned_64 := Shift_Right (X, 32);
      Y0 : constant Unsigned_64 := Y and Masque_32;
      Y1 : constant Unsigned_64 := Shift_Right (Y, 32);
      P00 : constant Unsigned_64 := X0 * Y0;
      P01 : constant Unsigned_64 := X0 * Y1;
      P10 : constant Unsigned_64 := X1 * Y0;
      P11 : constant Unsigned_64 := X1 * Y1;
      Milieu : constant Unsigned_64 :=
        Shift_Right (P00, 32) + (P01 and Masque_32) + (P10 and Masque_32);
   begin
      Bas  := (P00 and Masque_32) or Shift_Left (Milieu, 32);
      Haut := P11 + Shift_Right (P01, 32) + Shift_Right (P10, 32) + Shift_Right (Milieu, 32);
   end Mul_128;

   procedure Div_128 (Haut, Bas, D : Unsigned_64;
                      Q_Haut, Q_Bas, Reste : out Unsigned_64) is
      R, QH, QL, Bit : Unsigned_64 := 0;
      Retenue : Boolean;
   begin
      for I in reverse 0 .. 127 loop
         if I >= 64 then
            Bit := Shift_Right (Haut, I - 64) and 1;
         else
            Bit := Shift_Right (Bas, I) and 1;
         end if;
         Retenue := (R and Bit_63) /= 0;
         R := Shift_Left (R, 1) or Bit;
         if Retenue or else R >= D then
            R := R - D;
            if I >= 64 then
               QH := QH or Shift_Left (1, I - 64);
            else
               QL := QL or Shift_Left (1, I);
            end if;
         end if;
      end loop;
      Q_Haut := QH;
      Q_Bas := QL;
      Reste := R;
   end Div_128;

   --------------------------------------------------------------------------------
   --  Regles V8
   --------------------------------------------------------------------------------

   --  (A * B) / C, quotient exact tronque ou arrondi (mi-chemin a l'ecart de zero)
   procedure Mul_Div_V8 (A, B, C : Signe; Arrondir : Boolean;
                         Faute_Sortie : out Natural; Q_Sortie : out Unsigned_64) is
      Negatif : constant Boolean := ((A < 0) /= (B < 0)) /= (C < 0);
      Haut, Bas, QH, QL, Reste, D : Unsigned_64;
   begin
      Faute_Sortie := Sans_Faute;
      Q_Sortie := 0;
      if C = 0 then
         Faute_Sortie := Faute_Division;
         return;
      end if;
      D := Abs_Mot (C);
      Mul_128 (Abs_Mot (A), Abs_Mot (B), Haut, Bas);
      Div_128 (Haut, Bas, D, QH, QL, Reste);
      if Arrondir and then Reste >= D - Reste then                -- 2 * reste >= |C|
         QL := QL + 1;
         if QL = 0 then
            QH := QH + 1;
         end if;
      end if;
      if QH /= 0 or else QL > Bit_63 or else (QL = Bit_63 and not Negatif) then
         Faute_Sortie := Faute_Debordement;
         return;
      end if;
      if Negatif then
         Q_Sortie := 0 - QL;
      else
         Q_Sortie := QL;
      end if;
   end Mul_Div_V8;

   procedure Executer (Op : Natural; S : Sources; Faute_Sortie : out Natural; R_Sortie : out Unsigned_64) is
      SA : constant Signe := Vers_Signe (S (0));
      SB : constant Signe := Vers_Signe (S (1));
      Faute : Natural := Sans_Faute;
      R : Unsigned_64 := 0;
   begin
      case Op is
         when OP_MUL =>
            if Deborde_Mul (S (0), S (1)) then
               Faute := Faute_Debordement;
            else
               R := S (0) * S (1);
            end if;
         when OP_DIV | OP_REMI | OP_MODI =>
            if SB = 0 then
               Faute := Faute_Division;
            elsif SA = Signe'First and SB = -1 then
               if Op = OP_DIV then
                  Faute := Faute_Debordement;
               else
                  R := 0;                                        -- resultat exact (V7)
               end if;
            elsif Op = OP_DIV then
               R := Vers_Mot (SA / SB);
            elsif Op = OP_REMI then
               R := Vers_Mot (SA rem SB);
            else
               R := Vers_Mot (SA mod SB);
            end if;
         when OP_CVTIX =>                                          -- ( i denom numer )
            Mul_Div_V8 (SA, SB, Vers_Signe (S (2)), False, Faute, R);
         when OP_CVTXI =>                                          -- ( x numer denom )
            Mul_Div_V8 (SA, SB, Vers_Signe (S (2)), True, Faute, R);
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

   procedure Ecrire (Op, Nb : Natural; S : Sources) is
      Faute : Natural;
      R : Unsigned_64;
   begin
      Executer (Op, S, Faute, R);
      Text_IO.Put_Line (Sortie, "I " & Hex (Unsigned_64 (Op), 2) & " " & Dec (Nb)
                        & " " & Hex (S (0), 16) & " " & Hex (S (1), 16) & " " & Hex (S (2), 16)
                        & " " & Hex (Unsigned_64 (Faute), 2) & " " & Hex (R, 16));
      Nb_Lignes := Nb_Lignes + 1;
      if Faute /= Sans_Faute then
         Nb_Fautes := Nb_Fautes + 1;
      end if;
   end Ecrire;

   procedure Generer (Op : Natural; Nombre : Positive) is
      S : Sources;
      K : Natural;
      Q, M : Unsigned_64;
   begin
      for N in 1 .. Nombre loop
         S := (Mot, Mot, Mot);
         K := Tirer (10);
         case Op is
            when OP_MUL =>
               if K < 3 then                                        -- pres de 2^63
                  K := Tirer (64);
                  S (0) := Shift_Left (1, K);
                  S (1) := Shift_Left (1, 63 - K) + Unsigned_64 (Tirer (3)) - 1;
                  if Tirer (2) = 0 then S (0) := 0 - S (0); end if;
                  if Tirer (2) = 0 then S (1) := 0 - S (1); end if;
               elsif K < 6 then
                  S (0) := Petit_Signe; S (1) := Petit_Signe;
               end if;
            when OP_DIV | OP_REMI | OP_MODI =>
               if K = 0 then
                  S (1) := 0;                                       -- faute 128
               elsif K = 1 then
                  S (0) := Bit_63; S (1) := 16#FFFF_FFFF_FFFF_FFFF#;  -- -2^63 / -1
               elsif K < 5 then
                  S (1) := Petit_Signe;
               end if;
            when OP_CVTIX =>                                        -- ( i denom numer )
               if K = 0 then
                  S (2) := 0;                                       -- faute 128
               elsif K < 6 then                                     -- SMALL realiste
                  S (1) := 1 + Unsigned_64 (Tirer (1_000_000));
                  S (2) := 1 + Unsigned_64 (Tirer (1_000_000));
               elsif K < 8 then
                  S (1) := Petit_Signe; S (2) := Petit_Signe;
               end if;
            when OP_CVTXI =>                                        -- ( x numer denom )
               if K = 0 then
                  S (2) := 0;                                       -- faute 128
               elsif K < 4 then                                     -- mi-chemin exact
                  M := 1 + Unsigned_64 (Tirer (100_000));           -- denom = +/- 2m
                  Q := Unsigned_64 (Tirer (1_000_000));
                  S (1) := 1;
                  S (2) := 2 * M;
                  S (0) := Q * S (2) + M;                           -- x = q * denom + m
                  if Tirer (2) = 0 then S (0) := 0 - S (0); end if;
                  if Tirer (2) = 0 then S (2) := 0 - S (2); end if;
               elsif K = 4 then                                     -- frontiere de l'arrondi
                  --  (2^32 - 1)(2^32 + 1) = 2^64 - 1 : quotient exact +/- (2^63 - 0,5),
                  --  arrondi a 2^63 (faute 129) ou a -2^63 (representable)
                  S (0) := 16#FFFF_FFFF#; S (1) := 16#1_0000_0001#; S (2) := 2;
                  if Tirer (2) = 0 then S (0) := 0 - S (0); end if;
                  if Tirer (2) = 0 then S (2) := 0 - S (2); end if;
               elsif K < 8 then
                  S (1) := 1 + Unsigned_64 (Tirer (1_000_000));
                  S (2) := Petit_Signe;
               end if;
            when others =>
               null;
         end case;
         if Op = OP_CVTIX or Op = OP_CVTXI then
            Ecrire (Op, 3, S);
         else
            Ecrire (Op, 2, S);
         end if;
      end loop;
   end Generer;

begin
   if Args.Nombre /= 3 then
      raise Usage;
   end if;
   Par_Operation := Positive'Value (Args.Argument (1));
   Etat := Etat xor Unsigned_64 (Positive'Value (Args.Argument (2)));
   Text_IO.Create (Sortie, Text_IO.Out_File, Args.Argument (3));
   Text_IO.Put_Line (Sortie, "# MULDIV_UNIT : " & Args.Argument (1) & " instructions par operation, graine "
                     & Args.Argument (2) & " (regles V8)");
   Generer (OP_MUL, Par_Operation);
   Generer (OP_DIV, Par_Operation);
   Generer (OP_REMI, Par_Operation);
   Generer (OP_MODI, Par_Operation);
   Generer (OP_CVTIX, Par_Operation);
   Generer (OP_CVTXI, Par_Operation);
   Text_IO.Close (Sortie);
   Text_IO.Put_Line (Dec (Nb_Lignes) & " instructions, dont " & Dec (Nb_Fautes) & " en faute");
exception
   when Usage =>
      Text_IO.Put_Line ("usage : gen_vecteurs_muldiv <par operation> <graine> <sortie>");
      Args.Code_De_Sortie (2);
end Gen_Vecteurs_Muldiv;
