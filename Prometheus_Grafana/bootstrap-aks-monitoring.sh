#!/usr/bin/env bash
#
# bootstrap-aks-monitoring.sh
#
# Interactive entry point for AKS monitoring setup. Prompts for the common
# config values, lets you pick Option 1 (Azure-native) or Option 2
# (self-managed on this VM), then execs the matching script with the
# right environment variables set.
#
# Expects setup-azure-native-monitoring.sh and setup-selfmanaged-monitoring.sh
# to be present in the same directory as this script.
#
# Usage:
#   chmod +x bootstrap-aks-monitoring.sh
#   ./bootstrap-aks-monitoring.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AZURE_NATIVE_SCRIPT="$SCRIPT_DIR/setup-azure-native-monitoring.sh"
SELFMANAGED_SCRIPT="$SCRIPT_DIR/setup-selfmanaged-monitoring.sh"

log()  { echo -e "\n\033[1;34m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mWARNING: $*\033[0m"; }
die()  { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

[[ -f "$AZURE_NATIVE_SCRIPT" ]] || die "Missing $AZURE_NATIVE_SCRIPT - place it next to this script."
[[ -f "$SELFMANAGED_SCRIPT" ]] || die "Missing $SELFMANAGED_SCRIPT - place it next to this script."

prompt() {
  # prompt <var_name> <question> [default]
  local var_name="$1" question="$2" default="${3:-}"
  local input
  if [[ -n "$default" ]]; then
    read -rp "$question [$default]: " input
    input="${input:-$default}"
  else
    while true; do
      read -rp "$question: " input
      [[ -n "$input" ]] && break
      echo "This value is required."
    done
  fi
  printf -v "$var_name" '%s' "$input"
}

prompt_yes_no() {
  # prompt_yes_no <var_name> <question> <default: y|n>
  local var_name="$1" question="$2" default="$3"
  local input
  read -rp "$question [$default]: " input
  input="${input:-$default}"
  if [[ "$input" =~ ^[Yy] ]]; then
    printf -v "$var_name" 'true'
  else
    printf -v "$var_name" 'false'
  fi
}

echo "============================================================"
echo "  AKS Monitoring Bootstrap"
echo "============================================================"

# ---------------------------------------------------------------------------
# Common config
# ---------------------------------------------------------------------------
prompt RESOURCE_GROUP  "Azure resource group name"
prompt AKS_NAME        "AKS cluster name"

# ---------------------------------------------------------------------------
# Choose option
# ---------------------------------------------------------------------------
echo
echo "Which setup do you want to run?"
echo "  1) Azure-native (Managed Prometheus + Azure Managed Grafana) - recommended"
echo "  2) Self-managed on this VM (Prometheus + Grafana via kube-prometheus-stack, optional Loki)"
CHOICE=""
while [[ "$CHOICE" != "1" && "$CHOICE" != "2" ]]; do
  read -rp "Enter 1 or 2: " CHOICE
done

export RESOURCE_GROUP AKS_NAME

if [[ "$CHOICE" == "1" ]]; then
  # -------------------------------------------------------------------------
  # Option 1: Azure-native
  # -------------------------------------------------------------------------
  prompt LOCATION      "Azure region (e.g. eastus)"
  prompt GRAFANA_NAME  "Azure Managed Grafana instance name"

  read -rp "Log Analytics workspace resource ID for Container Insights logs (leave blank to skip): " LOG_ANALYTICS_WS_ID
  read -rp "Azure Monitor workspace resource ID for least-privilege RBAC scope (leave blank to use resource-group scope): " AZURE_MONITOR_WORKSPACE_ID

  export LOCATION GRAFANA_NAME LOG_ANALYTICS_WS_ID AZURE_MONITOR_WORKSPACE_ID

  log "Launching setup-azure-native-monitoring.sh"
  exec "$AZURE_NATIVE_SCRIPT"

else
  # -------------------------------------------------------------------------
  # Option 2: Self-managed
  # -------------------------------------------------------------------------
  prompt SUBSCRIPTION_ID "Azure subscription ID"

  read -rsp "Grafana admin password (leave blank to use insecure default - not recommended): " GRAFANA_ADMIN_PASSWORD
  echo
  GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-ChangeMeStrongPassword!}"

  echo
  echo "Grafana service exposure:"
  echo "  1) LoadBalancer (public IP, quick to access, no auth in front - dev/test only)"
  echo "  2) ClusterIP (private, access via kubectl port-forward - recommended for production)"
  SVC_CHOICE=""
  while [[ "$SVC_CHOICE" != "1" && "$SVC_CHOICE" != "2" ]]; do
    read -rp "Enter 1 or 2 [1]: " SVC_CHOICE
    SVC_CHOICE="${SVC_CHOICE:-1}"
  done
  if [[ "$SVC_CHOICE" == "1" ]]; then
    GRAFANA_SERVICE_TYPE="LoadBalancer"
  else
    GRAFANA_SERVICE_TYPE="ClusterIP"
  fi

  prompt_yes_no INSTALL_LOKI "Install Loki + Promtail for log aggregation as well?" "y"

  export SUBSCRIPTION_ID GRAFANA_ADMIN_PASSWORD GRAFANA_SERVICE_TYPE INSTALL_LOKI

  log "Launching setup-selfmanaged-monitoring.sh"
  exec "$SELFMANAGED_SCRIPT"
fi
