# AKS Monitoring Setup Guide (Dynatrace)

Deploys Dynatrace Operator on AKS and applies a DynaKube custom resource for full-stack monitoring: OneAgent (DaemonSet), CSI driver, and ActiveGate.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Script Reference](#script-reference)
- [Prerequisites](#prerequisites)
- [Monitoring Modes](#monitoring-modes)
- [Manual Setup Walkthrough](#manual-setup-walkthrough)
  - [Step 1: Connect to AKS](#step-1-connect-to-aks)
  - [Step 2: Install Dynatrace Operator](#step-2-install-dynatrace-operator)
  - [Step 3: Create the token secret](#step-3-create-the-token-secret)
  - [Step 4: Apply the DynaKube custom resource](#step-4-apply-the-dynakube-custom-resource)
  - [Step 5: Verify data is flowing](#step-5-verify-data-is-flowing)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

**1. Get your Dynatrace API URL and tokens**
Dynatrace UI → **Access Tokens** → create an **Operator token** and a **Data ingest token**. Your API URL looks like `https://abc12345.live.dynatrace.com/api`.

**2. Make the script executable**

```bash
chmod +x setup-dynatrace-monitoring.sh
```

**3. Set your details and run it**

```bash
export RESOURCE_GROUP="aks-monitoring-test-rg"
export AKS_NAME="aks-monitoring-test-cluster"
export SUBSCRIPTION_ID="<subscription-id>"
export DT_API_URL="https://<your-environment-id>.live.dynatrace.com/api"
export DT_OPERATOR_TOKEN="<operator-token>"
export DT_DATA_INGEST_TOKEN="<data-ingest-token>"
./setup-dynatrace-monitoring.sh
```

That's it — the script installs prerequisites, connects to AKS, installs Dynatrace Operator, and applies a `cloudNativeFullStack` DynaKube.

---

## Script Reference

| File | What it does |
|---|---|
| `setup-dynatrace-monitoring.sh` | Installs prerequisites, connects to AKS, installs Dynatrace Operator via Helm, creates the token secret, applies the DynaKube CR |

**Variables**

| Variable | Required | Default |
|---|---|---|
| `RESOURCE_GROUP` | Yes | `aks-monitoring-test-rg` |
| `AKS_NAME` | Yes | `aks-monitoring-test-cluster` |
| `SUBSCRIPTION_ID` | Yes | — |
| `DT_API_URL` | Yes | — |
| `DT_OPERATOR_TOKEN` | Yes | — |
| `DT_DATA_INGEST_TOKEN` | Yes | — |
| `DT_MONITORING_MODE` | No | `cloudNativeFullStack` |
| `DYNATRACE_NAMESPACE` | No | `dynatrace` |
| `DYNAKUBE_NAME` | No | `dynakube` |
| `DYNATRACE_OPERATOR_CHART_VERSION` | No | empty (latest) |
| `WORKDIR` | No | `$HOME/aks-dynatrace` |

---

## Prerequisites

- Existing AKS cluster
- A Dynatrace environment (SaaS or Managed) with an API URL and access tokens
- Azure CLI, `kubectl`, and `helm` (auto-installed by the script if missing)

---

## Monitoring Modes

`DT_MONITORING_MODE` controls how deep the monitoring goes:

| Mode | What it gives you |
|---|---|
| `cloudNativeFullStack` (default) | Host + Kubernetes + application-level monitoring, injected via webhook. Best default for most clusters. |
| `classicFullStack` | Same depth as cloudNativeFullStack but installed directly on the host rather than via the CSI driver/webhook — heavier-weight, used when the CSI driver isn't viable. |
| `hostMonitoring` | Node/host-level metrics only, no per-application code injection. Lightest footprint. |
| `applicationMonitoring` | Application-level injection only, no host monitoring. Use when host visibility is already covered elsewhere. |

---

## Manual Setup Walkthrough

### Step 1: Connect to AKS

```bash
az login
az account set --subscription "<subscription-id>"
az aks get-credentials -g aks-monitoring-test-rg -n aks-monitoring-test-cluster --overwrite-existing
kubectl get nodes
```

---

### Step 2: Install Dynatrace Operator

```bash
helm repo add dynatrace https://raw.githubusercontent.com/Dynatrace/dynatrace-operator/main/config/helm/repos/stable
helm repo update

kubectl create namespace dynatrace
helm install dynatrace-operator dynatrace/dynatrace-operator -n dynatrace --atomic
```

---

### Step 3: Create the token secret

```bash
kubectl -n dynatrace create secret generic dynakube \
  --from-literal="apiToken=<operator-token>" \
  --from-literal="dataIngestToken=<data-ingest-token>"
```

---

### Step 4: Apply the DynaKube custom resource

The script detects the DynaKube CRD's actual served `apiVersion` from the cluster automatically (`kubectl get crd dynakubes.dynatrace.com -o jsonpath=...`) rather than assuming one, since this changes across Operator releases. It also runs a preflight check against `DT_API_URL` to confirm the API is reachable and the operator token is accepted before creating anything.

If you're doing this step manually instead, check which version your Operator serves first:

```bash
kubectl api-resources | grep -i dynakube
kubectl get crd dynakubes.dynatrace.com -o jsonpath='{.spec.versions[?(@.served==true)].name}'
```

Create `dynakube.yaml` using whichever version that returns (`v1beta5` is current as of Operator 1.7+):

```yaml
apiVersion: dynatrace.com/v1beta5
kind: DynaKube
metadata:
  name: dynakube
  namespace: dynatrace
  annotations:
    feature.dynatrace.com/automatic-kubernetes-api-monitoring: "true"
spec:
  apiUrl: https://<your-environment-id>.live.dynatrace.com/api
  oneAgent:
    cloudNativeFullStack: {}
  activeGate:
    capabilities:
      - routing
      - kubernetes-monitoring
```

Apply it:

```bash
kubectl apply -f dynakube.yaml
```

---

### Step 5: Verify data is flowing

```bash
kubectl get dynakube -n dynatrace
kubectl describe dynakube dynakube -n dynatrace
kubectl get pods -n dynatrace -o wide
```

In the Dynatrace UI, go to **Kubernetes** and confirm your cluster appears (first full-stack data can take a few minutes).

---

## Security Best Practices

- Store `apiToken` and `dataIngestToken` only in the Kubernetes Secret the script creates — never in the DynaKube YAML or a values file.
- Scope tokens as narrowly as Dynatrace allows for their purpose (operator vs. data-ingest) rather than issuing broad admin tokens.
- If you're on AKS, note that the AKS admissions enforcer excludes AKS-managed namespaces from code-module injection by default — this is expected and doesn't indicate a broken install; see the Dynatrace docs on supported distributions for details.
- Rotate tokens periodically and update the `dynakube` secret with `kubectl apply` rather than recreating the DynaKube CR.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| DynaKube shows `Error` phase | Bad `apiUrl` or token | `kubectl describe dynakube dynakube -n dynatrace` for the exact error message |
| No OneAgent pod on some nodes | DaemonSet scheduling issue | `kubectl get pods -n dynatrace -o wide` vs `kubectl get nodes`; check taints/tolerations |
| CRD apply fails after Operator upgrade | `apiVersion` in your DynaKube YAML is out of date | The script re-detects this automatically on each run; if applying manually, re-run `kubectl get crd dynakubes.dynatrace.com -o jsonpath=...` and update the manifest |
| Script warns "could not detect the DynaKube CRD's served apiVersion" | CRD not installed yet, or Operator install hasn't finished | Confirm `kubectl get pods -n dynatrace` shows the operator running, then re-run the script |
| Script warns about HTTP 401/403 during preflight | Operator token invalid or missing required scopes | Recreate the token with the scopes documented for Dynatrace Operator (entities, settings, problem/event feed) |
| Code injection skipped for some namespaces on AKS | AKS admissions enforcer excludes AKS-managed namespaces by default | Expected behavior — see Dynatrace's "Supported distributions" docs for the AKS-specific note |
| Cluster doesn't appear in Dynatrace UI | Data ingest token missing required scopes | Recreate the token with `Ingest metrics`, `Ingest logs`, and `Ingest events` scopes |
