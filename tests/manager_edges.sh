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
export BH_SHORTCUT_BIN="$ROOT_DIR/bin/bh"
export BH_CRON_FILE="$TEST_ROOT/etc/cron.d/backhaul-manager-health"
export BH_BACKUP_DIR="$TEST_ROOT/var/backups/backhaul-manager"

install -d -m 755 "$(dirname "$BH_BIN")" "$BH_SYSTEMD_DIR" \
    "$(dirname "$BH_CRON_FILE")"
install -m 755 /bin/true "$BH_BIN"
chmod 755 "$BH_SYSTEMD_DIR" "$(dirname "$BH_CRON_FILE")"

fail() {
    printf 'Manager edge test failed: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local expected="$1"
    shift
    local output status
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    ((status != 0)) || fail "command unexpectedly succeeded: $*"
    grep -Fq -- "$expected" <<<"$output" ||
        fail "missing error '$expected' in: $output"
}

expect_failure "--name requires a value." \
    "$BH_MANAGER_BIN" server add --name
expect_failure "--token requires a value." \
    "$BH_MANAGER_BIN" client add --token
expect_failure "--version requires a value." \
    "$BH_MANAGER_BIN" binary install --version
expect_failure "--interval requires a value." \
    "$BH_MANAGER_BIN" cron install --interval

expect_failure "Invalid bind IPv4 address" \
    "$BH_MANAGER_BIN" server add \
        --name badip \
        --bind 999.1.1.1:9000 \
        --token 0123456789abcdef0123456789abcdef \
        --map 8000=127.0.0.1:80

expect_failure "Invalid IPv4 address" \
    "$BH_MANAGER_BIN" client add \
        --name badip \
        --remote 999.1.1.1:9000 \
        --token 0123456789abcdef0123456789abcdef

expect_failure "Ports must not contain leading zeroes" \
    "$BH_MANAGER_BIN" client add \
        --name leading-zero-control \
        --remote 192.0.2.10:09000 \
        --token 0123456789abcdef0123456789abcdef

expect_failure "Ports must not contain leading zeroes" \
    "$BH_MANAGER_BIN" server add \
        --name leading-zero-map \
        --bind 0.0.0.0:9000 \
        --token 0123456789abcdef0123456789abcdef \
        --map 08000=127.0.0.1:80

expect_failure "Port must be between 1 and 65535" \
    "$BH_MANAGER_BIN" client add \
        --name oversized-port \
        --remote 192.0.2.10:999999999999999999999999999999 \
        --token 0123456789abcdef0123456789abcdef

expect_failure "entered more than once" \
    "$BH_MANAGER_BIN" server add \
        --name duplicate \
        --bind 0.0.0.0:9000 \
        --token 0123456789abcdef0123456789abcdef \
        --map 8000=127.0.0.1:80 \
        --map 8000=127.0.0.1:81

expect_failure "conflicts with the tunnel control port" \
    "$BH_MANAGER_BIN" server add \
        --name conflict \
        --bind 0.0.0.0:9000 \
        --token 0123456789abcdef0123456789abcdef \
        --map 9000=127.0.0.1:80

expect_failure "The token must contain at least 16 characters" \
    "$BH_MANAGER_BIN" client add \
        --name short-token \
        --remote 192.0.2.10:9000 \
        --token short

"$BH_MANAGER_BIN" server add \
    --name primary \
    --bind 0.0.0.0:9000 \
    --token 0123456789abcdef0123456789abcdef \
        --map 8000=127.0.0.1:80

if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify \
        "$BH_SYSTEMD_DIR/backhaul-primary-server.service"
fi

[[ "$(stat -c '%a' "$BH_SYSTEMD_DIR")" == "755" ]] ||
    fail "atomic install changed systemd directory permissions"

inline_config="$BH_CONFIG_DIR/legacy-inline.toml"
inline_unit="$BH_SYSTEMD_DIR/backhaul-legacy-inline.service"
tee "$inline_config" >/dev/null <<'EOF'
[server]
bind_addr = "0.0.0.0:9100"
transport = "wsmux"
token = "abcdef0123456789abcdef0123456789"
ports = ["8100=127.0.0.1:8100", "8101=127.0.0.1:8101"]
EOF
tee "$inline_unit" >/dev/null <<EOF
[Service]
ExecStart=$BH_BIN -c=$inline_config
EOF

inline_list="$("$BH_MANAGER_BIN" mapping list backhaul-legacy-inline.service)"
grep -Fq '8100=127.0.0.1:8100' <<<"$inline_list" ||
    fail "inline mapping 8100 was not detected"
