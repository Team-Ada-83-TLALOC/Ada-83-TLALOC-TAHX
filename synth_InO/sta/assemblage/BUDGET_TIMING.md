# Budget de timing à deux niveaux dans TAHX

Cette note explique comment les contraintes de timing des huit macros de TAHX_1 sont
fixées et révisées : ce que disent les SDC, dans quel repère de temps, ce que voit chaque
STA, et comment `rebudgeter.py` partage la période entre les macros. Elle décrit le code
tel qu'il est (`synth_InO/sta/`, `synth_InO/sta/assemblage/`, `pnr_InO/`) ; les procédures
pas à pas sont dans `LISEZMOI.md`, `PASSATION_SOC_TAHX.md` et `ARCHI_SOC_TAHX.md`.

Exemple suivi tout au long : `stack_unit_16_8`, SDC rebudgété v11h (période 26 ns,
g = 0,877, insertion interne 1,18 ns).

---

## 1. Le problème

TAHX_1 est placé-routé en deux niveaux :

- **les macros** (fetch, decode_predict, decode_queue, stack_unit, exec_entier, exec_arith,
  system, data_cache), chacune par un run LibreLane séparé, avec son propre SDC ;
- **l'assemblage** (sommet), qui pose les macros selon le plan v11h, route les liaisons
  entre elles et la logique de liaison, et voit chaque macro comme une boîte noire :
  un LEF (forme, broches, obstructions) et un modèle de timing `.lib`.

Un chemin critique du circuit commence souvent dans une macro, traverse une ou deux autres
macros et finit dans une quatrième. Aucun run ne voit ce chemin entier : chaque macro n'en
voit que son morceau, et l'assemblage ne voit des macros que leurs modèles. Il faut donc
**partager la période entre les morceaux** : c'est le budget. Chaque SDC de macro est un
contrat : « tes entrées arrivent au plus tard à tel instant, tes sorties doivent être
prêtes au plus tard à tel instant ; à toi de tenir ce qu'il y a entre les deux ».

Si le partage est mauvais, une macro peut tenir son contrat alors que le circuit entier
échoue (budget trop large ici, trop serré là), ou au contraire échouer sur un contrat
impossible alors qu'une autre macro avait de la marge à revendre.

## 2. Le repère de temps

Une seule origine pour tout le SDC d'une macro : **le front montant de `clk` à la broche
`clk_i` de la macro**, t = 0. `create_clock -period T` met les fronts à 0, T, 2T…

Notations :

| symbole | sens | stack_unit v11h |
|---|---|---|
| T | période | 26 ns |
| U | incertitude de setup (`set_clock_uncertainty -setup`) | 0,5 ns |
| U_h | incertitude de hold | 0,1 ns |
| L_j | insertion d'horloge interne : du front à `clk_i` au front à la bascule j | moyenne 1,18 ns |
| t_su, t_h | setup et hold de la bascule (dans le `.lib` de la cellule) | quelques centaines de ps |
| t_cq | horloge → sortie de la bascule | |
| b | biais du rebudget (§ 7) | 0,3 ns |

