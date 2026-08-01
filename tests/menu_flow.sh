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
export BH_MANAGER_BIN="$TEST_ROOT/usr/local/sbin/backhaul-manager"
export BH_MENU_BIN="$ROOT_DIR/bin/backhaul-menu"
export BH_CRON_FILE="$TEST_ROOT/etc/cron.d/backhaul-manager-health"
export BH_BACKUP_DIR="$TEST_ROOT/var/backups/backhaul-manager"
export FAKE_MENU_LOG="$TEST_ROOT/menu-actions.log"

install -d "$TEST_ROOT/fake-bin" "$(dirname "$BH_BIN")" \
    "$(dirname "$BH_MANAGER_BIN")" "$BH_CONFIG_DIR" "$BH_SYSTEMD_DIR"

tee "$BH_BIN" >/dev/null <<'EOF'
#!/usr/bin/env bash
printf 'backhaul v0.7.2\n'
EOF
chmod 755 "$BH_BIN"

tee "$BH_MANAGER_BIN" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >>"${FAKE_MENU_LOG:?}"
printf '\n' >>"${FAKE_MENU_LOG:?}"

if [[ "${FAKE_MANAGER_FAIL_ON:-}" == "${1:-}" ]]; then
    printf '[ERROR] simulated %s failure\n' "${1:-}" >&2
    exit 7
fi

case "${1:-}" in
    list)
        printf 'server    de    enabled    active    backhaul-de-server.service\n'
        ;;
    status)
        printf 'Status: active (%s)\n' "${2:-unknown}"
        ;;
    cron)
        if [[ "${2:-}" == "status" ]]; then
            printf 'Cron: not-installed\n'
        else
            printf '[OK] cron %s\n' "${2:-}"
        fi
        ;;
    health)
        printf 'Summary: total=1 healthy=1 repaired=0 skipped=0 failed=0\n'
        ;;
    backup)
        printf '[OK] backup %s\n' "${2:-}"
        ;;
    mapping)
        if [[ "${2:-}" == "list" ]]; then
            printf 'Mappings:\n  8200=127.0.0.1:8090\n'
        else
            printf '[OK] mapping %s\n' "${2:-}"
        fi
        ;;
    doctor)
        printf 'Diagnostics completed.\n'
        ;;
    restart|retire|server|client|binary)
        printf '[OK] %s\n' "${1:-}"
        ;;
    *)
        printf '[OK] %s\n' "${1:-command}"
        ;;
esac
EOF
chmod 755 "$BH_MANAGER_BIN"

tee "$TEST_ROOT/fake-bin/systemctl" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u
printf 'systemctl %q ' "$@" >>"${FAKE_MENU_LOG:?}"
printf '\n' >>"${FAKE_MENU_LOG:?}"
case "${1:-}" in
    is-active)
        printf 'active\n'
        exit 0
        ;;
    is-enabled)
        printf 'enabled\n'
        exit 0
        ;;
    start|stop|restart|enable|disable)
        exit 0
        ;;
esac
exit 0
EOF
chmod 755 "$TEST_ROOT/fake-bin/systemctl"

tee "$TEST_ROOT/fake-bin/journalctl" >/dev/null <<'EOF'
#!/usr/bin/env bash
printf 'Fake journal output.\n'
EOF
chmod 755 "$TEST_ROOT/fake-bin/journalctl"

tee "$TEST_ROOT/fake-bin/ss" >/dev/null <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$TEST_ROOT/fake-bin/ss"

tee "$TEST_ROOT/fake-bin/sysctl" >/dev/null <<'EOF'
#!/usr/bin/env bash
printf 'test-value\n'
EOF
chmod 755 "$TEST_ROOT/fake-bin/sysctl"

export PATH="$TEST_ROOT/fake-bin:$PATH"

server_config="$BH_CONFIG_DIR/de-server.toml"
server_unit="$BH_SYSTEMD_DIR/backhaul-de-server.service"
tee "$server_config" >/dev/null <<'EOF'
[server]
bind_addr = "0.0.0.0:9200"
transport = "wsmux"
token = "0123456789abcdef0123456789abcdef"
ports = ["8200=127.0.0.1:8090"]
EOF
tee "$server_unit" >/dev/null <<EOF
[Service]
ExecStart=$BH_BIN -c $server_config
EOF

fail() {
    printf 'Menu flow test failed: %s\n' "$*" >&2
    exit 1
}

run_menu() {
    local input="$1"
    printf '%b' "$input" |
        timeout 8 "$BH_MENU_BIN" 2>&1
}

assert_contains() {
    local output="$1"
    local expected="$2"
    grep -Fq -- "$expected" <<<"$output" ||
        fail "missing menu text: $expected"
}

main_output="$(run_menu '0\n')"
assert_contains "$main_output" 'HOMA GHOST TUNNEL MANAGER'
assert_contains "$main_output" 'Manager version: 1.1.11'
assert_contains "$main_output" 'Create a new tunnel (IPv4 / IPv6)'
assert_contains "$main_output" 'Update Manager from GitHub'

submenu_output="$(
    run_menu '1\n0\n4\n0\n5\n0\n6\n0\n7\n0\n8\n0\n9\nn\n\n0\n'
)"
assert_contains "$submenu_output" 'Configure the Iran entry server'
assert_contains "$submenu_output" 'Check and auto-repair'
assert_contains "$submenu_output" 'Set a custom interval'
assert_contains "$submenu_output" 'Create a new backup'
assert_contains "$submenu_output" 'Run full Backhaul diagnostics'
assert_contains "$submenu_output" 'Show core version and hash'

