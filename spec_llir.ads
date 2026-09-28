--  Lecture de la table des opcodes de LLIR_hardware_support (V3, V4 : meme table).
--
--  Une ligne de la table a la forme
--     numero TAB famille TAB binaire TAB x TAB nom [complement] ... ; commentaire
--  ou famille est A, B, C ou D et binaire s'ecrit b suivi de 0, 1, _ et i (i : bits de
--  l'immediat de LI imm4). Seuls le nom et le complement entre crochets sont lus avant le ';'.
--  Toute autre ligne est ignoree : les commentaires et les autres sections de la specification
--  peuvent evoluer librement.
--
--  Utilise par gen_hx_codes (table de decodage de tx_run) et gen_tahx_isa (paquetage VHDL).
package Spec_LLIR is

   type Complement is (Aucun, B16, B24, C24, C32, D8, D16, D24, D32, D64, D8_8,
                       BR8, BR16, BR24, BR32);

   Octets_Complement : constant array (Complement) of Natural :=
     (Aucun => 0, B16 => 2, B24 => 3, C24 => 3, C32 => 4, D8 => 1, D16 => 2, D24 => 3,
      D32 => 4, D64 => 8, D8_8 => 2, BR8 => 1, BR16 => 2, BR24 => 3, BR32 => 4);

   Longueur_Nom_Max : constant := 16;

   type Entree is record
      Defini  : Boolean;
      Numero  : Natural;                       -- numero de la specification (1 .. 180)
      Famille : Character;                     -- 'A' .. 'D'
      Nom     : String (1 .. Longueur_Nom_Max);
      Lg_Nom  : Natural;
      Compl   : Complement;
      Imm4    : Boolean;                       -- LI imm4 : 16 valeurs du premier octet
   end record;

   type Table_Opcodes is array (0 .. 255) of Entree;

   Erreur : exception;                         -- table mal formee ; voir Message

   procedure Lire (Chemin : String; Table : out Table_Opcodes);
   function Message return String;

   function Nom (E : Entree) return String;
   function Nombre_Opcodes (Table : Table_Opcodes) return Natural;   -- numeros distincts

   --  Utilitaires d'ecriture partages par les generateurs
   function Decimal (N : Integer; Largeur : Natural) return String;  -- cadre a droite
   function Hexa_2 (N : Natural) return String;                      -- 2 chiffres majuscules

end Spec_LLIR;
