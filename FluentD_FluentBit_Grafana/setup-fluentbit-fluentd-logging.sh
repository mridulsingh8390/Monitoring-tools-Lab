#!/usr/bin/env bash
#
# setup-fluentbit-fluentd-logging.sh
#
# Deploys a Fluent Bit + Fluentd logging pipeline on AKS that ships logs to
# an existing Loki instance (the one installed by setup-selfmanaged-monitoring.sh).
#
# Architecture:
#   Fluent Bit (DaemonSet, every node) --forward protocol--> Fluentd (aggregator)
#   --fluent-plugin-grafana-loki--> Loki --> Grafana
#
# Usage:
#   1. Edit the variables in the "CONFIG" section below (or export them
#      as environment variables before running).
#   2. chmod +x setup-fluentbit-fluentd-logging.sh
#   3. ./setup-fluentbit-fluentd-logging.sh
#
# Requires an existing AKS cluster and a reachable Loki instance
# (defaults assume Loki was installed via setup-selfmanaged-monitoring.sh
# in the "loki" namespace).

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG - edit these or export as env vars before running
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-aks-monitoring-test-rg}"
AKS_NAME="${AKS_NAME:-aks-monitoring-test-cluster}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-<subscription-id>}"

LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-logging}"

# Existing Loki endpoint to ship logs to. Default matches the Loki installed
# by setup-selfmanaged-monitoring.sh (namespace "loki", service "loki").
LOKI_URL="${LOKI_URL:-http://loki.loki.svc.cluster.local:3100}"

FLUENTD_RELEASE="${FLUENTD_RELEASE:-fluentd}"
FLUENTBIT_RELEASE="${FLUENTBIT_RELEASE:-fluent-bit}"

# Optional: pin exact chart versions for repeatable installs.
FLUENTD_CHART_VERSION="${FLUENTD_CHART_VERSION:-}"
FLUENTBIT_CHART_VERSION="${FLUENTBIT_CHART_VERSION:-}"

# Optional: pin the exact fluent-plugin-grafana-loki gem version (recommended -
# RubyGems installs at pod startup, so an unpinned version can drift or fail
# to resolve if the registry has a transient issue).
FLUENTD_LOKI_PLUGIN_VERSION="${FLUENTD_LOKI_PLUGIN_VERSION:-1.2.20}"

# Optional: JSON array of tolerations for Fluent Bit, e.g.
#   '[{"key":"dedicated","operator":"Equal","value":"logging","effect":"NoSchedule"}]'
# Leave empty if your node pools aren't tainted.
FLUENTBIT_TOLERATIONS_JSON="${FLUENTBIT_TOLERATIONS_JSON:-}"

