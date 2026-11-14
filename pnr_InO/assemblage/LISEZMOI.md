# pnr_InO/assemblage — assemblage du cœur TAHX_1 (8 macros)

Premier essai : **routage global seulement**, pour voir si le plan se route.

```
BRUT=<brut.il> pnr_InO/assemblage/extraire_sommet.sh      # src/tahx_1_sommet.v, src/bb/*.v
pnr_InO/assemblage/generer_config.py elargi               # config_elargi.yaml
cd pnr_InO/assemblage
librelane config_elargi.yaml --to OpenROAD.GlobalRouting
```

- `extraire_sommet.sh` : RTL du sommet (logique de liaison à plat, environ 900 cellules
  RTL) et déclaration de chaque macro (`vh`). `BRUT` est le RTLIL élaboré de
  `TAHX_1(IN_ORDER)` (`pnr_InO/etat_macros.sh` l'écrit dans son dossier temporaire ; ou
  `yosys -m ghdl -p "ghdl --std=08 TAHX_1 IN_ORDER; hierarchy -top TAHX_1; write_rtlil brut.il"`
  depuis `vhdl_InO/` après `Z_analyze.sh 08`).
- `generer_config.py` : positions du plan de `synth_InO/sta/plan_puce/canaux.py`
  (`PLANS`), LEF et `.lib` de `pnr_InO/macros/<m>/vues/` (`vues_macros.sh`), GDS du run
  noté dans `PROVENANCE_VUES.txt`. Marge de 150 µm autour des macros ; positions au pas
  de 0,48 µm.
- **Sans grille d'alimentation** (`OpenROAD.GeneratePDN` retiré) : chaque macro a sa grille
  jusqu'à TopMetal1, la couche du haut, et la grille du sommet ne peut pas s'y raccorder
  par le dessus. Le routage global est donc un peu optimiste (TopMetal1 et Metal4 libres
  dans les canaux). Pour l'assemblage complet : macros en `PDN_MULTILAYER: false`
  (Metal4 seul), grille TopMetal1 au sommet.

À lire après le run : le tableau du routage global (`*-openroad-globalrouting/*.log`,
`Total Overflow` et dépassement par couche), la carte de congestion (GUI d'OpenROAD,
*Heat Maps*), et `canaux.py --plan elargi` pour comparer canal par canal.

## Floorplan v2 (v11h, 13 novembre)

```
pnr_InO/assemblage/generer_config.py v11h                 # config_v11h.yaml
cd pnr_InO/assemblage
librelane config_v11h.yaml --to OpenROAD.GlobalRouting
```

- Plan exact de `canaux.py` (`PLANS["v11h"]`), LEF v2 (`<m>_v2.lef`), horloge 26 ns.
- Positions au sommet : x au pas de 0,48 µm (pistes Metal2, broches N/S), **y au pas de
  0,42 µm** (pistes Metal3, broches E/O) ; les marges sont arrondies à ces pas, si bien
  que les décalages relatifs du floorplan (1100,40 ; 599,76 ; 1071,84 ; 2438,52 ;
  2388,96 ; 20,16) sont gardés exactement. Avant, y était arrondi au pas de 0,48.
- Marge de 150 µm, **550 µm en haut** (`MARGE_HAUT` du plan) : zone du bloc
  `frontend_control` du modèle Logisim (logique de liaison : `commit` → `recovery` /
  `retire` / `redirect`), placée librement par le placement global, et passage des bus
  du nord de `stack_unit` vers le nord de `fetch` et de `decode_predict`. Puce
  7079,52 × 4238,64 µm.
- GDS. LibreLane vérifie au chargement que chaque GDS de `MACROS` existe, mais ne le lit
  qu'à l'écriture du GDS de la puce (`KLayout.StreamOut`, XOR, DRC).
  - `--gds auto` (défaut) : run v2 complet le plus récent de `pnr_InO/macros/<m>/runs/`
    (`final/klayout_gds/*.gds`, et `resolved.json` avec `pin_order_v2.cfg` et la boîte du
    LEF v2) ; à défaut, **GDS fantôme** `gds_fantomes/<m>.gds` (cellule du nom de la
    macro réduite à son contour, couche prBoundary 189/4), écrit par
    `gds_fantomes.py`. L'origine de chaque GDS est notée en commentaire dans le YAML.
  - Les fantômes suffisent à l'essai `--to OpenROAD.GlobalRouting`, pas au GDS final : il
    faudra les runs v2 menés jusqu'au bout (`RUN_KLAYOUT_STREAMOUT: true` dans les
    `config_v2.yaml`), puis relancer `generer_config.py v11h` sur la machine des runs.
  - `--gds vues` : GDS des runs v1 (`PROVENANCE_VUES.txt`, chemins absolus), tailles v1.
- `.lib` : encore celles des runs v1 (`vues/lib/`), mêmes ports en v1 et v2 ; à
  remplacer par `vues_macros.sh` sur les runs v2 (passation, § 4, étape 3).
- Comparer au routage global : `synth_InO/sta/plan_puce/canaux.py --plan v11h`
  (points chauds) et `alignement.py --plan v11h` (bus droits au bit près).
