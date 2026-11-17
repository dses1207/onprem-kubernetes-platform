# Architecture

[繁體中文](architecture.zh-TW.md)

## 1. End-to-end flow

A request travels from the user to the data through these layers:

```
User → DNS (*.example.com → VIP) → kube-vip → Traefik → Service → Pod → PVC (Longhorn) → local disk
                                                                         ↘ scheduled backups to S3
```

The clusters themselves are provisioned and upgraded through Rancher. etcd snapshots also go to S3.

## 2. Layer by layer

### 2.1 Ingress: DNS, kube-vip, Traefik

- Each system gets one `<name>.example.com` A record. All of them point at the same VIP, and Traefik routes by Host.
- There is no cloud load balancer on-prem. kube-vip announces the VIP over L2 ARP and also hands out IPs for `type: LoadBalancer` services from a fixed address pool.
- Traefik has a default TLSStore holding a wildcard certificate, so an Ingress only needs `tls.hosts` and no namespace has to carry its own certificate. Port 80 always redirects to 443.
- Traefik over ingress-nginx: upstream has announced the retirement of ingress-nginx, and newer RKE2 releases default to Traefik.

### 2.2 Compute: node roles and scheduling

| Role | Count | Taint | Purpose |
|---|---|---|---|
| control-plane / etcd | 3 | control-plane | API, etcd |
| infra worker | 3 | `node-role/infra:NoSchedule` | Platform components: monitoring, logging, MQ |
| app worker | 3 | none | General application workloads |
| GPU worker | 1+ | as needed | Inference / training |

Lesson learned: the scheduler looks at requests, not actual usage. We once had nodes at 5% real CPU usage but 68% of CPU requested.
After cordoning one node, every CronJob went Pending. The fix was to adjust requests, not to add machines.

### 2.3 Storage: Longhorn

- PVCs join a backup group by label, so Longhorn settings do not need to change for each new volume (see `platform/longhorn/`):
  - `db` group: snapshot every 6 hours (keep 4) plus a daily S3 backup (keep 7)
  - `daily` group: daily S3 backup (keep 3)
- Node shutdown protection (see `platform/node-shutdown-protection/`): the RKE2 shutdown sequence does not detach volumes cleanly,
  so there are two layers of defense, kubelet graceful shutdown and a drain before shutdown.
- When VMs are cloned from the same image, the diskUUID in `longhorn-disk.cfg` is duplicated. See [postmortem 0002](postmortems/0002-network-partition-longhorn-fs-corruption.md).

### 2.4 Database: CloudNativePG

- 3 instances, synchronous HA replication slots, WAL continuously archived to S3.
- `max_slot_wal_keep_size` must be set. Without it, a replica that stays down for a long time keeps its slot holding WAL indefinitely, and the WAL volume fills up.

### 2.5 GPU: DRA

- The GPU Operator runs in DRA mode. Pods request GPUs through `resourceClaims` instead of `nvidia.com/gpu: 1`.
- A CEL selector can target specific cards, for example to exclude a card on the node that another program is already using.
- Inference and training are separated by PriorityClass. When resources run short, training is evicted first (see `platform/scheduling/`).

### 2.6 Observability

- Metrics: kube-prometheus-stack. Alertmanager pushes to the team chat room through a relay service.
- Logs: fluent-bit DaemonSet → Loki. The tolerations have to cover every node, including the tainted infra and storage nodes.
  Otherwise, when something breaks, the storage component logs are exactly the ones you cannot find.

## 3. Disaster recovery

| Scenario | Approach |
|---|---|
| etcd quorum lost | Rancher `etcdSnapshotRestore` from the latest S3 snapshot |
| Volume filesystem corrupted | Take a snapshot to preserve the current state first, then restore from a healthy replica or an S3 backup |
| Single node down for a long time | Remove the machine and add a replacement node; databases fail over automatically through HA |
