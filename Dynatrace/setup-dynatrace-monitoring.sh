#!/usr/bin/env bash
#
# setup-dynatrace-monitoring.sh
#
# Deploys Dynatrace Operator on AKS and applies a DynaKube custom resource
# for cloudNativeFullStack monitoring (OneAgent + CSI driver + ActiveGate).
#
# Usage:
#   1. Edit the variables in the "CONFIG" section below (or export them
#      as environment variables before running).
#   2. chmod +x setup-dynatrace-monitoring.sh
#   3. ./setup-dynatrace-monitoring.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG - edit these or export as env vars before running
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-aks-monitoring-test-rg}"
AKS_NAME="${AKS_NAME:-aks-monitoring-test-cluster}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-<subscription-id>}"

DYNATRACE_NAMESPACE="${DYNATRACE_NAMESPACE:-dynatrace}"
DYNAKUBE_NAME="${DYNAKUBE_NAME:-dynakube}"

# Required: Dynatrace environment API URL, e.g. https://abc12345.live.dynatrace.com/api
DT_API_URL="${DT_API_URL:-<dynatrace-api-url>}"

# Required tokens (generate under Dynatrace -> Access Tokens):
#   Operator token needs: Read entities, Read settings, Write settings, Access
#   problem and event feed, and (for cloudNativeFullStack) Create/read/update/
#   delete tokens as documented for Dynatrace Operator.
#   Data ingest token needs: Ingest metrics, Ingest logs, Ingest events.
DT_OPERATOR_TOKEN="${DT_OPERATOR_TOKEN:-<operator-token>}"
DT_DATA_INGEST_TOKEN="${DT_DATA_INGEST_TOKEN:-<data-ingest-token>}"

# cloudNativeFullStack (recommended default), classicFullStack, hostMonitoring,
# or applicationMonitoring. See the README for the difference.
DT_MONITORING_MODE="${DT_MONITORING_MODE:-cloudNativeFullStack}"

DYNATRACE_OPERATOR_CHART_VERSION="${DYNATRACE_OPERATOR_CHART_VERSION:-}"

WORKDIR="${WORKDIR:-$HOME/aks-dynatrace}"

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

# Detects which DynaKube API version the installed Operator's CRD actually
# serves, rather than hardcoding one - this changes across Operator releases
# (v1beta1 -> ... -> v1beta5 and beyond).
detect_dynakube_api_version() {
  local served
  served=$(kubectl get crd dynakubes.dynatrace.com -o jsonpath='{.spec.versions[?(@.served==true)].name}' 2>/dev/null)
  if [[ -z "$served" ]]; then
    echo ""
    return
  fi
  # Multiple served versions may be listed space-separated; take the last
  # (newest) one.
  echo "$served" | awk '{print $NF}'
}

