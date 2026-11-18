# SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
# SPDX-License-Identifier: GPL-3.0-or-later
#
# PDN_CFG de l'assemblage de TAHX_1 avec les macros alimentees par leurs bords
# (option B de la passation du 18 novembre, § 4 ; faisabilite : outils/bords_alim.py).
#
# 1. Grille du sommet : celle de LibreLane, telle quelle (common/pdn_cfg.tcl : Metal4
#    vertical, TopMetal1 horizontal, rails Metal1 ; coupee autour des macros au halo
#    PDN_HORIZONTAL_HALO / PDN_VERTICAL_HALO).
# 2. Apres pdngen, un PEIGNE de chaque cote gauche et droit de chaque macro, dans le
#    halo :
#
#        coeur | halo                                 | macro
#              |   ext.      rail ext.       rail     |
#   TM1 ===================  ext   |          |       |
#              |          | ===== stub ============== |=== bande TM1 (VPWR)
#              |          |   +   |  stub ============|=== bande TM1 (VGND)
#   TM1 =================== ext ==|===+       |       |
#              |  exterieur        interieur          |
#              |  (Metal4)         (Metal4)           |
#
#    - deux rails Metal4 verticaux paralleles au bord (un par net) ;
#    - chaque bande TopMetal1 de la macro (broche VPWR / VGND du LEF qui s'arrete pres
#      du bord) est prolongee jusqu'a son rail (stub), TopVia1 sur le rail ;
#    - chaque bande TopMetal1 de la grille du sommet arretee au halo est prolongee
#      jusqu'au rail de son net (attache), TopVia1 sur le rail.
#    Un stub ne croise que le rail de l'autre net (couche differente) ; les attaches
#    du rail exterieur ne croisent rien. Seules les attaches du rail interieur
#    passent la ou sont les stubs du rail exterieur : l'ordre des rails est choisi
#    par cote pour ne perdre aucune attache (pas de 50 um des deux grilles : toutes
#    les attaches d'un cote sont dans la meme situation). Tout nouveau rectangle
#    est verifie (espacement de la couche, recouvrement d'un autre net, autres
#    macros) ; un ecart de moins de l'espacement avec une forme du meme net est
#    comble ; une attache en conflit est omise, un stub en conflit est une erreur.
#    Les zones entre le bout des bandes et le bord de la macro sont libres dans les
#    ODB des macros (bords_alim.py) ; l'OBS des LEF du sommet y est ouvert
#    (generer_config.py --obs peigne).
# Bilan par macro et par cote dans le journal (lignes [PEIGNE]) ; check_power_grid
# (pdn.tcl de LibreLane) verifie ensuite que tout est relie.
#
# Essai hors LibreLane : pnr_InO/outils/essai_peigne/lancer.sh (macros reelles,
# grille factice decalee sur 50 phases ; 18 novembre, OpenROAD de 2022 : aucune
# erreur, au moins 21 attaches par rail, espacements et connexite verifies a part).
#
# Variables : PEIGNE_RAIL_LARGEUR (2,8 um), PEIGNE_RAIL_ECART (2,0), PEIGNE_RAIL_BORD
# (0,5 : du rail interieur au bord de la macro), PEIGNE_PORTEE (30 um : distance au
# bord jusqu'a laquelle une bande de macro est raccordee).

source $::env(SCRIPTS_DIR)/openroad/common/pdn_cfg.tcl

namespace eval ::tahx_peigne {
    variable bilan {}
}

proc ::tahx_peigne::param {nom defaut} {
    if { [info exists ::env($nom)] } { return $::env($nom) }
    return $defaut
}

# distance entre deux rectangles {x1 y1 x2 y2} (0 s'ils se touchent ou se recouvrent)
proc ::tahx_peigne::distance {a b} {
    lassign $a ax1 ay1 ax2 ay2
    lassign $b bx1 by1 bx2 by2
    set dx [expr {max(0, max($bx1 - $ax2, $ax1 - $bx2))}]
    set dy [expr {max(0, max($by1 - $ay2, $ay1 - $by2))}]
    return [expr {sqrt(double($dx) * $dx + double($dy) * $dy)}]
}

