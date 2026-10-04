#!/bin/bash
#	Reconstruit les vecteurs du test N3_EXC_TEST0 (EXC_TEST0).
#	  generer.sh <dépôt du compilateur> <dépôt eXecutor>
ICI=$(cd "$(dirname "$0")" && pwd)
exec "$ICI/../commun/n3_generer.sh" "$1" "$2" exc_test0 "$ICI"
