#!/usr/bin/env bash
#
# setup-azure-native-monitoring.sh
#
# Automates Option 1 from the AKS Monitoring Setup Guide:
#   Azure-native monitoring (Managed Prometheus + Azure Managed Grafana)
#
# Usage:
#   1. Edit the variables in the "CONFIG" section below (or export them
#      as environment variables before running).
#   2. chmod +x setup-azure-native-monitoring.sh
#   3. ./setup-azure-native-monitoring.sh
#
# The script installs prerequisites (Azure CLI, kubectl) if missing, then
# runs Steps 1-4 of Option 1. Steps 5-7 (dashboard import, alert rule
# authoring, final verification) involve portal/UI or org-specific choices
# and are printed as a checklist at the end rather than automated blindly.

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG - edit these or export as env vars before running
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-<your-rg>}"
AKS_NAME="${AKS_NAME:-<your-aks-name>}"
LOCATION="${LOCATION:-<your-region>}"
GRAFANA_NAME="${GRAFANA_NAME:-aks-mon-test-grafana}"

# Optional: set to a Log Analytics workspace resource ID to also enable
# Container Insights logging via the classic "monitoring" addon.
# Leave empty to skip.
LOG_ANALYTICS_WS_ID="${LOG_ANALYTICS_WS_ID:-}"

# Optional but recommended for least-privilege: set to the Azure Monitor
# workspace resource ID (e.g. /subscriptions/.../resourceGroups/.../providers/
# Microsoft.Monitor/accounts/<name>). If left empty, the script falls back
# to granting "Monitoring Reader" at the whole resource-group scope, which
# is broader than necessary.
AZURE_MONITOR_WORKSPACE_ID="${AZURE_MONITOR_WORKSPACE_ID:-}"

