#!/usr/bin/env bash
#
# setup-selfmanaged-monitoring.sh
#
# Automates Option 2 from the AKS Monitoring Setup Guide:
#   Self-managed monitoring on an Ubuntu VM
#   (Prometheus + Grafana via kube-prometheus-stack, optional Loki + Promtail)
#
# Intended to be run ON the Ubuntu VM that will host/drive the monitoring stack.
#
# Usage:
#   1. Edit the variables in the "CONFIG" section below (or export them
#      as environment variables before running).
#   2. chmod +x setup-selfmanaged-monitoring.sh
#   3. ./setup-selfmanaged-monitoring.sh
#
# The script installs prerequisites (apt packages, Azure CLI, kubectl, helm),
# connects to AKS, installs kube-prometheus-stack, and optionally installs
# Loki + Promtail for log aggregation.

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG - edit these or export as env vars before running
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-<your-rg>}"
AKS_NAME="${AKS_NAME:-<your-aks-name>}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-<subscription-id>}"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
LOKI_NAMESPACE="${LOKI_NAMESPACE:-loki}"

GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-ChangeMeStrongPassword!}"
PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-15d}"
PROMETHEUS_STORAGE_SIZE="${PROMETHEUS_STORAGE_SIZE:-50Gi}"
GRAFANA_STORAGE_SIZE="${GRAFANA_STORAGE_SIZE:-20Gi}"
ALERTMANAGER_STORAGE_SIZE="${ALERTMANAGER_STORAGE_SIZE:-10Gi}"

INSTALL_LOKI="${INSTALL_LOKI:-true}"   # set to "false" to skip Loki + Promtail
LOKI_STORAGE_SIZE="${LOKI_STORAGE_SIZE:-20Gi}"

# Grafana Service type. LoadBalancer is convenient for a quick test but
# exposes Grafana on a public IP with no auth in front of it. Set to
# "ClusterIP" for production and put an Ingress + TLS + auth in front instead.
GRAFANA_SERVICE_TYPE="${GRAFANA_SERVICE_TYPE:-LoadBalancer}"

# Optional: pin exact chart versions for repeatable installs. Leave empty
# to use whatever is latest in the repo at install time.
# Find current versions with: helm search repo prometheus-community/kube-prometheus-stack --versions
KUBE_PROMETHEUS_STACK_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-}"
PROMTAIL_CHART_VERSION="${PROMTAIL_CHART_VERSION:-}"

WORKDIR="${WORKDIR:-$HOME/aks-monitoring}"

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

# Builds a "--version X" arg array if a version string was provided, empty otherwise.
version_arg() {
  local v="$1"
  if [[ -n "$v" ]]; then
    echo "--version $v"
  fi
}

require_placeholder_check() {
  local var_name="$1" var_value="$2"
  if [[ "$var_value" == \<*\> ]]; then
    die "$var_name is still set to a placeholder ('$var_value'). Edit the CONFIG section or export $var_name before running."
  fi
}

# ---------------------------------------------------------------------------
# Step 1: Prepare Ubuntu VM (prerequisites)
# ---------------------------------------------------------------------------
prepare_vm() {
  log "Step 1: Installing base packages"
  sudo apt update && sudo apt upgrade -y
  sudo apt install -y curl wget git gnupg2 ca-certificates lsb-release \
    apt-transport-https software-properties-common unzip jq

  if ! command -v az >/dev/null 2>&1; then
    log "Azure CLI not found, installing..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  else
    log "Azure CLI already installed."
  fi
}

# ---------------------------------------------------------------------------
# Step 2: Install kubectl + helm
# ---------------------------------------------------------------------------
install_kubectl_and_helm() {
  log "Step 2: Installing kubectl and helm"

  if ! command -v kubectl >/dev/null 2>&1; then
    az aks install-cli
  else
    log "kubectl already installed."
  fi
  kubectl version --client

  if ! command -v helm >/dev/null 2>&1; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    log "helm already installed."
  fi
  helm version
}