Dans le run de la macro, après la CTS, l'horloge est **propagée** : chaque bascule voit le
front à L_j, qui varie d'une bascule à l'autre (le skew interne). Avant la CTS, l'horloge
est idéale (L_j = 0). U et t_su sont deux termes distincts qui s'additionnent : t_su est
une propriété de la cellule, U une marge que nous choisissons (gigue, imprécision des
modèles, écart entre STA de macro et STA d'assemblage).

```
 0      L≈1,18                                          T=26   T+L
 |front |front aux                                       |      |
 |clk_i |bascules                                        |      |
 |      |                                                |      |
 |-- entrée : le signal est au port à D_in ; puis d_int jusqu'à la bascule j,
 |           qui doit l'avoir avant T + L_j - t_su - U
 |      |
 |      |-- sortie : lancée à L_i, doit être au port avant T - U - D_out
```

## 3. Ce que disent les trois groupes du SDC

### 3.1 `set_input_delay -max D_in` : un instant

Le signal est stable au port au plus tard D_in après le front 0 (ce qui se passe hors de
la macro). Vérification de setup d'un chemin entrée → bascule j :

    D_in + d_int  ≤  T + L_j − t_su − U

`-min D_in,min` : instant au plus tôt où le signal peut changer, pour le hold :

    D_in,min + d_int,min  ≥  L_j + t_h + U_h

Exemple : `decode_slot_i.canon[28]` a `-max 7.559`. Budget interne jusqu'à la bascule :
26 + 1,18 − 0,5 − 7,559 ≈ **19,1 ns**, t_su compris.

### 3.2 `set_output_delay -max D_out` : une durée, le complément d'un instant

D_out est le temps que l'extérieur consomme après le port avant le front suivant. La
donnée doit donc être au port avant **T − U − D_out** :

    L_i + t_cq + d_int  ≤  T − U − D_out

`-min` est l'exigence de hold de l'extérieur : la donnée ne doit pas changer au port avant
−D_out,min. Une valeur positive rend ce hold trivial.

Exemple : `commit_o.fault[*]` a `-max 21.984` : la sortie doit être au port avant
26 − 0,5 − 21,98 = 3,52 ns, soit 3,52 − 1,18 = **2,34 ns** pour t_cq et la logique.
C'est presque une sortie directe de bascule.

**Lecture à retenir : la valeur d'une entrée est un instant ; celle d'une sortie est ce
qui reste après l'instant de sortie avant le front suivant.**

### 3.3 `set_max_delay -from in -to out V` : les traversées

Pour un chemin combinatoire qui entre par un port et ressort par un autre sans bascule.
Sans `set_max_delay`, OpenSTA le vérifierait avec l'horloge :

    D_in + d  ≤  T − U − D_out

Ce serait faux. D_in est le pire cas sur *tous* les chemins qui passent par l'entrée,
D_out sur *tous* ceux qui passent par la sortie, et ce ne sont pas les mêmes : la
différence peut être bien trop large, ou trop serrée, voire négative. (Premier cas
rencontré, le 29 octobre : `issue_ready_i → decode_take_o` de stack_unit à −9,4 ns sur une
traversée de quelques portes, alors que le même chemin avait +4,8 ns dans le cœur entier.)

`set_max_delay` remplace l'exigence tirée de l'horloge par une borne fixe. Entre deux
ports, OpenSTA compte quand même le D_in de départ, et retire du requis le D_out
d'arrivée **et l'incertitude d'horloge** (ligne `clock uncertainty` sous `max_delay`
dans les rapports) :

    D_in + d  ≤  V − U − D_out

Le SDC écrit **V = D_in + D + D_out + U** (depuis le 16 novembre), donc tout s'annule :
**d ≤ D**, la part interne allouée à cette paire de ports. Les SDC antérieurs écrivaient
V = D_in + D + D_out : chaque traversée y avait 0,5 ns de moins que prévu.

Exemple (SDC v11h, avant la correction) : `sync_valid_i → decode_take_o` à 12,100 =
6,747 + 1,993 + 3,360, donc d ≤ 1,993 − 0,5 = 1,49 ns au lieu de 1,993. Avec la seule
horloge, on aurait autorisé 26 − 0,5 − 6,75 − 3,36 = 15,4 ns.

### 3.4 Bus et bits

Une ligne sur `[get_ports {bus[*]}]` contraint tous les bits. Une ligne `-max` plus loin sur
`bus[28]` **remplace** la valeur pour ce seul bit (OpenSTA retient la dernière valeur de
même horloge et de même sens min/max, sans `-add_delay`) ; le `-min` du bus reste valable
pour tous les bits. D'où la forme « valeur du pire bit, puis les bits qui s'en écartent ».
Pour `set_max_delay`, une surcharge bit à bit plus serrée l'emporte (à priorité égale,
OpenSTA retient la borne la plus serrée).

