# synth_InO/sta/assemblage — STA d'assemblage de TAHX_1 avec les macros routées

Les huit macros sont vues par leurs **modèles de timing** (`pnr_InO/macros/<m>/vues/lib/`,
écrits par LibreLane à partir du routage), la logique de liaison est synthétisée à part,
et les fils du sommet sont estimés d'après un plan de puce (`../plan_puce/canaux.py`).
Rien n'est placé : c'est une vérification des budgets avant l'assemblage LibreLane.

```
LIB=$STDLIB/sg13cmos5l_stdcell_slow_1p08V_125C.lib BRUT=<brut.il> ./synth_colle.sh   # tahx_1_colle.v
export STDLIB=<…/sg13cmos5l_stdcell/lib> MACROS=../../../pnr_InO/macros PLAN_PUCE=../plan_puce
COIN=slow sta -no_splash -exit connexions.tcl                    # connexions.txt
./fils.py connexions.txt elargi fils_elargi_slow.tcl --coin slow
COIN=slow FILS=fils_elargi_slow.tcl SORTIE=as_slow_elargi sta -no_splash -exit sta_assemblage.tcl
```

- `lire.tcl` : cellules et modèles des macros du coin `COIN` (slow, typ, fast), netlist,
  horloge `PERIODE` (25), incertitude `INCERT` (0,5), ports à `IO_FRAC` (0,3) de la
  période, `RESET_i` à 1 ns (bascule de synchronisation).
- `fils.py` : positions des broches d'après les LEF et le plan ; cellules de liaison au
  barycentre de leurs voisins ; fil Manhattan × 1,3 ; 1,55 Ω/µm, 0,20 fF/µm ; répéteurs
  tous les 500 µm (0,16 / 0,09 / 0,06 ns par tampon, lent / typique / rapide) ; écrit un
  modèle en π par net et un Elmore par charge (`sta::set_pi_model`, `sta::set_elmore`).
- `sta_assemblage.tcl` : WNS, TNS, et pour les `NCH` pires extrémités la suite des blocs
  traversés (fichier `.rpt`) ; pire chemin détaillé (`.chemin`).

Limites : horloge idéale au sommet (l'incertitude couvre l'écart entre macros) ;
transitions dégradées le long des fils seulement via le modèle en π ; bibliothèque de
cellules de la branche `dev` de la PDK d'IHP.

## Rebudgétage des SDC de macros (P78)

```
COIN=slow FILS=fils_aligne_dc_slow.tcl SORTIE=chemins_dc.txt sta -no_splash -exit releve_chemins.tcl
./rebudgeter.py chemins_dc.txt --periode 25 --sortie sdc_rebudget    # g par macro, SDC des macros à relancer
./verifier_budgets.py chemins_dc.txt sdc_rebudget                    # chaque segment reçoit >= g d - biais
```

- `releve_chemins.tcl` : chemins qui traversent des macros (les `NCH` pires, `PAR_EXT` par
  extrémité, marge < `SMAX`), **plus le pire chemin par chaque broche de macro** de marge
  < `SMAX` ; pour chaque chemin, les instants aux broches de macros. Demande
  `Path::arrivals()`, ajouté à `search/Search.i` d'OpenSTA :
  ```
  FloatSeq arrivals() { FloatSeq a; const Path *p = self;
    while (p) { a.push_back(p->arrival()); p = p->prevPath(); } return a; }
  ```
  (compiler avec `-DBUILD_TESTS=OFF -DUSE_TCL_READLINE=OFF -DCUDD_DIR=…`).
- `rebudgeter.py` : un facteur g_M ≤ 1 par macro sur ses segments internes, choisi par un
  programme linéaire en nombres mixtes (scipy) : période atteignable d'abord, puis coût
  des relances (`COUT`) et effort (1 − g) / (1 − g_min) (`GMIN` : accélération jugée
  atteignable par macro). Instant alloué à chaque broche : arrivée mise à l'échelle plus
  la moitié de la marge restante, le même pour la sortie d'une macro et l'entrée qu'elle
  attaque. SDC : `-max` réécrits (valeur du pire bit par bus, plus une valeur propre pour
  chaque bit qui s'en écarte de plus de 0,25 ns), `-min` gardés (hold), traversées en
  `set_max_delay` par paire de bus (la plus large des paires de bits, pour que chaque
  paire ait au moins son budget). `--biais 0,3` ns resserre tout (écart d'horloge entre
  macros au sommet).
  **Insertion d'horloge interne** (`LAT`, mesurée par `latence_macros.tcl`) : les `.lib`
  des macros sont écrites en horloge idéale (horloge → sortie et setup sans l'arbre
  interne), si bien qu'un chemin de A vers B est plus long de L_A − L_B que dans la STA
  d'assemblage ; `rebudgeter.py` l'ajoute en segments fixes. L : `ino_fetch` 2,39,
  `ino_data_cache` 2,22, `stack_unit` 1,20, `ino_system` 1,04, `exec_entier` 1,01,
  `decode_predict` 0,98, `exec_arith` 0,95, `decode_queue` 0,71 ns (coin lent).
  Traversées absentes du relevé : complétées par les arcs combinatoires des `.lib`
  (retard à 0,039 pF, × g). Si la cible n'est pas atteignable dans les `GMIN`, les SDC
  sont écrits à la période atteignable (`create_clock`).
- `verifier_budgets.py` : relit les SDC et vérifie, segment par segment du relevé et arc
  par arc des `.lib`, que le budget donné vaut au moins g d − biais.

Erreurs corrigées en route, à ne pas refaire : une valeur par bus (le pire bit n'est
pas celui du plus long chemin interne : `complete_i.fault[0]` de `stack_unit` aurait eu
5,5 ns pour 9,8) et une traversée bornée par sa paire de bits la plus serrée ; et un relevé
limité aux pires chemins par extrémité (`issue_i.operand → complete_o.result` d'`exec_entier`
absent, donc budgété par défaut à 3,6 ns pour 13,3) ; les latences internes oubliées
(`ino_data_cache` aurait dû gagner 2,2 ns de plus que prévu).
