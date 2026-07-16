# AKS Logging Setup Guide (Fluent Bit + Fluentd → Loki)

This guide deploys a log collection pipeline on AKS:

```
Fluent Bit (DaemonSet, every node)  --forward-->  Fluentd (aggregator)  --loki plugin-->  Loki  -->  Grafana
```

- **Fluent Bit** tails container logs on every node and forwards them.
- **Fluentd** receives, aggregates, and ships logs to Loki using `fluent-plugin-grafana-loki`.
- **Loki** stores the logs (reuses the Loki instance from the earlier monitoring setup).

---

## Table of Contents

- [Quick Start](#quick-start)
- [Script Reference](#script-reference)
- [Prerequisites](#prerequisites)
- [Manual Setup Walkthrough](#manual-setup-walkthrough)
  - [Step 1: Connect to AKS](#step-1-connect-to-aks)
  - [Step 2: Add the Fluent Helm repo](#step-2-add-the-fluent-helm-repo)
  - [Step 3: Deploy Fluentd (aggregator)](#step-3-deploy-fluentd-aggregator)
  - [Step 4: Deploy Fluent Bit (DaemonSet)](#step-4-deploy-fluent-bit-daemonset)
  - [Step 5: Verify logs are flowing](#step-5-verify-logs-are-flowing)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

**1. Make sure Loki is already running** (from the earlier monitoring setup — namespace `loki`, service `loki.loki.svc.cluster.local:3100`). If not, run `setup-selfmanaged-monitoring.sh` with `INSTALL_LOKI=true` first.

**2. Make the script executable**

```bash
chmod +x setup-fluentbit-fluentd-logging.sh
```

**3. Set your connection details and run it**

```bash
export RESOURCE_GROUP="aks-monitoring-test-rg"
export AKS_NAME="aks-monitoring-test-cluster"
export SUBSCRIPTION_ID="<subscription-id>"
./setup-fluentbit-fluentd-logging.sh
```

That's it — Fluentd and Fluent Bit are deployed automatically, and the script prints verification steps at the end.

---

## Script Reference

| File | What it does |
|---|---|
| `setup-fluentbit-fluentd-logging.sh` | Installs prerequisites, connects to AKS, deploys Fluentd then Fluent Bit |

**Variables**

| Variable | Required | Default |
|---|---|---|
| `RESOURCE_GROUP` | Yes | `aks-monitoring-test-rg` |
| `AKS_NAME` | Yes | `aks-monitoring-test-cluster` |
| `SUBSCRIPTION_ID` | Yes | — |
| `LOGGING_NAMESPACE` | No | `logging` |
| `LOKI_URL` | No | `http://loki.loki.svc.cluster.local:3100` |
| `FLUENTD_RELEASE` | No | `fluentd` |
| `FLUENTBIT_RELEASE` | No | `fluent-bit` |
| `FLUENTD_CHART_VERSION` | No | empty (latest) |
| `FLUENTBIT_CHART_VERSION` | No | empty (latest) |
| `FLUENTD_LOKI_PLUGIN_VERSION` | No | `1.2.20` |
| `FLUENTBIT_TOLERATIONS_JSON` | No | empty | JSON array, e.g. `[{"key":"dedicated","operator":"Equal","value":"logging","effect":"NoSchedule"}]` |
| `WORKDIR` | No | `$HOME/aks-logging` |

---

## Prerequisites

- Existing AKS cluster
- Existing Loki instance reachable from the cluster (see the monitoring setup guide) — the script checks for the Loki service/namespace before deploying and warns if it can't find it
- Azure CLI, `kubectl`, and `helm` (auto-installed by the script if missing)
- If your node pools are tainted, set `FLUENTBIT_TOLERATIONS_JSON` so Fluent Bit's DaemonSet can schedule on every node

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

### Step 2: Add the Fluent Helm repo

```bash
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update
kubectl create namespace logging
```

---

### Step 3: Deploy Fluentd (aggregator)

Create `fluentd-values.yaml`:

```yaml
replicaCount: 1

plugins:
  - fluent-plugin-grafana-loki -v 1.2.20

env:
  - name: LOKI_URL
    value: "http://loki.loki.svc.cluster.local:3100"

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
```

> `replicaCount: 1` matters here — Loki rejects out-of-order writes for identical label sets, so running more than one Fluentd aggregator without extra worker-id labeling can cause dropped/rejected logs.
>
> The buffer uses an `emptyDir`, so buffered-but-unflushed logs are lost if the pod restarts. For durability across restarts, swap `emptyDir` for a `PersistentVolumeClaim`.

Install:

```bash
helm install fluentd fluent/fluentd -n logging -f fluentd-values.yaml
```

Check pods:

```bash
kubectl get pods -n logging
```

---

### Step 4: Deploy Fluent Bit (DaemonSet)

Create `fluent-bit-values.yaml`:

```yaml
config:
  outputs: |
    [OUTPUT]
        Name          forward
        Match         *
        Host          fluentd.logging.svc.cluster.local
        Port          24224
```

Install:

```bash
helm install fluent-bit fluent/fluent-bit -n logging -f fluent-bit-values.yaml
```

Check pods (should be one per node):

```bash
kubectl get pods -n logging -l app.kubernetes.io/name=fluent-bit -o wide
```

---

### Step 5: Verify logs are flowing

```bash
kubectl logs -n logging -l app.kubernetes.io/name=fluentd --tail=50
```

In Grafana, open **Explore**, select the **Loki** data source, and query:

```
{cluster="aks"}
```

If nothing appears, check Fluent Bit for forwarding errors:

```bash
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --tail=50
```

---

## Security Best Practices

- Fluentd's forward port (`24224`) is only exposed as `ClusterIP` — do not change it to `LoadBalancer` unless you add TLS and shared-key authentication on the `forward` input/output.
- If Loki requires authentication, set `username`/`password` in the `04_outputs.conf` match block rather than embedding credentials in plaintext — use a Kubernetes Secret mounted as an env var instead.
- Restrict which namespaces Fluent Bit tails logs from if you don't need cluster-wide collection (adjust the `INPUT` path/exclude filters).
- Rotate and scope any Loki tenant tokens if multi-tenancy is enabled on the Loki side.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Fluentd pod stuck in `CrashLoopBackOff` | `fluent-plugin-grafana-loki` failed to install (network/registry issue) | `kubectl logs` the pod; confirm the cluster can reach RubyGems, or pin a working `FLUENTD_CHART_VERSION` |
| No logs in Loki, but Fluentd is running | Fluent Bit can't reach Fluentd | Check the `Host` value in `fluent-bit-values.yaml` matches the Fluentd service name/namespace |
| Fluent Bit pods missing on some nodes | DaemonSet scheduling issue (taints/tolerations) | `kubectl get pods -n logging -o wide` and compare against `kubectl get nodes`; add tolerations if nodes are tainted |
| Logs appear but with no useful labels | Default Kubernetes filter not enriching records | Confirm Fluent Bit's default `kubernetes` filter is enabled (it is by default in the chart) and that `Merge_Log` is on |
| `rpc error: ... Entry out of order` in Fluentd logs | Multiple Fluentd replicas sending same-labeled streams out of order | Keep `replicaCount: 1` for the aggregator, or add a worker-id label if you scale it out |

---

## When you might not need Fluentd at all

Fluent Bit has a built-in Loki output plugin, so if you don't need Fluentd's aggregation, parsing, or routing features, you can skip Fluentd entirely and point Fluent Bit directly at Loki:

```yaml
config:
  outputs: |
    [OUTPUT]
        Name  loki
        Match *
        Host  loki.loki.svc.cluster.local
        Port  3100
        Labels agent=fluent-bit
```

This is simpler and has one less moving part. Use the Fluentd aggregator (as in this guide) when you need centralized parsing/filtering/routing across many Fluent Bit forwarders, or when downstream teams need a single control point for log transforms.
