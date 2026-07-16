#!/usr/bin/env bash
#
# setup-newrelic-monitoring.sh
#
# Deploys the New Relic Kubernetes integration (nri-bundle) on AKS:
# infrastructure agent (DaemonSet), kube-state-metrics, Prometheus
# OpenMetrics integration, Kubernetes events, and log forwarding.
#
# Usage:
#   1. Edit the variables in the "CONFIG" section below (or export them
#      as environment variables before running).
#   2. chmod +x setup-newrelic-monitoring.sh
#   3. ./setup-newrelic-monitoring.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG - edit these or export as env vars before running
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-aks-monitoring-test-rg}"
AKS_NAME="${AKS_NAME:-aks-monitoring-test-cluster}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-<subscription-id>}"

NEWRELIC_NAMESPACE="${NEWRELIC_NAMESPACE:-newrelic}"
NEWRELIC_RELEASE="${NEWRELIC_RELEASE:-newrelic-bundle}"

# Required: your New Relic license key (Account -> API keys -> Ingest - License)
NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-<license-key>}"

# How the cluster shows up in the New Relic UI
NEW_RELIC_CLUSTER_NAME="${NEW_RELIC_CLUSTER_NAME:-$AKS_NAME}"

# Feature toggles
ENABLE_LOGGING="${ENABLE_LOGGING:-true}"
ENABLE_KUBE_EVENTS="${ENABLE_KUBE_EVENTS:-true}"
ENABLE_PROMETHEUS="${ENABLE_PROMETHEUS:-true}"
LOW_DATA_MODE="${LOW_DATA_MODE:-true}"   # reduces ingest volume/cost - recommended for test clusters

NRI_BUNDLE_CHART_VERSION="${NRI_BUNDLE_CHART_VERSION:-}"

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

# Finds a DaemonSet by Helm release/instance label and returns its name.
# rollout status requires a named resource, not a label selector, so we
# resolve the name first rather than passing -l directly to rollout status.
find_daemonset_name() {
  local ns="$1" release="$2"
  kubectl get ds -n "$ns" -l "app.kubernetes.io/instance=${release}" \
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
# Deploy New Relic (nri-bundle)
# ---------------------------------------------------------------------------
install_newrelic() {
  log "Deploying New Relic Kubernetes integration"

  require_placeholder_check NEW_RELIC_LICENSE_KEY "$NEW_RELIC_LICENSE_KEY"

  if [[ -z "$NRI_BUNDLE_CHART_VERSION" ]]; then
    warn "NRI_BUNDLE_CHART_VERSION is unset - installing latest. Key names (ksm.enabled, prometheus.enabled, logging.enabled, kubeEvents.enabled) can change between nri-bundle versions. For repeatable installs, pin a version and check it with: helm show values newrelic/nri-bundle --version <x.y.z>"
  fi

  helm repo add newrelic https://helm-charts.newrelic.com
  helm repo update

  kubectl create namespace "$NEWRELIC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  local version_flag=()
  version_args_for "$NRI_BUNDLE_CHART_VERSION" version_flag

  if helm status "$NEWRELIC_RELEASE" -n "$NEWRELIC_NAMESPACE" >/dev/null 2>&1; then
    log "Release '$NEWRELIC_RELEASE' already exists, upgrading instead of installing"
    helm upgrade "$NEWRELIC_RELEASE" newrelic/nri-bundle \
      -n "$NEWRELIC_NAMESPACE" \
      --set global.licenseKey="$NEW_RELIC_LICENSE_KEY" \
      --set global.cluster="$NEW_RELIC_CLUSTER_NAME" \
      --set global.lowDataMode="$LOW_DATA_MODE" \
      --set newrelic-infrastructure.privileged=true \
      --set ksm.enabled=true \
      --set kubeEvents.enabled="$ENABLE_KUBE_EVENTS" \
      --set prometheus.enabled="$ENABLE_PROMETHEUS" \
      --set logging.enabled="$ENABLE_LOGGING" \
      "${version_flag[@]}"
  else
    helm install "$NEWRELIC_RELEASE" newrelic/nri-bundle \
      -n "$NEWRELIC_NAMESPACE" \
      --set global.licenseKey="$NEW_RELIC_LICENSE_KEY" \
      --set global.cluster="$NEW_RELIC_CLUSTER_NAME" \
      --set global.lowDataMode="$LOW_DATA_MODE" \
      --set newrelic-infrastructure.privileged=true \
      --set ksm.enabled=true \
      --set kubeEvents.enabled="$ENABLE_KUBE_EVENTS" \
      --set prometheus.enabled="$ENABLE_PROMETHEUS" \
      --set logging.enabled="$ENABLE_LOGGING" \
      "${version_flag[@]}"
  fi

  log "Waiting for the New Relic infrastructure DaemonSet to become ready (up to 3 minutes)..."
  local ds_name
  ds_name=$(find_daemonset_name "$NEWRELIC_NAMESPACE" "$NEWRELIC_RELEASE")
  if [[ -n "$ds_name" ]]; then
    kubectl rollout status "daemonset/${ds_name}" -n "$NEWRELIC_NAMESPACE" --timeout=180s || \
      warn "Not ready yet. Check with: kubectl get pods -n $NEWRELIC_NAMESPACE"
  else
    warn "Could not resolve the infrastructure DaemonSet name automatically. Check with: kubectl get ds -n $NEWRELIC_NAMESPACE"
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

1. Check pods:
     kubectl get pods -n ${NEWRELIC_NAMESPACE}

2. In the New Relic UI, go to:
     Kubernetes -> Cluster explorer
   and confirm cluster "${NEW_RELIC_CLUSTER_NAME}" appears (can take 2-3 minutes).

3. If nothing appears, check the infrastructure agent logs:
     kubectl logs -n ${NEWRELIC_NAMESPACE} -l app.kubernetes.io/name=newrelic-infrastructure --tail=50

============================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  install_prerequisites
  connect_to_aks
  install_newrelic
  print_verification_steps
}

main "$@"
