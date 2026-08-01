#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export BH_SKIP_ROOT_CHECK=1
export BH_NO_SYSTEMD=0
export BH_SERVICE_HEALTH_DELAY=0
export BH_SERVICE_STABLE_CHECKS=1
export BH_SERVICE_HEALTH_ATTEMPTS=2
export BH_HEALTH_REPAIR_WAIT=0
export BH_BIN="$TEST_ROOT/usr/local/bin/backhaul"
export BH_CONFIG_DIR="$TEST_ROOT/etc/backhaul"
export BH_STATE_DIR="$TEST_ROOT/etc/backhaul-manager"
export BH_SYSTEMD_DIR="$TEST_ROOT/etc/systemd/system"
export BH_PROJECT_DIR="$ROOT_DIR"
export BH_MANAGER_BIN="$ROOT_DIR/bin/backhaul-manager"
export BH_CRON_FILE="$TEST_ROOT/etc/cron.d/backhaul-manager-health"
export BH_BACKUP_DIR="$TEST_ROOT/var/backups/backhaul-manager"
export FAKE_SYSTEMCTL_STATE="$TEST_ROOT/systemctl-state"

install -d "$TEST_ROOT/fake-bin" "$BH_SYSTEMD_DIR" "$BH_CONFIG_DIR" \
    "$(dirname "$BH_BIN")" "$FAKE_SYSTEMCTL_STATE"
install -m 755 /bin/true "$BH_BIN"

tee "$TEST_ROOT/fake-bin/systemctl" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="${FAKE_SYSTEMCTL_STATE:?}"
command_name="${1:-}"
shift || true

case "$command_name" in
    is-enabled)
        unit="${1:?}"
        cat "$state_dir/$unit.enabled"
        [[ "$(cat "$state_dir/$unit.enabled")" == "enabled" ]]
        ;;
    is-active)
        if [[ "${1:-}" == "--quiet" ]]; then shift; fi
        unit="${1:?}"
        cat "$state_dir/$unit.active"
        [[ "$(cat "$state_dir/$unit.active")" == "active" ]]
        ;;
    enable)
        unit="${1:?}"
        printf 'enabled\n' >"$state_dir/$unit.enabled"
        ;;
    restart)
        unit="${1:?}"
        printf 'active\n' >"$state_dir/$unit.active"
        ;;
    reset-failed|daemon-reload)
        exit 0
        ;;
    *)
        printf 'unsupported fake systemctl command: %s\n' "$command_name" >&2
        exit 2
        ;;
esac
EOF
chmod 755 "$TEST_ROOT/fake-bin/systemctl"
export PATH="$TEST_ROOT/fake-bin:$PATH"

tee "$BH_CONFIG_DIR/ir2.toml" >/dev/null <<'EOF'
[server]
bind_addr = "0.0.0.0:9000"
transport = "wsmux"
token = "0123456789abcdef0123456789abcdef"
ports = ["8090=127.0.0.1:8090"]
EOF

tee "$BH_SYSTEMD_DIR/backhaul-ir2.service" >/dev/null <<EOF
[Service]
ExecStart=$BH_BIN -c $BH_CONFIG_DIR/ir2.toml
EOF

tee "$BH_CONFIG_DIR/uk-client.toml" >/dev/null <<'EOF'
[client]
remote_addr = "203.0.113.10:9600"
transport = "wsmux"
token = "abcdef0123456789abcdef0123456789"
EOF

tee "$BH_SYSTEMD_DIR/backhaul-uk-client.service" >/dev/null <<EOF
[Service]
ExecStart=$BH_BIN -c $BH_CONFIG_DIR/uk-client.toml
EOF

printf 'enabled\n' >"$FAKE_SYSTEMCTL_STATE/backhaul-ir2.service.enabled"
printf 'inactive\n' >"$FAKE_SYSTEMCTL_STATE/backhaul-ir2.service.active"
printf 'disabled\n' >"$FAKE_SYSTEMCTL_STATE/backhaul-uk-client.service.enabled"
printf 'inactive\n' >"$FAKE_SYSTEMCTL_STATE/backhaul-uk-client.service.active"

"$ROOT_DIR/bin/backhaul-manager" health --repair --quiet

grep -qx enabled "$FAKE_SYSTEMCTL_STATE/backhaul-ir2.service.enabled"
grep -qx active "$FAKE_SYSTEMCTL_STATE/backhaul-ir2.service.active"
grep -qx disabled "$FAKE_SYSTEMCTL_STATE/backhaul-uk-client.service.enabled"
grep -qx inactive "$FAKE_SYSTEMCTL_STATE/backhaul-uk-client.service.active"

"$ROOT_DIR/bin/backhaul-manager" health --repair --enable-disabled --quiet
grep -qx enabled "$FAKE_SYSTEMCTL_STATE/backhaul-uk-client.service.enabled"
grep -qx active "$FAKE_SYSTEMCTL_STATE/backhaul-uk-client.service.active"
list_output="$("$ROOT_DIR/bin/backhaul-manager" list)"
grep -q 'backhaul-ir2.service' <<<"$list_output"

printf 'Health repair tests passed.\n'
