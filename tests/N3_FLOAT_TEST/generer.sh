#!/bin/bash
#	Reconstruit les vecteurs du test N3_FLOAT_TEST (FLOAT_TEST).
#	  generer.sh <dépôt du compilateur> <dépôt eXecutor>
ICI=$(cd "$(dirname "$0")" && pwd)
exec "$ICI/../commun/n3_generer.sh" "$1" "$2" float_test "$ICI"
