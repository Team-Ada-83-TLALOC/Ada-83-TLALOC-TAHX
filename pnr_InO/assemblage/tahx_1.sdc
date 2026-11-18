# SDC du sommet de TAHX_1 (assemblage des 8 macros, plan v11h), 17 novembre 2026.
# Remplace le SDC generique de LibreLane (PNR_SDC_FILE et SIGNOFF_SDC_FILE de
# config_<plan>.yaml, ecrits par generer_config.py). Lu aussi par OpenSTA seul.
#
# Hypotheses (BUDGET_TIMING.md, lire.tcl de synth_InO/sta/assemblage) :
#  - periode : CLOCK_PERIOD de la configuration (generer_config.py --periode, 27,5 ns) ;
#  - incertitude 0,5 ns en setup, 0,1 ns en hold, comme les SDC des macros ;
#  - pas de derate : les .lib des macros sont deja aux coins lent et rapide, et leurs
#    budgets ont ete faits sans (le SDC generique de l'IHP mettait +-5 % sur toutes les
#    cellules, arcs des macros compris, et 0,25 ns d'incertitude) ;
#  - propagation de l'horloge : laissee au flux (aucune commande ici ; LibreLane propage
#    apres la CTS et garde l'horloge ideale avant).
#
# Ports. TAHX_1 sera un bloc du SoC : ses E/S iront vers la matrice (I_*, D_*) et vers
# le bloc sud-est (signaux de puce), en logique synchrone de la meme horloge, donc avec
# a peu pres la meme latence d'arbre que les macros. Les delais d'E/S sont comptes depuis
# une horloge virtuelle clk_soc de latence de source LAT_SOMMET, l'arrivee de l'horloge
# aux broches d'horloge des macros (run du 16 novembre : 2,35 ns de tampons a l'entree
# de l'arbre, puis 4,80 a 5,75 ns aux macros ; 5,0 retenu). Avant la CTS, l'horloge
# reelle porte la meme latence en latence ideale ; apres, sa latence est celle de
# l'arbre construit, et LAT_SOMMET doit suivre l'equilibrage de l'arbre (§ 4.2 de la
# passation). Sans ce repere, les entrees arrivaient 5 ns trop tot (hold) et les
# sorties partaient 5 ns trop tard (setup) par rapport aux budgets. Valeurs :
#  - entree  -max : IO_FRAC x periode (logique du SoC avant le port) ; -min : ENTREE_MIN
#    (bascule du SoC, sortie au plus tot) ;
#  - sortie  -max : IO_FRAC x periode (logique et setup du SoC apres le port) ; -min : 0 ;
#  - RESET_i : sortie de la bascule de synchronisation du SoC, 1 ns (-max et -min).
# (-reference_pin vers la broche d'horloge de chaque macro serait plus juste, mais fait
# planter l'OpenSTA de developpement du 17 novembre dans Sim::isDisabledCond.)
#
# Exception : RESET_i -> complete_o d'ino_exec_entier -> stack_unit. Arc combinatoire
# de 9,6 ns (masquage de COMPLETE par RESET_i dans les unites entiere, de branchement,
# complexe et le chemin rapide memoire) qui fixait la periode (27,76 ns ; 27,21 sans
# lui). Faux chemin : sous reset, stack_unit (seul consommateur de COMPLETE) ignore
# COMPLETE, son reset synchrone etant prioritaire ; hors reset, COMPLETE ne depend pas
# de RESET_i (les valid viennent de bascules remises a zero). Le RTL est corrige (patch
# du 16 novembre) ; l'exception reste sans effet sur une macro exec_entier refaite
# depuis ce RTL, qui n'a plus l'arc.

proc tahx_env { nom defaut } {
   if { [info exists ::env($nom)] } { return $::env($nom) }
   return $defaut
}

set PERIODE    [tahx_env CLOCK_PERIOD 27.5]
set IO_FRAC    0.3
set ENTREE_MIN 1.0
set LAT_SOMMET 5.0

create_clock -name clk -period $PERIODE [get_ports CLK_i]
create_clock -name clk_soc -period $PERIODE
set_clock_latency $LAT_SOMMET [get_clocks clk]
set_clock_latency -source $LAT_SOMMET [get_clocks clk_soc]
set_clock_uncertainty -setup 0.5 [get_clocks {clk clk_soc}]
set_clock_uncertainty -hold  0.1 [get_clocks {clk clk_soc}]
set_clock_transition [tahx_env CLOCK_TRANSITION_CONSTRAINT 0.15] [get_clocks clk]

set_max_fanout [tahx_env MAX_FANOUT_CONSTRAINT 10] [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
   set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}

set entrees [list]
foreach p [all_inputs] {
   if { [get_full_name $p] ne "CLK_i" } { lappend entrees $p }
}
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X $entrees
set_load 0.02 [all_outputs]

# ---------------------------------------------------------------------------- E/S
# Macro reliee a chaque port (parcours de la liaison synthetisee) :
#   ino_fetch      : I_*, ICACHE_INVALIDATE_i
#   ino_data_cache : D_* (D_SIZE_o et D_WSTRB_o sont des constantes)
#   ino_system     : le reste (HALT_REQ_i et IRQ_PENDING_i vont aussi a stack_unit)
# Les E/S xSPI et I2C viendront avec le RTL du SoC.
set IO [expr { $IO_FRAC * $PERIODE }]
set sorties [all_outputs]
set_input_delay  -max $IO         -clock clk_soc $entrees
set_input_delay  -min $ENTREE_MIN -clock clk_soc $entrees
set_output_delay -max $IO         -clock clk_soc $sorties
set_output_delay -min 0           -clock clk_soc $sorties
set_input_delay 1.0 -clock clk_soc [get_ports RESET_i]

# ------------------------------------------------------------------- exception
# Sans broche trouvee, -through vide etendrait le faux chemin a tout RESET_i : erreur.
set cpl [get_pins -quiet {u_core.u_backend.u_entier/complete_o*}]
if { [llength $cpl] == 0 } {
   error "tahx_1.sdc : aucune broche u_core.u_backend.u_entier/complete_o*"
}
set_false_path -from [get_ports RESET_i] -through $cpl
