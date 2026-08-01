#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export BH_SKIP_ROOT_CHECK=1
export BH_NO_SYSTEMD=1
export BH_BIN="$TEST_ROOT/usr/local/bin/backhaul"
export BH_CONFIG_DIR="$TEST_ROOT/etc/backhaul"
export BH_STATE_DIR="$TEST_ROOT/etc/backhaul-manager"
export BH_SYSTEMD_DIR="$TEST_ROOT/etc/systemd/system"
export BH_PROJECT_DIR="$ROOT_DIR"
export BH_MANAGER_BIN="$ROOT_DIR/bin/backhaul-manager"
export BH_MENU_BIN="$ROOT_DIR/bin/backhaul-menu"
export BH_CRON_FILE="$TEST_ROOT/etc/cron.d/backhaul-manager-health"
export BH_BACKUP_DIR="$TEST_ROOT/var/backups/backhaul-manager"

fail() {
    printf 'Backup restore test failed: %s\n' "$*" >&2
    exit 1
}

install -d -m 700 "$BH_CONFIG_DIR"
install -d -m 755 "$BH_SYSTEMD_DIR" "$(dirname "$BH_CRON_FILE")"
cat >"$BH_CONFIG_DIR/test-client.toml" <<'CFG'
[client]
remote_addr = "192.0.2.20:9000"
transport = "wsmux"
token = "0123456789abcdef0123456789abcdef"
CFG
cat >"$BH_SYSTEMD_DIR/backhaul-test-client.service" <<EOF_UNIT
[Unit]
Description=Backup restore test
[Service]
ExecStart=/bin/true -c $BH_CONFIG_DIR/test-client.toml
EOF_UNIT
printf '*/5 * * * * root true\n' >"$BH_CRON_FILE"
chmod 600 "$BH_CONFIG_DIR/test-client.toml"
chmod 644 "$BH_SYSTEMD_DIR/backhaul-test-client.service" "$BH_CRON_FILE"

"$BH_MANAGER_BIN" backup create >/dev/null
archive="$(find "$BH_BACKUP_DIR" -maxdepth 1 -type f -name 'backhaul-backup-*.tar.gz' | head -n1)"
[[ -n "$archive" ]] || fail "backup was not created"

printf 'corrupted config\n' >"$BH_CONFIG_DIR/test-client.toml"
printf 'corrupted unit\n' >"$BH_SYSTEMD_DIR/backhaul-test-client.service"
printf 'corrupted cron\n' >"$BH_CRON_FILE"

if "$BH_MANAGER_BIN" backup restore "$archive" >/dev/null 2>&1; then
    fail "restore succeeded without --yes"
fi

"$BH_MANAGER_BIN" backup restore "$archive" --yes >/dev/null

grep -Fq 'remote_addr = "192.0.2.20:9000"' "$BH_CONFIG_DIR/test-client.toml" ||
    fail "config was not restored"
grep -Fq 'Description=Backup restore test' "$BH_SYSTEMD_DIR/backhaul-test-client.service" ||
    fail "unit was not restored"
grep -Fq '*/5 * * * * root true' "$BH_CRON_FILE" ||
    fail "cron was not restored"
[[ "$(stat -c '%a' "$BH_CONFIG_DIR/test-client.toml")" == "600" ]] ||
    fail "restored config permissions are not 600"
[[ "$(stat -c '%a' "$BH_SYSTEMD_DIR/backhaul-test-client.service")" == "644" ]] ||
    fail "restored unit permissions are not 644"

backup_count="$(find "$BH_BACKUP_DIR" -maxdepth 1 -type f -name 'backhaul-backup-*.tar.gz' | wc -l)"
[[ "$backup_count" -ge 2 ]] || fail "pre-restore safety backup was not created"

outside="$TEST_ROOT/outside.tar.gz"
cp "$archive" "$outside"
if "$BH_MANAGER_BIN" backup restore "$outside" --yes >/dev/null 2>&1; then
    fail "restore accepted an archive outside the backup directory"
fi

malicious_root="$TEST_ROOT/malicious"
mkdir -p "$malicious_root"
printf 'x\n' >"$malicious_root/escape"
tar -czf "$BH_BACKUP_DIR/backhaul-backup-malicious.tar.gz" \
    --transform='s#escape#../escape#' -C "$malicious_root" escape