# ---------------------------------------------------------------------------
# Step 3: Connect VM to AKS
# ---------------------------------------------------------------------------
connect_to_aks() {
  log "Step 3: Connecting to AKS cluster"

  require_placeholder_check RESOURCE_GROUP "$RESOURCE_GROUP"
  require_placeholder_check AKS_NAME "$AKS_NAME"
  require_placeholder_check SUBSCRIPTION_ID "$SUBSCRIPTION_ID"

  az account show >/dev/null 2>&1 || az login
  az account set --subscription "$SUBSCRIPTION_ID"
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_NAME" --overwrite-existing

  kubectl get nodes
}

# ---------------------------------------------------------------------------
# Step 4: Install Prometheus + Grafana (kube-prometheus-stack)
# ---------------------------------------------------------------------------
install_kube_prometheus_stack() {
  log "Step 4: Installing kube-prometheus-stack"

  mkdir -p "$WORKDIR"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update

  kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  cat > "$WORKDIR/kube-prom-values.yaml" <<EOF
grafana:
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  service:
    type: ${GRAFANA_SERVICE_TYPE}
  persistence:
    enabled: true
    size: ${GRAFANA_STORAGE_SIZE}

prometheus:
  prometheusSpec:
    retention: ${PROMETHEUS_RETENTION}
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${PROMETHEUS_STORAGE_SIZE}

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${ALERTMANAGER_STORAGE_SIZE}
EOF

  if [[ "$GRAFANA_ADMIN_PASSWORD" == "ChangeMeStrongPassword!" ]]; then
    warn "You're using the default Grafana admin password. Set GRAFANA_ADMIN_PASSWORD before running in anything beyond a quick test."
  fi

  if [[ "$GRAFANA_SERVICE_TYPE" == "LoadBalancer" ]]; then
    warn "GRAFANA_SERVICE_TYPE=LoadBalancer exposes Grafana on a public IP with no auth/TLS in front of it. Fine for a quick test; for production set GRAFANA_SERVICE_TYPE=ClusterIP and put an Ingress + TLS + auth in front instead."
  fi

  local version_flag
  version_flag=$(version_arg "$KUBE_PROMETHEUS_STACK_VERSION")

  if helm status monitoring -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
    log "Release 'monitoring' already exists, upgrading instead of installing"
    helm upgrade monitoring prometheus-community/kube-prometheus-stack \
      -n "$MONITORING_NAMESPACE" \
      -f "$WORKDIR/kube-prom-values.yaml" \
      $version_flag
  else
    helm install monitoring prometheus-community/kube-prometheus-stack \
      -n "$MONITORING_NAMESPACE" \
      -f "$WORKDIR/kube-prom-values.yaml" \
      $version_flag
  fi

  log "Waiting for pods to become ready (up to 5 minutes)..."
  kubectl wait --for=condition=Ready pods --all -n "$MONITORING_NAMESPACE" --timeout=300s || \
    warn "Some pods are not ready yet. Check with: kubectl get pods -n $MONITORING_NAMESPACE"
}