# rectangle nouveau {couche net rect} face a une liste de formes :
# -> {} si rien ne gene ; {court <description>} si une forme d'un autre net est trop
# pres ; sinon {proche <rect> ...} : formes du meme net a moins de l'espacement sans
# la toucher (a combler)
proc ::tahx_peigne::conflit {forme formes esp} {
    lassign $forme c n r
    lassign $r x1 y1 x2 y2
    set proches {}
    foreach f $formes {
        lassign $f fc fn fr
        if { $fc ne $c } { continue }
        lassign $fr u1 v1 u2 v2
        # tri rapide
        if { $u1 > $x2 + $esp || $u2 < $x1 - $esp || $v1 > $y2 + $esp || $v2 < $y1 - $esp } { continue }
        set d [distance $r $fr]
        if { $fn eq $n } {
            if { $d > 0 && $d < $esp } { lappend proches $fr }
        } elseif { $d < $esp } {
            return [list court "$c $fn ([join $fr { }])"]
        }
    }
    if { [llength $proches] } { return [concat proche $proches] }
    return {}
}

# rectangle qui comble l'ecart entre deux rectangles du meme net (recouvrement en x
# et ecart en y, ou l'inverse) ; "" s'ils ne se font face que par un coin
proc ::tahx_peigne::comble {a b} {
    lassign $a ax1 ay1 ax2 ay2
    lassign $b bx1 by1 bx2 by2
    set ox1 [expr {max($ax1, $bx1)}]; set ox2 [expr {min($ax2, $bx2)}]
    set oy1 [expr {max($ay1, $by1)}]; set oy2 [expr {min($ay2, $by2)}]
    if { $ox2 > $ox1 } {
        return [list $ox1 [expr {min($ay2, $by2)}] $ox2 [expr {max($ay1, $by1)}]]
    }
    if { $oy2 > $oy1 } {
        return [list [expr {min($ax2, $bx2)}] $oy1 [expr {max($ax1, $bx1)}] $oy2]
    }
    return ""
}

# essai d'un nouveau rectangle : -> {ok {formes a ajouter}} ou {ko description}
proc ::tahx_peigne::essayer {forme formes esp} {
    set c [conflit $forme $formes $esp]
    if { $c eq "" } { return [list ok [list $forme]] }
    if { [lindex $c 0] eq "court" } { return [list ko [lindex $c 1]] }
    lassign $forme couche n r
    set ajout [list $forme]
    foreach fr [lrange $c 1 end] {
        set k [comble $r $fr]
        if { $k eq "" } { return [list ko "$couche $n : coin a moins de l'espacement"] }
        set f [list $couche $n $k]
        if { [lindex [conflit $f $formes $esp] 0] eq "court" } { return [list ko "$couche $n : comblement impossible"] }
        lappend ajout $f
    }
    return [list ok $ajout]
}

# geometrie d'une broche de macro, du repere du maitre a celui de la puce
proc ::tahx_peigne::placer {inst r} {
    set bb [$inst getBBox]
    set bx1 [$bb xMin]; set by1 [$bb yMin]; set bx2 [$bb xMax]; set by2 [$bb yMax]
    lassign $r x1 y1 x2 y2
    switch -- [$inst getOrient] {
        R0   { return [list [expr {$bx1 + $x1}] [expr {$by1 + $y1}] [expr {$bx1 + $x2}] [expr {$by1 + $y2}]] }
        MY   { return [list [expr {$bx2 - $x2}] [expr {$by1 + $y1}] [expr {$bx2 - $x1}] [expr {$by1 + $y2}]] }
        MX   { return [list [expr {$bx1 + $x1}] [expr {$by2 - $y2}] [expr {$bx1 + $x2}] [expr {$by2 - $y1}]] }
        R180 { return [list [expr {$bx2 - $x2}] [expr {$by2 - $y2}] [expr {$bx2 - $x1}] [expr {$by2 - $y1}]] }
        default { error "orientation [$inst getOrient] de [$inst getName] non traitee" }
    }
}

