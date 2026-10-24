# synth_InO/sta — estimation du timing de TAHX_1 avant placement

But : savoir, sans run LibreLane, quels chemins limitent la fréquence du cœur entier, en
particulier ceux qui **traversent plusieurs macros** de `pnr_InO` (invisibles aux runs
macro par macro, qui utilisent le SDC par défaut). Une synthèse (20 à 30 min) puis quelques
minutes d'OpenSTA par coin.

## 1. Netlist hiérarchique

```
cd synth_InO/sta
LIB=$PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib \
BRUT=<brut.il> ./synth_hier.sh 20          # -> tahx_1_sg13.v
KS=1 LIB=… BRUT=… ./synth_hier.sh 20       # additionneurs Kogge-Stone -> tahx_1_sg13_ks.v
```

- `BRUT` : RTLIL élaboré de `TAHX_1(IN_ORDER)`, celui que `pnr_InO/etat_macros.sh` produit
  (ou `vhdl_InO/mesure_par_module.sh`). Défaut `../par_module/brut.il`.
- Les sept macros (`stack_unit_16_8`, `ino_decode_queue`, `ino_decode_predict`,
  `ino_execute`, `ino_system`, `ino_data_cache`, `ino_fetch`) gardent leur hiérarchie ; la
  liaison de `TAHX_1` est à plat ; les SRAM IHP sont des boîtes noires.
- ABC reçoit une cible `-D` (la période) et `-constr` (tampons, redimensionnement), comme
  la synthèse de LibreLane. Ce n'est pas un `repair_timing` : la cible est par module et
  ignore les budgets entre macros.
- Flot ABC (`ABC=direct`, défaut) : `synth -noabc`, puis une seule projection ABC sans
  `&fraig` ni `scorr`. Le `abc -fast` de `synth` projette pour la surface et défait les
  arbres ; `&fraig -x` (script par défaut de Yosys, `ABC=yosys`) ne termine pas en
  plusieurs heures sur un multiplieur de Wallace ou des additionneurs Kogge-Stone.
- `SOUS="ino_float_unit fexp_unit"` synthétise ces unités à part (`keep_hierarchy`) : sinon
  la division flottante, hors d'atteinte de la cible, fixe le temps requis de tout
  `ino_execute` et ABC y relâche les autres chemins jusqu'à son retard.
- Yosys 0.33 projette les `$alu` en retenue propagée ; `KS=1` applique
  `lcu_kogge_stone.v` (préfixe parallèle). Sur un additionneur 64 bits isolé (typ) :
  9,0 → 6,3 ns pour +20 % de surface.

Puis, pour que l'estimation ne compte pas les échelles de tampons d'ABC (sortance limitée
à 10 par des `buf_1` chaînés, jusqu'à 20 en série sur un net de sortance 200) :

```
./arbres_tampons.py tahx_1_sg13.v tahx_1_sg13_arbres.v     # quelques secondes
```

Chaque grappe de tampons est remplacée par un arbre équilibré (`buf_4` aux feuilles, `buf_8`
au-dessus, sortance 8), ce que ferait `repair_design` dans un flot place-route.

## 2. OpenSTA

```
PERIODE=20 COIN=slow WLM=Zero \
STDLIB=$PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib \
SRAMLIB=$PDK_ROOT/ihp-sg13g2/libs.ref/sg13g2_sram/lib \
sta -no_splash -exit sta_tahx.tcl
```

Le `sta` fourni avec LibreLane (OpenROAD) convient ; `openroad -no_splash -exit
sta_tahx.tcl` aussi. Variables : `COIN` slow / typ / fast ; `WLM` modèle de fil des .lib
(`Zero`, `10k`, `30k`… ; vide : capacités de broches seules) ; `NETLIST` (défaut
`tahx_1_sg13.v`) ; `NCHEMINS` (3000) ; `IO_FRAC` (0,3 de la période pris hors du cœur
sur chaque port) ; `INCERT` (0,5 ns).

Sorties `sta_<coin>_<période>_<modèle>[_<variante>].*`, la variante venant du nom de la
netlist (`tahx_1_sg13_arbres.v` → `_arbres`) :

| fichier | contenu |
|---|---|
| `.rpt` | pire chemin détaillé, TNS, WNS |
| `.chemins` | un chemin par extrémité : marge, registre de départ, registre d'arrivée (noms RTL), suite des macros traversées |
| `.paires` | par suite de macros traversées : nombre de chemins, pire marge — **le fichier à lire d'abord** |
| `.budgets` | par port de macro traversé : arrivée au plus tard et marge, base de futurs `set_input_delay` / `set_output_delay` par macro |

La dernière ligne affichée donne la période atteignable (période − pire marge). Les
retards ne dépendent de la période que par la cible d'ABC : un run à 20 ns suffit pour
lire la fréquence ; 15 ou 25 ns changent les marges, pas les chemins.

## 3. Lecture des bornes

- `WLM=Zero` : fils de capacité nulle, borne **optimiste**.
- `WLM=30k` : modèle statistique d'un bloc de 30 000 µm² appliqué à chaque net, borne
  **pessimiste** pour les nets locaux, mais pas pour les liaisons longues entre macros.
- Point de calibration : `ino_fetch` seul, registre à registre, typ : 7,1 ns (Zero),
  10,1 ns (30k), 16,5 ns dans un run routé à `CLOCK_PERIOD: 100` (non contraint, 1 249
  violations de slew au coin slow). Un run contraint à 20–40 ns se situera entre les deux
  bornes.