# ---------------------------------------------------------------------------
# Step 5: Access Grafana
# ---------------------------------------------------------------------------
print_grafana_access() {
  log "Step 5: Grafana access info"

  kubectl get svc -n "$MONITORING_NAMESPACE"

  log "Waiting for Grafana LoadBalancer external IP (up to 3 minutes)..."
  EXTERNAL_IP=""
  for i in $(seq 1 18); do
    EXTERNAL_IP=$(kubectl get svc -n "$MONITORING_NAMESPACE" monitoring-grafana \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$EXTERNAL_IP" ]] && break
    sleep 10
  done

  if [[ -n "$EXTERNAL_IP" ]]; then
    log "Grafana URL: http://${EXTERNAL_IP}"
  else
    warn "External IP not yet assigned. Check later with: kubectl get svc -n $MONITORING_NAMESPACE"
  fi

  echo "Username: admin"
  echo "Password: (value of GRAFANA_ADMIN_PASSWORD, or retrieve with the command below)"
  echo '  kubectl get secret -n '"$MONITORING_NAMESPACE"' monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo'
}

# ---------------------------------------------------------------------------
# Step 6: Install Loki (optional)
# ---------------------------------------------------------------------------
install_loki() {
  log "Step 6: Installing Loki"

  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo update

  kubectl create namespace "$LOKI_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  cat > "$WORKDIR/loki-values.yaml" <<EOF
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: ${LOKI_STORAGE_SIZE}
EOF

  warn "This installs Loki with local filesystem storage - fine for dev/small workloads only. For production or long log retention, switch storage.type to an object store (e.g. Azure Blob) in $WORKDIR/loki-values.yaml."

  local loki_version_flag
  loki_version_flag=$(version_arg "$LOKI_CHART_VERSION")

  if helm status loki -n "$LOKI_NAMESPACE" >/dev/null 2>&1; then
    helm upgrade loki grafana/loki -n "$LOKI_NAMESPACE" -f "$WORKDIR/loki-values.yaml" $loki_version_flag
  else
    helm install loki grafana/loki -n "$LOKI_NAMESPACE" -f "$WORKDIR/loki-values.yaml" $loki_version_flag
  fi

  kubectl get pods -n "$LOKI_NAMESPACE"
}

# ---------------------------------------------------------------------------
# Step 7: Configure AKS logs to Loki (optional)
# ---------------------------------------------------------------------------
install_promtail() {
  log "Step 7: Installing Promtail (ships container logs to Loki)"

  local promtail_version_flag
  promtail_version_flag=$(version_arg "$PROMTAIL_CHART_VERSION")

  if helm status promtail -n "$LOKI_NAMESPACE" >/dev/null 2>&1; then
    helm upgrade promtail grafana/promtail -n "$LOKI_NAMESPACE" \
      --set config.clients[0].url="http://loki.${LOKI_NAMESPACE}.svc.cluster.local:3100/loki/api/v1/push" \
      $promtail_version_flag
  else
    helm install promtail grafana/promtail -n "$LOKI_NAMESPACE" \
      --set config.clients[0].url="http://loki.${LOKI_NAMESPACE}.svc.cluster.local:3100/loki/api/v1/push" \
      $promtail_version_flag
  fi

  kubectl get pods -n "$LOKI_NAMESPACE" -l app.kubernetes.io/name=promtail -o wide

  cat <<EOF

To add Loki as a Grafana data source:
  1. Grafana UI -> Connections -> Data sources -> Add data source
  2. Select Loki
  3. URL: http://loki.${LOKI_NAMESPACE}.svc.cluster.local:3100
  4. Save & test
  5. In Explore, try query: {namespace="default"}
EOF
}

# ---------------------------------------------------------------------------
# Remaining manual steps (Step 9 alerts, security hardening)
# ---------------------------------------------------------------------------
print_manual_steps() {
  cat <<EOF

============================================================
  Automated steps complete. Remaining manual/recommended steps:
============================================================

Step 8: Persistent storage and retention
  - Confirm storage class supports the sizes/access modes used:
      kubectl get storageclass
  - Consider object storage (Azure Blob) for Loki if you need long retention.
  - Set up disk snapshots/backups if this data must survive a rebuild.

Step 9: Alerts
  - Configure Alertmanager receivers (Slack/email/webhook) by extending
    $WORKDIR/kube-prom-values.yaml under alertmanager.config, then:
      helm upgrade monitoring prometheus-community/kube-prometheus-stack \\
        -n $MONITORING_NAMESPACE -f $WORKDIR/kube-prom-values.yaml
  - Recommended alerts: Node NotReady, Pod CrashLoopBackOff, high CPU/memory,
    disk pressure, API server error rate, HPA maxed out, ingress 5xx spike,
    PersistentVolume nearing capacity.

Security Best Practices (see README):
  - Do not leave Grafana/Prometheus/Alertmanager exposed via a public
    LoadBalancer IP without auth + TLS in front (ingress + cert-manager).
  - Replace the default Grafana admin password and manage it as a Secret,
    not plaintext in a values file.
  - Lock down the monitoring VM (NSGs, patching, kubeconfig rotation).

============================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  prepare_vm
  install_kubectl_and_helm
  connect_to_aks
  install_kube_prometheus_stack
  print_grafana_access

  if [[ "$INSTALL_LOKI" == "true" ]]; then
    install_loki
    install_promtail
  else
    log "INSTALL_LOKI=false, skipping Loki/Promtail installation."
  fi

  print_manual_steps
}

main "$@"