# TopVia1 : via Metal4 -> TopMetal1 a une coupure, et demi-cotes de ses plots.
# Par ordre de preference : PEIGNE_VIA, TopVia1EWNS du PDK, puis le plus petit plot
# TopMetal1 parmi les vias a une coupure. Un OpenROAD recent range aussi dans la techno
# les VIA des LEF de macros (ino_decode_queue_via4_5_1000_2000_...), a ecarter : leur
# plot TopMetal1 de 2 um ne tient pas sur une bande de 1,64 um (essai du 18 novembre).
proc ::tahx_peigne::via_tm1 {tech m4 tm1} {
    set voulu [param PEIGNE_VIA TopVia1EWNS]
    set meilleur ""
    foreach v [$tech getVias] {
        if { [$v getBottomLayer] ne $m4 || [$v getTopLayer] ne $tm1 } { continue }
        set h4 ""; set ht ""; set hc 0; set ncoup 0
        foreach b [$v getBoxes] {
            set l [$b getTechLayer]
            set dx [expr {([$b xMax] - [$b xMin]) / 2}]
            set dy [expr {([$b yMax] - [$b yMin]) / 2}]
            if { $l eq $m4 } { set h4 [list $dx $dy] } elseif { $l eq $tm1 } { set ht [list $dx $dy] } else { set hc $dx; incr ncoup }
        }
        if { $ncoup != 1 || $h4 eq "" || $ht eq "" } { continue }
        set c [list $v $h4 $ht $hc]
        if { [$v getName] eq $voulu } { set meilleur $c ; break }
        set taille [expr {max([lindex $ht 0], [lindex $ht 1])}]
        if { $meilleur eq "" || $taille < max([lindex $meilleur 2 0], [lindex $meilleur 2 1]) } {
            set meilleur $c
        }
    }
    if { $meilleur eq "" } { error "pas de via Metal4 -> TopMetal1 a une coupure dans la techno" }
    if { [[lindex $meilleur 0] getName] ne $voulu } {
        puts "\[PEIGNE\] ATTENTION via $voulu absent, pris : [[lindex $meilleur 0] getName]"
    }
    return $meilleur
}

