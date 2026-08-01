# Staged deployment on active servers

Use this guide when Backhaul services are already enabled and active. Installing
with `--skip-binary` does not replace the current core, configs, units, or PIDs.

## Recommended order

Start with a low-risk Client and leave central entry servers until last. Verify
each server before moving to the next one.

## Install the Manager only

```bash
bash <(curl -fsSL --ipv4 \
  https://raw.githubusercontent.com/radar-kx/Backhaul-homa-ghost-tunnel-manager/main/install.sh) \
  --skip-binary --enable-health-cron 5
```

Validate:

```bash
sudo bh list
sudo bh health
sudo bh cron status
pgrep -a backhaul
```

Existing Backhaul PIDs should remain unchanged during a Manager-only upgrade.

## Staged core update

Create a backup and update one low-risk Client first:

```bash
sudo bh backup create
sudo bh binary install --latest
sudo bh health
```

The release asset digest is checked before extraction. Services that were active
before the update are restarted and must pass several consecutive active-state
checks. If a service crashes after an apparently successful restart, the
previous binary and service states are restored.

## Restore a backup

```bash
sudo bh backup list
sudo bh backup restore /var/backups/backhaul-manager/BACKUP.tar.gz --yes
```

Restore creates another safety backup before changing live files. Verify all
units and logs afterwards:

```bash
sudo bh list
sudo bh health
sudo journalctl -u backhaul-NAME-client.service -n 100 --no-pager
```

## Reboot validation

Reboot servers one at a time. Wait until the current server and tunnel have
fully recovered before rebooting the next server. Do not reboot both ends of a
critical tunnel simultaneously.
