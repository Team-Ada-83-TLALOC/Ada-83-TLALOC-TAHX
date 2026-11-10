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
