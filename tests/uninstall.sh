#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export BH_SKIP_ROOT_CHECK=1
export BH_NO_SYSTEMD=1
export BH_BIN="$TEST_ROOT/usr/local/bin/backhaul"
export BH_CONFIG_DIR="$TEST_ROOT/etc/backhaul"
export BH_SYSTEMD_DIR="$TEST_ROOT/etc/systemd/system"
export BH_PROJECT_DIR="$TEST_ROOT/opt/backhaul-tunnel-manager"
export BH_MANAGER_BIN="$TEST_ROOT/usr/local/sbin/backhaul-manager"
export BH_MENU_BIN="$TEST_ROOT/usr/local/sbin/backhaul-menu"
export BH_SHORTCUT_BIN="$TEST_ROOT/usr/local/bin/bh"
export BH_CRON_FILE="$TEST_ROOT/etc/cron.d/backhaul-manager-health"
export BH_BACKUP_DIR="$TEST_ROOT/var/backups/backhaul-manager"

fail() {
    printf 'Uninstall test failed: %s\n' "$*" >&2
    exit 1
}

create_fixture() {
    install -d "$BH_CONFIG_DIR" "$BH_SYSTEMD_DIR" "$BH_PROJECT_DIR" \
        "$(dirname "$BH_BIN")" "$(dirname "$BH_MANAGER_BIN")" \
        "$(dirname "$BH_CRON_FILE")"
    printf 'core\n' >"$BH_BIN"
    printf 'manager\n' >"$BH_MANAGER_BIN"
    printf 'menu\n' >"$BH_MENU_BIN"
    printf 'shortcut\n' >"$BH_SHORTCUT_BIN"
    printf 'project\n' >"$BH_PROJECT_DIR/README"
    printf 'cron\n' >"$BH_CRON_FILE"
    tee "$BH_CONFIG_DIR/test-client.toml" >/dev/null <<'EOF'
[client]
remote_addr = "192.0.2.10:9000"
transport = "wsmux"
token = "0123456789abcdef0123456789abcdef"
EOF
    tee "$BH_SYSTEMD_DIR/backhaul-test-client.service" >/dev/null <<EOF
[Service]
ExecStart=$BH_BIN -c $BH_CONFIG_DIR/test-client.toml
EOF
}

set +e
BH_PROJECT_DIR="/" "$ROOT_DIR/uninstall.sh" >/dev/null 2>&1
unsafe_project_status=$?
printf 'PURGE\n' |
    BH_CONFIG_DIR="/" "$ROOT_DIR/uninstall.sh" --purge-all >/dev/null 2>&1
unsafe_config_status=$?
set -e
((unsafe_project_status != 0)) ||
    fail "uninstall accepted the filesystem root as the project directory"
((unsafe_config_status != 0)) ||
    fail "purge accepted the filesystem root as the config directory"

create_fixture
"$ROOT_DIR/uninstall.sh" >/dev/null

[[ -e "$BH_BIN" ]] || fail "default uninstall removed the core"
[[ -e "$BH_CONFIG_DIR/test-client.toml" ]] ||
    fail "default uninstall removed a config"
[[ -e "$BH_SYSTEMD_DIR/backhaul-test-client.service" ]] ||
    fail "default uninstall removed a unit"
[[ ! -e "$BH_MANAGER_BIN" && ! -e "$BH_MENU_BIN" &&
   ! -e "$BH_SHORTCUT_BIN" && ! -e "$BH_PROJECT_DIR" ]] ||
    fail "default uninstall left Manager files behind"
[[ ! -e "$BH_CRON_FILE" ]] ||
    fail "default uninstall left the Manager cron file behind"

create_fixture
printf 'PURGE\n' | "$ROOT_DIR/uninstall.sh" --purge-all >/dev/null

[[ ! -e "$BH_BIN" ]] || fail "purge left the core behind"
[[ ! -e "$BH_CONFIG_DIR" ]] || fail "purge left configs behind"
[[ ! -e "$BH_SYSTEMD_DIR/backhaul-test-client.service" ]] ||
    fail "purge left a unit behind"

latest_backup="$(
    find "$BH_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
        -name 'uninstall-*' -printf '%T@ %p\n' |
        sort -nr |
        awk 'NR == 1 {print $2}'
)"
[[ -n "$latest_backup" ]] || fail "purge did not create a backup"
[[ -e "$latest_backup/core/backhaul" ]] ||
    fail "purge backup does not contain the core"
[[ -e "$latest_backup/configs/test-client.toml" ]] ||
    fail "purge backup does not contain the config"
[[ -e "$latest_backup/systemd/backhaul-test-client.service" ]] ||
    fail "purge backup does not contain the unit"

printf 'Uninstall tests passed.\n'
