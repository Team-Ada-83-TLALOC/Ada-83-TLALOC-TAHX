pragma Ada_95;
with Ada.Command_Line;
package body Args is
   function Nombre return Natural is
   begin
      return Ada.Command_Line.Argument_Count;
   end Nombre;

   function Argument (N : Positive) return String is
   begin
      return Ada.Command_Line.Argument (N);
   end Argument;

   procedure Code_De_Sortie (Code : Integer) is
   begin
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Exit_Status (Code));
   end Code_De_Sortie;
end Args;
