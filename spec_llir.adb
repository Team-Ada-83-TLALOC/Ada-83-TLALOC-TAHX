with Text_IO;
package body Spec_LLIR is

   Texte_Message : String (1 .. 200);
   Lg_Message    : Natural := 0;

   TAB : constant Character := Character'Val (9);
   CR  : constant Character := Character'Val (13);

   procedure Echouer (Texte : String) is
      N : Natural := Texte'Length;
   begin
      if N > Texte_Message'Length then
         N := Texte_Message'Length;
      end if;
      Texte_Message (1 .. N) := Texte (Texte'First .. Texte'First + N - 1);
      Lg_Message := N;
      raise Erreur;
   end Echouer;

   function Message return String is
   begin
      return Texte_Message (1 .. Lg_Message);
   end Message;

   function Nom (E : Entree) return String is
   begin
      return E.Nom (1 .. E.Lg_Nom);
   end Nom;

   function Decimal (N : Integer; Largeur : Natural) return String is
      Brut : constant String := Integer'Image (N);
      Debut : Positive := Brut'First;
   begin
      if Brut (Debut) = ' ' then
         Debut := Debut + 1;
      end if;
      declare
         S : constant String := Brut (Debut .. Brut'Last);
      begin
         if S'Length >= Largeur then
            return S;
         end if;
         return (1 .. Largeur - S'Length => ' ') & S;
      end;
   end Decimal;

   function Hexa_2 (N : Natural) return String is
      Chiffres : constant String (1 .. 16) := "0123456789ABCDEF";
   begin
      return Chiffres (N / 16 + 1) & Chiffres (N mod 16 + 1);
   end Hexa_2;

   function Nombre_Opcodes (Table : Table_Opcodes) return Natural is
      Vu : array (0 .. 1000) of Boolean := (others => False);
      N  : Natural := 0;
   begin
      for C in Table'Range loop
         if Table (C).Defini and then not Vu (Table (C).Numero) then
            Vu (Table (C).Numero) := True;
            N := N + 1;
         end if;
      end loop;
      return N;
   end Nombre_Opcodes;

   function Est_Blanc (C : Character) return Boolean is
   begin
      return C = ' ' or C = TAB;
   end Est_Blanc;

   function Lire_Complement (Mot : String) return Complement is
   begin
      for C in Complement'First .. Complement'Last loop
         if C /= Aucun and then Complement'Image (C) = Mot then
            return C;
         end if;
      end loop;
      Echouer ("complement inconnu : [" & Mot & "]");
      return Aucun;
   end Lire_Complement;

   --  Analyse d'une ligne ; Trouve = False si ce n'est pas une ligne de la table.
   procedure Analyser (L : String; Table : in out Table_Opcodes) is
      P      : Natural := L'First;
      Numero : Natural := 0;
      Famille : Character;
      Bits   : String (1 .. 16);
      Nb_Bits : Natural := 0;
      Fin_Reste : Natural;
      E      : Entree;
      Base   : Natural := 0;
      Nb_I   : Natural := 0;
      Derniere : Natural;
   begin
      --  numero
      if P > L'Last or else L (P) not in '0' .. '9' then
         return;
      end if;
      while P <= L'Last and then L (P) in '0' .. '9' loop
         Numero := Numero * 10 + Character'Pos (L (P)) - Character'Pos ('0');
         P := P + 1;
      end loop;
      --  TAB famille TAB
      if P + 2 > L'Last or else L (P) /= TAB or else L (P + 2) /= TAB
        or else L (P + 1) not in 'A' .. 'D' then
         return;
      end if;
      Famille := L (P + 1);
      P := P + 3;
      --  binaire
      if P > L'Last or else L (P) /= 'b' then
         return;
      end if;
      P := P + 1;
      while P <= L'Last and then (L (P) = '0' or L (P) = '1' or L (P) = '_' or L (P) = 'i') loop
         if L (P) /= '_' then
            if Nb_Bits = Bits'Last then
               return;
            end if;
            Nb_Bits := Nb_Bits + 1;
            Bits (Nb_Bits) := L (P);
         end if;
         P := P + 1;
      end loop;
      --  TAB x TAB
      if Nb_Bits = 0 or else P + 2 > L'Last or else L (P) /= TAB or else L (P + 1) /= 'x'
        or else L (P + 2) /= TAB then
         return;
      end if;
      P := P + 3;
      if Nb_Bits /= 8 then
         Echouer ("opcode" & Integer'Image (Numero) & " : " & Integer'Image (Nb_Bits) & " bits");
      end if;

      --  reste de la ligne jusqu'au ';'
      Fin_Reste := L'Last;
      for K in P .. L'Last loop
         if L (K) = ';' then
            Fin_Reste := K - 1;
            exit;
         end if;
      end loop;

      E.Defini := True;
      E.Numero := Numero;
      E.Famille := Famille;
      E.Lg_Nom := 0;
      E.Compl := Aucun;
      E.Imm4 := False;
      E.Nom := (others => ' ');

      --  mots : le premier est le nom, un mot entre crochets est le complement
      declare
         K : Natural := P;
         Debut : Natural;
      begin
         loop
            while K <= Fin_Reste and then Est_Blanc (L (K)) loop
               K := K + 1;
            end loop;
            exit when K > Fin_Reste;
            Debut := K;
            while K <= Fin_Reste and then not Est_Blanc (L (K)) loop
               K := K + 1;
            end loop;
            declare
               Mot : constant String := L (Debut .. K - 1);
            begin
               if E.Lg_Nom = 0 then
                  if Mot'Length > Longueur_Nom_Max then
                     Echouer ("nom trop long : " & Mot);
                  end if;
                  E.Nom (1 .. Mot'Length) := Mot;
                  E.Lg_Nom := Mot'Length;
               elsif Mot (Mot'First) = '[' then
                  declare
                     D : Natural := Mot'First;
                     F : Natural := Mot'Last;
                  begin
                     while D <= F and then (Mot (D) = '[' or Mot (D) = ']') loop
                        D := D + 1;
                     end loop;
                     while F >= D and then (Mot (F) = '[' or Mot (F) = ']') loop
                        F := F - 1;
                     end loop;
                     E.Compl := Lire_Complement (Mot (D .. F));
                  end;
               end if;
            end;
         end loop;
      end;
      if E.Lg_Nom = 0 then
         Echouer ("opcode" & Integer'Image (Numero) & " sans nom");
      end if;

      --  valeur(s) du premier octet ; les bits i prennent toutes les valeurs
      for K in 1 .. 8 loop
         Base := Base * 2;
         if Bits (K) = '1' then
            Base := Base + 1;
         elsif Bits (K) = 'i' then
            Nb_I := Nb_I + 1;
         end if;
      end loop;
      E.Imm4 := Nb_I > 0;
      Derniere := 2 ** Nb_I - 1;
      for V in 0 .. Derniere loop
         declare
            Code : Natural := 0;
            Reste : Natural := V;
            Poids : Natural := 2 ** Nb_I;
         begin
            for K in 1 .. 8 loop
               Code := Code * 2;
               if Bits (K) = '1' then
                  Code := Code + 1;
               elsif Bits (K) = 'i' then
                  Poids := Poids / 2;
                  Code := Code + Reste / Poids;
                  Reste := Reste mod Poids;
               end if;
            end loop;
            if Table (Code).Defini then
               Echouer ("premier octet " & Hexa_2 (Code) & " defini deux fois");
            end if;
            Table (Code) := E;
         end;
      end loop;
   end Analyser;

   procedure Lire (Chemin : String; Table : out Table_Opcodes) is
      F : Text_IO.File_Type;
      Ligne : String (1 .. 4096);
      Last : Natural;
      T : Table_Opcodes;
   begin
      for C in T'Range loop
         T (C).Defini := False;
         T (C).Numero := 0;
         T (C).Famille := ' ';
         T (C).Nom := (others => ' ');
         T (C).Lg_Nom := 0;
         T (C).Compl := Aucun;
         T (C).Imm4 := False;
      end loop;
      begin
         Text_IO.Open (F, Text_IO.In_File, Chemin);
      exception
         when others =>
            Echouer ("impossible d'ouvrir " & Chemin);
      end;
      while not Text_IO.End_Of_File (F) loop
         Text_IO.Get_Line (F, Ligne, Last);
         if Last = Ligne'Last then
            Echouer ("ligne trop longue dans " & Chemin);
         end if;
         if Last >= 1 and then Ligne (Last) = CR then
            Last := Last - 1;
         end if;
         Analyser (Ligne (1 .. Last), T);
      end loop;
      Text_IO.Close (F);
      Table := T;
   end Lire;

end Spec_LLIR;
