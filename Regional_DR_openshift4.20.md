# Regional DR on OpenShift 4.20 — RamenDR + Ceph RBD Failover Test

Part 2 of a fully disconnected OpenShift 4.20 build. Part 1 tested pod-level resilience with Litmus Chaos on a single cluster: [litmus_openshift-4.20](https://github.com/pankajps/litmus_openshift-4.20).

This part tests site-level resilience — an actual failover between two independent clusters, not a simulation.

## What this proves

Primary and DR are two separate OpenShift 4.20 clusters, fully air-gapped, connected by Submariner. Storage replication runs on RamenDR + Ceph RBD async mirroring. An ACM hub manages both.

A live, actively-written-to PostgreSQL instance was deployed on Primary. A failover was triggered on purpose, mid-write, to DR. The goal was a real RPO/RTO number, not a claim.

## Architecture

<img width="1536" height="1024" alt="DR_failover_test_Pankaj" src="https://github.com/user-attachments/assets/6fc72682-8cb4-4547-9150-14711aa27a11" />


Same disconnected discipline as Part 1 — every image and operator mirrored into a private registry before it ever touches a cluster.

## Setup, in order

1. Two independent OpenShift 4.20 clusters (Primary, DR), UPI install, non-overlapping cluster/service CIDRs — required for Submariner, decide this before install, not after
2. A compact 3-node ACM hub, importing both as managed clusters
3. Submariner between Primary and DR — cross-cluster pod/service networking
4. ODF/Ceph on both sites, `MirrorPeer` + `DRPolicy` to establish RBD async mirroring
5. A sample stateful app (Postgres + a writer job) deployed and placed under `DRPlacementControl`

Full command sequence and configs for each step are in [`/setup`](./setup).

## Running the test

```bash
# baseline
psql -c "SELECT max(ts) FROM heartbeat;"

# trigger failover
oc patch drpc <name> -n <ns> --type merge -p '{"spec":{"action":"Failover","failoverCluster":"dr"}}'

# confirm the real storage-level role swap
rbd mirror pool status <pool> --verbose

# confirm data on DR
psql -c "SELECT count(*), max(ts) FROM heartbeat;"
```

Full test script and step-by-step in [`/test`](./test).


## Verification

Two independent checks, same discipline as Part 1:

- `rbd mirror pool status` — confirms the actual Ceph-level primary/secondary role swap, not just a Kubernetes object saying so
- Direct data comparison — last row on Primary before failover vs. last row that actually landed on DR

Both had to agree before calling it a pass.

## Results

| Metric | Result |
|---|---|
| RPO | ~3 min (measured, matches the 5-min replication interval) |
| RTO — storage failover | minutes (automated, the real RamenDR/Ceph mechanism) |
| RTO — total | ~44 min |

The gap between those two RTO numbers is the honest part.

## What I hit

- A volume can't demote to secondary on Ceph while its pod is still running on the source cluster. Fine for GitOps-deployed apps (placement handles it); a plain `oc apply` app needs an explicit scale-down before failover.
- RamenDR's optional feature to auto-restore the app's Kubernetes manifests (not just the data) depends on OADP/Velero, and its auto-generated backup location has no way to trust a self-signed internal S3 endpoint in this setup. Ruled out every config surface I could find before calling this a real, open gap rather than a misconfiguration. Redeployed the app manually to complete the test.
- Restoring an RWO volume into a freshly-created namespace on another cluster can leave files owned by a UID range the new namespace doesn't have. Worth checking both namespaces' `sa.scc.uid-range` before failover.

None of these are hidden in the number above — they're why the total RTO is 44 minutes and not the few minutes the storage layer alone took.

## Coming next

Getting OADP/Velero working properly and closing the self-signed cert gap for real, so the manifest-restore side is fully automated too.

#OpenShift #RegionalDR #RamenDR #Ceph #Submariner #Kubernetes #SRE
