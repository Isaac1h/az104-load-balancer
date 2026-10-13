#!/usr/bin/env bash
#
# deploy.sh : déploie le lab « Load Balancer Standard public » (AZ-104).
#
# Architecture déployée :
#   - 1 VNet (10.10.0.0/16) avec 1 sous-réseau web (10.10.1.0/24) protégé par un NSG
#   - 2 VM Ubuntu 24.04 sans IP publique, nginx installé par cloud-init
#   - 1 IP publique Standard statique
#   - 1 Load Balancer Standard : frontal, pool principal, sonde HTTP,
#     règle d'équilibrage 80 vers 80, règle NAT SSH vers vm-web1, règle sortante
#
# Utilisation (Cloud Shell ou poste avec Azure CLI connecté) :
#   ./scripts/deploy.sh
#
# Toutes les valeurs ci-dessous peuvent être surchargées par variable d'environnement :
#   LOCATION=westeurope SSH_SOURCE_IP=203.0.113.10 ./scripts/deploy.sh
#
# SSH_SOURCE_IP : IP publique autorisée à se connecter en SSH via la règle NAT.
#   Laisser vide pour ne pas ouvrir le SSH (la règle NAT existe, mais le NSG bloque).
#   Attention : dans Cloud Shell, l'IP sortante n'est pas celle de ton poste.

set -euo pipefail

# ─── Paramètres ──────────────────────────────────────────────────────────────
RG="${RG:-rg-lab-lb}"
LOCATION="${LOCATION:-francecentral}"

VNET="${VNET:-vnet-lab-lb}"
VNET_PREFIX="${VNET_PREFIX:-10.10.0.0/16}"
SUBNET="${SUBNET:-snet-web}"
SUBNET_PREFIX="${SUBNET_PREFIX:-10.10.1.0/24}"
NSG="${NSG:-nsg-web}"

PIP="${PIP:-pip-lb-web}"
LB="${LB:-lb-web}"
FRONTEND="${FRONTEND:-fe-web}"
POOL="${POOL:-pool-web}"
PROBE="${PROBE:-probe-http}"
RULE="${RULE:-rule-http}"
NAT_RULE="${NAT_RULE:-nat-ssh-vm1}"
NAT_PORT="${NAT_PORT:-50001}"
OUTBOUND_RULE="${OUTBOUND_RULE:-outbound-web}"

VMS=(vm-web1 vm-web2)
VM_SIZE="${VM_SIZE:-Standard_B1s}"
VM_IMAGE="${VM_IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
SSH_SOURCE_IP="${SSH_SOURCE_IP:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT="${SCRIPT_DIR}/cloud-init-web.yaml"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ─── Prérequis ───────────────────────────────────────────────────────────────
command -v az >/dev/null || { echo "Azure CLI introuvable." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "Non connecté : lance « az login »." >&2; exit 1; }
[[ -f "$CLOUD_INIT" ]] || { echo "Fichier cloud-init manquant : $CLOUD_INIT" >&2; exit 1; }

log "Abonnement : $(az account show --query name -o tsv)"

# ─── 1. Groupe de ressources ─────────────────────────────────────────────────
log "Groupe de ressources $RG ($LOCATION)"
az group create --name "$RG" --location "$LOCATION" --output none

# ─── 2. Réseau : VNet, sous-réseau, NSG ──────────────────────────────────────
log "VNet $VNET et sous-réseau $SUBNET"
az network vnet create \
  --resource-group "$RG" --name "$VNET" --location "$LOCATION" \
  --address-prefixes "$VNET_PREFIX" \
  --subnet-name "$SUBNET" --subnet-prefixes "$SUBNET_PREFIX" \
  --output none

log "NSG $NSG"
az network nsg create --resource-group "$RG" --name "$NSG" --location "$LOCATION" --output none

# Un Load Balancer Standard conserve l'IP source du client : pour la VM, la requête
# vient d'Internet, pas du Load Balancer. Le NSG doit donc autoriser Internet sur le port 80.
az network nsg rule create \
  --resource-group "$RG" --nsg-name "$NSG" --name allow-http-internet \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes Internet --destination-port-ranges 80 \
  --output none

# La sonde d'intégrité part de 168.63.129.16 (balise AzureLoadBalancer).
# La règle par défaut AllowAzureLoadBalancerInBound (65001) la couvre déjà ;
# cette règle explicite rend le besoin visible et résiste à un futur « deny all ».
az network nsg rule create \
  --resource-group "$RG" --nsg-name "$NSG" --name allow-http-probe \
  --priority 110 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes AzureLoadBalancer --destination-port-ranges 80 \
  --output none

# Le NSG évalue le trafic après la traduction NAT : le port à autoriser est 22, pas $NAT_PORT.
if [[ -n "$SSH_SOURCE_IP" ]]; then
  log "Ouverture SSH depuis $SSH_SOURCE_IP uniquement"
  az network nsg rule create \
    --resource-group "$RG" --nsg-name "$NSG" --name allow-ssh-admin \
    --priority 120 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "$SSH_SOURCE_IP" --destination-port-ranges 22 \
    --output none
else
  log "SSH_SOURCE_IP vide : pas de règle SSH dans le NSG (accès SSH bloqué)"