# Set to "true" if your tenant/cluster needs the aks-preview extension for
# any of the flags used here. Most current Azure CLI versions don't need this.
INSTALL_AKS_PREVIEW_EXTENSION="${INSTALL_AKS_PREVIEW_EXTENSION:-false}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo -e "\n\033[1;34m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mWARNING: $*\033[0m"; }
die()  { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

on_error() {
  local exit_code=$?
  echo -e "\033[1;31m\nScript failed (exit code $exit_code) at line $BASH_LINENO while running: $BASH_COMMAND\033[0m" >&2
  echo "Re-run after fixing the issue above - the script is safe to re-run (idempotent)." >&2
  exit "$exit_code"
}
trap on_error ERR

require_placeholder_check() {
  local var_name="$1" var_value="$2"
  if [[ "$var_value" == \<*\> ]]; then
    die "$var_name is still set to a placeholder ('$var_value'). Edit the CONFIG section or export $var_name before running."
  fi
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
install_prerequisites() {
  log "Checking prerequisites"

  if ! command -v az >/dev/null 2>&1; then
    log "Azure CLI not found, installing..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  else
    log "Azure CLI already installed: $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo present)"
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    log "kubectl not found, installing via az aks install-cli..."
    az aks install-cli
  else
    log "kubectl already installed: $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1 || echo present)"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      log "jq not found, installing (optional, not required by this script)..."
      sudo apt-get update -y && sudo apt-get install -y jq
    else
      warn "jq not found and sudo isn't available here - skipping. jq isn't required by this script, only helpful for manual debugging."
    fi
  fi

  log "Prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# Step 1: Register required Azure providers
# ---------------------------------------------------------------------------
register_providers() {
  log "Step 1: Registering required Azure resource providers"

  if [[ "$INSTALL_AKS_PREVIEW_EXTENSION" == "true" ]]; then
    log "INSTALL_AKS_PREVIEW_EXTENSION=true, installing/upgrading aks-preview extension"
    az extension add --name aks-preview --upgrade
  fi

  for ns in Microsoft.ContainerService Microsoft.Monitor Microsoft.Dashboard Microsoft.AlertsManagement; do
    az provider register --namespace "$ns"
  done

  log "Waiting for Microsoft.Monitor and Microsoft.Dashboard to finish registering (this can take a few minutes)..."
  for ns in Microsoft.Monitor Microsoft.Dashboard; do
    for i in $(seq 1 30); do
      state=$(az provider show --namespace "$ns" --query registrationState -o tsv)
      echo "  $ns: $state"
      [[ "$state" == "Registered" ]] && break
      sleep 15
    done
  done
}

# ---------------------------------------------------------------------------
# Step 2: Enable monitoring add-ons on AKS
# ---------------------------------------------------------------------------
enable_monitoring_addons() {
  log "Step 2: Enabling Azure Monitor managed Prometheus metrics on AKS"

  require_placeholder_check RESOURCE_GROUP "$RESOURCE_GROUP"
  require_placeholder_check AKS_NAME "$AKS_NAME"

  az aks update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --enable-azure-monitor-metrics

  if [[ -n "$LOG_ANALYTICS_WS_ID" ]]; then
    log "LOG_ANALYTICS_WS_ID provided, enabling Container Insights (logs) addon"
    az aks enable-addons \
      --resource-group "$RESOURCE_GROUP" \
      --name "$AKS_NAME" \
      --addons monitoring \
      --workspace-resource-id "$LOG_ANALYTICS_WS_ID"
  else
    log "LOG_ANALYTICS_WS_ID not set, skipping Container Insights (logs) addon. Set it and re-run if you need Log Analytics integration."
  fi
}

# ---------------------------------------------------------------------------
# Step 3: Create or attach Azure Managed Grafana
# ---------------------------------------------------------------------------
create_grafana() {
  log "Step 3: Creating (or reusing) Azure Managed Grafana instance"

  require_placeholder_check GRAFANA_NAME "$GRAFANA_NAME"
  require_placeholder_check LOCATION "$LOCATION"

  local name_len=${#GRAFANA_NAME}
  if (( name_len < 2 || name_len > 23 )); then
    die "GRAFANA_NAME '$GRAFANA_NAME' is $name_len characters - Azure Managed Grafana workspace names must be 2-23 characters. Shorten it and re-run (e.g. 'aks-mon-test-grafana')."
  fi

  if az grafana show -g "$RESOURCE_GROUP" -n "$GRAFANA_NAME" >/dev/null 2>&1; then
    log "Grafana instance '$GRAFANA_NAME' already exists, reusing it."
  else
    az grafana create \
      --name "$GRAFANA_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION"
  fi

  GRAFANA_ID=$(az grafana show -g "$RESOURCE_GROUP" -n "$GRAFANA_NAME" --query id -o tsv)
  log "Grafana resource ID: $GRAFANA_ID"
}

# ---------------------------------------------------------------------------
# Step 4: Connect Grafana to Azure Monitor workspace (RBAC)
# ---------------------------------------------------------------------------
grant_grafana_access() {
  log "Step 4: Granting Grafana's managed identity 'Monitoring Reader' on the resource group"

  GRAFANA_PRINCIPAL_ID=$(az grafana show -g "$RESOURCE_GROUP" -n "$GRAFANA_NAME" --query identity.principalId -o tsv)

  if [[ -z "$GRAFANA_PRINCIPAL_ID" || "$GRAFANA_PRINCIPAL_ID" == "None" ]]; then
    die "Could not resolve Grafana's managed identity principal ID. Check that the Grafana instance was created successfully."
  fi

  if [[ -n "$AZURE_MONITOR_WORKSPACE_ID" ]]; then
    SCOPE="$AZURE_MONITOR_WORKSPACE_ID"
    log "Assigning 'Monitoring Reader' at Azure Monitor workspace scope (least privilege): $SCOPE"
  else
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
    warn "AZURE_MONITOR_WORKSPACE_ID not set - granting 'Monitoring Reader' at the whole resource-group scope: $SCOPE"
    warn "For production, set AZURE_MONITOR_WORKSPACE_ID to scope this down to just the Azure Monitor workspace."
  fi

  az role assignment create \
    --assignee-object-id "$GRAFANA_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Monitoring Reader" \
    --scope "$SCOPE" \
    || warn "Role assignment failed or already exists - check with 'az role assignment list --assignee $GRAFANA_PRINCIPAL_ID'"
}

# ---------------------------------------------------------------------------
# Remaining manual steps
# ---------------------------------------------------------------------------
print_manual_steps() {
  GRAFANA_ENDPOINT=$(az grafana show -g "$RESOURCE_GROUP" -n "$GRAFANA_NAME" --query properties.endpoint -o tsv 2>/dev/null || echo "<check portal>")

  cat <<EOF

============================================================
  Automated steps complete. Remaining manual steps:
============================================================

Grafana endpoint: ${GRAFANA_ENDPOINT}

Step 5: Import dashboards
  - Open Grafana -> Dashboards -> Import
  - Import Kubernetes/AKS dashboards: cluster overview, node/pod CPU & memory,
    API server latency/errors, workload-level dashboards

Step 6: Alerts
  - Create alert rules in Azure Monitor (recommended) or Grafana alerting for:
      Node NotReady, Pod CrashLoopBackOff, high CPU/memory, disk pressure,
      API server error rate, HPA maxed out, ingress 5xx spike

Step 7: Verify metrics and logs
  - Confirm these metrics appear in Grafana/Azure Monitor:
      node_cpu_seconds_total, kube_pod_status_phase,
      container_memory_working_set_bytes
  - If Log Analytics is enabled, confirm ContainerLogV2 and KubePodInventory
    tables are populating

============================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  install_prerequisites
  az account show >/dev/null 2>&1 || { log "Not logged in to Azure, running 'az login'"; az login; }
  register_providers
  enable_monitoring_addons
  create_grafana
  grant_grafana_access
  print_manual_steps
}

main "$@"
