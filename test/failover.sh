#!/usr/bin/env bash
# Real, run-it-yourself failover test.
# Requires: PRIMARY_KUBECONFIG, DR_KUBECONFIG, HUB_KUBECONFIG env vars set.
set -euo pipefail

NS=inventory-db
DRPC=inventory-db-drpc
POOL=ocs-storagecluster-cephblockpool

echo "=== Baseline (Primary) ==="
oc --kubeconfig="$PRIMARY_KUBECONFIG" exec -n "$NS" deploy/postgres -- \
  psql -U dbadmin -d inventory -c "SELECT max(ts) FROM heartbeat;"
date -u

echo "=== Triggering failover (Hub) ==="
oc --kubeconfig="$HUB_KUBECONFIG" patch drpc "$DRPC" -n "$NS" --type merge \
  -p '{"spec":{"action":"Failover","failoverCluster":"dr"}}'

echo "=== Quiescing source pod (Primary) ==="
# Required for a plain, non-GitOps ("discovered") app: a VolRep-backed PVC
# can't demote to secondary while its pod is still running -- GitOps apps
# get this step for free from ACM's placement mechanism, a plain `oc apply`
# app needs it done explicitly.
oc --kubeconfig="$PRIMARY_KUBECONFIG" scale deployment postgres -n "$NS" --replicas=0

echo "=== Watching real storage-level role swap (Primary) ==="
oc --kubeconfig="$PRIMARY_KUBECONFIG" exec -n openshift-storage deploy/rook-ceph-tools -- \
  rbd mirror pool status "$POOL" --verbose

echo "=== DRPC status (Hub) ==="
oc --kubeconfig="$HUB_KUBECONFIG" get drpc "$DRPC" -n "$NS" -o jsonpath='{.status.conditions}' | jq

echo ""
echo "Next: bring the app back up on DR. If kubeObjectProtection works on your"
echo "S3 endpoint, it happens automatically -- otherwise, see TEST.md for the"
echo "manual redeploy steps (including a real, documented UID-range gotcha)."
