# AKS Monitoring Setup Guide (Datadog)

Deploys the Datadog Agent (DaemonSet + Cluster Agent) on AKS via the official Helm chart: infrastructure metrics, container logs, and Kubernetes state metrics, with APM available as an opt-in toggle.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Script Reference](#script-reference)
- [Prerequisites](#prerequisites)
- [Manual Setup Walkthrough](#manual-setup-walkthrough)
  - [Step 1: Connect to AKS](#step-1-connect-to-aks)
  - [Step 2: Create the API/App key secret](#step-2-create-the-apiapp-key-secret)
  - [Step 3: Install the Datadog Agent chart](#step-3-install-the-datadog-agent-chart)
  - [Step 4: Verify data is flowing](#step-4-verify-data-is-flowing)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

**1. Get your Datadog API and App keys**
Datadog UI → **Organization Settings → API Keys** (and **Application Keys**).

**2. Make the script executable**

```bash
chmod +x setup-datadog-monitoring.sh
```

**3. Set your details and run it**

```bash
export RESOURCE_GROUP="aks-monitoring-test-rg"
export AKS_NAME="aks-monitoring-test-cluster"
export SUBSCRIPTION_ID="<subscription-id>"
export DD_API_KEY="<datadog-api-key>"
export DD_APP_KEY="<datadog-app-key>"
export DD_SITE="datadoghq.com"   # change if your org uses a different Datadog site
./setup-datadog-monitoring.sh
```

That's it — the script installs prerequisites, connects to AKS, deploys the Datadog Agent, and prints verification steps.

---

## Script Reference

| File | What it does |
|---|---|
| `setup-datadog-monitoring.sh` | Installs prerequisites, connects to AKS, creates the API/App key secret, deploys the Datadog Agent via Helm |

**Variables**

| Variable | Required | Default |
|---|---|---|
| `RESOURCE_GROUP` | Yes | `aks-monitoring-test-rg` |
| `AKS_NAME` | Yes | `aks-monitoring-test-cluster` |
| `SUBSCRIPTION_ID` | Yes | — |
| `DD_API_KEY` | Yes | — |
| `DD_APP_KEY` | Yes | — |
| `DD_SITE` | No | `datadoghq.com` |
| `DD_CLUSTER_NAME` | No | same as `AKS_NAME` |
| `DATADOG_NAMESPACE` | No | `datadog` |
| `DATADOG_RELEASE` | No | `datadog-agent` |
| `ENABLE_LOGS` | No | `true` |
| `ENABLE_APM` | No | `false` |
| `DATADOG_CHART_VERSION` | No | empty (latest) |
| `WORKDIR` | No | `$HOME/aks-datadog` |

---

## Prerequisites

- Existing AKS cluster
- A Datadog account with an API key and an Application key
- Know your Datadog **site** (`datadoghq.com`, `datadoghq.eu`, `us3.datadoghq.com`, `us5.datadoghq.com`, `ap1.datadoghq.com`, etc.) — using the wrong one is the most common setup mistake
- Azure CLI, `kubectl`, and `helm` (auto-installed by the script if missing)

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

### Step 2: Create the API/App key secret

```bash
kubectl create namespace datadog

kubectl -n datadog create secret generic datadog-secret \
  --from-literal api-key=<datadog-api-key> \
  --from-literal app-key=<datadog-app-key>
```

---

### Step 3: Install the Datadog Agent chart

Create `datadog-values.yaml`:

```yaml
targetSystem: "linux"

datadog:
  apiKeyExistingSecret: datadog-secret
  appKeyExistingSecret: datadog-secret
  site: "datadoghq.com"
  clusterName: "aks-monitoring-test-cluster"

  logs:
    enabled: true
    containerCollectAll: true

  apm:
    portEnabled: false

  # AKS-specific kubelet cert path - required, the chart cannot auto-detect AKS
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
```

Install:

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update
helm install datadog-agent datadog/datadog -n datadog -f datadog-values.yaml
```

Check pods (expect one agent pod per node, plus a cluster agent):

```bash
kubectl get pods -n datadog
```

---

### Step 4: Verify data is flowing

```bash
kubectl exec -it -n datadog $(kubectl get pod -n datadog -l app.kubernetes.io/instance=datadog-agent,app.kubernetes.io/component=agent -o jsonpath='{.items[0].metadata.name}') -- agent status
```

In the Datadog UI, go to **Infrastructure → Kubernetes** and confirm your cluster appears (can take 1-2 minutes).

---

## Security Best Practices

- Never put `DD_API_KEY` / `DD_APP_KEY` directly in `datadog-values.yaml` — the script creates a Secret (`datadog-secret`) and references it via `apiKeyExistingSecret`/`appKeyExistingSecret` instead.
- `containerCollectAll: true` tails every container's logs — on high-pod-density clusters this can drive up ingestion cost. Switch to annotation-based opt-in (`containerCollectAll: false` plus `ad.datadoghq.com/<container>.logs` annotations) once you know which workloads you actually need logs from.
- Enable Cluster Agent HA (`clusterAgent.replicas: 2`) in production — a single Cluster Agent replica is a monitoring single point of failure.
- Pin the Helm chart version (`DATADOG_CHART_VERSION`) for CI/CD so upgrades are deliberate, not automatic.
- Exclude noisy namespaces (`kube-system`, your monitoring namespace) from log collection unless you specifically need them.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Agent pods `CrashLoopBackOff` on AKS specifically | `providers.aks.enabled` not set | Confirm `providers.aks.enabled: true` — this is required, the chart cannot auto-detect AKS |
| Kubelet connection errors in agent logs | Wrong `hostCAPath` | Confirm the value matches `/etc/kubernetes/certs/kubeletserver.crt` on your AKS nodes — this path is correct for many AKS setups but can vary by node image/Kubernetes version, so confirm against current Datadog AKS docs if agents can't reach the kubelet |
| No data in Datadog UI | Wrong `DD_SITE` | Double-check your org's actual Datadog site (US1 vs EU1 vs US3/US5/AP1) — this is the most common cause |
| High log ingestion / cost spike | `containerCollectAll: true` on a busy cluster | Switch to annotation-based per-container log collection |
| Cluster Agent pod not starting | Missing or mismatched token/secret | `kubectl describe pod` the cluster agent; check `clusterAgent.token` / `clusterAgent.tokenExistingSecret` |