fi

# NSG posé sur le sous-réseau plutôt que sur chaque carte réseau :
# une seule politique pour toutes les VM web, y compris celles ajoutées plus tard.
az network vnet subnet update \
  --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET" \
  --network-security-group "$NSG" --output none

# ─── 3. IP publique et Load Balancer ─────────────────────────────────────────
log "IP publique Standard statique $PIP"
az network public-ip create \
  --resource-group "$RG" --name "$PIP" --location "$LOCATION" \
  --sku Standard --allocation-method Static --output none

log "Load Balancer Standard $LB (frontal $FRONTEND, pool $POOL)"
az network lb create \
  --resource-group "$RG" --name "$LB" --location "$LOCATION" \
  --sku Standard --public-ip-address "$PIP" \
  --frontend-ip-name "$FRONTEND" --backend-pool-name "$POOL" \
  --output none

log "Sonde d'intégrité HTTP $PROBE (port 80, chemin /)"
# Une sonde HTTP vérifie que nginx répond 200, pas seulement que le port est ouvert :
# un service planté avec le port encore en écoute serait vu sain par une sonde TCP.
az network lb probe create \
  --resource-group "$RG" --lb-name "$LB" --name "$PROBE" \
  --protocol Http --port 80 --path / --interval 15 \
  --output none

log "Règle d'équilibrage $RULE (TCP 80 vers 80)"
# --disable-outbound-snat : la sortie Internet des VM est confiée à la règle sortante
# explicite plus bas, plutôt qu'à une SNAT implicite liée à la règle d'entrée.
az network lb rule create \
  --resource-group "$RG" --lb-name "$LB" --name "$RULE" \
  --protocol Tcp --frontend-port 80 --backend-port 80 \
  --frontend-ip-name "$FRONTEND" --backend-pool-name "$POOL" \
  --probe-name "$PROBE" --idle-timeout 4 --disable-outbound-snat true \
  --output none

log "Règle NAT entrante $NAT_RULE (TCP $NAT_PORT vers 22 sur vm-web1)"
az network lb inbound-nat-rule create \
  --resource-group "$RG" --lb-name "$LB" --name "$NAT_RULE" \
  --protocol Tcp --frontend-port "$NAT_PORT" --backend-port 22 \
  --frontend-ip-name "$FRONTEND" --output none

log "Règle sortante $OUTBOUND_RULE"
# Les VM n'ont pas d'IP publique : sans sortie explicite, cloud-init ne pourrait pas
# télécharger nginx. La règle sortante fait sortir le pool par l'IP du Load Balancer.
az network lb outbound-rule create \
  --resource-group "$RG" --lb-name "$LB" --name "$OUTBOUND_RULE" \
  --frontend-ip-configs "$FRONTEND" --address-pool "$POOL" \
  --protocol All --idle-timeout 4 --outbound-ports 10000 \
  --output none

# ─── 4. Cartes réseau et VM ──────────────────────────────────────────────────
for VM in "${VMS[@]}"; do
  NIC="${VM}VMNic"   # même nom que celui généré par « az vm create » dans le lab
  log "Carte réseau $NIC (pool $POOL, sans IP publique)"

  NIC_ARGS=(
    --resource-group "$RG" --name "$NIC" --location "$LOCATION"
    --vnet-name "$VNET" --subnet "$SUBNET"
    --lb-name "$LB" --lb-address-pools "$POOL"
  )
  # Seule vm-web1 est rattachée à la règle NAT SSH.
  [[ "$VM" == "${VMS[0]}" ]] && NIC_ARGS+=(--lb-inbound-nat-rules "$NAT_RULE")
  az network nic create "${NIC_ARGS[@]}" --output none

  log "VM $VM ($VM_SIZE, Ubuntu 24.04, nginx par cloud-init)"
  az vm create \
    --resource-group "$RG" --name "$VM" --location "$LOCATION" \
    --image "$VM_IMAGE" --size "$VM_SIZE" \
    --nics "$NIC" \
    --admin-username "$ADMIN_USER" --generate-ssh-keys \
    --custom-data "$CLOUD_INIT" \
    --output none
done

# ─── 5. Résumé ───────────────────────────────────────────────────────────────
LB_IP="$(az network public-ip show --resource-group "$RG" --name "$PIP" --query ipAddress -o tsv)"

log "Déploiement terminé"
cat <<EOF

IP publique du Load Balancer : $LB_IP

Tester l'équilibrage (une nouvelle connexion TCP par requête) :
  for i in \$(seq 1 10); do curl -s http://$LB_IP | grep -o 'vm-web[0-9]'; done

Tester la bascule :
  az vm stop -g $RG -n ${VMS[0]}      # puis relancer la boucle curl
  az vm start -g $RG -n ${VMS[0]}

SSH vers ${VMS[0]} via la règle NAT (si SSH_SOURCE_IP était renseigné) :
  ssh -p $NAT_PORT $ADMIN_USER@$LB_IP

cloud-init peut prendre 1 à 2 minutes après la création des VM avant que nginx réponde.
Pour tout supprimer : ./scripts/cleanup.sh
EOF
