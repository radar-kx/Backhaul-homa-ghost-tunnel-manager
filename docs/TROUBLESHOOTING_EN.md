# Troubleshooting

## Client service is active but user traffic times out

Check, in order:

1. `sudo backhaul-manager doctor` on the entry server.
2. The Client log contains `control channel established successfully`.
3. Control and public ports are open in both host and provider firewalls.
4. The country domain points to the correct entry-server IPv4 address.
5. There is no incorrect AAAA record.
6. The user-facing port matches the left side of the Server mapping.
7. The client SNI matches the Xray certificate domain.
8. The mapped Xray destination port is listening on the exit server.

## Control channel cannot connect

```bash
sudo backhaul-manager logs client COUNTRY_NAME
```

- `connection refused`: Server listener is down or the control port is closed.
- `i/o timeout`: firewall, routing, or provider filtering is blocking the path.
- token error: Server and Client tokens differ.

## Core update stops because no digest is available

This is a security stop. Verify server time, DNS, and access to `api.github.com`
and `github.com`, then retry:

```bash
sudo homa binary install --latest
```

`--allow-unverified-download` explicitly bypasses release-hash verification and
is not recommended for normal use.

## Core update reports success but a service later crashes

Version 1.1.10 waits for multiple consecutive active checks. A delayed crash
causes automatic rollback. Inspect both the current and previous boot logs:

```bash
sudo journalctl -u backhaul-NAME-client.service -n 200 --no-pager
sudo homa health
```

## Backup restore is rejected

- The archive must be a regular file directly inside
  `/var/backups/backhaul-manager`.
- Archives containing absolute paths, `..`, symlinks, duplicate entries, or
  unknown files are rejected.
- Version 3 backups preserve the original config path and unit state.
- A failed restore prints the path of the pre-restore safety backup.

## Menu is clipped on a phone

Version 1.1.10 keeps the complete five-line HOMA logo on narrow terminals when
at least 20 rows are available and truncates option labels before they wrap.
Only viewports shorter than 20 rows use the compact `[ HOMA ]` badge. Keep at
least 20 terminal columns available. Reconnect the SSH session if the app
reports stale row/column dimensions.

## One mapped port does not work

Check both the mapping and the local Xray listener:

```bash
sudo homa mapping list backhaul-NAME-server.service
ss -lntp | grep -E ':(8090|8091|8092)[[:space:]]'
```
## Menu flashing or stale pages in Termius

Since version 1.1.11, arrow navigation repaints only the previous and current
selection rows. Status, health, and backup pages are also erased in place after
Enter, so they do not appear above the next menu. Scrollback from before `bh` is
intentionally preserved.
