# FAQ

### Is this crash-consistent or application-consistent replication?

Crash-consistent. RBD async mirroring via snapshots captures the volume's
on-disk state at each 5-minute interval — it doesn't coordinate with
PostgreSQL to flush and quiesce first. Postgres's own WAL recovery on
startup is what makes the restored data usable rather than corrupted. For a
database that doesn't have that kind of crash recovery built in, this same
setup could hand you a genuinely inconsistent volume. Worth knowing before
assuming this generalizes to any workload.

### Did you test failback, or only one direction?

Both directions work via the same `Relocate` action (see `TEST.md`), and
the mechanism is symmetric — but the *measured* RPO/RTO numbers in the
writeup are from Primary→DR only. Failback was verified to complete
correctly, not independently timed.

### What happens if both sites think they're primary at the same time?

Not tested here, and worth being direct about that. RamenDR/Ceph RBD
mirroring depends on the previous primary genuinely being demoted before
the new one is promoted — this build never simulated a scenario where
Primary comes back online mid-failover without being told to demote first.
Real split-brain protection would need cluster fencing (RamenDR has a
`DRCluster.spec.clusterFence` field for this, unused in this build) —
that's a real gap in what was actually proven here, not a solved problem.

### How does client traffic actually get redirected to DR?

It doesn't, in this test — explicitly called out as "not exercised" in the
architecture diagram. This test proves the data and the workload come up
correctly on DR. Getting real users there (DNS cutover, a GSLB, a global
load balancer) is a separate, unaddressed layer.

### Why not fix the OADP/self-signed cert issue by just using a real CA?

That's genuinely the real fix, not a workaround — noted as such in
`TEST.md`. This environment uses a fully air-gapped internal domain with a
self-signed cluster CA throughout (not just for this one endpoint), so
"just get a real cert" means either running an internal CA that RamenDR's
dynamically-generated Velero object would trust automatically, or filing
this as a real gap against RamenDR itself, since as of the version tested
(`odr-cluster-operator` v4.20.17-rhodf) there's no config surface to
specify a CA for that specific auto-generated object.

### Why plain PostgreSQL and not a proper HA Postgres operator (Patroni, CrunchyData, etc.)?

Deliberate — the point of this test was the *platform's* DR mechanism
(Submariner + RamenDR + Ceph), not database-level HA. A real production
Postgres deployment would likely run its own HA operator *and* sit under
this same DR layer — those are complementary, not competing. Using a
plain Deployment kept the variable being tested isolated to the platform.

### Is 44 minutes an acceptable RTO for a real production SLA?

The platform's own automated mechanism — storage-level failover — was
single-digit minutes; see the RTO breakdown in `TEST.md`. The other ~36
minutes were real, mostly one-time diagnostic and setup work (a still-open
OADP gap, a missing image mirror, a UID-range mismatch) that a pre-built
runbook removes almost entirely on a repeat run. Whether *that* residual
number meets a given SLA depends on the SLA — this repo gives you the real
components to do that math yourself rather than a marketing number.

### Does this scale beyond two sites?

Not tested. RamenDR's `DRPolicy` takes a list of `DRClusters`, and the
upstream project does document N-way topologies, but everything in this
repo — the CIDR planning, the Submariner mesh, the test itself — was built
and proven for exactly two spokes plus a hub.

### How would you monitor replication health continuously, not just during a manual test?

Not built out here — this was a one-time, manually-triggered, manually-verified
test (`rbd mirror pool status` run by hand). A real deployment would want
this alerted on continuously (Ceph's own mirror daemon health, RamenDR's own
conditions, `lastGroupSyncTime` drift) rather than checked on demand. Real,
honest gap in what's here versus what a production setup needs.

### RBD only, or does this cover CephFS too?

RBD only (`ocs-storagecluster-ceph-rbd`, block storage) — matches the
`ReadWriteOnce` Postgres volume used in the test. RamenDR does support
CephFS-backed volumes too; not exercised in this build.

### Have you filed this as a bug against RamenDR/OADP upstream?

Not yet, as of this writeup. The diagnosis is documented in detail in
`TEST.md` and the runbook (repo/blog link) — happy to file it upstream, or
if someone reading this already knows the real fix, genuinely interested.