grep -Fq '8101=127.0.0.1:8101' <<<"$inline_list" ||
    fail "inline mapping 8101 was not detected"

expect_failure "conflicts with the tunnel control port" \
    "$BH_MANAGER_BIN" mapping add \
        backhaul-legacy-inline.service 9100=127.0.0.1:8102

"$BH_MANAGER_BIN" mapping add \
    backhaul-legacy-inline.service 8102=127.0.0.1:8102
"$BH_MANAGER_BIN" mapping remove \
    backhaul-legacy-inline.service 8101

python3 - "$inline_config" <<'PY'
import pathlib
import sys
import tomllib

config = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
assert config["server"]["ports"] == [
    "8100=127.0.0.1:8100",
    "8102=127.0.0.1:8102",
]
PY

empty_backup_dir="$TEST_ROOT/empty-backups"
BH_BACKUP_DIR="$empty_backup_dir" "$BH_MANAGER_BIN" backup list |
    grep -Fq 'No backups exist.'

"$BH_MANAGER_BIN" backup create
"$BH_MANAGER_BIN" backup create
backup_count="$(
    find "$BH_BACKUP_DIR" -maxdepth 1 -type f \
        -name 'backhaul-backup-*.tar.gz' | wc -l
)"
[[ "$backup_count" -eq 2 ]] ||
    fail "backup names collided within the same second"
while IFS= read -r archive; do
    [[ "$(stat -c '%a' "$archive")" == "600" ]] ||
        fail "backup permissions are not 600: $archive"
done < <(
    find "$BH_BACKUP_DIR" -maxdepth 1 -type f \
        -name 'backhaul-backup-*.tar.gz'
)

"$BH_MANAGER_BIN" cron install --interval 5
[[ "$(stat -c '%a' "$(dirname "$BH_CRON_FILE")")" == "755" ]] ||
    fail "atomic install changed cron directory permissions"

doctor_output="$("$BH_MANAGER_BIN" doctor)"
grep -Fq 'No local Backhaul listening port was found.' <<<"$doctor_output" ||
    fail "doctor did not explain an empty listening-port result"

redacted_output="$(
    printf '2\n1\n6\n\n0\n0\n' |
        "$BH_MENU_BIN"
)"
grep -Fq '***REDACTED***' <<<"$redacted_output" ||
    fail "the menu did not redact the token"
if grep -Fq 'abcdef0123456789abcdef0123456789' <<<"$redacted_output"; then
    fail "a token leaked through the safe config view"
fi

printf 'test certificate\n' >"$TEST_ROOT/all-transports.crt"
printf 'test private key\n' >"$TEST_ROOT/all-transports.key"
transports=(tcp tcpmux ws wss wsmux wssmux)
transport_index=0
for transport in "${transports[@]}"; do
    transport_index=$((transport_index + 1))
    client_name="client-$transport"
    server_name="server-$transport"
    control_port=$((12000 + transport_index))
    public_port=$((13000 + transport_index))
    target_port=$((14000 + transport_index))

    "$BH_MANAGER_BIN" client add \
        --name "$client_name" \
        --remote "192.0.2.10:$control_port" \
        --transport "$transport" \
        --token 0123456789abcdef0123456789abcdef \
        >/dev/null

    server_args=(
        server add
        --name "$server_name"
        --bind "0.0.0.0:$control_port"
        --transport "$transport"
        --token abcdef0123456789abcdef0123456789
        --map "$public_port=127.0.0.1:$target_port"
    )
    if [[ "$transport" == "wss" || "$transport" == "wssmux" ]]; then
        server_args+=(
            --tls-cert "$TEST_ROOT/all-transports.crt"
            --tls-key "$TEST_ROOT/all-transports.key"
        )
    fi
    "$BH_MANAGER_BIN" "${server_args[@]}" >/dev/null
done

python3 - "$BH_CONFIG_DIR" <<'PY'
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
transports = ("tcp", "tcpmux", "ws", "wss", "wsmux", "wssmux")
for transport in transports:
    client = tomllib.loads((root / f"client-{transport}-client.toml").read_text())
    server = tomllib.loads((root / f"server-{transport}-server.toml").read_text())
    assert client["client"]["transport"] == transport
    assert server["server"]["transport"] == transport
    if transport in {"wss", "wssmux"}:
        assert server["server"]["tls_cert"].endswith("all-transports.crt")
        assert server["server"]["tls_key"].endswith("all-transports.key")
PY

printf 'Manager edge tests passed.\n'
