# Node shutdown protection

[繁體中文](README.zh-TW.md)

Prevents ext4 corruption on Longhorn volumes when a node shuts down.

## Why this is needed

The RKE2/k3s shutdown sequence does not detach Longhorn volumes cleanly
([longhorn#7206](https://github.com/longhorn/longhorn/issues/7206); a maintainer confirmed it is a design gap).

How the corruption happens:
1. Shutdown starts and containerd / instance-manager are stopped
2. The engine process is gone, but ext4 is still mounted and the page cache still holds dirty pages
3. The iSCSI connection drops, the kernel tries to flush the superblock, and gets an I/O error
4. ext4 switches to read-only, but the metadata is already half written
5. After reboot, journal replay cannot repair it, `fsck` fails, and the PVC will not mount

Longhorn still shows `robustness: healthy` at this point, because the block layer cannot see the state of ext4 above it.

## Two layers of defense

The upstream Kubernetes position is that the two are complementary, not alternatives:

| Layer | Files | Covers |
|---|---|---|
| kubelet graceful shutdown | `kubelet-shutdown-config.yaml`<br>`60-shutdown-grace.yaml` | Unplanned shutdown (`reboot`, `shutdown`) |
| Automatic drain on shutdown | `rke2-drain-on-shutdown.service`<br>`rke2-drain-node.sh` | Same, and also moves the pods off the node |

Neither covers `reboot -f`, a hardware power loss, or a forced VM power-off, because those bypass the systemd inhibitor lock entirely.
Planned maintenance should still be drained by hand.

## The InhibitDelayMaxSec limit

Graceful node shutdown relies on the systemd inhibitor lock, and `InhibitDelayMaxSec` in `/etc/systemd/logind.conf`
**defaults to only 30 seconds**, which cuts off kubelet's `shutdownGracePeriod`.
If you set 180s without changing logind, you only get 30s.

`systemd-logind` does not support reload, and restarting it kicks every SSH session,
so the install script only writes the config file. The new value takes effect after the node reboots.

```bash
systemctl show systemd-logind -p InhibitDelayMaxUSec --value
# 30s  = not in effect yet
# 5min = in effect
```

## Deployment

```bash
sudo bash install-shutdown-protection.sh   # run on every node; safe to re-run
```

The script does not restart rke2. At the end it prints the drain / restart / uncordon steps to run by hand during a maintenance window.
