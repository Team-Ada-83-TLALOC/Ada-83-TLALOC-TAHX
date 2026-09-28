--  Acces a la ligne de commande et au code de sortie du processus.
--  Seule unite ecrite en Ada 95 (son corps) : Ada 83 n'offre aucun acces
--  normalise a la ligne de commande.
package Args is
   function Nombre return Natural;
   function Argument (N : Positive) return String;
   procedure Code_De_Sortie (Code : Integer);
end Args;
