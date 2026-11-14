# Évaluateur de plan de puce TAHX_SOC (P66–P69)

- `connexions_macros.py <netlist_hiérarchique.v>` : liaisons bit à bit entre macros (→ `liens.json`, 253 couples de champs ; tiré de la netlist v5s du sommet `TAHX_1`).
- `plan_puce.py` : ports des macros (`ports.json`), placement des broches selon la sémantique de LibreLane (pas constant par côté, `$n` = emplacements vides, ouest/est de bas en haut, nord/sud de gauche à droite), orientations N/FN/FS/S, longueur des liaisons (bits × mm, Manhattan entre barycentres de champs) et pires distances critiques (chaînage, FAST_PIPE, arith, décodeur).
- `plans.py` : boîtes des macros, `pin_order` (dossier `cfg/`), groupes de broches `G` et `cfg(**côtés)` pour écrire un `pin_order` sans commentaire.
- `recherche_plan.py [n]` : recuit simulé (n tirages) ; macros à broches figées déplaçables et retournables, `exec_entier` / `exec_arith` / `system` à broches libres (estimation optimiste).
- `plan_retenu.py` : plan initial avec `stack_unit` aux broches de la v69 → chaînage 0,18–0,40 mm (0,75 affiché : artefact `issue_o.slot` → `issue_valid_i`), FAST_PIPE 0,64, arith 0,32, total ≈ 4 940 bits·mm.

Limites : barycentre par champ (un champ très étalé est mal représenté), pas de congestion, blocs SoC et périphériques réduits à un point.

## Floorplan v2 (v11h, 13 novembre)

- `canaux.py --plan v11h` : plan exact du floorplan v2 (`pnr_InO/FLOORPLAN_TAHX_v11h.md` ; y au pas de 0,42 µm, x au pas de 0,48 µm), lu avec les LEF v2 (`<m>_v2.lef`, clé `LEF` du plan ; `--lef v1|v2` pour forcer). `lef_macro()` et `version_lef()` servent aussi à `fils.py` et à `generer_config.py`.
- `alignement.py [--plan v11h] [--detail]` : liaisons directes broche à broche d'après la netlist synthétisée du sommet (`pnr_InO/assemblage/runs/*/06-yosys-synthesis/TAHX_1.nl.v`, mêmes ports en v1 et v2) ; décalage bit à bit des bus droits, paires croisées des bus coudés (fil en L), contrôle de la grille du sommet.
- `lire_circ.py [modèle.circ]` : positions des sous-circuits du modèle Logisim (coin haut-gauche = `loc` + rect − ancre), comparées au plan.

Résultat v11h (LEF v2) : 2 483 bits de bus droits à décalage nul (predict → dq 577, system → entier 449, stack → entier 439 sur 440, fetch → predict 326, entier → system 193, dq → stack 143, stack ↔ dcache 168, arith → entier 78, dcache → system 67, …) ; stack → arith : 1 paire croisée (`issue_class[2]` / `issue_op[0]`), comme relevé par Vincent. Le modèle Logisim place la rangée du bas (`exec_arith`, `exec_entier`, `ino_system`) 8,5 µm trop haut : avec ses positions, dcache → system serait décalé de 8,52 µm.
