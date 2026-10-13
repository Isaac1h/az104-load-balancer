#!/usr/bin/env bash
#
# cleanup.sh : supprime tout le lab en supprimant le groupe de ressources.
# Les VM, le Load Balancer et l'IP publique sont facturés tant qu'ils existent.
#
# Utilisation : ./scripts/cleanup.sh   (ou RG=mon-groupe ./scripts/cleanup.sh)

set -euo pipefail

RG="${RG:-rg-lab-lb}"

read -r -p "Supprimer le groupe de ressources « $RG » et tout son contenu ? (oui/non) " REPONSE
[[ "$REPONSE" == "oui" ]] || { echo "Annulé."; exit 0; }

az group delete --name "$RG" --yes --no-wait
echo "Suppression lancée en arrière-plan. Suivi : az group show -n $RG --query properties.provisioningState"