run_menu \
    '1\n1\nde\n0.0.0.0:9200\n203.0.113.10\n\n8200=127.0.0.1:8090\n\ny\n\n0\n' \
    >/dev/null
run_menu \
    '1\n2\nde\n203.0.113.10:9200\n\nabcdef0123456789abcdef0123456789\ny\n\n0\n' \
    >/dev/null

status_output="$(run_menu '2\n1\n\n0\n0\n')"
assert_contains "$status_output" 'Tunnel management: backhaul-de-server.service'
assert_contains "$status_output" 'Status: active'

logs_output="$(run_menu '2\n2\n\n0\n0\n')"
assert_contains "$logs_output" 'Fake journal output.'

run_menu '2\n3\ny\n\n0\n0\n' >/dev/null
run_menu '2\n4\n1\n\n0\n0\n' >/dev/null
run_menu '2\n4\n2\nn\n0\n0\n' >/dev/null
run_menu '2\n4\n3\n\n0\n0\n' >/dev/null
run_menu '2\n4\n4\n\n0\n0\n' >/dev/null
run_menu '2\n4\n5\ny\n\n0\n0\n' >/dev/null
run_menu '2\n5\n1\n\n0\n0\n' >/dev/null
run_menu '2\n5\n2\n8201=127.0.0.1:8091\ny\n\n0\n0\n' >/dev/null
run_menu '2\n5\n3\n8200\ny\n\n0\n0\n' >/dev/null

config_output="$(run_menu '2\n6\n\n0\n0\n')"
assert_contains "$config_output" '***REDACTED***'
if grep -Fq '0123456789abcdef0123456789abcdef' <<<"$config_output"; then
    fail "safe config view exposed the token"
fi

run_menu '2\n7\nn\n0\n0\n' >/dev/null
invalid_output="$(run_menu '2\ninvalid\n\n0\n0\n')"
assert_contains "$invalid_output" 'Invalid selection.'

dashboard_output="$(run_menu '3\n\n0\n')"
assert_contains "$dashboard_output" 'Automatic health-check status'

run_menu '4\n1\n\n0\n' >/dev/null
run_menu '4\n2\n\n0\n' >/dev/null
run_menu '5\n1\n\n0\n' >/dev/null
run_menu '5\n2\n\n0\n' >/dev/null
run_menu '5\n3\n7\n\n0\n' >/dev/null
run_menu '5\n4\ny\n\n0\n' >/dev/null
run_menu '6\n1\n\n0\n' >/dev/null
run_menu '6\n2\n\n0\n' >/dev/null

diagnostic_output="$(run_menu '7\n1\n\n0\n')"
assert_contains "$diagnostic_output" 'Diagnostics completed.'
listening_output="$(run_menu '7\n2\n\n0\n')"
assert_contains "$listening_output" 'No local Backhaul listening port was found.'
connections_output="$(run_menu '7\n3\n\n0\n')"
assert_contains "$connections_output" 'No active Backhaul TCP connection was found.'
network_output="$(run_menu '7\n4\n\n0\n')"
assert_contains "$network_output" 'No settings were changed by this option.'

core_output="$(run_menu '8\n1\n\n0\n')"
assert_contains "$core_output" 'backhaul v0.7.2'
run_menu '8\n2\n\nn\n\n0\n' >/dev/null
run_menu '9\nn\n\n0\n' >/dev/null

export FAKE_MANAGER_FAIL_ON=health
failure_output="$(run_menu '4\n1\n\n0\n')"
unset FAKE_MANAGER_FAIL_ON
assert_contains "$failure_output" 'simulated health failure'
[[ "$(grep -Fc 'HOMA GHOST TUNNEL MANAGER' <<<"$failure_output")" -ge 2 ]] ||
    fail "the menu exited after a child command failed"

timeout 5 "$BH_MENU_BIN" </dev/null >/dev/null ||
    fail "EOF did not close the menu cleanly"

client_config="$BH_CONFIG_DIR/fr-client.toml"
client_unit="$BH_SYSTEMD_DIR/backhaul-fr-client.service"
tee "$client_config" >/dev/null <<'EOF'
[client]
remote_addr = "203.0.113.10:9200"
transport = "wsmux"
token = "abcdef0123456789abcdef0123456789"
EOF
tee "$client_unit" >/dev/null <<EOF
[Service]
ExecStart=$BH_BIN -c $client_config
EOF

multi_invalid="$(run_menu '2\nx\n\n0\n')"
assert_contains "$multi_invalid" 'Invalid selection.'
multi_valid="$(run_menu '2\n2\n0\n0\n')"
assert_contains "$multi_valid" 'Tunnel management: backhaul-fr-client.service'

grep -Fq 'server add' "$FAKE_MENU_LOG" ||
    fail "server creation did not reach the Manager"
grep -Fq 'client add' "$FAKE_MENU_LOG" ||
    fail "client creation did not reach the Manager"
grep -Fq 'mapping add' "$FAKE_MENU_LOG" ||
    fail "mapping add did not reach the Manager"
grep -Fq 'mapping remove' "$FAKE_MENU_LOG" ||
    fail "mapping remove did not reach the Manager"

if LC_ALL=C grep -q '[^ -~[:space:]]' "$ROOT_DIR/bin/backhaul-menu"; then
    fail "the interactive menu contains non-ASCII text"
fi
if grep -Eqi 'Sakht|Entekhab|Bazgasht|Namayesh|Modiriat|Faal|Khorooj' \
    "$ROOT_DIR/bin/backhaul-menu"; then
    fail "Finglish text remains in the interactive menu"
fi

printf 'Menu flow tests passed.\n'
