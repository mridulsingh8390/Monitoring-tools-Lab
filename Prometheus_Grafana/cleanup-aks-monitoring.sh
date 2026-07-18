#!/usr/bin/env bash
#
# cleanup-aks-monitoring.sh
#
# Deletes everything created by the AKS monitoring setup scripts:
# the resource group (AKS cluster, Managed Grafana, etc.), and optionally
# the auto-created default Azure Monitor workspace resource group.
# Also removes the local kubeconfig entry for the deleted cluster.
#
# Usage:
#   export RESOURCE_GROUP="aks-monitoring-test-rg"
#   export AKS_NAME="aks-monitoring-test-cluster"
#   chmod +x cleanup-aks-monitoring.sh
#   ./cleanup-aks-monitoring.sh

set -euo pipefail
export MSYS_NO_PATHCONV=1

RESOURCE_GROUP="${RESOURCE_GROUP:-aks-monitoring-test-rg}"
AKS_NAME="${AKS_NAME:-aks-monitoring-test-cluster}"

log()  { echo -e "\n\033[1;34m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mWARNING: $*\033[0m"; }
die()  { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run 'az login' first."

echo "============================================================"
echo "  This will PERMANENTLY DELETE the resource group:"
echo "    ${RESOURCE_GROUP}"
echo "  and everything in it (AKS cluster, Managed Grafana, disks, etc.)"
echo "============================================================"
read -rp "Type the resource group name to confirm: " CONFIRM

if [[ "$CONFIRM" != "$RESOURCE_GROUP" ]]; then
  die "Confirmation did not match '${RESOURCE_GROUP}'. Nothing was deleted."
fi

if ! az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
  warn "Resource group '$RESOURCE_GROUP' not found - nothing to delete there."
else
  log "Deleting resource group '$RESOURCE_GROUP' (this runs in the background)..."
  az group delete --name "$RESOURCE_GROUP" --yes --no-wait
  log "Delete started. Check progress with: az group show --name $RESOURCE_GROUP"
fi

log "Removing local kubeconfig entries for '$AKS_NAME'"
kubectl config delete-context "$AKS_NAME" 2>/dev/null || true
kubectl config delete-cluster "$AKS_NAME" 2>/dev/null || true
kubectl config delete-user "clusterUser_${RESOURCE_GROUP}_${AKS_NAME}" 2>/dev/null || true

echo
echo "============================================================"
echo "  Also delete the auto-created default Azure Monitor workspace?"
echo "  (only if nothing else in your subscription uses it)"
echo "============================================================"
read -rp "Delete DefaultResourceGroup-<region> too? [y/N]: " DELETE_DEFAULT_RG

if [[ "$DELETE_DEFAULT_RG" =~ ^[Yy] ]]; then
  read -rp "Enter the default resource group name (e.g. DefaultResourceGroup-centralindia): " DEFAULT_RG
  if [[ -n "$DEFAULT_RG" ]] && az group show --name "$DEFAULT_RG" >/dev/null 2>&1; then
    log "Deleting '$DEFAULT_RG'..."
    az group delete --name "$DEFAULT_RG" --yes --no-wait
    log "Delete started. Check progress with: az group show --name $DEFAULT_RG"
  else
    warn "Resource group '$DEFAULT_RG' not found - skipping."
  fi
else
  log "Skipping default resource group. Delete it manually later if you're sure nothing else uses it."
fi

log "Cleanup complete. Deletions run in the background - check the Azure portal or 'az group list -o table' to confirm when they finish."