proc ::tahx_peigne::construire {} {
    variable bilan
    set block [ord::get_db_block]
    set tech [[ord::get_db] getTech]
    set u [$tech getDbUnitsPerMicron]
    set tm1 [$tech findLayer TopMetal1]
    set m4 [$tech findLayer Metal4]
    set esp_tm1 [$tm1 getSpacing]
    set esp_m4 [$m4 getSpacing]
    lassign [via_tm1 $tech $m4 $tm1] via h4 ht hc
    set pas_via [expr {2 * $hc + [[$tech findLayer TopVia1] getSpacing]}]

    set halo [expr {round([param PDN_HORIZONTAL_HALO 10] * $u)}]
    set rl [expr {round([param PEIGNE_RAIL_LARGEUR 2.8] * $u)}]
    set re [expr {round([param PEIGNE_RAIL_ECART 2.0] * $u)}]
    set rb [expr {round([param PEIGNE_RAIL_BORD 0.5] * $u)}]
    set portee [expr {round([param PEIGNE_PORTEE 30] * $u)}]
    set ext_max [expr {$rb + 2 * $rl + $re}]
    if { $ext_max + $esp_tm1 > $halo } {
        error "peigne : [expr {($ext_max + $esp_tm1) / double($u)}] um ne tiennent pas dans le halo de [expr {$halo / double($u)}] um"
    }

    # formes existantes : grille du sommet (hors vias), puis les rectangles ajoutes
    set formes {}
    set nets_alim {}
    foreach net [$block getNets] {
        if { ![$net isSpecial] } { continue }
        foreach sw [$net getSWires] {
            foreach b [$sw getWires] {
                if { [$b isVia] } { continue }
                set l [$b getTechLayer]
                if { $l ne $tm1 && $l ne $m4 } { continue }
                lappend formes [list [$l getName] [$net getName] [list [$b xMin] [$b yMin] [$b xMax] [$b yMax]]]
            }
        }
    }
    set macros {}
    foreach inst [$block getInsts] {
        if { [[$inst getMaster] isBlock] } { lappend macros $inst }
    }
    set erreurs 0
    set ajouts {}

    foreach inst $macros {
        set bb [$inst getBBox]
        set X1 [$bb xMin]; set Y1 [$bb yMin]; set X2 [$bb xMax]; set Y2 [$bb yMax]
        # autres macros : obstacle sur toutes les couches
        set autres {}
        foreach o $macros {
            if { $o eq $inst } { continue }
            set ob [$o getBBox]
            foreach c {TopMetal1 Metal4} {
                lappend autres [list $c "<[$o getName]>" [list [$ob xMin] [$ob yMin] [$ob xMax] [$ob yMax]]]
            }
        }
        # bandes TopMetal1 des broches d'alimentation, par cote : {net y1 y2 x_bout}
        set bandes(G) {}; set bandes(D) {}
        foreach mt [[$inst getMaster] getMTerms] {
            set st [$mt getSigType]
            if { $st ne "POWER" && $st ne "GROUND" } { continue }
            set it [$inst findITerm [$mt getName]]
            if { $it eq "NULL" || [$it getNet] eq "NULL" } {
                puts "\[PEIGNE\] ATTENTION [$inst getName]/[$mt getName] : broche non reliee a un net (PDN_MACRO_CONNECTIONS ?)"
                continue
            }
            set net [[$it getNet] getName]
            lappend nets_alim $net
            foreach mp [$mt getMPins] {
                foreach b [$mp getGeometry] {
                    if { [$b getTechLayer] ne $tm1 } { continue }
                    set r [placer $inst [list [$b xMin] [$b yMin] [$b xMax] [$b yMax]]]
                    lassign $r x1 y1 x2 y2
                    if { $x2 - $x1 < 10 * ($y2 - $y1) } { continue }   ;# pas une bande horizontale
                    if { $x1 - $X1 <= $portee } { lappend bandes(G) [list $net $y1 $y2 $x1] }
                    if { $X2 - $x2 <= $portee } { lappend bandes(D) [list $net $y1 $y2 $x2] }
                }
            }
        }
        foreach cote {G D} {
            if { [llength $bandes($cote)] == 0 } { continue }
            set nets [lsort -unique [lmap b $bandes($cote) {lindex $b 0}]]
            if { [llength $nets] != 2 } {
                puts "\[PEIGNE\] ATTENTION [$inst getName] cote $cote : nets $nets, peigne a deux nets seulement"
                incr erreurs
                continue
            }
            set ry1 [tcl::mathfunc::min {*}[lmap b $bandes($cote) {lindex $b 1}]]
            set ry2 [tcl::mathfunc::max {*}[lmap b $bandes($cote) {lindex $b 2}]]
            # rails : {x1 x2} interieur puis exterieur
            if { $cote eq "G" } {
                set rint [list [expr {$X1 - $rb - $rl}] [expr {$X1 - $rb}]]
                set rext [list [expr {$X1 - $rb - 2 * $rl - $re}] [expr {$X1 - $rb - $rl - $re}]]
            } else {
                set rint [list [expr {$X2 + $rb}] [expr {$X2 + $rb + $rl}]]
                set rext [list [expr {$X2 + $rb + $rl + $re}] [expr {$X2 + $rb + 2 * $rl + $re}]]
            }
            # formes voisines du cote (le reste ne peut pas gener)
            if { $cote eq "G" } {
                set zx1 [expr {$X1 - $halo - 5 * $u}]; set zx2 [expr {$X1 + $portee + $u}]
            } else {
                set zx1 [expr {$X2 - $portee - $u}]; set zx2 [expr {$X2 + $halo + 5 * $u}]
            }
            set zy1 [expr {$ry1 - 5 * $u}]; set zy2 [expr {$ry2 + 5 * $u}]
            set proches {}
            foreach f [concat $formes $autres] {
                lassign [lindex $f 2] x1 y1 x2 y2
                if { $x2 < $zx1 || $x1 > $zx2 || $y2 < $zy1 || $y1 > $zy2 } { continue }
                lappend proches $f
            }
            # attaches candidates : bandes TopMetal1 de la grille arretees au halo
            set cand {}
            foreach f $proches {
                lassign $f c n r
                if { $c ne "TopMetal1" || [lsearch -exact $nets $n] < 0 } { continue }
                lassign $r x1 y1 x2 y2
                if { $y1 < $ry1 || $y2 > $ry2 || $x2 - $x1 < $y2 - $y1 } { continue }
                if { $cote eq "G" && $x2 <= $X1 - $halo + $u && $x2 >= $X1 - $halo - 3 * $u } {
                    lappend cand [list $n $y1 $y2 $x2]
                } elseif { $cote eq "D" && $x1 >= $X2 + $halo - $u && $x1 <= $X2 + $halo + 3 * $u } {
                    lappend cand [list $n $y1 $y2 $x1]
                }
            }
            # les deux ordres des rails ; le meilleur : aucun stub en conflit, puis le
            # plus d'attaches pour le net le moins attache
            set essais {}
            foreach ordre [list $nets [lreverse $nets]] {
                lassign $ordre n_int n_ext
                set rail($n_int) $rint; set rail($n_ext) $rext
                set neuf {}
                set ko {}
                # rails
                foreach n $ordre {
                    lassign $rail($n) a b
                    set f [list Metal4 $n [list $a $ry1 $b $ry2]]
                    lassign [essayer $f $proches $esp_m4] etat res
                    if { $etat ne "ok" } { lappend ko "rail $n : $res" ; continue }
                    lappend neuf [concat [lindex $res 0] rail]
                    foreach k [lrange $res 1 end] { lappend neuf [concat $k comble] }
                }
                # stubs (de la bande de la macro au bord exterieur de son rail)
                foreach b $bandes($cote) {
                    lassign $b n y1 y2 xb
                    lassign $rail($n) a bb_
                    if { $cote eq "G" } { set r [list $a $y1 [expr {$xb + $u}] $y2] } else { set r [list [expr {$xb - $u}] $y1 $bb_ $y2] }
                    set f [list TopMetal1 $n $r]
                    lassign [essayer $f [concat $proches [lmap x $neuf {lrange $x 0 2}]] $esp_tm1] etat res
                    if { $etat ne "ok" } { lappend ko "stub $n y [expr {$y1 / double($u)}] : $res" ; continue }
                    lappend neuf [concat [lindex $res 0] stub]
                    foreach k [lrange $res 1 end] { lappend neuf [concat $k comble] }
                }
                # attaches (du bout de la bande de la grille au bord interieur de son rail)
                set natt($n_int) 0; set natt($n_ext) 0; set nomis 0
                foreach b $cand {
                    lassign $b n y1 y2 xb
                    lassign $rail($n) a bb_
                    if { $cote eq "G" } { set r [list [expr {$xb - $u}] $y1 $bb_ $y2] } else { set r [list $a $y1 [expr {$xb + $u}] $y2] }
                    set f [list TopMetal1 $n $r]
                    lassign [essayer $f [concat $proches [lmap x $neuf {lrange $x 0 2}]] $esp_tm1] etat res
                    if { $etat ne "ok" } {
                        incr nomis
                        continue
                    }
                    lappend neuf [concat [lindex $res 0] attache]
                    foreach k [lrange $res 1 end] { lappend neuf [concat $k comble] }
                    incr natt($n)
                }
                set mini [expr {min($natt($n_int), $natt($n_ext))}]
                lappend essais [list [llength $ko] $mini $ordre $neuf $ko [array get natt] $nomis [array get rail]]
            }
            set essais [lsort -integer -decreasing -index 1 $essais]
            set essais [lsort -integer -increasing -index 0 $essais]
            lassign [lindex $essais 0] nko mini ordre neuf ko natt_l nomis rail_l
            array set natt $natt_l
            array set rail $rail_l
            set ligne "\[PEIGNE\] [$inst getName] [expr {$cote eq {G} ? {gauche} : {droite}}] :\
                [llength $bandes($cote)] bandes, rail interieur [lindex $ordre 0], exterieur [lindex $ordre 1],\
                attaches [lindex $ordre 0] $natt([lindex $ordre 0]) / [lindex $ordre 1] $natt([lindex $ordre 1])\
                (omises $nomis)"
            puts $ligne
            lappend bilan $ligne
            if { $nko > 0 } {
                foreach k [lrange $ko 0 9] { puts "\[PEIGNE\]    ERREUR $k" }
                incr erreurs
                continue
            }
            if { $mini == 0 } {
                puts "\[PEIGNE\]    ERREUR : un rail sans attache a la grille du sommet"
                incr erreurs
            }
            foreach f $neuf { lappend ajouts [concat $f [list $rail([lindex $f 1])]] }
            # les rectangles ajoutes comptent pour les cotes suivants
            foreach f $neuf { lappend formes [lrange $f 0 2] }
        }
    }

    # ecriture : rectangles et vias (TopMetal1 d'un net sur le rail Metal4 du meme net)
    set nv 0; set nr 0
    foreach net [lsort -unique $nets_alim] {
        set dbnet [$block findNet $net]
        set sw [odb::dbSWire_create $dbnet ROUTED]
        foreach f $ajouts {
            lassign $f c n r genre rx
            if { $n ne $net } { continue }
            lassign $r x1 y1 x2 y2
            odb::dbSBox_create $sw [$tech findLayer $c] $x1 $y1 $x2 $y2 STRIPE
            incr nr
            if { $genre eq "rail" || $genre eq "comble" } { continue }
            # vias : plots Metal4 dans le rail, plots TopMetal1 dans la bande
            lassign $rx a b
            set xmin [expr {max($a + [lindex $h4 0], $x1 + [lindex $ht 0])}]
            set xmax [expr {min($b - [lindex $h4 0], $x2 - [lindex $ht 0])}]
            set yc [expr {($y1 + $y2) / 2}]
            if { $y2 - $y1 < 2 * [lindex $ht 1] || $xmax < $xmin } {
                puts "\[PEIGNE\] ERREUR via impossible $net ([join $r { }])"
                incr erreurs
                continue
            }
            set k [expr {int(($xmax - $xmin) / $pas_via) + 1}]
            set x0 [expr {($xmin + $xmax - ($k - 1) * $pas_via) / 2}]
            for {set i 0} {$i < $k} {incr i} {
                odb::dbSBox_create $sw $via [expr {$x0 + $i * $pas_via}] $yc STRIPE
                incr nv
            }
        }
    }
    puts "\[PEIGNE\] [llength $macros] macros : $nr rectangles, $nv coupures TopVia1 ([$via getName]), $erreurs erreur(s)"
    if { $erreurs > 0 } {
        error "peigne : $erreurs erreur(s), voir les lignes \[PEIGNE\]"
    }
}

# pdngen de pdn.tcl : la grille, puis les peignes
if { [info commands ::tahx_peigne::pdngen_orig] eq "" } {
    rename ::pdngen ::tahx_peigne::pdngen_orig
    proc ::pdngen {args} {
        ::tahx_peigne::pdngen_orig {*}$args
        ::tahx_peigne::construire
    }
}
