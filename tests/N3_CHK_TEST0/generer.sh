#!/bin/bash
#	Reconstruit les vecteurs du test N3_CHK_TEST0 (CHK_TEST0).
#	  generer.sh <dépôt du compilateur> <dépôt eXecutor>
ICI=$(cd "$(dirname "$0")" && pwd)
exec "$ICI/../commun/n3_generer.sh" "$1" "$2" chk_test0 "$ICI"
