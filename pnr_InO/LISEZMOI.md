# pnr_InO — macros IHP SG13 (LibreLane)

Une macro par répertoire de `macros/` : `config.yaml`, `pin_order.cfg`, scripts propres
(placement des SRAM, DRC…), `src/` (Verilog extrait du RTL, SRAM en boîtes noires) et,
le cas échéant, le LEF abstrait. Les `runs/` de LibreLane et les répertoires de DRC ne
sont pas suivis par git (`.gitignore`) ; ce qui fait foi d'un run est son résumé.

| macro | module de tête | extraction |
|---|---|---|
| `stack_unit_16_8` | `stack_unit_16_8` | `vhdl_InO/extraire_units.sh` |
| `decode_queue` | `ino_decode_queue` | `vhdl_InO/extraire_units.sh` |
| `ino_decode_predict` | `ino_decode_predict` | `vhdl_InO/extraire_units.sh` |
| `ino_exec_entier` | `ino_exec_entier` (entier, mémoire, co-pile, BLOCK, EXC_MACH) | `vhdl_InO/extraire_units.sh` |
| `ino_exec_arith` | `ino_exec_arith` (MUL/DIV, flottant, FEXP) | `vhdl_InO/extraire_units.sh` |
| `ino_system` | `ino_system` | `vhdl_InO/extraire_units.sh` |
| `ino_data_cache` | `ino_data_cache` (6 SRAM) | `vhdl_InO/extraire_data_cache.sh` |
| `ino_fetch` | `ino_fetch` (SRAM 2P) | `vhdl_InO/extraire_ino_fetch.sh` |

## Cycle de travail

1. **Où en est-on ?** `pnr_InO/etat_macros.sh` élabore le RTL courant, extrait toutes les
   macros dans un répertoire temporaire et compare leur structure (« stat » Yosys après
   flatten) à celle de `src/` : « à jour » ou « PÉRIMÉE ». Une minute environ. Le texte du
   Verilog peut différer d'une élaboration à l'autre sans que la macro change.
2. **Avant un run** : `pnr_InO/etat_macros.sh --extraire <macro>` (ou `tout`) réécrit
   `src/` depuis le RTL courant et écrit `PROVENANCE.txt` (commit du RTL, outils,
   empreinte). Une macro déjà à jour garde son `src/` ; seule sa provenance est écrite.
3. **Run LibreLane** dans le répertoire de la macro, comme avant.
4. **Après le run** : `pnr_InO/resume_run.py pnr_InO/macros/<macro>` écrit
   `RESULTATS.txt` (marges setup/hold par coin, surfaces, utilisation, DRC, antennes) à
   partir de `runs/<dernier>/final/metrics.json`. On committe `PROVENANCE.txt` et
   `RESULTATS.txt` avec les changements de configuration.

Variable utile : `GHDL_PREFIX` (bibliothèques VHDL de GHDL) si le greffon `ghdl` de
Yosys ne les trouve pas seul, par exemple `GHDL_PREFIX=/usr/lib/ghdl/mcode/vhdl`.

## Placement des broches : `outils/position_broches.py`

Calcule sans lancer le flux où `OpenROAD.CustomIOPlacement` (`io_place.py` de LibreLane) mettra chaque broche, et fait l'inverse. Le modèle retrouve exactement les 8 031 broches des huit LEF de `vues/` (`--verifier-lef`).

```
outils/position_broches.py macros/ino_data_cache                # positions par groupe (um)
outils/position_broches.py macros/ino_data_cache --detail       # ... et par bit
outils/position_broches.py macros/ino_data_cache --cfg essai.cfg --lef essai.lef
outils/position_broches.py macros/ino_data_cache --viser souhaits.txt --sortie pin_order_25ns.cfg
```

Comment `io_place.py` place les broches d'un côté :
- **Emplacements.** Une piste sur deux de la couche de broches : Metal2 au pas de 0,96 µm sur N et S, Metal3 au pas de 0,84 µm sur E et W. La première piste est à un pas du bord. On obtient S emplacements.
- **Pas commun.** n = bits réels + somme des `$N`, puis t = ⌊S/n⌋. Une broche avance de t emplacements, un `$N` de N·t : `$N` n'est donc **pas** une distance fixe.
- **Centrage.** Les u = S − (t(n−1)+1) emplacements libres sont répartis par moitié aux deux bouts. Ajouter quelques broches sur un côté déplace donc tout le côté : en passant `stack_rsp_o` au nord, le bloc est de `ino_data_cache` monte de 29 µm.
- **Sens.** Croissant : de gauche à droite sur N et S, de bas en haut sur E et W. `#NR`, `#ER`… inversent la liste, `$` compris.
- **Piège.** Si n = S exactement avec des `$`, `io_place.py` s'arrête en erreur d'assertion.

Mode inverse (`--viser`) :
- **Fichier de souhaits.** La syntaxe du cfg, plus `> 386.0` (le groupe commence à 386 µm, en comptant depuis l'origine du côté), `>+20` (20 µm après le groupe précédent) et `%pas 2` (une broche tous les deux emplacements).
- **Calcul.** Le cfg produit vise n = S − 1, de sorte que t vaut 1 (ou le pas demandé) et que chaque `$N` vaut exactement N emplacements. Le cfg est relu et replacé pour contrôle.
- **Essai sans relance.** `--lef` écrit un LEF minimal, lisible par `canaux.py` et `fils.py`, pour juger un placement de broches (congestion, fils du sommet) avant de relancer la macro.

## Points ouverts

- Les macros utilisent le SDC par défaut de LibreLane (`CLOCK_PERIOD: 100`) : les chemins
  combinatoires entre macros introduits par les paliers V1 à V5 de
  `ETUDE_VITESSE_TAHX_InO.md` n'y sont pas budgétés. À traiter avant de viser 50 MHz.
- Livrables finaux (GDS, LIB) : pas encore suivis ; au-delà de 50 Mo, Git LFS ou les
  « releases » GitHub.
