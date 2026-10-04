#!/bin/bash
#	Reconstruit les vecteurs du test N3_TAHX_1 (DIS_BONJOUR).
#	  generer.sh <dépôt du compilateur> <dépôt eXecutor>
ICI=$(cd "$(dirname "$0")" && pwd)
exec "$ICI/../commun/n3_generer.sh" "$1" "$2" DIS_BONJOUR "$ICI"
