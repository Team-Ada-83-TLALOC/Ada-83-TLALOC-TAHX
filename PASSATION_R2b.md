# TAHX_1 — fiche de passation R2b (octobre 2026)

À joindre en début de nouvelle session, avec le dépôt TAHX à jour (commit « R2b étroits » ou suivant).

## État de la machine

- TAHX_1 exécute les programmes N3 exactement comme tx_run : sortie, code de sortie, et **trace pas à pas** (option `-x` de tx_run, comparée par `tests/commun/N3_PLATEFORME.vhd`).
- DIS_BONJOUR : 16 190 cycles au premier assemblage → **4 907 cycles** (IPC 0,15 → 0,51).
- Les optimisations faites, dans l'ordre : cache de données à chemin rapide multi-ports, LINK/UNLINK hors de la tête, blocs par mots de 8 octets, rangements sans sondage, adresse et donnée des rangements séparées, fin de la règle des écrivains (règle V8 des cellules de calcul), fenêtre de pile circulaire R2a, R2b points 1, 2 et 3a.
- Compteurs de performance : `perf.txt` dans `tests/travail/N3_xxx/` (temps en tête par classe d'instruction, raisons d'attente de la LSQ, arrêts du renommage).

## Règles V8 ajoutées (section Piles, [Q17] et [Q18])

1. **Cellules de calcul** : une cellule empilée et pas encore dépilée (ni passée sous DSP) n'est écrite par aucun accès calculé (rangement B lvl = 1111, rangement C, blocs, EXC_MACH).
2. **Au-dessus de DSP** : aucun accès, ni lecture ni écriture ; UNLINK et UNLINKR ne font pas remonter DSP.
3. Mesure (tx_run, TLALOC compilant float_test.adb, 68 M instructions) : 0 violation de l'une ou l'autre. `tx_run -v` vérifie les deux règles.

## Renommage (K1b_RENAME_DISPATCH) : où en est R2

- **Fenêtre circulaire de 64 mots** (`STACK_CACHE_WORDS`) : entrée (a / 8) mod 64, adresse gardée, une seule comparaison.
- **Chargements directs de 8 octets** (B, lvl 0..14, alignés, au plus DSP) d'une cellule en fenêtre : servis par son registre, sans exécution.
- **Accès directs étroits** (3a) : lecture → SBFXI/UBFXI sur le registre de la cellule ; écriture → BFII, dont la destination devient le registre de la cellule. Classe ISSUE_INTEGER, sans accès mémoire.
- **Copies** (points 1 et 2) : opérations sur la fenêtre gardées par instruction (`robinfo.ops`, 8 au plus) ; fenêtre retirée `cwin` rejouée au retrait ; une copie par point de reprise ; les reprises rétablissent la copie ou la fenêtre retirée ; les invalidations (STACK_INVALIDATE, maintenance) touchent toutes les copies.
- **Libération d'un registre** : quatre comptes nuls — fenêtre spéculative (`mapcnt`), fenêtre retirée (`mapcnt_c`), copies (`mapcnt_k`), installations en attente (`mapcnt_p` : DUP, OVER, chargement servi installent un registre existant au retrait).
- **LINK** oublie les correspondances de la zone qu'il alloue.
- **Toujours en écriture immédiate** : un SPILL par push. En écriture immédiate, une copie mal choisie à une reprise ne fausse aucune valeur : le banc ne peut pas encore prouver la justesse des copies.

## Reste à faire pour R2b

**3b. Écriture différée** (le gain attendu : la LSQ pleine de SPILL cause 2 233 des 2 412 arrêts du renommage sur DIS_BONJOUR ; sur TLALOC, SPILL 37,2 M → 447 000).
- Plus de SPILL au push ; SPILL quand une cellule **vivante** est chassée de la fenêtre (attaché à l'instruction qui la chasse). Une cellule qui meurt par la descente de DSP ne fait aucun SPILL (règle [Q18]).
- Le SPILL d'une écriture étroite convertie (BFII) disparaît aussi.
- Accès directs à cheval sur deux cellules en fenêtre : à traiter (SPILL préalable avec un ordre « le SPILL d'une instruction précède ses propres accès » dans la LSQ, ou autre).
- **Banc du renommage** : tenir une *mémoire physique* écrite seulement par les SPILL (et les rangements), et faire rendre aux FILL la valeur de cette mémoire. Sans cela, un SPILL manquant ou faux ne se voit pas. Interdire aussi ses chargements au-dessus de DSP (aujourd'hui tolérés).
- Mettre l'écriture différée derrière un **générique désactivé par défaut** tant que 4 et 5 manquent.

**4. Maintenance réelle** : `STACK_MAINT` de réécriture d'un intervalle (CTX_SAVE, blocs qui lisent la pile) émet les SPILL des cellules en fenêtre de l'intervalle et attend leur écriture.

**5. Lectures calculées de cellules en fenêtre** (3 sur 68 M dans TLALOC, 45 dans FLOAT_TEST : une routine `LQ` par pointeur sur un paramètre empilé) : vérification en tête contre la fenêtre retirée ; en cas de recouvrement, réécriture des cellules et réexécution de la lecture (reprise sur l'état retiré au pc de l'instruction). Un filtre d'adresse grossier ne convient pas (1,55 M lectures calculées tombent près de la fenêtre).

## Méthode qui a fait ses preuves

- **Plusieurs graines** pour le banc du renommage : deux défauts n'apparaissaient qu'avec certaines (`sed -E "s/(constant SEED_1[^=]*:= )[0-9]+;/\1N;/"` sur une copie). Les lancer deux par deux : une commande ne doit pas dépasser 5 minutes.
- **Erreurs introduites** après chaque changement, sur une copie : un banc doit détecter chacune, sinon il faut le compléter.
- **Mesurer dans tx_run avant de concevoir** (copie instrumentée hors dépôt) : c'est ce qui a fondé les deux règles et dimensionné la fenêtre.
- **Contrôle de cohérence de simulation** dans le renommage (`dbg_map_err`, entre `translate_off` et `translate_on`) : les comptes de registres contre les tables, à chaque cycle.
- Les tests N3 longs (POW1, CASE_ST1, CHK_TEST0, FLOAT_TEST) se lancent en local avec `-j 16`.
