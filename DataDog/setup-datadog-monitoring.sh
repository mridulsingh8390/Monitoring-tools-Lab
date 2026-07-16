#!/usr/bin/env bash
#
# setup-datadog-monitoring.sh
#
# Deploys the Datadog Agent (DaemonSet + Cluster Agent) on AKS via the
# official Helm chart: infrastructure metrics, container logs, and
# (optionally) APM.
#
# Usage:
#   1. Edit the variables in the "CONFIG" section below (or export them
#      as environment variables before running).
#   2. chmod +x setup-datadog-monitoring.sh
#   3. ./setup-datadog-monitoring.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG - edit these or export as env vars before running
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-aks-monitoring-test-rg}"
AKS_NAME="${AKS_NAME:-aks-monitoring-test-cluster}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-<subscription-id>}"

DATADOG_NAMESPACE="${DATADOG_NAMESPACE:-datadog}"
DATADOG_RELEASE="${DATADOG_RELEASE:-datadog-agent}"

# Required: from Datadog -> Organization Settings -> API Keys / Application Keys
DD_API_KEY="${DD_API_KEY:-<datadog-api-key>}"
DD_APP_KEY="${DD_APP_KEY:-<datadog-app-key>}"

# Datadog site: datadoghq.com (US1), datadoghq.eu (EU1), us3.datadoghq.com,
# us5.datadoghq.com, ap1.datadoghq.com, ddog-gov.com, etc.
DD_SITE="${DD_SITE:-datadoghq.com}"

DD_CLUSTER_NAME="${DD_CLUSTER_NAME:-$AKS_NAME}"

# Feature toggles
ENABLE_LOGS="${ENABLE_LOGS:-true}"
ENABLE_APM="${ENABLE_APM:-false}"

DATADOG_CHART_VERSION="${DATADOG_CHART_VERSION:-}"

WORKDIR="${WORKDIR:-$HOME/aks-datadog}"

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

version_args_for() {
  local v="$1"
  local -n out_array="$2"
  out_array=()
  if [[ -n "$v" ]]; then
    out_array+=(--version "$v")
  fi
}

# Finds a DaemonSet/pod by Helm release/instance label rather than guessing
# a hardcoded label - the exact label keys used by the chart (app vs
# app.kubernetes.io/name) have varied across chart versions.
find_daemonset_name() {
  local ns="$1" release="$2"
  kubectl get ds -n "$ns" -l "app.kubernetes.io/instance=${release}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

find_agent_pod_name() {
  local ns="$1" release="$2"
  kubectl get pod -n "$ns" -l "app.kubernetes.io/instance=${release},app.kubernetes.io/component=agent" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
install_prerequisites() {
  log "Checking prerequisites"
  command -v az >/dev/null 2>&1 || { log "Installing Azure CLI"; curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash; }
  command -v kubectl >/dev/null 2>&1 || { log "Installing kubectl"; az aks install-cli; }
  command -v helm >/dev/null 2>&1 || { log "Installing helm"; curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
  log "Prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# Connect to AKS
# ---------------------------------------------------------------------------
connect_to_aks() {
  log "Connecting to AKS cluster"
  require_placeholder_check RESOURCE_GROUP "$RESOURCE_GROUP"
  require_placeholder_check AKS_NAME "$AKS_NAME"
  require_placeholder_check SUBSCRIPTION_ID "$SUBSCRIPTION_ID"

  az account show >/dev/null 2>&1 || az login
  az account set --subscription "$SUBSCRIPTION_ID"
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_NAME" --overwrite-existing
  kubectl get nodes
}

# ---------------------------------------------------------------------------
# Deploy Datadog Agent
# ---------------------------------------------------------------------------
install_datadog() {
  log "Deploying Datadog Agent"

  require_placeholder_check DD_API_KEY "$DD_API_KEY"
  require_placeholder_check DD_APP_KEY "$DD_APP_KEY"

  mkdir -p "$WORKDIR"
  helm repo add datadog https://helm.datadoghq.com
  helm repo update

  kubectl create namespace "$DATADOG_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # Store API/App keys in a Secret rather than plaintext in values.yaml
  kubectl -n "$DATADOG_NAMESPACE" create secret generic datadog-secret \
    --from-literal api-key="$DD_API_KEY" \
    --from-literal app-key="$DD_APP_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  cat > "$WORKDIR/datadog-values.yaml" <<EOF
targetSystem: "linux"

datadog:
  apiKeyExistingSecret: datadog-secret
  appKeyExistingSecret: datadog-secret
  site: "${DD_SITE}"
  clusterName: "${DD_CLUSTER_NAME}"

  logs:
    enabled: ${ENABLE_LOGS}
    containerCollectAll: true

  apm:
    portEnabled: ${ENABLE_APM}

  # AKS-specific kubelet cert path - required, chart cannot auto-detect AKS
  kubelet:
    host:
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
    hostCAPath: /etc/kubernetes/certs/kubeletserver.crt

providers:
  aks:
    enabled: true

clusterAgent:
  enabled: true
EOF

  local version_flag=()
  version_args_for "$DATADOG_CHART_VERSION" version_flag

  if helm status "$DATADOG_RELEASE" -n "$DATADOG_NAMESPACE" >/dev/null 2>&1; then
    log "Release '$DATADOG_RELEASE' already exists, upgrading instead of installing"
    helm upgrade "$DATADOG_RELEASE" datadog/datadog -n "$DATADOG_NAMESPACE" -f "$WORKDIR/datadog-values.yaml" "${version_flag[@]}"
  else
    helm install "$DATADOG_RELEASE" datadog/datadog -n "$DATADOG_NAMESPACE" -f "$WORKDIR/datadog-values.yaml" "${version_flag[@]}"
  fi

  log "Waiting for the Datadog Agent DaemonSet to become ready (up to 3 minutes)..."
  local ds_name
  ds_name=$(find_daemonset_name "$DATADOG_NAMESPACE" "$DATADOG_RELEASE")
  if [[ -n "$ds_name" ]]; then
    kubectl rollout status "daemonset/${ds_name}" -n "$DATADOG_NAMESPACE" --timeout=180s || \
      warn "Not ready yet. Check with: kubectl get pods -n $DATADOG_NAMESPACE"
  else
    warn "Could not resolve the Datadog Agent DaemonSet name automatically. Check with: kubectl get ds -n $DATADOG_NAMESPACE"
  fi
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
print_verification_steps() {
  cat <<EOF

============================================================
  Deployment complete. Verify data is flowing:
============================================================

1. Check pods (expect one agent pod per node, plus a cluster agent):
     kubectl get pods -n ${DATADOG_NAMESPACE}

2. Run the built-in Agent status/health check:
     kubectl exec -it -n ${DATADOG_NAMESPACE} \$(kubectl get pod -n ${DATADOG_NAMESPACE} -l app.kubernetes.io/instance=${DATADOG_RELEASE},app.kubernetes.io/component=agent -o jsonpath='{.items[0].metadata.name}') -- agent status

3. In the Datadog UI, go to Infrastructure -> Kubernetes and confirm
   cluster "${DD_CLUSTER_NAME}" appears (can take 1-2 minutes).

============================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  install_prerequisites
  connect_to_aks
  install_datadog
  print_verification_steps
}

main "$@"
