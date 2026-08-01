# Backhaul Homa Ghost Tunnel Manager

A safe, English-language CLI and interactive menu for installing and managing
multiple independent [Backhaul](https://github.com/Musixal/Backhaul) tunnels on
Ubuntu and Debian.

Version `1.1.11` can create new server/client tunnels and discover existing or
legacy `backhaul-*.service` units without rewriting their configuration.

## Highlights

- Multiple independent Server and Client tunnels
- IPv4 and bracketed IPv6 endpoints
- `tcp`, `tcpmux`, `ws`, `wss`, `wsmux`, and `wssmux`
- Mobile-terminal menu with arrow-key and numeric navigation
- Incremental two-row selection repaint to avoid full-menu flashing in Termius
- Temporary status/backup pages are cleared on return without polluting scrollback
- Compact rendering down to 12 rows and 20 columns without option wrapping
- Transactional config/unit deployment with automatic rollback
- Conditional health checks that do not restart healthy services
- Versioned backups and transactional restore with a pre-restore safety backup
- Latest official Backhaul release discovery and GitHub asset SHA-256 checking
- Delayed crash detection after core updates and binary rollback
- Safe retirement archives instead of immediate destructive deletion
- Automated Bash, PTY, backup, rollback, upgrade, and uninstall tests

## Install beside existing tunnels

This preserves the current Backhaul binary, configs, services, and running PIDs:

```bash
bash <(curl -fsSL --ipv4 \
  https://raw.githubusercontent.com/radar-kx/Backhaul-homa-ghost-tunnel-manager/main/install.sh) \
  --skip-binary --enable-health-cron 5
```

Then run:

```bash
sudo bh
```

## Fresh installation

Install the tested default Backhaul core:

```bash
bash <(curl -fsSL --ipv4 \
  https://raw.githubusercontent.com/radar-kx/Backhaul-homa-ghost-tunnel-manager/main/install.sh) \
  --enable-health-cron 5
```

Install the latest official release instead:

```bash
sudo ./install.sh --latest --enable-health-cron 5
```

Online downloads require the SHA-256 digest published in GitHub release
metadata. If an old release has no published digest, the operation stops. The
explicit `--allow-unverified-download` bypass exists for exceptional cases and
should not be used unless the file was validated independently.

## Main menu

```text
1) Create a new tunnel (IPv4 / IPv6)
2) Manage tunnels
3) Show all tunnel statuses
4) Health check and auto-repair
5) Manage health-check cron
6) Backups and restore
7) Network diagnostics
8) Install or update the Backhaul core
9) Update Manager from GitHub
0) Exit
```

## Useful commands

```bash
sudo bh list
sudo bh health --repair
sudo bh cron status
sudo bh backup create
sudo bh backup list
sudo bh backup restore /var/backups/backhaul-manager/BACKUP.tar.gz --yes
sudo bh binary install --latest
sudo bh doctor
```

## Create a Server

```bash
sudo bh server add \
  --name tr \
  --bind 0.0.0.0:9300 \
  --public-host 203.0.113.10 \
  --transport wsmux \
  --map 8300=127.0.0.1:8090 \
  --map 8301=127.0.0.1:8091 \
  --map 8302=127.0.0.1:8092 \
  --open-firewall
```

The generated Client command contains the tunnel token. Keep it private.

## Create a Client

```bash
sudo bh client add \
  --name tr \
  --remote 203.0.113.10:9300 \
  --transport wsmux \
  --token 'TOKEN_GENERATED_ON_SERVER'
```

Use brackets for IPv6: `[2001:db8::10]:9300`.

## Backup restore safety

Restore accepts only regular backup archives located directly in
`/var/backups/backhaul-manager`. It rejects absolute paths, `..` traversal,
symlinks, duplicate entries, unknown metadata, unreferenced files, unsafe config
paths, invalid unit/config relationships, and archives that exceed the extraction
size limit. A new safety backup is created before live files are changed. If
restored services do not remain healthy, the previous files and service states
are restored.

## Files

| Path | Purpose |
|---|---|
| `/usr/local/bin/backhaul` | Backhaul core |
| `/usr/local/bin/bh` | Short menu/CLI command |
| `/usr/local/sbin/backhaul-manager` | CLI manager |
| `/usr/local/sbin/backhaul-menu` | Interactive menu |
| `/opt/backhaul-tunnel-manager` | Installed Manager files |
| `/etc/backhaul` | Restricted tunnel configs |
| `/etc/systemd/system/backhaul-*.service` | Tunnel units |
| `/etc/cron.d/backhaul-manager-health` | Scheduled health check |
| `/var/backups/backhaul-manager` | Backups and retirement archives |

## Documentation

- [English deployment guide](docs/DEPLOYMENT_EN.md)
- [English troubleshooting guide](docs/TROUBLESHOOTING_EN.md)
- [Persian deployment guide](docs/DEPLOYMENT_FA.md)
- [Persian troubleshooting guide](docs/TROUBLESHOOTING_FA.md)

## Uninstall

The default uninstall removes only the Manager and its cron entry. Active
Backhaul tunnels, configs, and core remain untouched:

```bash
sudo ./uninstall.sh
```

Full removal requires `--purge-all`, an explicit confirmation phrase, and a
verified backup before files are removed.

## License

The Manager is released under the MIT License. Backhaul is a separate project
with its own license; its binary and source code are not redistributed here.
