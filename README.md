<div align="center">

# Gost IP6 Script — Optimized Fork

[English](README.md) | [فارسی](README-Fa.md)

An interactive Bash installer/manager for **Gost** tunnels (IPv4 / IPv6), with automatic
server optimization and fast (jsDelivr CDN) downloads.

</div>

---

## Install

Run as **root** on your server:

```bash
bash <(curl -Ls https://cdn.jsdelivr.net/gh/Aknuun/Gost-ip6@v2.3.1/install.sh)
```

The script self-installs to `/etc/gost/install.sh`, so afterwards you can just type:

```bash
gost
```

to open the menu again.

> Requirements: root access, `bash`, and a Debian/Ubuntu-like system (tested on Ubuntu 20.04 / 22.04 / 24.04 / 26.04).

---

## What this fork adds

This is a fork of [masoudgb/Gost-ip6](https://github.com/masoudgb/Gost-ip6) (v2.2.0)
with production hardening and quality-of-life improvements:

### 1. Automatic swap
Before installing, a swap file is created sized to the server's RAM and free disk
(e.g. ~2 GB swap on a 2 GB RAM server). This prevents the kernel OOM-killer from
killing the tunnel under load. `vm.swappiness` is set to `10` (safety net, not active swapping).

### 2. Kernel / network tuning
Written to `/etc/sysctl.d/99-gost-tuning.conf` and applied persistently:
- `nf_conntrack_max = 262144`
- `somaxconn`, `tcp_max_syn_backlog`, `netdev_max_backlog`
- `tcp_tw_reuse`, `tcp_fin_timeout`, `tcp_slow_start_after_idle`
- larger `rmem`/`wmem` buffers, higher `fs.file-max`, `swappiness=10`

### 3. Journald size cap
`SystemMaxUse=200M` so gost's per-connection logging can't fill the disk
(the original setup could grow journals past 1 GB).

### 4. Hardened systemd units
Each `gost_*.service` is generated with:
```
Restart=always
RestartSec=5
StartLimitIntervalSec=0
OOMScoreAdjust=-1000
LimitNOFILE=1048576
TasksMax=infinity
After=network-online.target
```
So if gost crashes or is OOM-killed it comes back automatically, and it is
protected from being chosen by the OOM-killer.

### 5. Fast downloads (jsDelivr CDN)
Gost binaries and the script itself are downloaded from the jsDelivr CDN instead
of GitHub, which is much faster/reliable from Iran. Plain `wget` with a `curl`
fallback — no changes are made to the server's DNS settings.

### 6. No version prompt
The tunnel install always uses the **official Gost 2.11.5** — it no longer asks
"official or latest".

---

## Menu options

| # | Option |
|---|--------|
| 1 | Gost Tunnel By IP4 |
| 2 | Gost Tunnel By IP6 |
| 3 | Gost Status |
| 4 | Update Script |
| 5 | Add New IP |
| 6 | Change Gost Version (manual) |
| 7 | Auto Restart Gost |
| 8 | Auto Clear Cache |
| 9 | Install BBR |
| 10 | Uninstall |
| 11 | Apply Optimizations (Swap + Tuning) |
| 12 | Exit |

When you install a tunnel (options 1 or 2), the optimizations are applied
automatically.

---

## Configuration notes

- Protocol choices: `tcp`, `udp`, `grpc`.
- Port range must be between `54` and `65000`; avoid duplicate ports.
- Re-open the menu any time with the `gost` command.

---

## Credits

- Original script: **Masoud Gb** — special thanks to **Hamid Router**
- Optimized fork: **Aknuun**

Original repository: https://github.com/masoudgb/Gost-ip6

## Version

`v2.3.1-opt`
