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
export BH_BIN="$TEST_ROOT/usr/local/bin/backhaul"
export BH_CONFIG_DIR="$TEST_ROOT/etc/backhaul"
export BH_STATE_DIR="$TEST_ROOT/etc/backhaul-manager"
export BH_SYSTEMD_DIR="$TEST_ROOT/etc/systemd/system"
export BH_PROJECT_DIR="$ROOT_DIR"
export BH_MANAGER_BIN="$ROOT_DIR/bin/backhaul-manager"
export BH_BACKUP_DIR="$TEST_ROOT/var/backups/backhaul-manager"
export FAKE_SYSTEMCTL_STATE="$TEST_ROOT/systemctl-state"
export FAKE_SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"

install -d "$TEST_ROOT/fake-bin" "$BH_CONFIG_DIR" "$BH_STATE_DIR" \
    "$BH_SYSTEMD_DIR" "$(dirname "$BH_BIN")" "$FAKE_SYSTEMCTL_STATE"
install -m 755 /bin/true "$BH_BIN"

tee "$TEST_ROOT/fake-bin/systemctl" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="${FAKE_SYSTEMCTL_STATE:?}"
log_file="${FAKE_SYSTEMCTL_LOG:?}"
printf '%q ' "$@" >>"$log_file"
printf '\n' >>"$log_file"

command_name="${1:-}"
shift || true

read_state() {
    local unit="$1"
    local kind="$2"
    local fallback="$3"
    if [[ -r "$state_dir/$unit.$kind" ]]; then
        cat "$state_dir/$unit.$kind"
    else
        printf '%s\n' "$fallback"
    fi
}

case "$command_name" in
    daemon-reload|reset-failed)
        exit 0
        ;;
    is-enabled)
        quiet=0
        if [[ "${1:-}" == "--quiet" ]]; then
            quiet=1
            shift
        fi
        unit="${1:?}"
        state="$(read_state "$unit" enabled disabled)"
        if [[ "$state" == "enabled" ]]; then
            ((quiet == 1)) || printf 'enabled\n'
            exit 0
        fi
        ((quiet == 1)) || printf 'disabled\n'
        exit 1
        ;;
    is-active)
        quiet=0
        if [[ "${1:-}" == "--quiet" ]]; then
            quiet=1
            shift
        fi
        unit="${1:?}"
        state="$(read_state "$unit" active inactive)"
        ((quiet == 1)) || printf '%s\n' "$state"
        [[ "$state" == "active" ]]
        ;;
    enable)
        unit="${1:?}"
        printf 'enabled\n' >"$state_dir/$unit.enabled"
        ;;
    disable)
        if [[ -e "$state_dir/fail-disable" ]]; then
            rm -f -- "$state_dir/fail-disable"
            exit 1
        fi
        if [[ "${1:-}" == "--now" ]]; then
            shift
            stop_now=1
        else
            stop_now=0
        fi
        unit="${1:?}"
        printf 'disabled\n' >"$state_dir/$unit.enabled"
        ((stop_now == 0)) || printf 'inactive\n' >"$state_dir/$unit.active"
        ;;
    restart|start)
        unit="${1:?}"
        if [[ -e "$state_dir/fail-next-restart" && "$command_name" == "restart" ]]; then
            rm -f -- "$state_dir/fail-next-restart"
            exit 1
        fi
        printf 'active\n' >"$state_dir/$unit.active"
        ;;
    stop)
        unit="${1:?}"
        printf 'inactive\n' >"$state_dir/$unit.active"
        ;;
    status)
        unit="${*: -1}"
        printf 'Fake status for %s\n' "$unit"
        ;;
    *)
        printf 'Unsupported fake systemctl command: %s\n' "$command_name" >&2
        exit 2
        ;;
esac
EOF
chmod 755 "$TEST_ROOT/fake-bin/systemctl"
export PATH="$TEST_ROOT/fake-bin:$PATH"

fail() {
    printf 'Deploy rollback test failed: %s\n' "$*" >&2
    exit 1
}

unit="backhaul-ru-client.service"
config="$BH_CONFIG_DIR/ru-client.toml"
unit_file="$BH_SYSTEMD_DIR/$unit"

tee "$config" >/dev/null <<'EOF'
[client]
remote_addr = "192.0.2.10:9000"
transport = "wsmux"
token = "0123456789abcdef0123456789abcdef"
EOF
tee "$unit_file" >/dev/null <<EOF
[Service]
ExecStart=$BH_BIN -c $config
EOF
printf 'enabled\n' >"$FAKE_SYSTEMCTL_STATE/$unit.enabled"
printf 'active\n' >"$FAKE_SYSTEMCTL_STATE/$unit.active"

old_config_hash="$(sha256sum "$config" | awk '{print $1}')"
old_unit_hash="$(sha256sum "$unit_file" | awk '{print $1}')"
touch "$FAKE_SYSTEMCTL_STATE/fail-next-restart"

set +e
failure_output="$(
    "$BH_MANAGER_BIN" client add \
        --name ru \
        --remote 198.51.100.20:9100 \
        --transport wsmux \
        --token abcdef0123456789abcdef0123456789 \
        --replace 2>&1
)"
failure_status=$?
set -e

((failure_status != 0)) || fail "failed replacement unexpectedly succeeded"
grep -Fq 'previous config and service state were restored' <<<"$failure_output" ||
    fail "rollback confirmation was not reported"
[[ "$(sha256sum "$config" | awk '{print $1}')" == "$old_config_hash" ]] ||
    fail "the previous config was not restored"
[[ "$(sha256sum "$unit_file" | awk '{print $1}')" == "$old_unit_hash" ]] ||
    fail "the previous unit was not restored"
grep -qx enabled "$FAKE_SYSTEMCTL_STATE/$unit.enabled" ||
    fail "the previous startup state was not restored"
grep -qx active "$FAKE_SYSTEMCTL_STATE/$unit.active" ||
    fail "the previous runtime state was not restored"

"$BH_MANAGER_BIN" client add \
    --name ru \
    --remote 198.51.100.20:9100 \
    --transport wsmux \
    --token abcdef0123456789abcdef0123456789 \
    --replace
grep -Fq 'remote_addr = "198.51.100.20:9100"' "$config" ||
    fail "successful replacement did not install the new config"
grep -qx active "$FAKE_SYSTEMCTL_STATE/$unit.active" ||
    fail "successful replacement did not leave the service active"

touch "$FAKE_SYSTEMCTL_STATE/fail-disable"
set +e
"$BH_MANAGER_BIN" retire "$unit" --yes >/dev/null 2>&1
retire_failure_status=$?
set -e
((retire_failure_status != 0)) ||
    fail "retire unexpectedly succeeded when the service could not stop"
[[ -e "$config" && -e "$unit_file" ]] ||
    fail "retire removed files even though the service could not stop"

new_unit="backhaul-failed-client.service"
touch "$FAKE_SYSTEMCTL_STATE/fail-next-restart"
set +e
"$BH_MANAGER_BIN" client add \
    --name failed \
    --remote 203.0.113.30:9200 \
    --transport wsmux \
    --token fedcba9876543210fedcba9876543210 \
    >/dev/null 2>&1
new_failure_status=$?
set -e
((new_failure_status != 0)) || fail "failed new deployment unexpectedly succeeded"
[[ ! -e "$BH_CONFIG_DIR/failed-client.toml" ]] ||
    fail "failed new deployment left a config behind"
[[ ! -e "$BH_SYSTEMD_DIR/$new_unit" ]] ||
    fail "failed new deployment left a unit behind"

printf 'Deploy rollback tests passed.\n'