### 3.5 Le reste de l'en-tête

`set_driving_cell sg13cmos5l_buf_4` sur les entrées et `set_load 0.02` (pF) sur les
sorties : ce qui pilote et ce que charge la macro, pour les fronts et les retards aux
ports. Ce sont des hypothèses fixes, pas des valeurs mesurées sur l'assemblage.

## 4. Ce que voit chaque STA

### 4.1 La STA d'une macro (run LibreLane)

Netlist de la macro, son SDC, horloge propagée après CTS, parasites extraits. Elle voit
chaque L_j exact. Elle vérifie :

- bascule → bascule : `L_i + t_cq + d ≤ T + L_j − t_su − U` (les budgets n'y sont pour rien) ;
- entrée → bascule, bascule → sortie, traversées : § 3.

### 4.2 La STA d'assemblage

Netlist de l'assemblage, SPEF de l'assemblage routé, macros vues par leur `.lib`
(`pnr_InO/macros/<m>/vues/lib/`, écrits par LibreLane à la fin du run de la macro).
**Horloge du sommet idéale** : le front arrive à t = 0 sur toutes les broches `clk_i`.

Les `.lib` des macros sont écrits **en horloge idéale** : leur arc horloge → sortie
n'inclut pas l'insertion interne L_A, et leur arc de setup ne la retranche pas non plus.
Un chemin de la macro A vers la macro B est donc, dans le silicium, plus long de
**L_A − L_B** que ce que montre la STA d'assemblage. `rebudgeter.py` ajoute ce terme en
segments fixes : +L_A au départ, −L_B à l'arrivée. Les L sont mesurés par
`latence_macros.tcl` (moyenne aux bascules ; pour `ino_data_cache`, moyenne à l'horloge des
SRAM, `LATSRAM`, parce que ses chemins critiques partent des SRAM).

### 4.3 Pourquoi les deux ne disent pas la même chose

- la STA d'assemblage utilise la moyenne L, pas les L_j ;
- elle ignore pour l'instant l'arbre d'horloge du sommet (skew entre macros : 2,40 ns
  mesurés sur l'assemblage v11h, alors que le biais n'en couvre que 0,3) ;
- les `.lib` sont des modèles : fronts et charges approximés aux broches ;
- chaque relance d'une macro change son `.lib`.

C'est pour couvrir une partie de ces écarts que U et b existent, et c'est pour cela qu'on
vérifie à la fin sur l'assemblage routé avec `STAPostPNR`, la seule STA qui fait foi.

## 5. La boucle de budget

```
 SDC initiaux (estimation du cœur entier)
        │
        ▼
 runs des 8 macros ──► vues/ (LEF, .lib, netlist, SPEF)      pnr_InO/vues_macros.sh
        │
        ▼
 assemblage LibreLane jusqu'à STAPostPNR                   pnr_InO/assemblage/
        │
        ▼
 relevé des chemins traversant des macros                   releve_chemins.tcl
 latences internes L                                        latences_macros.sh
        │
        ▼
 rebudget : g par macro, instants τ, nouveaux SDC           rebudgeter.py
 contrôle                                                   verifier_budgets.py
        │
        ▼
 relance des seules macros dont le budget a changé ─────────► (retour aux vues)
```

### 5.1 Historique des SDC

