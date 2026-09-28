--  Genere tx_run/hx_codes.ads (table de decodage des opcodes HX) a partir de la table des
--  opcodes de LLIR_hardware_support et des codes TX de tx_run/tx_codes.ads.
--
--     gen_hx_codes SPEC tx_codes.ads hx_codes.ads
--
--  Portage en Ada 83 de gen_hx_codes.py : la table produite est identique ; seule la ligne
--  d'en-tete qui nomme le generateur change.
with Text_IO;
with Args;
with Spec_LLIR; use Spec_LLIR;
procedure Gen_HX_Codes is

   --  codes TX : lignes « OP_nom : constant := n; » de tx_codes.ads
   Max_Codes : constant := 400;
   type Code_TX is record
      Nom  : String (1 .. 32);
      Lg   : Natural;
      Code : Natural;
   end record;
   Codes : array (1 .. Max_Codes) of Code_TX;
   Nb_Codes : Natural := 0;

   Absent : exception;
   Nom_Absent : String (1 .. 32);
   Lg_Absent : Natural := 0;

   Genre : constant array (Complement) of String (1 .. 9) :=
     (Aucun => "G_Aucun  ", B16 => "G_B16    ", B24 => "G_B24    ", C24 => "G_C24    ",
      C32 => "G_C32    ", D8 => "G_D8     ", D16 => "G_D16    ", D24 => "G_D24    ",
      D32 => "G_D32    ", D64 => "G_D64    ", D8_8 => "G_D8_8   ", BR8 => "G_BR8    ",
      BR16 => "G_BR16   ", BR24 => "G_BR24   ", BR32 => "G_BR32   ");

   Table : Table_Opcodes;
   Sortie : Text_IO.File_Type;
   Nb_Definis : Natural := 0;

   procedure Lire_Codes (Chemin : String) is
      F : Text_IO.File_Type;
      L : String (1 .. 1024);
      Last, P, D : Natural;
      N : Natural;
   begin
      Text_IO.Open (F, Text_IO.In_File, Chemin);
      while not Text_IO.End_Of_File (F) loop
         Text_IO.Get_Line (F, L, Last);
         P := 1;
         while P <= Last and then L (P) = ' ' loop
            P := P + 1;
         end loop;
         if P + 2 <= Last and then L (P .. P + 2) = "OP_" then
            P := P + 3;
            D := P;
            while P <= Last and then (L (P) in 'A' .. 'Z' or L (P) in 'a' .. 'z'
                                      or L (P) in '0' .. '9' or L (P) = '_') loop
               P := P + 1;
            end loop;
            declare
               Nom : constant String := L (D .. P - 1);
            begin
               while P <= Last and then L (P) = ' ' loop
                  P := P + 1;
               end loop;
               if P <= Last and then L (P) = ':' then
                  P := P + 1;
                  while P <= Last and then L (P) = ' ' loop
                     P := P + 1;
                  end loop;
                  if P + 7 <= Last and then L (P .. P + 7) = "constant" then
                     P := P + 8;
                     while P <= Last and then L (P) = ' ' loop
                        P := P + 1;
                     end loop;
                     if P + 1 <= Last and then L (P .. P + 1) = ":=" then
                        P := P + 2;
                        while P <= Last and then L (P) = ' ' loop
                           P := P + 1;
                        end loop;
                        if P <= Last and then L (P) in '0' .. '9' then
                           N := 0;
                           while P <= Last and then L (P) in '0' .. '9' loop
                              N := N * 10 + Character'Pos (L (P)) - Character'Pos ('0');
                              P := P + 1;
                           end loop;
                           Nb_Codes := Nb_Codes + 1;
                           Codes (Nb_Codes).Nom (1 .. Nom'Length) := Nom;
                           Codes (Nb_Codes).Lg := Nom'Length;
                           Codes (Nb_Codes).Code := N;
                        end if;
                     end if;
                  end if;
               end if;
            end;
         end if;
      end loop;
      Text_IO.Close (F);
   end Lire_Codes;

   function Code_De (Nom : String) return Natural is
   begin
      for K in 1 .. Nb_Codes loop
         if Codes (K).Nom (1 .. Codes (K).Lg) = Nom then
            return Codes (K).Code;
         end if;
      end loop;
      Nom_Absent (1 .. Nom'Length) := Nom;
      Lg_Absent := Nom'Length;
      raise Absent;
   end Code_De;

   function Est_LEXCMP (N : String) return Boolean is
      --  U?LEXCMP[BWDQ]
      D : Positive := N'First;
   begin
      if N'Length >= 1 and then N (D) = 'U' then
         D := D + 1;
      end if;
      return N'Last - D + 1 = 7 and then N (D .. D + 5) = "LEXCMP"
        and then (N (N'Last) = 'B' or N (N'Last) = 'W' or N (N'Last) = 'D' or N (N'Last) = 'Q');
   end Est_LEXCMP;

   procedure L (Texte : String) is
   begin
      Text_IO.Put_Line (Sortie, Texte);
   end L;

begin
   if Args.Nombre /= 3 then
      Text_IO.Put_Line ("usage : gen_hx_codes SPEC tx_codes.ads hx_codes.ads");
      Args.Code_De_Sortie (2);
      return;
   end if;
   Lire (Args.Argument (1), Table);
   Lire_Codes (Args.Argument (2));
   Text_IO.Create (Sortie, Text_IO.Out_File, Args.Argument (3));

   L ("--  Table de decodage des opcodes HX : GENERE par outils/gen_hx_codes a partir de");
   L ("--  LLIR_hardware_support (table des opcodes) et de tx_codes.ads. Ne pas modifier a la main.");
   L ("--  Pour chaque octet d'opcode : format du complement et code TX equivalent.");
   L ("package HX_Codes is");
   L ("");
   L ("   type Genre is (G_Illegal, G_Aucun, G_Imm4, G_B16, G_B24, G_C24, G_C32,");
   L ("                  G_D8, G_D16, G_D24, G_D32, G_D64, G_D8_8, G_BR8, G_BR16, G_BR24, G_BR32);");
   L ("");
   L ("   --  octets de complement par genre");
   L ("   Longueur_Complement : constant array (Genre) of Natural :=");
   L ("     (G_Illegal => 0, G_Aucun => 0, G_Imm4 => 0, G_B16 => 2, G_B24 => 3, G_C24 => 3, G_C32 => 4,");
   L ("      G_D8 => 1, G_D16 => 2, G_D24 => 3, G_D32 => 4, G_D64 => 8, G_D8_8 => 2,");
   L ("      G_BR8 => 1, G_BR16 => 2, G_BR24 => 3, G_BR32 => 4);");
   L ("");
   L ("   type Description is record");
   L ("      G    : Genre;");
   L ("      Code : Integer;                -- code TX (tx_codes.ads), 0 si illegal");
   L ("   end record;");
   L ("");
   L ("   Table : constant array (0 .. 255) of Description := (");
   for C in 0 .. 255 loop
      declare
         E : Entree renames Table (C);
         G : String (1 .. 9) := "G_Illegal";
         Code : Natural := 0;
         Libelle : String (1 .. 40);
         Lg : Natural;
         Sep : Character := ',';
      begin
         Libelle (1 .. 7) := "reserve";
         Lg := 7;
         if E.Defini and then Nom (E) /= "RTX" then      -- RTX : sans equivalent TX
            if E.Imm4 then
               G := "G_Imm4   ";
               Code := Code_De ("LI");
               Libelle (1 .. 7) := "LI imm4";
            else
               G := Genre (E.Compl);
               if Est_LEXCMP (Nom (E)) then
                  Code := Code_De ("LEXCMP");
               else
                  Code := Code_De (Nom (E));
               end if;
               Lg := E.Lg_Nom;
               Libelle (1 .. Lg) := Nom (E);
               if E.Compl /= Aucun then
                  declare
                     S : constant String := " [" & Complement'Image (E.Compl) & "]";
                  begin
                     Libelle (Lg + 1 .. Lg + S'Length) := S;
                     Lg := Lg + S'Length;
                  end;
               end if;
            end if;
            Nb_Definis := Nb_Definis + 1;
         end if;
         if C = 255 then
            Sep := ' ';
         end if;
         L ("      " & Decimal (C, 3) & " => (" & G & ", " & Decimal (Code, 3) & ")" & Sep
            & "   -- " & Hexa_2 (C) & " " & Libelle (1 .. Lg));
      end;
   end loop;
   L ("   );");
   L ("");
   L ("   Nombre_Opcodes : constant := " & Decimal (Nb_Definis, 1)
      & ";   -- codes definis, imm4 compte pour 16");
   L ("");
   L ("end HX_Codes;");
   Text_IO.Close (Sortie);
exception
   when Spec_LLIR.Erreur =>
      Text_IO.Put_Line ("gen_hx_codes : " & Spec_LLIR.Message);
      Args.Code_De_Sortie (1);
   when Absent =>
      Text_IO.Put_Line ("gen_hx_codes : code TX absent de tx_codes.ads : OP_"
                        & Nom_Absent (1 .. Lg_Absent));
      Args.Code_De_Sortie (1);
end Gen_HX_Codes;
