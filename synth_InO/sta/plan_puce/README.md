# Évaluateur de plan de puce TAHX_SOC (P66–P69)

- `connexions_macros.py <netlist_hiérarchique.v>` : liaisons bit à bit entre macros (→ `liens.json`, 253 couples de champs ; tiré de la netlist v5s du sommet `TAHX_1`).
- `plan_puce.py` : ports des macros (`ports.json`), placement des broches selon la sémantique de LibreLane (pas constant par côté, `$n` = emplacements vides, ouest/est de bas en haut, nord/sud de gauche à droite), orientations N/FN/FS/S, longueur des liaisons (bits × mm, Manhattan entre barycentres de champs) et pires distances critiques (chaînage, FAST_PIPE, arith, décodeur).
- `plans.py` : boîtes des macros, `pin_order` (dossier `cfg/`), groupes de broches `G` et `cfg(**côtés)` pour écrire un `pin_order` sans commentaire.
- `recherche_plan.py [n]` : recuit simulé (n tirages) ; macros à broches figées déplaçables et retournables, `exec_entier` / `exec_arith` / `system` à broches libres (estimation optimiste).
- `plan_retenu.py` : plan initial avec `stack_unit` aux broches de la v69 → chaînage 0,18–0,40 mm (0,75 affiché : artefact `issue_o.slot` → `issue_valid_i`), FAST_PIPE 0,64, arith 0,32, total ≈ 4 940 bits·mm.

Limites : barycentre par champ (un champ très étalé est mal représenté), pas de congestion, blocs SoC et périphériques réduits à un point.
