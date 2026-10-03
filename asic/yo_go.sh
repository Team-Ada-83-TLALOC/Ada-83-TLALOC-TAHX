#	Analyse GHDL de TAHX_1, dans l'ordre des dépendances.
#	./Z_analyze.sh [93c|08]		(08 par défaut)
STD=${1:-08}

#	Fichiers qui reposent sur un paquetage de VHDL-2008 : sautés en 93c.
#	(Seule liste du dépôt : tests/V0_CABLAGE la relit.)
VHDL2008_SEULEMENT="L4__float64_pkg.vhd L4_FLOAT_UNIT_rtl.vhd"

analyse ()
{
	if [ "$STD" = 93c ] && [[ " $VHDL2008_SEULEMENT " == *" $1 "* ]]; then
		echo "($1 : VHDL-2008 seulement)"
		return 0
	fi
	ghdl analyze --std=$STD "$1"
}
A=analyse


#	Specifications, Definitions

$A ../vhdl/A__TAHX_1_isa.vhd			|| exit 1
#$A A__TAHX_1_isa_table.vhd		|| exit 1

#	UNITE INSTRUCTIONS

$A ../vhdl/I1__fetch_decode_types.vhd		|| exit 1
#$A R__rob_types.vhd			|| exit 1

#$A I1_FETCH_UNIT.vhd			|| exit 1
#$A I1_FETCH_UNIT_rtl.vhd		|| exit 1
$A ../vhdl/I2_FETCH_BYTE_QUEUE.vhd		|| exit 1
$A I2_FETCH_BYTE_QUEUE_banked.vhd		|| exit 1
$A ../vhdl/I2_FETCH_BYTE_QUEUE_rtl.vhd		|| exit 1

LIB="$HOME/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib"

yosys -m ghdl -p "
  ghdl --std=08 FETCH_BYTE_QUEUE BANKED;
  prep -top FETCH_BYTE_QUEUE;
  opt;
  stat -width;
  synth -top FETCH_BYTE_QUEUE -noabc;
  dfflibmap -liberty $LIB;
  abc -liberty $LIB;
  clean;
  stat -liberty $LIB;
" > out1.txt

yosys -m ghdl -p "
  ghdl --std=08 FETCH_BYTE_QUEUE RTL;
  prep -top FETCH_BYTE_QUEUE;
  opt;
  stat -width;
  synth -top FETCH_BYTE_QUEUE -noabc;
  dfflibmap -liberty $LIB;
  abc -liberty $LIB;
  clean;
  stat -liberty $LIB;
" > out2.txt


