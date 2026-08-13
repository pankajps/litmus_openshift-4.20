# Chaos Engineering with Litmus — Configuration, Test, and Results

This document covers the chaos engineering piece of the primary site build in isolation: cluster verification before testing, how Litmus Chaos was configured, the actual experiment run, and the measured result. It intentionally excludes cluster installation and infrastructure setup — see [`primary-site-runbook.md`](./primary-site-runbook.md) for that.

## Target Application

A small HA demo app exists specifically as a stable, observable chaos target:

- **Deployment**: `haproxy-chaos-demo`, namespace `chaos-demo`
- **2 replicas**, spread across different worker nodes via `podAntiAffinity`
- Each pod runs haproxy, returning `Hello from <pod-name>` on `/` — makes failover visually obvious
- Fronted by a `Service` (ClusterIP, port 8080) and an OpenShift `Route`
- Metrics exposed natively via haproxy's built-in Prometheus exporter (`/metrics` on port 8405), scraped by platform user-workload monitoring

## Cluster Verification (Pre-Test)

Before running any chaos experiment, confirmed the cluster and target app were in a known-good state:

```bash
oc get nodes
# All 6 nodes Ready — 3 control-plane, 3 workers

oc get pods -n chaos-demo -o wide
# Both haproxy-chaos-demo replicas Running, on different nodes

oc get route haproxy-chaos-demo -n chaos-demo
# Route resolving, app reachable

oc rsh -n openshift-storage deploy/rook-ceph-tools -- ceph -s
# health: HEALTH_OK

curl -s -o /dev/null -w "%{http_code}\n" http://<route-host>
# 200
```

Chaos experiments are only meaningful against a genuinely healthy baseline — running one against a cluster with existing problems just adds noise to the result.

## Litmus Chaos Setup

### ChaosCenter and Self-Agent

Litmus was installed as the full ChaosCenter portal (Helm chart `litmuschaos/litmus`) with a self-managed agent connecting the same cluster as its own chaos target — cluster-wide access, namespace `litmus`. All container images were mirrored into a private registry ahead of time, since this cluster has no outbound internet access.

### Default ChaosHub Is Not Usable in a Disconnected Cluster

Litmus ships with a default "Litmus ChaosHub" that syncs its experiment catalog via a live `git clone` of `github.com/litmuschaos/chaos-charts`, performed by the in-cluster `litmus-server` pod. Since only the bastion host has internet egress — not workloads running inside the cluster — this sync can never succeed. The ChaosHub UI correctly shows `Disconnected`, 0 experiments, and cannot be redirected to an internal mirror through the UI (no edit option; the hub URL is a database record, not a Kubernetes resource).

**This does not block chaos testing.** ChaosHub is purely a catalog/browsing convenience — `chaos-operator`, which actually watches `ChaosEngine`/`ChaosExperiment` custom resources and executes faults, has no dependency on it. The fix: fetch the specific experiment definition once via a host with internet access, and apply it directly.

```bash
git clone --depth 1 https://github.com/litmuschaos/chaos-charts.git
# Definition found at: chaos-charts/faults/kubernetes/pod-delete/{fault.yaml, engine.yaml}
```

### ChaosExperiment

The `fault.yaml` from upstream, with its image reference redirected to the local mirror (`litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest` → local registry path):

```yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosExperiment
metadata:
  name: pod-delete
  namespace: chaos-demo
spec:
  definition:
    scope: Namespaced
    image: "registry.primary.ocplab.internal:8443/litmuschaos/go-runner:latest"
    imagePullPolicy: Always
    args:
      - -c
      - ./experiments -name pod-delete
    command:
      - /bin/bash
    env:
      - name: TOTAL_CHAOS_DURATION
        value: "30"
      - name: FORCE
        value: "true"
      - name: CHAOS_INTERVAL
        value: "10"
      - name: PODS_AFFECTED_PERC
        value: "50"
      - name: SEQUENCE
        value: "parallel"
    permissions:
      # scoped to exactly what the experiment needs: create/delete pods,
      # read owning Deployments/ReplicaSets, manage its own CRs
      - apiGroups: [""]
        resources: ["pods"]
        verbs: ["create", "delete", "get", "list", "patch", "update", "deletecollection"]
      - apiGroups: ["apps"]
        resources: ["deployments", "replicasets"]
        verbs: ["list", "get"]
      - apiGroups: ["litmuschaos.io"]
        resources: ["chaosengines", "chaosexperiments", "chaosresults"]
        verbs: ["create", "list", "get", "patch", "update", "delete"]      
```

