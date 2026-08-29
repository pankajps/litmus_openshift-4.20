# Test

`failover.sh` triggers a real failover of a live, continuously-written-to app
and confirms the storage-level role swap directly against Ceph, not just a
Kubernetes status field.

```bash
export PRIMARY_KUBECONFIG=/path/to/primary/kubeconfig
export DR_KUBECONFIG=/path/to/dr/kubeconfig
export HUB_KUBECONFIG=/path/to/hub/kubeconfig

oc --kubeconfig="$PRIMARY_KUBECONFIG" apply -f app.yaml
oc --kubeconfig="$HUB_KUBECONFIG" apply -f drpc.yaml
# wait for DRPC status to show Protected: True before running the test
./failover.sh
```

## What actually happened in this build, honestly

The script gets you through the real, automated part: failover trigger,
source pod quiesce, and the actual Ceph RBD primary/secondary role swap.
That part is genuinely automated and was confirmed working directly against
`rbd mirror pool status`.

What it doesn't do automatically, in this build specifically: recreate the
app's own Deployment/Service on DR. That's `kubeObjectProtection`'s job
(commented out in `drpc.yaml`), and it hit a real, fully-diagnosed limitation
here — RamenDR's own auto-generated `BackupStorageLocation` object has no
field anywhere to trust a self-signed internal S3 certificate, and it's
regenerated on every reconcile so a manual patch doesn't hold. If your S3
endpoint has a real CA-signed cert instead of a self-signed one, uncomment
that field and this step should just work.

Given that, completing the test meant redeploying the app manually on DR:

```bash
# image needs to exist on DR's own registry too -- easy to miss
podman pull registry.primary.ocplab.internal:8443/rhel9/postgresql-15:latest
podman tag registry.primary.ocplab.internal:8443/rhel9/postgresql-15:latest <dr-registry>/rhel9/postgresql-15:latest
podman push <dr-registry>/rhel9/postgresql-15:latest --tls-verify=false --remove-signatures

oc --kubeconfig="$DR_KUBECONFIG" apply -f app.yaml   # minus the PVC block -- it already exists via VRG restore
```

**A real gotcha you'll likely hit here:** each OpenShift namespace gets its
own independently-allocated UID/GID range. If Primary's and DR's `inventory-db`
namespaces got different ranges, the restored volume's files will be owned by
a UID the DR pod can't touch, and the container will crash-loop on a
permissions error. Check first:

```bash
oc --kubeconfig="$PRIMARY_KUBECONFIG" get namespace inventory-db -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}'
oc --kubeconfig="$DR_KUBECONFIG" get namespace inventory-db -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}'
```

If they differ, fix ownership before starting the pod:

```bash
oc --kubeconfig="$DR_KUBECONFIG" debug node/<node-hosting-the-volume> -- chroot /host bash -c "chown -R <dr-uid>:<dr-gid> /var/lib/kubelet/pods/*/volumes/kubernetes.io~csi/*/mount/userdata"
```

## Reading the results

```bash
date -u   # RTO end point
oc --kubeconfig="$DR_KUBECONFIG" get pods -n inventory-db
oc --kubeconfig="$DR_KUBECONFIG" exec -n inventory-db deploy/postgres -- psql -U dbadmin -d inventory -c "SELECT count(*), max(ts) FROM heartbeat;"
```

**RPO** = baseline timestamp (from `failover.sh`'s first block) minus the
`max(ts)` you get here. Should be bounded by your `schedulingInterval`.

**RTO** — report it decomposed if you hit the manual steps above: the
automated storage failover time (the real platform number) is genuinely
different from the manual-step time, and conflating them into one number
hides which parts are actually production-ready automation.

## Failback

```bash
oc --kubeconfig="$HUB_KUBECONFIG" patch drpc inventory-db-drpc -n inventory-db --type merge  -p '{"spec":{"action":"Relocate","preferredCluster":"primary"}}'
oc --kubeconfig="$DR_KUBECONFIG" scale deployment postgres -n inventory-db --replicas=0
```
Same considerations apply symmetrically in reverse.
