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
| `ino_execute` | `ino_execute` | `vhdl_InO/extraire_units.sh` |
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

## Points ouverts

- Les macros utilisent le SDC par défaut de LibreLane (`CLOCK_PERIOD: 100`) : les chemins
  combinatoires entre macros introduits par les paliers V1 à V5 de
  `ETUDE_VITESSE_TAHX_InO.md` n'y sont pas budgétés. À traiter avant de viser 50 MHz.
- Livrables finaux (GDS, LIB) : pas encore suivis ; au-delà de 50 Mo, Git LFS ou les
  « releases » GitHub.
