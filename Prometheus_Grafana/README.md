# AKS Monitoring Setup Guide (Prometheus + Grafana)

This guide covers **two options** to monitor an Azure Kubernetes Service (AKS) cluster:

1. **Azure-native monitoring** (Managed Prometheus + Managed Grafana)
2. **Self-managed monitoring on Ubuntu VM** (Prometheus + Grafana + optional Loki)

---

## Table of Contents

- [Quick Start](#quick-start)
- [Script Reference](#script-reference)
- [Prerequisites](#prerequisites)
- [Option 1: Azure-native Monitoring (Recommended)](#option-1-azure-native-monitoring-recommended)
  - [Architecture](#architecture)
  - [Step 1: Register required Azure providers](#step-1-register-required-azure-providers)
  - [Step 2: Enable monitoring add-ons on AKS](#step-2-enable-monitoring-add-ons-on-aks)
  - [Step 3: Create or attach Azure Managed Grafana](#step-3-create-or-attach-azure-managed-grafana)
  - [Step 4: Connect Grafana to Azure Monitor workspace](#step-4-connect-grafana-to-azure-monitor-workspace)
  - [Step 5: Import dashboards](#step-5-import-dashboards)
  - [Step 6: Alerts](#step-6-alerts)
  - [Step 7: Verify metrics and logs](#step-7-verify-metrics-and-logs)
- [Option 2: Self-managed on Ubuntu VM](#option-2-self-managed-on-ubuntu-vm)
  - [Architecture](#architecture-1)
  - [Step 1: Prepare Ubuntu VM](#step-1-prepare-ubuntu-vm)
  - [Step 2: Install kubectl + helm](#step-2-install-kubectl--helm)
  - [Step 3: Connect VM to AKS](#step-3-connect-vm-to-aks)
  - [Step 4: Install Prometheus + Grafana (kube-prometheus-stack)](#step-4-install-prometheus--grafana-kube-prometheus-stack)
  - [Step 5: Access Grafana](#step-5-access-grafana)
  - [Step 6: Install Loki (optional)](#step-6-install-loki-optional)
  - [Step 7: Configure AKS logs to Loki (optional)](#step-7-configure-aks-logs-to-loki-optional)
  - [Step 8: Persistent storage and retention](#step-8-persistent-storage-and-retention)
  - [Step 9: Alerts](#step-9-alerts)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)
- [Recommendation](#recommendation)
- [Cleanup](#cleanup)

---

## Quick Start

**1. Create a test cluster**

```bash
az group create --name aks-monitoring-test-rg --location centralindia

az aks create \
  --resource-group aks-monitoring-test-rg \
  --name aks-monitoring-test-cluster \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys
```

**2. Make the scripts executable**

```bash
chmod +x bootstrap-aks-monitoring.sh setup-azure-native-monitoring.sh setup-selfmanaged-monitoring.sh
```

**3. Run the bootstrap script**

```bash
./bootstrap-aks-monitoring.sh
```

**4. When prompted, enter:**

```
Resource group: aks-monitoring-test-rg
AKS cluster name: aks-monitoring-test-cluster
Option: 1 (Azure-native) or 2 (self-managed)
```

That's it — the script installs any missing tools and runs the rest automatically.

> Option 2 (self-managed) must be run **on the Ubuntu VM** that will host Prometheus/Grafana. Option 1 can run from any machine with `az` access.

> **Running in Windows Git Bash (MINGW64)?** All scripts already `export MSYS_NO_PATHCONV=1` internally to stop Git Bash from mangling `/subscriptions/...`-style arguments into Windows paths. If you ever run `az`/`kubectl` commands manually outside the scripts, set that env var yourself first: `export MSYS_NO_PATHCONV=1`.

---

## Script Reference

| File | What it does |
|---|---|
| `bootstrap-aks-monitoring.sh` | Asks a few questions, then runs the correct script below |
| `setup-azure-native-monitoring.sh` | Sets up Option 1 (Managed Prometheus + Managed Grafana) |
| `setup-selfmanaged-monitoring.sh` | Sets up Option 2 (Prometheus + Grafana + optional Loki on a VM) |
| `cleanup-aks-monitoring.sh` | Deletes everything the scripts created — see [Cleanup](#cleanup) |

All three files must be in the same folder.

**setup-azure-native-monitoring.sh variables**

| Variable | Required | Default |
|---|---|---|
| `RESOURCE_GROUP` | Yes | — |
| `AKS_NAME` | Yes | — |
| `LOCATION` | Yes | — |
| `GRAFANA_NAME` | Yes | — (must be 2-23 characters — Azure Managed Grafana limit) |
| `LOG_ANALYTICS_WS_ID` | No | empty |
| `AZURE_MONITOR_WORKSPACE_ID` | No | empty |
| `INSTALL_AKS_PREVIEW_EXTENSION` | No | `false` |

**setup-selfmanaged-monitoring.sh variables**

| Variable | Required | Default |
|---|---|---|
| `RESOURCE_GROUP` | Yes | — |
| `AKS_NAME` | Yes | — |
| `SUBSCRIPTION_ID` | Yes | — |
| `GRAFANA_ADMIN_PASSWORD` | No | `ChangeMeStrongPassword!` |
| `GRAFANA_SERVICE_TYPE` | No | `LoadBalancer` |
| `PROMETHEUS_RETENTION` | No | `15d` |
| `PROMETHEUS_STORAGE_SIZE` | No | `50Gi` |
| `GRAFANA_STORAGE_SIZE` | No | `20Gi` |
| `ALERTMANAGER_STORAGE_SIZE` | No | `10Gi` |
| `INSTALL_LOKI` | No | `true` |
| `LOKI_STORAGE_SIZE` | No | `20Gi` |
| `KUBE_PROMETHEUS_STACK_VERSION` | No | empty (latest) |
| `LOKI_CHART_VERSION` | No | empty (latest) |
| `PROMTAIL_CHART_VERSION` | No | empty (latest) |
| `WORKDIR` | No | `$HOME/aks-monitoring` |

To skip prompts, export variables directly and run the script instead of the bootstrap:

```bash
export RESOURCE_GROUP="aks-monitoring-test-rg"
export AKS_NAME="aks-monitoring-test-cluster"
export LOCATION="centralindia"
export GRAFANA_NAME="aks-mon-test-grafana"
./setup-azure-native-monitoring.sh
```

---

## Prerequisites

- Azure subscription with permission to:
  - Manage AKS
  - Create Azure Monitor / Managed Grafana resources
- Existing AKS cluster
- Azure CLI installed (`az`)
- `kubectl` installed
- `helm` installed (for Option 2)
- Network connectivity:
  - VM to AKS API server
  - If private AKS, VM must be in same VNet or peered network
- (Optional) Domain + TLS cert for production Grafana endpoint

---

## Option 1: Azure-native Monitoring (Recommended)

This option uses Azure-managed services with minimal ops overhead.

### Architecture

- **AKS** emits metrics/logs
- **Azure Monitor managed service for Prometheus** stores Prometheus metrics
- **Azure Managed Grafana** visualizes dashboards
- **Azure Monitor / Log Analytics** handles logs and alerts

### Step 1: Register required Azure providers

```bash
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Monitor
az provider register --namespace Microsoft.Dashboard
az provider register --namespace Microsoft.AlertsManagement
```

Check status:

```bash
az provider show --namespace Microsoft.Monitor --query registrationState -o tsv
az provider show --namespace Microsoft.Dashboard --query registrationState -o tsv
```

---

### Step 2: Enable monitoring add-ons on AKS

Set variables:

```bash
RESOURCE_GROUP="aks-monitoring-test-rg"
AKS_NAME="aks-monitoring-test-cluster"
LOCATION="centralindia"
```

Enable Azure Monitor metrics/logs integration for AKS:

```bash
az aks update \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --enable-azure-monitor-metrics
```

> If your org uses Log Analytics/Container Insights too, enable it as per policy:
```bash
LOG_ANALYTICS_WS_ID="/subscriptions/<subscription-id>/resourceGroups/aks-monitoring-test-rg/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>"
az aks enable-addons \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --addons monitoring \
  --workspace-resource-id $LOG_ANALYTICS_WS_ID
```

---

### Step 3: Create or attach Azure Managed Grafana

```bash
GRAFANA_NAME="aks-mon-test-grafana"

az grafana create \
  --name $GRAFANA_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION
```

Get Grafana resource ID:

```bash
GRAFANA_ID=$(az grafana show -g $RESOURCE_GROUP -n $GRAFANA_NAME --query id -o tsv)
echo $GRAFANA_ID
```

---

### Step 4: Connect Grafana to Azure Monitor workspace

When `--enable-azure-monitor-metrics` is enabled, Azure creates/uses an Azure Monitor workspace.
Link Grafana to it via the portal or CLI/RBAC steps:

1. Open **Azure Managed Grafana** in the portal.
2. Go to **Data Sources** and ensure the **Azure Monitor** source is configured.
3. Grant the Grafana managed identity `Monitoring Reader` on:
   - AKS resource
   - Azure Monitor workspace
   - (optional) Log Analytics workspace for logs

Typical role assignment:

```bash
GRAFANA_PRINCIPAL_ID=$(az grafana show -g $RESOURCE_GROUP -n $GRAFANA_NAME --query identity.principalId -o tsv)
SCOPE="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP"

az role assignment create \
  --assignee-object-id $GRAFANA_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Monitoring Reader" \
  --scope $SCOPE
```

> This scopes access to the whole resource group. For tighter, least-privilege access, set `SCOPE` to the specific Azure Monitor workspace resource ID instead.

---

### Step 5: Import dashboards

In Grafana, go to **Dashboards → Import**, paste one of the IDs below under "Import via grafana.com", click **Load**, select your **Prometheus/Azure Monitor** data source, then **Import**:

| ID | Dashboard |
|---|---|
| `12114` | Kubernetes / Compute Resources / Cluster — cluster-wide CPU/memory overview |
| `1860` | Node Exporter Full — node-level CPU, memory, disk, network |
| `18814` | Kubernetes / Networking (requires Advanced Network Observability) |

If the ID import fails (Azure Managed Grafana sometimes can't reach grafana.com directly), download the dashboard's JSON from the grafana.com page instead and use **Upload JSON file** in the same Import screen.

Alternatively, skip manual import entirely: linking Grafana to the cluster via `--grafana-resource-id` auto-provisions Azure's own curated dashboard set —

```bash
az aks update -g aks-monitoring-test-rg -n aks-monitoring-test-cluster \
  --grafana-resource-id "$GRAFANA_ID"
```

(`$GRAFANA_ID` is printed by `setup-azure-native-monitoring.sh` at the end of Step 3.)

---

### Step 6: Alerts

Create alerts in:
- **Azure Monitor alert rules** (preferred for centralized ops)
- or **Grafana alerting**

Recommended alerts:
- Node NotReady
- Pod CrashLoopBackOff
- High CPU/memory utilization
- Disk pressure
- API server error rate
- HPA maxed out
- Ingress 5xx spike

---

### Step 7: Verify metrics and logs

Validation checklist:
- Metrics visible for:
  - `node_cpu_seconds_total`
  - `kube_pod_status_phase`
  - `container_memory_working_set_bytes`
- Logs visible in Log Analytics:
  - `ContainerLogV2`
  - `KubePodInventory`
- Dashboard refresh working with expected scrape intervals

---

## Option 2: Self-managed on Ubuntu VM

Use this if you want full control and can manage upgrades/backup/security yourself.

### Architecture

- Ubuntu VM runs:
  - Prometheus
  - Grafana
  - (Optional) Loki + Promtail/Grafana Agent
- VM pulls metrics from AKS components (via Kubernetes service discovery / exporters)

---

### Step 1: Prepare Ubuntu VM

SSH to VM and install basics:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common unzip
```

---

### Step 2: Install kubectl + helm

Install kubectl:

```bash
az aks install-cli
kubectl version --client
```

Install Helm:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

---

### Step 3: Connect VM to AKS

```bash
RESOURCE_GROUP="aks-monitoring-test-rg"
AKS_NAME="aks-monitoring-test-cluster"

az login
# Find your subscription ID with: az account list --query "[].{name:name, id:id}" -o table
az account set --subscription "<subscription-id>"
az aks get-credentials -g $RESOURCE_GROUP -n $AKS_NAME --overwrite-existing

kubectl get nodes
```

---

### Step 4: Install Prometheus + Grafana (kube-prometheus-stack)

Add Helm repos:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

Create namespace:

```bash
kubectl create namespace monitoring
```

Create custom values file `kube-prom-values.yaml`:

```yaml
grafana:
  adminPassword: "ChangeMeStrongPassword!"
  service:
    type: LoadBalancer
  persistence:
    enabled: true
    size: 20Gi

prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
```

Install stack:

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f kube-prom-values.yaml
```

Check pods:

```bash
kubectl get pods -n monitoring
```

---

### Step 5: Access Grafana

Get Grafana service external IP:

```bash
kubectl get svc -n monitoring
```

Get admin password (if not set in values):

```bash
kubectl get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

Open:
- `http://<EXTERNAL-IP>`

Login:
- Username: `admin`
- Password: from above

> **Note:** Exposing Grafana via a public LoadBalancer IP with no additional protection is fine for a quick test, but see [Security Best Practices](#security-best-practices) before using this in anything resembling production.

---

### Step 6: Install Loki (optional)

Add the Grafana Helm repo:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

Create a namespace (or reuse `monitoring`):

```bash
kubectl create namespace loki
```

Install Loki in simple scalable/single-binary mode with a minimal values file `loki-values.yaml`:

```yaml
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
    size: 20Gi
```

Install:

```bash
helm install loki grafana/loki -n loki -f loki-values.yaml
```

Check pods:

```bash
kubectl get pods -n loki
```

---

### Step 7: Configure AKS logs to Loki (optional)

Deploy Promtail (or Grafana Agent) as a DaemonSet so it runs on every node and tails container logs:

```bash
helm install promtail grafana/promtail -n loki \
  --set config.clients[0].url=http://loki.loki.svc.cluster.local:3100/loki/api/v1/push
```

Verify Promtail pods are running on all nodes:

```bash
kubectl get pods -n loki -l app.kubernetes.io/name=promtail -o wide
```

Add Loki as a data source in Grafana:

1. Grafana UI → **Connections → Data sources → Add data source**
2. Select **Loki**
3. URL: `http://loki.loki.svc.cluster.local:3100`
4. Save & test

Once connected, use the **Explore** view in Grafana with a query like:

```
{namespace="default"}
```

to confirm logs are flowing from your AKS workloads.

---

### Step 8: Persistent storage and retention

- Prometheus, Grafana, and Loki all use `PersistentVolumeClaim`s backed by AKS's default storage class (typically Azure Disk, `managed-csi`).
- Confirm the storage class exists and supports the access modes used above:

```bash
kubectl get storageclass
```

- Adjust retention based on disk size and expected query volume:
  - Prometheus: `retention: 15d` is a reasonable starting point for a mid-size cluster; increase disk size proportionally to retention.
  - Loki: filesystem storage is fine for small/dev clusters; for larger or long-retention deployments, switch `storage.type` to an object store (Azure Blob, S3-compatible) instead of local disk.
- Set up regular snapshots or backups of the underlying disks if this data needs to survive a cluster or VM rebuild — Helm re-installing the charts does **not** restore historical data.

---

### Step 9: Alerts

Alertmanager is installed as part of `kube-prometheus-stack`. Configure notification routing by extending `kube-prom-values.yaml`:

```yaml
alertmanager:
  config:
    route:
      receiver: "default-receiver"
    receivers:
      - name: "default-receiver"
        # e.g. slack_configs, email_configs, webhook_configs
```

Recommended alert rules (same targets as Option 1):
- Node NotReady
- Pod CrashLoopBackOff
- High CPU/memory utilization
- Disk pressure
- API server error rate
- HPA maxed out
- Ingress 5xx spike
- PersistentVolume nearing capacity (self-managed stacks need this watched manually, unlike the Azure-native option)

Apply updated config:

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f kube-prom-values.yaml
```

---

## Security Best Practices

- **Never expose Grafana/Prometheus/Alertmanager directly to the internet** without authentication and TLS in front of them (ingress + cert-manager, or an Azure Application Gateway / Front Door).
- Change all default passwords immediately (`grafana.adminPassword` above is a placeholder — replace it or manage it via a Kubernetes Secret / Azure Key Vault, not plaintext in `values.yaml`).
- Restrict access with:
  - Network security groups / firewall rules on the VM (Option 2)
  - Azure AD authentication for Managed Grafana (Option 1) or an OAuth proxy for self-managed Grafana
- Use Kubernetes RBAC to scope what the monitoring service accounts can read (metrics/logs only, not write access to workloads).
- Rotate the `kubeconfig` credentials on the monitoring VM and treat it as a privileged host — same patch/hardening cadence as any other bastion.
- For Log Analytics / Log data, apply data retention and access policies consistent with your org's compliance requirements.
- Scope the `Monitoring Reader` role assignment to the specific Azure Monitor workspace resource rather than the whole resource group where possible — this is tighter least-privilege than a resource-group-wide grant.
- Pin Helm chart versions (`--version x.y.z`) for `kube-prometheus-stack`, `loki`, and `promtail` in CI/CD or repeatable deployments, rather than always installing "latest," so upgrades are deliberate and reproducible.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `az provider show` stuck in "Registering" | Propagation delay | Wait a few minutes and re-check; can take up to 10–15 min |
| Grafana can't see Azure Monitor data | Missing role assignment | Re-check `Monitoring Reader` role on the correct scope (workspace, not just resource group) |
| `kube-prometheus-stack` pods stuck in `Pending` | No storage class / insufficient quota | Run `kubectl describe pod` and `kubectl get storageclass`; check node CPU/memory requests vs available capacity |
| Grafana LoadBalancer has no external IP | AKS load balancer provisioning delay, or no public LB SKU configured | Check `kubectl describe svc` in the `monitoring` namespace; confirm cluster's load balancer SKU is Standard |
| No logs in Loki/Log Analytics | Promtail/Container Insights not running on all nodes | Check DaemonSet pod count matches node count; check pod logs for connection errors to the log endpoint |
| VM can't reach AKS API server | Private cluster networking | Confirm VM is in the same VNet/peered VNet and NSGs allow the traffic |
| Alerts not firing | Alertmanager route/receiver misconfigured | `kubectl exec` into the Alertmanager pod and check its config, or use the Alertmanager UI to inspect silences/routes |
| `az role assignment create` fails with `MissingSubscription`, or any `az`/`kubectl` command with a `/subscriptions/...`-style argument behaves oddly | Running in Windows Git Bash (MINGW64/MSYS), which auto-converts leading-`/` arguments into Windows paths, corrupting them | The scripts already `export MSYS_NO_PATHCONV=1` to disable this; if you're running commands manually outside the scripts, set that env var yourself first |

---

## Recommendation

- **Choose Option 1 (Azure-native)** for most production scenarios: less operational burden, integrated with Azure RBAC/AD, managed upgrades and scaling, and centralized alerting alongside the rest of your Azure estate.
- **Choose Option 2 (self-managed)** if you need full control over the Prometheus/Grafana/Loki configuration, want to avoid Azure Managed Grafana costs, need on-prem/hybrid consistency, or are running in an environment where Azure Monitor managed services aren't available or approved.
- A hybrid approach is also common: use Azure Monitor managed Prometheus for metrics, but run self-managed Grafana or Loki for teams that need deep dashboard/log customization Azure Managed Grafana doesn't yet support.

---

## Cleanup

To delete everything the scripts created (AKS cluster, Managed Grafana, disks, etc.):

```bash
export MSYS_NO_PATHCONV=1
chmod +x cleanup-aks-monitoring.sh
export RESOURCE_GROUP="aks-monitoring-test-rg"
export AKS_NAME="aks-monitoring-test-cluster"
./cleanup-aks-monitoring.sh
```

It asks you to type the resource group name to confirm, then:

1. Deletes the resource group (removes the AKS cluster, Grafana instance, and everything else in it).
2. Removes the local `kubectl` context/cluster/user entries for the deleted cluster.
3. Optionally offers to also delete the auto-created `DefaultResourceGroup-<region>` (where the Azure Monitor workspace landed) — only say yes if nothing else in your subscription uses it.

Deletion runs in the background; check progress with `az group list -o table`.