WORKDIR="${WORKDIR:-$HOME/aks-logging}"

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

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
install_prerequisites() {
  log "Checking prerequisites"

  if ! command -v az >/dev/null 2>&1; then
    log "Azure CLI not found, installing..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    log "kubectl not found, installing via az aks install-cli..."
    az aks install-cli
  fi

  if ! command -v helm >/dev/null 2>&1; then
    log "helm not found, installing..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi

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
# Health check: confirm Loki is reachable before wiring up the pipeline
# ---------------------------------------------------------------------------
check_loki_available() {
  log "Checking that Loki is reachable"

  local loki_ns
  loki_ns=$(echo "$LOKI_URL" | sed -E 's#https?://[^.]+\.([^.]+)\.svc.*#\1#')

  if [[ -n "$loki_ns" ]] && kubectl get namespace "$loki_ns" >/dev/null 2>&1; then
    local loki_svc
    loki_svc=$(echo "$LOKI_URL" | sed -E 's#https?://([^.]+)\..*#\1#')
    if kubectl -n "$loki_ns" get svc "$loki_svc" >/dev/null 2>&1; then
      log "Found Loki service '$loki_svc' in namespace '$loki_ns'."
    else
      warn "Could not find service '$loki_svc' in namespace '$loki_ns'. Deployment will continue, but logs won't arrive until Loki is reachable at $LOKI_URL."
    fi
  else
    warn "Could not verify Loki's namespace from LOKI_URL='$LOKI_URL'. Deployment will continue, but double-check Loki is actually reachable at that address."
  fi
}

# ---------------------------------------------------------------------------
# Deploy Fluentd (aggregator, ships to Loki)
# ---------------------------------------------------------------------------
install_fluentd() {
  log "Deploying Fluentd (aggregator -> Loki)"

  check_loki_available

  mkdir -p "$WORKDIR"
  helm repo add fluent https://fluent.github.io/helm-charts
  helm repo update

  kubectl create namespace "$LOGGING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  local loki_plugin="fluent-plugin-grafana-loki"
  if [[ -n "$FLUENTD_LOKI_PLUGIN_VERSION" ]]; then
    loki_plugin="fluent-plugin-grafana-loki -v ${FLUENTD_LOKI_PLUGIN_VERSION}"
  fi

  cat > "$WORKDIR/fluentd-values.yaml" <<EOF
replicaCount: 1

plugins:
  - ${loki_plugin}

env:
  - name: LOKI_URL
    value: "${LOKI_URL}"

fileConfigs:
  04_outputs.conf: |-
    <match **>
      @type loki
      url "#{ENV['LOKI_URL']}"
      extra_labels {"cluster":"aks","source":"fluentd"}
      <buffer>
        @type file
        path /buffers/loki
        flush_mode interval
        flush_interval 10s
        retry_forever true
        chunk_limit_size 1m
        queue_limit_length 256
      </buffer>
    </match>

service:
  type: ClusterIP
  ports:
    - port: 24224
      targetPort: 24224
      protocol: TCP
      name: forward

extraVolumes:
  - name: loki-buffer
    emptyDir: {}

extraVolumeMounts:
  - name: loki-buffer
    mountPath: /buffers
EOF

  local version_flag=()
  version_args_for "$FLUENTD_CHART_VERSION" version_flag

  if helm status "$FLUENTD_RELEASE" -n "$LOGGING_NAMESPACE" >/dev/null 2>&1; then
    log "Release '$FLUENTD_RELEASE' already exists, upgrading instead of installing"
    helm upgrade "$FLUENTD_RELEASE" fluent/fluentd -n "$LOGGING_NAMESPACE" -f "$WORKDIR/fluentd-values.yaml" "${version_flag[@]}"
  else
    helm install "$FLUENTD_RELEASE" fluent/fluentd -n "$LOGGING_NAMESPACE" -f "$WORKDIR/fluentd-values.yaml" "${version_flag[@]}"
  fi

  log "Waiting for Fluentd pod(s) to become ready (up to 3 minutes)..."
  kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=fluentd -n "$LOGGING_NAMESPACE" --timeout=180s || \
    warn "Fluentd not ready yet. Check with: kubectl get pods -n $LOGGING_NAMESPACE"
}

# ---------------------------------------------------------------------------
# Deploy Fluent Bit (DaemonSet, forwards to Fluentd)
# ---------------------------------------------------------------------------
install_fluentbit() {
  log "Deploying Fluent Bit (DaemonSet -> Fluentd)"

  local fluentd_host="${FLUENTD_RELEASE}.${LOGGING_NAMESPACE}.svc.cluster.local"

  cat > "$WORKDIR/fluent-bit-values.yaml" <<EOF
config:
  outputs: |
    [OUTPUT]
        Name          forward
        Match         *
        Host          ${fluentd_host}
        Port          24224
EOF

  if [[ -n "$FLUENTBIT_TOLERATIONS_JSON" ]]; then
    log "FLUENTBIT_TOLERATIONS_JSON set, adding tolerations for tainted node pools"
    echo "tolerations: ${FLUENTBIT_TOLERATIONS_JSON}" >> "$WORKDIR/fluent-bit-values.yaml"
  fi

  local version_flag=()
  version_args_for "$FLUENTBIT_CHART_VERSION" version_flag

  if helm status "$FLUENTBIT_RELEASE" -n "$LOGGING_NAMESPACE" >/dev/null 2>&1; then
    log "Release '$FLUENTBIT_RELEASE' already exists, upgrading instead of installing"
    helm upgrade "$FLUENTBIT_RELEASE" fluent/fluent-bit -n "$LOGGING_NAMESPACE" -f "$WORKDIR/fluent-bit-values.yaml" "${version_flag[@]}"
  else
    helm install "$FLUENTBIT_RELEASE" fluent/fluent-bit -n "$LOGGING_NAMESPACE" -f "$WORKDIR/fluent-bit-values.yaml" "${version_flag[@]}"
  fi

  log "Waiting for Fluent Bit pods to become ready on all nodes (up to 3 minutes)..."
  kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=fluent-bit -n "$LOGGING_NAMESPACE" --timeout=180s || \
    warn "Fluent Bit not ready yet. Check with: kubectl get pods -n $LOGGING_NAMESPACE -o wide"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
print_verification_steps() {
  cat <<EOF

============================================================
  Deployment complete. Verify logs are flowing:
============================================================

1. Check pods:
     kubectl get pods -n ${LOGGING_NAMESPACE}

2. Check Fluentd logs for connection/flush errors:
     kubectl logs -n ${LOGGING_NAMESPACE} -l app.kubernetes.io/name=fluentd --tail=50

3. In Grafana, open Explore, select the Loki data source, and query:
     {cluster="aks"}

   If nothing shows up, check Fluent Bit logs for forwarding errors:
     kubectl logs -n ${LOGGING_NAMESPACE} -l app.kubernetes.io/name=fluent-bit --tail=50

============================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  install_prerequisites
  connect_to_aks
  install_fluentd
  install_fluentbit
  print_verification_steps
}

main "$@"
