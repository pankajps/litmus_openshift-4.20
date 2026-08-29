# Setup

Assumes: two OpenShift 4.20 clusters already installed with **non-overlapping**
`clusterNetwork`/`serviceNetwork` CIDRs, ODF/Ceph already healthy on both, and
both imported into ACM as managed clusters (`primary`, `dr`).

Non-overlapping CIDRs are a hard requirement here, not a suggestion — Submariner
can't safely bridge two clusters with the same pod/service ranges, and Globalnet
(the usual fix for overlapping CIDRs) isn't supported with ODF Regional-DR.
Decide this before installing either cluster.

## 1. Submariner

Label a gateway node and, if you're on a fully private network with no real
public IP, annotate it too (see the comment in `02-submariner-config.yaml` —
skipping this can cause a completely silent, indefinite hang):

```bash
oc --kubeconfig=<primary-kubeconfig> label node <worker> submariner.io/gateway=true
oc --kubeconfig=<dr-kubeconfig> label node <worker> submariner.io/gateway=true
```

Apply the broker once, on the Hub:

```bash
oc apply -f 01-submariner-broker.yaml
```

Apply the per-spoke config (edit `<spoke-namespace>` to the real `ManagedCluster`
name each time — `primary`, then `dr`):

```bash
oc apply -f 02-submariner-config.yaml
```

Confirm both sides:

```bash
oc get managedclusteraddon submariner -n primary -o jsonpath='{.status.conditions}' | jq
oc get managedclusteraddon submariner -n dr -o jsonpath='{.status.conditions}' | jq
```

Look for `SubmarinerConnectionDegraded: False`. If the tunnel comes up but a
health-check ping keeps failing, check the *actual* VXLAN port the gateway is
using before assuming a documented default is correct:

```bash
oc --kubeconfig=<spoke-kubeconfig> debug node/<gateway-node> -- \
  chroot /host ip -d link show type vxlan
```

Open that exact UDP port between both clusters' security groups/firewalls.

## 2. RamenDR

Enable multi-cluster service export on each `StorageCluster` (see the comment
in `03-mirrorpeer.yaml`), then:

```bash
oc apply -f 03-mirrorpeer.yaml
```

```bash
oc get mirrorpeer mirrorpeer-primary-dr -o jsonpath='{.status}' | jq
```

Wait for `phase: ExchangedSecret`, then get the real S3 profile names it
generated and fill them into `04-drcluster.yaml`:

```bash
oc get configmap ramen-hub-operator-config -n openshift-operators \
  -o jsonpath='{.data.ramen_manager_config\.yaml}' | grep s3ProfileName
```

```bash
oc apply -f 04-drcluster.yaml
oc apply -f 05-drpolicy.yaml
```

Confirm:

```bash
oc get drcluster primary -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="Validated")'
oc get drcluster dr -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="Validated")'
oc get drpolicy dr-policy-primary-dr -o jsonpath='{.status}' | jq
```

Real, independent proof this is actually working — not just the status field:

```bash
oc --kubeconfig=<primary-kubeconfig> get volumereplicationclass
oc --kubeconfig=<dr-kubeconfig> get volumereplicationclass
```

Both should show the identical object name and provisioner.
