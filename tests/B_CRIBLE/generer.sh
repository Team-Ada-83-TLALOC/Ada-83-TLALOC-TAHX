#!/bin/bash
#	Reconstruit les vecteurs du test B_CRIBLE (B_CRIBLE).
#	  generer.sh <dépôt du compilateur> <dépôt eXecutor>
ICI=$(cd "$(dirname "$0")" && pwd)
exec "$ICI/../commun/n3_generer.sh" "$1" "$2" b_crible "$ICI"
