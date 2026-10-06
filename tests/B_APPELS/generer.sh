#!/bin/bash
#	Reconstruit les vecteurs du test B_APPELS (B_APPELS).
#	  generer.sh <dépôt du compilateur> <dépôt eXecutor>
ICI=$(cd "$(dirname "$0")" && pwd)
exec "$ICI/../commun/n3_generer.sh" "$1" "$2" b_appels "$ICI"