**Design decision — `PODS_AFFECTED_PERC`:** upstream defaults this to blank, which Litmus treats as 100%. On a 2-replica app with `SEQUENCE: parallel`, that would delete *both* replicas simultaneously — proving recovery from a full outage, not proving high availability. Set explicitly to `50` (~1 of 2 pods) so the surviving replica could be observed carrying traffic throughout the test.

### RBAC

No `rbac.yaml` shipped with this chart version. Built directly from the `permissions` block already declared in `fault.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-delete-sa
  namespace: chaos-demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-delete-sa
  namespace: chaos-demo
rules:
  # mirrors fault.yaml's permissions block exactly
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-delete-sa
  namespace: chaos-demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-delete-sa
subjects:
  - kind: ServiceAccount
    name: pod-delete-sa
    namespace: chaos-demo
```

```bash
oc adm policy add-scc-to-user anyuid -z pod-delete-sa -n chaos-demo
```
(OpenShift's default SCC rejects this chart's hardcoded container UID — same friction hit throughout the wider build with other upstream Helm charts. `anyuid` on the ServiceAccount resolves it durably, regardless of what any given manifest requests.)

### ChaosEngine

The actual trigger for a run, targeting the real application:

```yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: haproxy-pod-delete
  namespace: chaos-demo
spec:
  appinfo:
    appns: 'chaos-demo'
    applabel: 'app=haproxy-chaos-demo'
    appkind: 'deployment'
  engineState: 'active'
  chaosServiceAccount: pod-delete-sa
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: '30'
            - name: CHAOS_INTERVAL
              value: '10'
            - name: FORCE
              value: 'true'
            - name: PODS_AFFECTED_PERC
              value: '50'
```

## Test Execution

```bash
oc apply -f rbac-pod-delete.yaml
oc adm policy add-scc-to-user anyuid -z pod-delete-sa -n chaos-demo
oc apply -f chaosexperiment-pod-delete.yaml
oc apply -f chaosengine-haproxy.yaml
```

With `CHAOS_INTERVAL: 10` over a `TOTAL_CHAOS_DURATION: 30`, the experiment ran **multiple kill cycles** — roughly every 10 seconds across the full window — rather than a single event. Both original pods ended up deleted and replaced by the end of the test (confirmed by their differing pod start-times), not just one: a sustained, repeated-failure scenario rather than a single hiccup.

### Automated Verification

Rather than eyeball a curl loop, [`verify-chaos-resilience.sh`](../chaos-tests/verify-chaos-resilience.sh) is a real pass/fail test:

- Polls the app's Route once per second
- Tracks total requests and failures independently of Litmus's own scoring
- Watches for the `ChaosResult` to report `phase: Completed`
- Asserts **both** zero failed requests **and** Litmus's own `verdict: Pass` before exiting `0`/`1`

```bash
./verify-chaos-resilience.sh <route-url> haproxy-pod-delete chaos-demo
```

## Result

```
=== Results ===
Total requests:  81
Failed requests: 0
Success rate:    100.00%
Litmus verdict:  Pass
RESULT: PASS — Service remained available throughout the chaos window, Litmus verdict Pass.
```

Confirmed via `ChaosResult`, Litmus's own official scoring:

```yaml
status:
  experimentStatus:
    phase: Completed
    probeSuccessPercentage: "100"
    verdict: Pass
  history:
    failedRuns: 0
    passedRuns: 1
    stoppedRuns: 0
```

Re-ran the same experiment a second time from a clean state to confirm the result wasn't a fluke — **81 requests / 0 failures** on the run above, **95 requests / 0 failures** on an earlier run — consistent zero-downtime behavior across repeated tests, not a one-off pass.

## What This Actually Proves

The `haproxy-chaos-demo` Service kept serving every single request while Litmus deleted both of its underlying pods, in separate cycles, over a 30-second window. Kubernetes' own scheduling and the Service's endpoint tracking handled the failover — no manual intervention, no dropped traffic, independently verified two different ways (a custom polling script and Litmus's own probe scoring).

**Next**: a deeper technical breakdown of this Litmus setup (Part 1.5, next weekend), followed by the DR site build with cross-site replication and backup/restore via OADP and Velero (Part 2).