if "$BH_MANAGER_BIN" backup restore backhaul-backup-malicious.tar.gz --yes >/dev/null 2>&1; then
    fail "restore accepted a path-traversal archive"
fi

metadata_root="$TEST_ROOT/invalid-metadata"
mkdir -p "$metadata_root"
tar -xzf "$archive" -C "$metadata_root"
printf 'rogue config\n' >"$metadata_root/configs/rogue.toml"
printf 'backhaul-rogue-client.service\t%s\trogue.toml\n' \
    "$BH_CONFIG_DIR/rogue.toml" >>"$metadata_root/config-paths.tsv"
tar -czf "$BH_BACKUP_DIR/backhaul-backup-invalid-metadata.tar.gz" \
    -C "$metadata_root" .
if "$BH_MANAGER_BIN" backup restore backhaul-backup-invalid-metadata.tar.gz --yes >/dev/null 2>&1; then
    fail "restore accepted config metadata for a unit missing from the archive"
fi

legacy_root="$TEST_ROOT/legacy-format"
mkdir -p "$legacy_root/configs" "$legacy_root/systemd" "$legacy_root/cron"
cat >"$legacy_root/MANIFEST" <<'EOF_LEGACY_MANIFEST'
created_at=2026-07-30T00:00:00+00:00
manager_version=1.1.8
format_version=2
EOF_LEGACY_MANIFEST
cat >"$legacy_root/configs/legacy-client.toml" <<'EOF_LEGACY_CONFIG'
[client]
remote_addr = "198.51.100.30:9000"
transport = "wsmux"
token = "abcdef0123456789abcdef0123456789"
EOF_LEGACY_CONFIG
cat >"$legacy_root/systemd/backhaul-legacy-client.service" <<EOF_LEGACY_UNIT
[Service]
ExecStart=/bin/true -c $BH_CONFIG_DIR/legacy-client.toml
EOF_LEGACY_UNIT
printf 'backhaul-legacy-client.service\tdisabled\tinactive\n' \
    >"$legacy_root/service-state.tsv"
tar -czf "$BH_BACKUP_DIR/backhaul-backup-legacy-format.tar.gz" \
    -C "$legacy_root" .
"$BH_MANAGER_BIN" backup restore backhaul-backup-legacy-format.tar.gz --yes >/dev/null
grep -Fq '198.51.100.30:9000' "$BH_CONFIG_DIR/legacy-client.toml" ||
    fail "legacy format config was not restored"
grep -Fq 'legacy-client.toml' "$BH_SYSTEMD_DIR/backhaul-legacy-client.service" ||
    fail "legacy format unit was not restored"

format_root="$TEST_ROOT/unsupported-format"
mkdir -p "$format_root"
tar -xzf "$archive" -C "$format_root"
sed -i 's/^format_version=.*/format_version=99/' "$format_root/MANIFEST"
tar -czf "$BH_BACKUP_DIR/backhaul-backup-unsupported-format.tar.gz" \
    -C "$format_root" .
if "$BH_MANAGER_BIN" backup restore backhaul-backup-unsupported-format.tar.gz --yes >/dev/null 2>&1; then
    fail "restore accepted an unsupported backup format"
fi

extra_root="$TEST_ROOT/unreferenced-config"
mkdir -p "$extra_root"
tar -xzf "$archive" -C "$extra_root"
printf 'unreferenced config\n' >"$extra_root/configs/unreferenced.toml"
tar -czf "$BH_BACKUP_DIR/backhaul-backup-unreferenced-config.tar.gz" \
    -C "$extra_root" .
if "$BH_MANAGER_BIN" backup restore backhaul-backup-unreferenced-config.tar.gz --yes >/dev/null 2>&1; then
    fail "restore accepted an unreferenced config file"
fi

if BH_BACKUP_MAX_UNCOMPRESSED_BYTES=1 \
    "$BH_MANAGER_BIN" backup restore "$archive" --yes >/dev/null 2>&1; then
    fail "restore ignored the maximum uncompressed archive size"
fi

printf 'Backup restore tests passed.\n'
