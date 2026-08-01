#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
sentinel_pid=""
cleanup() {
    if [[ -n "$sentinel_pid" ]]; then
        kill "$sentinel_pid" 2>/dev/null || true
        wait "$sentinel_pid" 2>/dev/null || true
    fi
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

export BH_SKIP_ROOT_CHECK=1
export BH_NO_SYSTEMD=1
export BH_BIN="$TEST_ROOT/usr/local/bin/backhaul"
export BH_CONFIG_DIR="$TEST_ROOT/etc/backhaul"
export BH_STATE_DIR="$TEST_ROOT/etc/backhaul-manager"
export BH_SYSTEMD_DIR="$TEST_ROOT/etc/systemd/system"
export BH_PROJECT_DIR="$TEST_ROOT/opt/backhaul-tunnel-manager"
export BH_MANAGER_BIN="$TEST_ROOT/usr/local/sbin/backhaul-manager"
export BH_MENU_BIN="$TEST_ROOT/usr/local/sbin/backhaul-menu"
export BH_SHORTCUT_BIN="$TEST_ROOT/usr/local/bin/bh"
export BH_CRON_FILE="$TEST_ROOT/etc/cron.d/backhaul-manager-health"
export BH_BACKUP_DIR="$TEST_ROOT/var/backups/backhaul-manager"

install -d "$(dirname "$BH_BIN")" "$BH_SYSTEMD_DIR" "$BH_CONFIG_DIR"
install -d -m 750 "$BH_PROJECT_DIR"
printf 'existing-backhaul-binary\n' >"$BH_BIN"
chmod 755 "$BH_BIN"
before_hash="$(sha256sum "$BH_BIN" | awk '{print $1}')"

"$ROOT_DIR/install.sh" --enable-health-cron 5

after_hash="$(sha256sum "$BH_BIN" | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]]
[[ -x "$BH_MANAGER_BIN" ]]
[[ -x "$BH_MENU_BIN" ]]
[[ -x "$BH_SHORTCUT_BIN" ]]
[[ "$(stat -c '%a' "$BH_PROJECT_DIR")" == "750" ]]
grep -q '^\*/5 ' "$BH_CRON_FILE"
"$BH_MANAGER_BIN" version | grep -q '1.1.11'

printf '\n# rollback-sentinel\n' >>"$BH_PROJECT_DIR/lib/common.sh"
printf '\n# rollback-sentinel\n' >>"$BH_MANAGER_BIN"
project_hash_before_failed_upgrade="$(
    sha256sum "$BH_PROJECT_DIR/lib/common.sh" | awk '{print $1}'
)"
manager_hash_before_failed_upgrade="$(
    sha256sum "$BH_MANAGER_BIN" | awk '{print $1}'
)"
set +e
BH_MENU_BIN="/proc/1/homa-menu" \
    "$ROOT_DIR/install.sh" --skip-binary >/dev/null 2>&1
failed_atomic_upgrade_status=$?
set -e
((failed_atomic_upgrade_status != 0))
[[ "$(sha256sum "$BH_PROJECT_DIR/lib/common.sh" | awk '{print $1}')" == "$project_hash_before_failed_upgrade" ]]
[[ "$(sha256sum "$BH_MANAGER_BIN" | awk '{print $1}')" == "$manager_hash_before_failed_upgrade" ]]

config="$BH_CONFIG_DIR/ru-client.toml"
unit="$BH_SYSTEMD_DIR/backhaul-ru-client.service"
tee "$config" >/dev/null <<'EOF'
[client]
remote_addr = "192.0.2.10:9000"
transport = "wsmux"
token = "0123456789abcdef0123456789abcdef"
EOF
tee "$unit" >/dev/null <<EOF
[Service]
ExecStart=$BH_BIN -c $config
EOF
config_hash_before="$(sha256sum "$config" | awk '{print $1}')"
unit_hash_before="$(sha256sum "$unit" | awk '{print $1}')"

sleep 3600 &
sentinel_pid=$!
pid_before="$sentinel_pid"

"$ROOT_DIR/install.sh" --skip-binary

pid_after="$sentinel_pid"
kill -0 "$sentinel_pid"
[[ "$pid_before" == "$pid_after" ]]
[[ "$(sha256sum "$BH_BIN" | awk '{print $1}')" == "$before_hash" ]]
[[ "$(sha256sum "$config" | awk '{print $1}')" == "$config_hash_before" ]]
[[ "$(sha256sum "$unit" | awk '{print $1}')" == "$unit_hash_before" ]]
"$BH_MANAGER_BIN" version | grep -q '1.1.11'

set +e
"$ROOT_DIR/install.sh" --skip-binary --force-binary >/dev/null 2>&1
conflict_status=$?
"$ROOT_DIR/install.sh" --version >/dev/null 2>&1
missing_value_status=$?
set -e
((conflict_status != 0))
((missing_value_status != 0))

printf 'Install upgrade tests passed.\n'
