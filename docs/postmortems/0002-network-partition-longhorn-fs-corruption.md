# Postmortem 0002: Partial network partition corrupted a database filesystem, then WAL filled the disk

[繁體中文](0002-network-partition-longhorn-fs-corruption.zh-TW.md)

| Item | Details |
|---|---|
| Impact | Multiple stateful services on the production cluster; the authentication service's database went down with them |
| Duration | Network outage about 18 minutes; data repair and the follow-up incident took several days |
| Severity | High |

## Summary

A switch-level problem cut two workers off from part of the control plane for more than 5 minutes.
controller-manager marked both nodes unreachable, and after 300 seconds taint-based eviction marked the
Longhorn instance-manager on those nodes for deletion. As soon as the network came back, kubelet acted on that and killed it.
Every volume engine on those nodes went away with it, unflushed writes were lost, and ext4 was corrupted.

Five days later came a second incident. The corrupted database replica had never been repaired, so its replication slot kept WAL from being recycled.
Eventually the primary's WAL volume filled up and the whole database cluster stopped with a PANIC.

## Timeline (relative)

| T+ | Event |
|---|---|
| 0m | `no route to host` between `worker-2`, `worker-4` and part of the control plane (L2/ARP broken) |
| 1m | etcd leader election fails on one control-plane node; rke2-server exits on its own |
| 5m | instance-manager on both workers marked for deletion by taint-eviction-controller, because its toleration is only 300s |
| 18m | Network recovers; kubelet immediately kills instance-manager and the iSCSI targets disappear |
| 20m | Kernel logs `lost sync page write`; database Pods move to other nodes and fail fsck |
| Day 5 | CNPG primary logs `PANIC: could not write to file "pg_wal/xlogtemp": No space left on device` |

## Root cause

### Direct cause: the storage engine was killed by eviction

The default `node.kubernetes.io/unreachable` toleration on Longhorn instance-manager is only 300 seconds.
For a storage component, a temporary network outage was handled as a dead node, and that handling is what actually corrupted the data.

### Underlying cause: duplicate diskUUID

The nodes were cloned from the same VM image, and all 6 had the exact same diskUUID in `/var/lib/longhorn/longhorn-disk.cfg`.
Longhorn nodes kept fighting over replica ownership. Within 45 seconds, 98 of 114 replicas had a flapping `nodeID`.
On attach, a replica process could start on the wrong node and read empty or stale data.
This also ruled out repairing by evicting nodes one at a time.

### Follow-up incident: no limit on the replication slot

- The corrupted replica never came back, and its HA replication slot stayed at an old LSN.
- `max_slot_wal_keep_size` was not set (default `-1`, unlimited).
- `archive_timeout = 5min`: even when idle, this produces about 4.6 GB of WAL per day, so a 20 GiB volume lasts roughly 4–5 days.
- The database Cluster sat at `Ready=False` for 5 days with no alert.

## Troubleshooting notes

1. When several Pods restart at once with fsck errors, first check the syslog on each node for the same time window to see whether it is a network problem:
   ```bash
   kubectl get --raw /api/v1/nodes/<node>/proxy/logs/syslog | grep -i "no route to host"
   ```
2. Longhorn showing `robustness: healthy` does not mean the filesystem is intact. The block layer cannot see the state of ext4 above it.
3. Finding out why WAL is not recycled: archiving works and the standby is streaming, so the remaining suspect is the slot:
   ```sql
   SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
   FROM pg_replication_slots;
   ```

## Fix

### Database volume

1. Before touching anything, snapshot every affected volume.
2. Find the healthy replica whose head was written last, copy it to an isolated directory, mount it, extract pgdata, and confirm PostgreSQL crash recovery succeeds.
3. When restoring from S3, specify `backupTargetName`. Otherwise you get an empty volume, and CSI will run mkfs on it automatically.

### WAL volume full

1. Snapshot to preserve the current state.
2. Grow `walStorage`. The operator will not expand the PVC on its own once the disk is already full, so patch the PVC by hand.
3. Set the corrupted replica's PV to `Retain`, then delete that Pod and PVC. The operator creates a new instance and removes the old slot automatically.
4. WAL dropped from 20 GB to 600 MB, 3/3 healthy.
5. Set `max_slot_wal_keep_size = 10GB` (takes effect on reload).

## Prevention

- [ ] Regenerate the Longhorn diskUUID on every node; add a "remove longhorn-disk.cfg" step to the VM image process.
- [x] Set `max_slot_wal_keep_size` on the database.
- [ ] New alerts: CNPG Cluster `Ready=False` for more than 15 minutes, WAL volume usage > 70%.
- [ ] Move single-instance databases to HA, or at minimum confirm the daily S3 backup succeeds.
- [x] Node shutdown protection (see `platform/node-shutdown-protection/`).
- [ ] Evaluate tuning the unreachable toleration for storage components, and add network-level monitoring (switches, ARP).
