# Postmortem 0001: Adding an etcd member took down the whole cluster API

[繁體中文](0001-etcd-quorum-loss-on-slow-disk.zh-TW.md)

| Item | Details |
|---|---|
| Impact | AI cluster API unavailable; all deployments and scheduling stopped |
| Duration | About 1 hour |
| Severity | High (control plane fully down; existing Pods kept running) |

## Summary

To replace the host of a single-node cluster, we joined a new host with the `etcd + control-plane + worker` roles.
The new host's root disk was a low-RPM SMR drive, and it was compiling GPU drivers at the same time. Its etcd member never came up.
The cluster went from 1 vote to 2. Losing one vote meant losing quorum, so the API on the original, healthy node stopped too.

## Timeline (relative)

| T+ | Event |
|---|---|
| 0m | Registered new node `node-b` in Rancher with all three roles |
| 5m | `rke2-server` on `node-b` stuck in `activating`, load average 9–14 |
| 8m | Rancher reports cluster health check failed; the API on the original node `node-a` stops responding as well |
| 20m | Confirmed 2 etcd members, 1 healthy, quorum lost |
| 40m | Deleted the machine object for `node-b` and triggered `etcdSnapshotRestore` |
| 55m | `node-a` finished cluster-reset, API back |

## Root cause

1. etcd is extremely sensitive to disk fsync latency. The SMR drive, combined with a DKMS build running at the same time, meant etcd could not finish starting at all.
2. Going from 1 to 2 members is the most fragile expansion step. With 2 members, quorum is 2, so a problem on either node stops the whole cluster.
   During that window the cluster tolerates fewer failures than a single node does.
3. There was no hardware check before joining the node.

## Detours during troubleshooting

- The restore initially hung in the Shutdown phase. Earlier, to reduce load, we had manually stopped `rancher-system-agent` on `node-b`,
  so Rancher never got the report that rke2 had stopped. It only moved on after we deleted that machine object.
- The operator workstation ran out of memory and several background SSH sessions were OOM-killed. Against a slow node, use short commands, long timeouts, and less parallelism.

## Fix

```yaml
# Set on the cluster object (Rancher provisioning v2)
spec:
  rkeConfig:
    etcdSnapshotRestore:
      name: <latest S3 snapshot name>
      generation: 1
      restoreRKEConfig: none
```

## Prevention

- [x] Hard checks before adding a node (the node is not allowed to join if any fail):
  - Root disk `cat /sys/block/<dev>/queue/rotational` must be `0`
  - Load below threshold, GPU driver ready, automatic updates disabled
- [x] When replacing a node, remove the old node as soon as the new one is Ready, to shorten the 2-vote window.
- [ ] Measure fsync latency with `fio` (etcd's official guidance: WAL fsync 99th percentile < 10ms).
- [ ] Long-term: always run 3 control-plane nodes so a single failure does not affect quorum.
- [x] Runbook updated: when the API is down, first confirm the system-agent on every etcd node is alive, or delete the broken node's machine first.
