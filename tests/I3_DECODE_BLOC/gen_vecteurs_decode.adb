--  SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
--  SPDX-License-Identifier: GPL-3.0-or-later
--
--  Generateur des vecteurs de DECODE_BLOC (tests/I3_DECODE_BLOC).
--
--  Les champs de chaque instruction viennent de Decodeur_HX, le decodeur de tx_run (depot
--  eXecutor), qui execute les bancs HX a l'identique des bancs TX : c'est la reference des
--  positions de bits, des extensions de signe et des cibles. Ce programme n'ajoute que ce
--  qui est propre a DECODE_BLOC (en-tete de I3_DECODE_BLOC.vhd) : forme canonique (opcode
--  HX, deplacements relatifs, LI D64 en deux formes), formes de faute, fin du bloc.
--
--    gen_vecteurs_decode image  <image.hx> <pas> <copie.hx> <sortie>
--        fenetres pleines a un debut d'instruction sur <pas> (table de l'image) ;
--        <copie.hx> : copie de travail sans table, pour decoder aussi les donnees en ligne
--    gen_vecteurs_decode hasard <octets> <fenetres> <graine> <copie.hx> <sortie>
--        flot d'instructions tirees au hasard (opcodes reserves et champs illegaux
--        compris) ; fenetres a des positions, longueurs et fautes tirees
--
--  Sortie, une fenetre par groupe de lignes (hexadecimal en majuscules) :
--    W <pc:16> <nombre d'octets valides> <32 octets:64> <32 drapeaux de faute 0/1>
--    R <formes> <octets consommes> <need_more 0/1> <stop 0/1>
--    F <op:2> <lvl:1> <ofs:2> <val:8> <len:1> <position de l'instruction>   (une par forme)
with Interfaces; use Interfaces;
with Text_IO;
with Sequential_IO;
with Memoire;
with Decodeur_HX;
with HX_Codes; use HX_Codes;
with TX_Codes;
with Args;
procedure Gen_Vecteurs_Decode is

   package Octet_IO is new Sequential_IO (Unsigned_8);

   Fenetre : constant := 32;
   Largeur : constant := 8;

   --  Opcodes HX cites par l'en-tete de DECODE_BLOC (LLIR_hardware_support V8)
   OP_LI_D32   : constant := 16#C2#;
   OP_UBFXI    : constant := 16#C4#;
   OP_BFII     : constant := 16#C6#;
   UOP_LIHI    : constant := 16#C7#;
   UOP_ILLEGAL : constant := 16#EC#;
   UOP_FETCH_FAULT : constant := 16#ED#;
   OP_TRAP     : constant := 16#F0#;
   OP_UNLINK   : constant := 16#F8#;
   OP_UNLINKR  : constant := 16#F9#;
   OP_RTX      : constant := 16#FF#;

   --  RTX n'a pas d'equivalent TX : outils/gen_hx_codes.py le saute, et la table HX_Codes
   --  de tx_run le donne reserve. La specification V8 le definit (1 octet) : ce programme
   --  suit la specification et le decode lui-meme.

   Usage : exception;

   --------------------------------------------------------------------------------
   --  Hasard reproductible : xorshift64*
   --------------------------------------------------------------------------------

   Etat : Unsigned_64 := 16#9E37_79B9_7F4A_7C15#;

   Sortie : Text_IO.File_Type;

   Chiffres : constant String := "0123456789ABCDEF";

   type Octets_Fenetre is array (Natural range 0 .. Fenetre - 1) of Unsigned_8;
   type Fautes_Fenetre is array (Natural range 0 .. Fenetre - 1) of Boolean;
   Sans_Faute : constant Fautes_Fenetre := (others => False);

   type Forme is record
      Op, Lvl, Ofs, Lg, Position : Natural;
      Val : Unsigned_64;                         -- 32 bits de poids faible
   end record;
   type Formes is array (Natural range 0 .. Largeur - 1) of Forme;

   Nb_Fenetres, Nb_Formes, Nb_Stop, Nb_Attente : Natural := 0;

   type Octets is array (Natural range <>) of Unsigned_8;
   type Acces_Octets is access Octets;
   type Adresses is array (Natural range <>) of Unsigned_64;
   type Acces_Adresses is access Adresses;

   function Hasard return Unsigned_64 is
   begin
      Etat := Etat xor Shift_Right (Etat, 12);
      Etat := Etat xor Shift_Left (Etat, 25);
      Etat := Etat xor Shift_Right (Etat, 27);
      return Etat * 16#2545_F491_4F6C_DD1D#;
   end Hasard;

   function Tirer (N : Positive) return Natural is      -- 0 .. N - 1
   begin
      return Natural (Shift_Right (Hasard, 16) mod Unsigned_64 (N));
   end Tirer;

   --------------------------------------------------------------------------------
   --  Ecriture
   --------------------------------------------------------------------------------

   function Hex (V : Unsigned_64; N : Positive) return String is
      S : String (1 .. N);
      X : Unsigned_64 := V;
   begin
      for I in reverse S'Range loop
         S (I) := Chiffres (Natural (X mod 16) + 1);
         X := X / 16;
      end loop;
      return S;
   end Hex;

   function Dec (N : Natural) return String is
      S : constant String := Natural'Image (N);
   begin
      return S (S'First + 1 .. S'Last);
   end Dec;

   --------------------------------------------------------------------------------
   --  Une fenetre
   --------------------------------------------------------------------------------

   function Bas_32 (V : Unsigned_64) return Unsigned_64 is
   begin
      return V and 16#FFFF_FFFF#;
   end Bas_32;

   --  faute 137 connue au decodage, l'instruction etant entiere (octets O)
   function Illegale (O : Octets_Fenetre; P : Natural) return Boolean is
      Op : constant Natural := Natural (O (P));
      Famille : constant Natural := Op / 64;
      Mode : constant Natural := (Op / 16) mod 4;
      Fmt  : constant Natural := (Op / 4) mod 4;
      Sz   : constant Natural := Op mod 4;
      Lsb, W : Natural;
   begin
      if (Famille = 1 or Famille = 2) and Fmt /= 0
        and ((Mode = 0 and Sz <= 1) or Fmt = 3)        -- LVL_FRAME : LINK, EXC_MACH, CHK
        and O (P + 1) / 16 = 15 then
         return True;
      end if;
      if Op = OP_UNLINK or Op = OP_UNLINKR then
         return O (P + 1) < 1 or O (P + 1) > 14;
      end if;
      if Op >= OP_UBFXI and Op <= OP_BFII then
         Lsb := Natural (O (P + 1));
         W := Natural (O (P + 2));
         return W = 0 or W > 64 or Lsb > 64 - W;
      end if;
      if Op = OP_TRAP then
         return O (P + 1) = 15 or O (P + 1) > 18;
      end if;
      return False;
   end Illegale;

   procedure Traiter (PC : Unsigned_64; Nb : Natural; Fautes : Fautes_Fenetre) is
      O : Octets_Fenetre := (others => 0);
      F : Formes;
      N, P, L : Natural := 0;
      Consomme : Natural := 0;
      Attente, Stop : Boolean := False;
      Ligne : String (1 .. 2 * Fenetre);
      Drapeaux : String (1 .. Fenetre);
      T : Description;
      Op_TX, Lvl : Integer;
      Ofs, Val, Longueur : Unsigned_64;
      Poids : Integer;

      procedure Produire (Op, Lv, Of_S : Natural; V : Unsigned_64; Lg : Natural) is
      begin
         F (N) := (Op => Op, Lvl => Lv, Ofs => Of_S, Lg => Lg, Position => P, Val => Bas_32 (V));
         N := N + 1;
      end Produire;

   begin
      for I in O'Range loop
         if PC + Unsigned_64 (I) < Memoire.Fin_Code then
            O (I) := Unsigned_8 (Memoire.Lire_8 (PC + Unsigned_64 (I)));
         end if;
         Ligne (2 * I + 1 .. 2 * I + 2) := Hex (Unsigned_64 (O (I)), 2);
         if Fautes (I) then
            Drapeaux (I + 1) := '1';
         else
            Drapeaux (I + 1) := '0';
         end if;
      end loop;

      loop
         exit when N = Largeur;
         if P >= Nb then
            Attente := True;
            exit;
         end if;
         if Fautes (P) then                                     -- opcode en faute de lecture
            Produire (UOP_FETCH_FAULT, 0, 0, 0, 0);
            Stop := True;
            exit;
         end if;
         T := HX_Codes.Table (Natural (O (P)));
         if Natural (O (P)) = OP_RTX then
            T := (G => G_Aucun, Code => 0);
         end if;
         if T.G = G_Illegal then                                -- opcode reserve
            Produire (UOP_ILLEGAL, 0, 0, Unsigned_64 (O (P)), 0);
            Stop := True;
            exit;
         end if;
         L := 1 + Longueur_Complement (T.G);
         if P + L > Nb then                                     -- instruction incomplete
            Attente := True;
            exit;
         end if;
         for K in P + 1 .. P + L - 1 loop
            if Fautes (K) then
               Stop := True;
            end if;
         end loop;
         if Stop then                                           -- complement en faute
            Produire (UOP_FETCH_FAULT, 0, 0, 0, 0);
            exit;
         end if;
         if Illegale (O, P) then
            Produire (UOP_ILLEGAL, 0, 0, Unsigned_64 (O (P)), 0);
            Stop := True;
            exit;
         end if;
         exit when T.G = G_D64 and N > Largeur - 2;             -- LI D64 : deux cases

         if Natural (O (P)) = OP_RTX then
            Produire (OP_RTX, 0, 0, 0, 1);
            Consomme := Consomme + 1;
            P := P + 1;
            goto Suivante;
         end if;
         Decodeur_HX.Lire (PC + Unsigned_64 (P), Op_TX, Lvl, Ofs, Val, Longueur, Poids);
         if Natural (Longueur) /= L then
            raise Program_Error;
         end if;
         declare
            Op : constant Natural := Natural (O (P));
            Lv : Natural := 0;
         begin
            if Lvl = -1 then
               Lv := 15;
            elsif Lvl >= 0 then
               Lv := Lvl;
            end if;
            case T.G is
               when G_Aucun =>
                  if Op / 64 = 1 or Op / 64 = 2 then
                     Produire (Op, 15, 0, 0, L);                 -- FMT 00 : lvl = 1111
                  else
                     Produire (Op, 0, 0, 0, L);                  -- famille A, LEXCMP, RTD 0, RTX
                  end if;
               when G_Imm4 | G_D16 | G_D32 =>
                  Produire (Op, 0, 0, Val, L);
               when G_B16 | G_B24 =>
                  Produire (Op, Lv, 0, Val, L);
               when G_C24 | G_C32 =>
                  Produire (Op, Lv, Natural (Ofs), Val, L);
               when G_D8 =>
                  if Op_TX = TX_Codes.OP_UNLINK or Op_TX = TX_Codes.OP_UNLINKR then
                     Produire (Op, Lv, 0, 0, L);                 -- lvl = complement
                  else
                     Produire (Op, 0, 0, Val, L);                -- LI D8, TRAP
                  end if;
               when G_D64 =>
                  Produire (OP_LI_D32, 0, 0, Val, 0);
                  Produire (UOP_LIHI, 0, 0, Shift_Right (Val, 32), L);
               when G_D24 =>
                  if Op_TX = TX_Codes.OP_CALL then               -- absolu -> relatif
                     Produire (Op, 0, 0, Val - (PC + Unsigned_64 (P + L)), L);
                  else
                     Produire (Op, 0, 0, Val, L);                -- RTD n, EXC_RAISE
                  end if;
               when G_D8_8 =>
                  Produire (Op, 0, Natural (Ofs), Val, L);       -- val = lsb, ofs = w
               when G_BR8 | G_BR16 | G_BR24 | G_BR32 =>
                  Produire (Op, 0, 0, Val - (PC + Unsigned_64 (P + L)), L);
               when G_Illegal =>
                  raise Program_Error;
            end case;
         end;
         Consomme := Consomme + L;
         P := P + L;
      <<Suivante>> null;
      end loop;

      Text_IO.Put_Line (Sortie, "W " & Hex (PC, 16) & " " & Dec (Nb) & " " & Ligne & " " & Drapeaux);
      Text_IO.Put (Sortie, "R " & Dec (N) & " " & Dec (Consomme));
      if Attente then
         Text_IO.Put (Sortie, " 1");
      else
         Text_IO.Put (Sortie, " 0");
      end if;
      if Stop then
         Text_IO.Put_Line (Sortie, " 1");
      else
         Text_IO.Put_Line (Sortie, " 0");
      end if;
      for I in 0 .. N - 1 loop
         Text_IO.Put_Line (Sortie, "F " & Hex (Unsigned_64 (F (I).Op), 2) & " "
                           & Hex (Unsigned_64 (F (I).Lvl), 1) & " " & Hex (Unsigned_64 (F (I).Ofs), 2)
                           & " " & Hex (F (I).Val, 8) & " " & Hex (Unsigned_64 (F (I).Lg), 1)
                           & " " & Dec (F (I).Position));
      end loop;
      Nb_Fenetres := Nb_Fenetres + 1;
      Nb_Formes := Nb_Formes + N;
      if Stop then
         Nb_Stop := Nb_Stop + 1;
      end if;
      if Attente then
         Nb_Attente := Nb_Attente + 1;
      end if;
   end Traiter;

   --------------------------------------------------------------------------------
   --  Images
   --------------------------------------------------------------------------------


   --  ecrit une image HX : en-tete de 0x78 octets, puis Code ; sans table
   procedure Ecrire_Image (Nom : String; Code : Octets) is
      F : Octet_IO.File_Type;
      En_Tete : Octets (0 .. 16#77#) := (others => 0);
      Signature : constant String := "TLALOCHX";

      procedure Mot (Position : Natural; V : Unsigned_64) is
      begin
         for I in 0 .. 7 loop
            En_Tete (Position + I) := Unsigned_8 (Shift_Right (V, 8 * I) and 16#FF#);
         end loop;
      end Mot;

   begin
      for I in Signature'Range loop
         En_Tete (I - 1) := Unsigned_8 (Character'Pos (Signature (I)));
      end loop;
      Mot (8, 1);
      Mot (16, Memoire.Base_Image);
      Mot (24, Memoire.Entree);
      Mot (32, Unsigned_64 (Code'Length));
      Octet_IO.Create (F, Octet_IO.Out_File, Nom);
      for I in En_Tete'Range loop
         Octet_IO.Write (F, En_Tete (I));
      end loop;
      for I in Code'Range loop
         Octet_IO.Write (F, Code (I));
      end loop;
      Octet_IO.Close (F);
   end Ecrire_Image;

   procedure Mode_Image (Image, Copie : String; Pas : Positive) is
      Table : Unsigned_64;
      W, A, Taille : Unsigned_64;
      Nb_Debuts : Natural := 0;
      Code : Acces_Octets;
      Debuts : Acces_Adresses;
   begin
      Memoire.Charger_Image (Image, 0);
      Table := Memoire.Table_Instructions;
      if Table = 0 then
         Text_IO.Put_Line ("l'image n'a pas de table des instructions");
         raise Usage;
      end if;
      Taille := Memoire.Fin_Code - Memoire.Entree;
      Debuts := new Adresses (0 .. Memoire.Nombre_Instructions - 1);
      begin
         for K in 0 .. Memoire.Nombre_Instructions - 1 loop
            W := Memoire.Lire_32 (Table + Unsigned_64 (4 * K));
            if (W and 16#4000_0000#) = 0 then                  -- pas VIDE
               A := Memoire.Base_Image + (W and 16#3FFF_FFFF#);
               Debuts (Nb_Debuts) := A;
               Nb_Debuts := Nb_Debuts + 1;
            end if;
         end loop;

         --  copie sans table : Decodeur_HX decode alors toute position du code
         Code := new Octets (0 .. Natural (Taille) - 1);
         for I in Code'Range loop
            Code (I) := Unsigned_8 (Memoire.Lire_8 (Memoire.Entree + Unsigned_64 (I)));
         end loop;
         Ecrire_Image (Copie, Code.all);
         Memoire.Charger_Image (Copie, 0);
         Decodeur_HX.Preparer;

         Text_IO.Put_Line (Sortie, "# image " & Image & ", une fenetre pleine tous les "
                           & Dec (Pas) & " debuts d'instruction (" & Dec (Nb_Debuts) & " debuts)");
         declare
            K : Natural := 0;
            Reste : Unsigned_64;
            Nb : Natural;
         begin
            while K < Nb_Debuts loop
               Reste := Memoire.Fin_Code - Debuts (K);
               Nb := Fenetre;
               if Reste < Fenetre then
                  Nb := Natural (Reste);
               end if;
               Traiter (Debuts (K), Nb, Sans_Faute);
               K := K + Pas;
            end loop;
         end;
      end;
   end Mode_Image;

   procedure Mode_Hasard (Taille, Nb_Fen : Positive; Graine : Positive; Copie : String) is
      Code : Octets (0 .. Taille - 1) := (others => 0);
      Liste : array (0 .. Taille - 1) of Natural;
      Nb_Debuts : Natural := 0;
      P, L, Op : Natural := 0;
      Reserve : Boolean;
      Rien : Unsigned_64;
      T : Description;
      Fautes : Fautes_Fenetre;
      Depart, Nb, Reste, K : Natural;
   begin
      Etat := Etat xor Unsigned_64 (Graine);
      for I in 1 .. 16 loop                                     -- mise en train
         Rien := Hasard;
      end loop;

      --  flot d'instructions : 4 % d'opcodes reserves, complements tires avec un biais
      --  vers les bornes de ce que l'en-tete juge (UNLINK, TRAP, champs de bits)
      while P < Taille loop
         Reserve := Tirer (100) < 4;
         loop
            Op := Tirer (256);
            T := HX_Codes.Table (Op);
            exit when (T.G = G_Illegal) = Reserve;
         end loop;
         L := 1 + Longueur_Complement (T.G);
         Liste (Nb_Debuts) := P;
         Nb_Debuts := Nb_Debuts + 1;
         Code (P) := Unsigned_8 (Op);
         for J in 1 .. L - 1 loop
            if P + J < Taille then
               Code (P + J) := Unsigned_8 (Tirer (256));
            end if;
         end loop;
         if P + 2 < Taille and Tirer (100) < 80 then
            if Op = OP_UNLINK or Op = OP_UNLINKR then
               Code (P + 1) := Unsigned_8 (Tirer (16));
            elsif Op = OP_TRAP then
               Code (P + 1) := Unsigned_8 (Tirer (21));
            elsif Op >= OP_UBFXI and Op <= OP_BFII then
               Code (P + 1) := Unsigned_8 (Tirer (70));
               Code (P + 2) := Unsigned_8 (Tirer (70));
            end if;
         end if;
         P := P + L;
      end loop;

      Ecrire_Image (Copie, Code);
      Memoire.Charger_Image (Copie, 0);
      Decodeur_HX.Preparer;

      Text_IO.Put_Line (Sortie, "# hasard : " & Dec (Taille) & " octets, " & Dec (Nb_Fen)
                        & " fenetres, graine " & Dec (Graine));
      for F in 1 .. Nb_Fen loop
         if Tirer (100) < 70 then                               -- debut d'instruction
            Depart := Liste (Tirer (Nb_Debuts));
         else                                                   -- position quelconque
            Depart := Tirer (Taille);
         end if;
         Reste := Taille - Depart;
         if Reste > Fenetre then
            Reste := Fenetre;
         end if;
         if Tirer (100) < 60 then
            Nb := Reste;
         else
            Nb := Tirer (Reste + 1);
         end if;
         Fautes := Sans_Faute;
         K := Tirer (100);
         if K < 10 then                                         -- faute depuis une position
            for I in Natural range Tirer (Fenetre) .. Fenetre - 1 loop
               Fautes (I) := True;
            end loop;
         elsif K < 15 then                                      -- un octet en faute
            Fautes (Tirer (Fenetre)) := True;
         end if;
         Traiter (Memoire.Entree + Unsigned_64 (Depart), Nb, Fautes);
      end loop;
   end Mode_Hasard;

begin
   if Args.Nombre = 5 and then Args.Argument (1) = "image" then
      Text_IO.Create (Sortie, Text_IO.Out_File, Args.Argument (5));
      Mode_Image (Args.Argument (2), Args.Argument (4), Positive'Value (Args.Argument (3)));
   elsif Args.Nombre = 6 and then Args.Argument (1) = "hasard" then
      Text_IO.Create (Sortie, Text_IO.Out_File, Args.Argument (6));
      Mode_Hasard (Positive'Value (Args.Argument (2)), Positive'Value (Args.Argument (3)),
                   Positive'Value (Args.Argument (4)), Args.Argument (5));
   else
      raise Usage;
   end if;
   Text_IO.Close (Sortie);
   Text_IO.Put_Line (Dec (Nb_Fenetres) & " fenetres, " & Dec (Nb_Formes) & " formes, "
                     & Dec (Nb_Stop) & " arrets sur faute, " & Dec (Nb_Attente) & " attentes d'octets");
exception
   when Usage =>
      Text_IO.Put_Line ("usage : gen_vecteurs_decode image  <image.hx> <pas> <copie.hx> <sortie>");
      Text_IO.Put_Line ("        gen_vecteurs_decode hasard <octets> <fenetres> <graine> <copie.hx> <sortie>");
      Args.Code_De_Sortie (2);
   when Memoire.Faute =>
      Text_IO.Put_Line ("erreur : " & Memoire.Message);
      Args.Code_De_Sortie (1);
end Gen_Vecteurs_Decode;
