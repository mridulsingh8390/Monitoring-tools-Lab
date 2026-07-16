# AKS Monitoring Setup Guide (New Relic)

Deploys the New Relic Kubernetes integration (`nri-bundle`) on AKS: infrastructure agent (DaemonSet), kube-state-metrics, Prometheus OpenMetrics integration, Kubernetes events, and log forwarding.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Script Reference](#script-reference)
- [Prerequisites](#prerequisites)
- [Manual Setup Walkthrough](#manual-setup-walkthrough)
  - [Step 1: Connect to AKS](#step-1-connect-to-aks)
  - [Step 2: Add the New Relic Helm repo](#step-2-add-the-new-relic-helm-repo)
  - [Step 3: Install the nri-bundle chart](#step-3-install-the-nri-bundle-chart)
  - [Step 4: Verify data is flowing](#step-4-verify-data-is-flowing)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

**1. Get your New Relic license key**
New Relic UI → your profile → **API keys** → copy the **Ingest - License** key.

**2. Make the script executable**

```bash
chmod +x setup-newrelic-monitoring.sh
```

**3. Set your details and run it**

```bash
export RESOURCE_GROUP="aks-monitoring-test-rg"
export AKS_NAME="aks-monitoring-test-cluster"
export SUBSCRIPTION_ID="<subscription-id>"
export NEW_RELIC_LICENSE_KEY="<license-key>"
./setup-newrelic-monitoring.sh
```

That's it — the script installs prerequisites, connects to AKS, deploys the New Relic bundle, and prints verification steps.

---

## Script Reference

| File | What it does |
|---|---|
| `setup-newrelic-monitoring.sh` | Installs prerequisites, connects to AKS, deploys `nri-bundle` via Helm |

**Variables**

| Variable | Required | Default |
|---|---|---|
| `RESOURCE_GROUP` | Yes | `aks-monitoring-test-rg` |
| `AKS_NAME` | Yes | `aks-monitoring-test-cluster` |
| `SUBSCRIPTION_ID` | Yes | — |
| `NEW_RELIC_LICENSE_KEY` | Yes | — |
| `NEW_RELIC_CLUSTER_NAME` | No | same as `AKS_NAME` |
| `NEWRELIC_NAMESPACE` | No | `newrelic` |
| `NEWRELIC_RELEASE` | No | `newrelic-bundle` |
| `ENABLE_LOGGING` | No | `true` |
| `ENABLE_KUBE_EVENTS` | No | `true` |
| `ENABLE_PROMETHEUS` | No | `true` |
| `LOW_DATA_MODE` | No | `true` (reduces ingest volume/cost) |
| `NRI_BUNDLE_CHART_VERSION` | No | empty (latest) |

---

## Prerequisites

- Existing AKS cluster
- A New Relic account and license key
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

### Step 2: Add the New Relic Helm repo

```bash
helm repo add newrelic https://helm-charts.newrelic.com
helm repo update
kubectl create namespace newrelic
```

---

### Step 3: Install the nri-bundle chart

```bash
helm install newrelic-bundle newrelic/nri-bundle \
  -n newrelic \
  --set global.licenseKey=<license-key> \
  --set global.cluster=aks-monitoring-test-cluster \
  --set global.lowDataMode=true \
  --set newrelic-infrastructure.privileged=true \
  --set ksm.enabled=true \
  --set kubeEvents.enabled=true \
  --set prometheus.enabled=true \
  --set logging.enabled=true
```

Check pods:

```bash
kubectl get pods -n newrelic
```

You should see a `newrelic-infrastructure` DaemonSet pod on every node, plus `kube-state-metrics`, `nri-kube-events`, and `nri-prometheus` deployments.

---

### Step 4: Verify data is flowing

In the New Relic UI, go to **Kubernetes → Cluster explorer** and confirm your cluster appears (can take 2-3 minutes).

If nothing appears, check the infrastructure agent logs:

```bash
kubectl logs -n newrelic -l app.kubernetes.io/name=newrelic-infrastructure --tail=50
```

---

## Security Best Practices

- Don't put the license key in a committed values file — the script passes it via `--set` at install time; for GitOps/CI, store it in a Kubernetes Secret and reference it with `global.customSecretName` / `global.customSecretLicenseKey` instead.
- `newrelic-infrastructure.privileged=true` grants elevated host access needed for full infrastructure visibility — restrict this namespace's RBAC and don't enable it if you only need a subset of integrations.
- Enable `global.lowDataMode` (default here) to reduce cardinality/cost; turn it off deliberately once you know what data you need.
- Rotate license keys periodically via New Relic's API key management.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No cluster in New Relic UI after 5+ minutes | Wrong or expired license key | Re-check `NEW_RELIC_LICENSE_KEY`; confirm it's an **Ingest - License** key, not a User key |
| `newrelic-infrastructure` pods `CrashLoopBackOff` | Insufficient node permissions or resource limits | `kubectl describe pod` in the `newrelic` namespace; check resource requests against node capacity |
| Some nodes missing from Kubernetes cluster explorer | DaemonSet not scheduled on all nodes | `kubectl get pods -n newrelic -o wide` vs `kubectl get nodes`; check for taints needing tolerations |
| Duplicate/high cardinality metrics, high cost | `lowDataMode` disabled | Set `LOW_DATA_MODE=true` and re-run, or tune `newrelic-prometheus` scrape config |
| `helm install` succeeds but expected features are missing | `nri-bundle` value keys changed between chart versions | Pin `NRI_BUNDLE_CHART_VERSION` and check the actual keys for that version with `helm show values newrelic/nri-bundle --version <x.y.z>` |