1. **SDC d'origine** (`sdc_macro.tcl`, puis `sdc_traversees.tcl`) : une STA du cœur entier
   *estimé* (netlist de synthèse, fils « Zero »). Pour chaque port, le pire chemin du cœur
   qui y passe : entrée = arrivée du pilote extérieur, sortie = T − requis au plus tôt des
   charges extérieures. Insertion extérieure supposée de 0,8 ns (entrées + 0,8,
   sorties − 0,8), faute de quoi chaque entrée arrivait avant l'horloge des bascules
   internes (2 437 tampons de hold, échec du placement détaillé). Traversées :
   D = (arrivée à la sortie − arrivée à l'entrée) + 0,5 × marge du chemin.
   Une seule valeur par port, qui sert de max et de min. Exemple :
   `stack_unit_16_8_25ns.sdc.avant_rebudget`.
2. **P78** : premier rebudget, d'après une STA d'assemblage où les macros sont routées
   mais les fils du sommet *estimés* (`fils.py`, plan `aligne_dc`, `chemins_dc2.txt`).
   Période 26 ns, `-max` réécrits, `-min` gardés.
3. **v11h** : rebudget d'après l'**assemblage routé** v11h (netlist et SPEF réels,
   `chemins_v11h.txt`), latences mesurées (`latences_slow.txt`).

Le nom de fichier `<m>_25ns.sdc` a été gardé à chaque fois : **le nom ne dit pas la
version**, l'en-tête si (`# Rebudgete (rebudgeter.py, chemins_v11h.txt) …`). Garder une
copie nommée de chaque version utilisée par un run qu'on veut pouvoir refaire
(`stack_unit_16_8_25ns_P78.sdc`…), et retrouver la configuration d'un run avec
`pnr_InO/outils/config_run.py`.

## 6. Le relevé et les segments

`releve_chemins.tcl` lance, sur l'assemblage (coin lent, horloge idéale), les 40 000 pires
chemins (10 par extrémité au plus, marge < 4 ns), **plus le pire chemin passant par chaque
broche de macro** de marge < 4 ns. Le second passage est indispensable : les dix pires
chemins d'une extrémité peuvent tous passer par le même bus et laisser sans relevé une
traversée presque aussi longue (`issue_i.operand → complete_o.result` d'exec_entier,
budgétée par défaut à 3,6 ns pour 13,3 ns de chemin réel).

Chaque chemin est écrit avec ses instants aux broches des macros (format dans l'en-tête du
script). `rebudgeter.py` (`segments()`) le découpe aux broches des macros :

| segment | durée | appartient à |
|---|---|---|
| insertion de la macro de départ A | +L_A | fixe |
| horloge → sortie de A | arc du `.lib` de A | macro A |
| port d'entrée du sommet | son input_delay | fixe |
| liaison (fil, logique du sommet) | différence des instants | fixe |
| traversée de B (entrée → sortie) | différence des instants | macro B |
| entrée → bascule de C | setup du `.lib` de C | macro C |
| insertion de la macro d'arrivée C | −L_C | fixe |
| port de sortie du sommet | son output_delay | fixe |

La somme des segments d'un chemin vaut **T − U − marge** : un chemin tient si la somme
est ≤ T − U.

## 7. Le partage : programme linéaire, instants, SDC

### 7.1 Un facteur g par macro

On suppose qu'une macro relancée peut raccourcir **tous** ses segments internes d'un même
facteur g_M ≤ 1, et que les segments fixes ne bougent pas. Programme linéaire en nombres
mixtes (`resoudre()`, `scipy.optimize.milp`), variables g_M, y_M ∈ {0, 1} (macro relancée
ou non) et z (retard de période) :

- pour chaque chemin : Σ_M g_M · d_M + Σ fixes ≤ T − U + z ;
- y_M = 0 ⇒ g_M = 1 (pas relancée, pas accélérée) ; y_M = 1 ⇒ g_M ≥ GMIN_M ;
- on minimise d'abord z (la période atteignable est T + z), puis le coût des relances
  (`COUT`, par exemple 2 pour stack_unit, 4 pour fetch), puis l'effort
  (1 − g_M)/(1 − GMIN_M), pour **répartir l'accélération** plutôt que d'épuiser une seule
  macro.

`GMIN` traduit ce qu'on juge atteignable : 0,55 pour exec_entier, 0,75 pour stack_unit,
0,80 par défaut. Le milp v11h a retenu g = 0,877 pour stack_unit : ses segments internes
doivent être environ 12 % plus courts que dans la version routée relevée.

### 7.2 Des g aux instants τ

Avec ces g, chaque chemin est remis à l'échelle. Pour chaque broche p de macro :

- a′(p) : pire arrivée mise à l'échelle, sur les chemins qui passent par p ;
- r′(p) : pire requis (le plus tôt), sur les mêmes chemins ;
- marge s′ = r′ − a′ ;
- **instant alloué τ(p) = a′ + λ · s′**, avec λ = 0,5 : la moitié de la marge restante va à
  l'amont, l'autre moitié à l'aval.

La sortie d'une macro et l'entrée qu'elle attaque reçoivent ainsi le même instant, au fil
près. Les broches hors du relevé gardent τ = arrivée + λ × marge de la STA (plafonnée à
6 ns).

### 7.3 Des instants au SDC

- entrée : **D_in = τ + b** ;
- sortie : **D_out = (T − U + z) − τ + b** : la macro doit livrer avant τ − b ;
- **b = 0,3 ns** resserre les deux côtés : entre « A a fini » (τ − b) et « B commence »
  (τ + b), il reste 2b = 0,6 ns pour le fil et le décalage d'horloge entre macros ;
- valeur d'un bus : celle de son pire bit, plus une valeur propre pour chaque bit qui s'en
  écarte de plus de `ECART` = 0,25 ns (sans cela, `complete_i.fault[0]` de stack_unit, dont
  le chemin interne fait 9,8 ns, aurait hérité de l'instant tardif des autres bits et
  n'aurait eu que 5,5 ns) ;
- `-min` : repris de l'ancien SDC, borné par le plus petit `-max` du bus ;
- `create_clock` : T + z (les budgets en dépendent).

### 7.4 Les traversées

Pour chaque paire (entrée u, sortie v) d'une macro relevée, D est le plus petit, sur les
chemins qui la traversent, de

    g·d  +  λ · marge du chemin · (g·d / Σ des segments internes du chemin)

(sa part mise à l'échelle, plus sa part de la moitié de la marge restante), et au moins le
g·d du plus long passage. Puis V = D_in(u) + D + D_out(v) + U par paire de bits ; par paire de
bus, la plus large des paires de bits, et une surcharge bit à bit pour les paires plus
serrées de plus de 0,25 ns. Les traversées absentes du relevé mais présentes dans le
`.lib` de la macro reçoivent D = g × leur arc combinatoire à 0,039 pF.

### 7.5 Le contrôle

`verifier_budgets.py` relit les SDC écrits et vérifie, segment par segment, que chacun
reçoit au moins g·d − b :

- horloge → sortie : T − U − D_out − L ;
- entrée → bascule : T − U − D_in + L ;
- traversée : V − D_in − D_out − U.

## 8. Lire un résultat : stack_unit après le rebudget v11h

Le run `RUN_2026-11-14_21-00-40` de stack_unit, avec le SDC v11h, finit à −8,67 ns au coin
lent. Le pire chemin part de `decode_slot_i.canon[28]` :

- SDC : D_in = 7,559, donc τ = 7,26 ns. Budget interne jusqu'à la bascule (§ 3.1) :
  ≈ 19,1 ns.
- Dans le run, le signal atteint la bascule vers 34 ns, soit environ 27 ns à l'intérieur
  de la macro : 7 à 8 ns de trop.
- Avec le SDC P78, le même bit avait D_in = 8,683 : le budget v11h est **plus large**
  d'environ 1,1 ns. Le SDC n'explique donc pas l'échec ; le rapport détaillé montre trois
  cellules (un `buf_1`, une `nand3_1` à 0,41 pF et 5,5 ns de front, une `o21ai_1`) qui
  coûtent à elles seules environ 7 ns : de longs fils que la réparation n'a pas coupés
  (`DESIGN_REPAIR_MAX_WIRE_LENGTH: 0`).

La méthode de lecture est toujours la même : comparer le budget interne que le SDC donne
au chemin (§ 3, § 7.5) avec ce que le run consomme ; si le run consomme beaucoup plus que
le g·d du relevé, le problème est dans le placement-routage de la macro, pas dans le
budget.

## 9. Le hold

Les `-min` viennent tous de `sdc_macro.tcl`, qui écrivait une seule valeur par port : ce
sont des pires cas de setup réutilisés, pas de vrais budgets de hold. Aux entrées, ils
supposent que le signal ne change pas avant un instant peut-être trop tardif (hold
optimiste) ; aux sorties, ils rendent le hold trivial. Le hold aux interfaces se vérifie donc vraiment sur
l'assemblage (`STAPostPNR`, coin rapide). U_h = 0,1 ns seulement : 0,5 ns imposait environ
0,3 ns de retard à tous les chemins courts (2 300 tampons de hold, échec du placement
détaillé).

## 10. Limites connues et erreurs déjà faites

- **Horloge du sommet idéale** dans la STA d'assemblage et dans le relevé. Le skew réel
  entre macros n'est couvert que par b. À reprendre avec l'arbre d'horloge du sommet.
- **Un g par macro** : modèle commode, pas physique ; une relance n'accélère pas tous les
  chemins également.
- **Le flux est sensible** : un SDC à peine différent change les réparations, donc le
  placement, donc tout. Un bon run se garde (vues versionnées, config et SDC exacts) ; on
  ne relance une macro que si son budget a vraiment bougé.
- Erreurs corrigées, à ne pas refaire :
  - une seule valeur par bus (le pire bit n'est pas celui du plus long chemin interne) ;
  - une traversée bornée par sa paire de bits la plus serrée ;
  - un relevé limité aux pires chemins par extrémité ;
  - les latences internes oubliées (`ino_data_cache` aurait dû gagner 2,2 ns de plus) ;
  - L de data_cache prise aux bascules au lieu des SRAM (0,88 au lieu de 1,64 ns) ;
  - un ancien SDC déjà rebudgété relu comme un SDC d'origine ;
  - des `-min` supérieurs aux `-max` (ports « nouveau » de P78, pires bits de l'origine).
  - des `set_max_delay` de traversée sans l'incertitude d'horloge, qu'OpenSTA retire
    aussi : 0,5 ns de moins sur chaque traversée (SDC jusqu'au v11h_c compris) ;
  - un relevé par `report_checks` sans `-fields {input_pins}` (OpenSTA sans
    `arrivals()`, relevé v11h du 15 novembre) : les broches d'entrée des macros
    manquaient, leurs traversées comptaient comme segments fixes du sommet ; le milp ne
    pouvait pas les accélérer et les `set_max_delay` ne venaient que des arcs des `.lib`.
    `texte_vers_chemins.py` compte maintenant les traversées et avertit s'il n'y en a
    aucune.

## 11. Fichiers

| fichier | rôle |
|---|---|
| `synth_InO/sta/sdc_macro.tcl` | SDC d'origine d'une macro, d'après le cœur estimé |
| `synth_InO/sta/sdc_traversees.tcl` | traversées des SDC d'origine |
| `pnr_InO/vues_macros.sh` | vues d'une macro routée : LEF, `.lib`, netlist, SPEF |
| `assemblage/lire.tcl`, `sta_assemblage.tcl` | STA d'assemblage |
| `assemblage/fils.py` | fils du sommet estimés d'après un plan (avant l'assemblage routé) |
| `assemblage/releve_chemins.tcl` (+ `texte_vers_chemins.py`) | relevé des chemins |
| `assemblage/latence_macros.tcl`, `latences_macros.sh` | insertions internes L |
| `assemblage/rebudgeter.py` | g, τ, SDC rebudgétés |
| `assemblage/verifier_budgets.py` | contrôle des SDC écrits |
| `pnr_InO/outils/config_run.py` | configuration d'un run LibreLane retrouvée |

Commandes : `assemblage/LISEZMOI.md`, section « Rebudgétage des SDC de macros ».