# Best-effort connectivity/auth check against the Dynatrace API before
# applying the DynaKube - catches a bad URL or token early instead of
# waiting for the Operator to fail silently in the background.
preflight_check_dynatrace_api() {
  log "Preflight: checking Dynatrace API reachability and token"

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not available, skipping Dynatrace API preflight check."
    return
  fi

  if ! curl -sf -o /dev/null --max-time 10 "${DT_API_URL}/v1/time"; then
    warn "Could not reach ${DT_API_URL}/v1/time. Check DT_API_URL and network egress before continuing."
    return
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Api-Token ${DT_OPERATOR_TOKEN}" \
    "${DT_API_URL}/v1/time")

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    warn "Dynatrace API returned HTTP $http_code for the operator token - it may be invalid or lack required scopes. Deployment will continue, but the Operator may fail to authenticate."
  else
    log "Dynatrace API reachable, token accepted (HTTP $http_code)."
  fi
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
# Install Dynatrace Operator
# ---------------------------------------------------------------------------
install_operator() {
  log "Installing Dynatrace Operator"

  helm repo add dynatrace https://raw.githubusercontent.com/Dynatrace/dynatrace-operator/main/config/helm/repos/stable
  helm repo update

  kubectl create namespace "$DYNATRACE_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  local version_flag=()
  version_args_for "$DYNATRACE_OPERATOR_CHART_VERSION" version_flag

  if helm status dynatrace-operator -n "$DYNATRACE_NAMESPACE" >/dev/null 2>&1; then
    log "Release 'dynatrace-operator' already exists, upgrading instead of installing"
    helm upgrade dynatrace-operator dynatrace/dynatrace-operator -n "$DYNATRACE_NAMESPACE" --atomic "${version_flag[@]}"
  else
    helm install dynatrace-operator dynatrace/dynatrace-operator -n "$DYNATRACE_NAMESPACE" --atomic "${version_flag[@]}"
  fi

  log "Waiting for the Dynatrace Operator deployment to become ready..."
  kubectl rollout status deployment -n "$DYNATRACE_NAMESPACE" dynatrace-operator --timeout=180s || \
    warn "Not ready yet. Check with: kubectl get pods -n $DYNATRACE_NAMESPACE"
}

# ---------------------------------------------------------------------------
# Create tokens secret and apply the DynaKube custom resource
# ---------------------------------------------------------------------------
configure_dynakube() {
  log "Configuring DynaKube ($DT_MONITORING_MODE)"

  require_placeholder_check DT_API_URL "$DT_API_URL"
  require_placeholder_check DT_OPERATOR_TOKEN "$DT_OPERATOR_TOKEN"
  require_placeholder_check DT_DATA_INGEST_TOKEN "$DT_DATA_INGEST_TOKEN"

  preflight_check_dynatrace_api

  mkdir -p "$WORKDIR"

  kubectl -n "$DYNATRACE_NAMESPACE" create secret generic "$DYNAKUBE_NAME" \
    --from-literal="apiToken=${DT_OPERATOR_TOKEN}" \
    --from-literal="dataIngestToken=${DT_DATA_INGEST_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

  local oneagent_key=""
  case "$DT_MONITORING_MODE" in
    cloudNativeFullStack|classicFullStack|hostMonitoring|applicationMonitoring)
      oneagent_key="$DT_MONITORING_MODE" ;;
    *) die "Unknown DT_MONITORING_MODE '$DT_MONITORING_MODE'. Use cloudNativeFullStack, classicFullStack, hostMonitoring, or applicationMonitoring." ;;
  esac

  local dynakube_api_version
  dynakube_api_version=$(detect_dynakube_api_version)
  if [[ -z "$dynakube_api_version" ]]; then
    dynakube_api_version="v1beta5"
    warn "Could not detect the DynaKube CRD's served apiVersion from the cluster (CRD not found yet?). Falling back to '${dynakube_api_version}' - verify with: kubectl api-resources | grep -i dynakube"
  else
    log "Detected DynaKube apiVersion from installed CRD: ${dynakube_api_version}"
  fi

  cat > "$WORKDIR/dynakube.yaml" <<EOF
apiVersion: dynatrace.com/${dynakube_api_version}
kind: DynaKube
metadata:
  name: ${DYNAKUBE_NAME}
  namespace: ${DYNATRACE_NAMESPACE}
  annotations:
    feature.dynatrace.com/automatic-kubernetes-api-monitoring: "true"
spec:
  apiUrl: ${DT_API_URL}
  oneAgent:
    ${oneagent_key}: {}
  activeGate:
    capabilities:
      - routing
      - kubernetes-monitoring
EOF

  kubectl apply -f "$WORKDIR/dynakube.yaml"

  log "Waiting for DynaKube pods to roll out (this can take a few minutes)..."
  sleep 15
  kubectl get pods -n "$DYNATRACE_NAMESPACE"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
print_verification_steps() {
  cat <<EOF

============================================================
  Deployment complete. Verify data is flowing:
============================================================

1. Check the DynaKube status:
     kubectl get dynakube -n ${DYNATRACE_NAMESPACE}
     kubectl describe dynakube ${DYNAKUBE_NAME} -n ${DYNATRACE_NAMESPACE}

2. Confirm a OneAgent pod is running on every node:
     kubectl get pods -n ${DYNATRACE_NAMESPACE} -o wide

3. In the Dynatrace UI, go to Kubernetes and confirm your cluster appears
   (can take a few minutes for the first full-stack data to arrive).

============================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  install_prerequisites
  connect_to_aks
  install_operator
  configure_dynakube
  print_verification_steps
}

main "$@"
