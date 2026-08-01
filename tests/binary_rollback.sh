#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
FAKE_BIN="$TEST_ROOT/fake-bin"
STATE_FILE="$TEST_ROOT/systemctl-state"
COUNT_FILE="$TEST_ROOT/systemctl-count"
mkdir -p "$FAKE_BIN" "$TEST_ROOT/etc/systemd/system" "$TEST_ROOT/usr/local/bin"

cat >"$FAKE_BIN/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
set -u
state_file="${BH_TEST_SYSTEMCTL_STATE:?}"
count_file="${BH_TEST_SYSTEMCTL_COUNT:?}"
command="${1:-}"
shift || true
case "$command" in
    is-active)
        state="$(cat "$state_file")"
        if [[ "$state" == "before" || "$state" == "rollback" || "$state" == "success" ]]; then
            [[ "${1:-}" == "--quiet" ]] || printf 'active\n'
            exit 0
        fi
        count=0
        [[ -r "$count_file" ]] && count="$(cat "$count_file")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$count_file"
        if ((count == 1)); then
            [[ "${1:-}" == "--quiet" ]] || printf 'active\n'
            exit 0
        fi
        [[ "${1:-}" == "--quiet" ]] || printf 'failed\n'
        exit 3
        ;;
    is-enabled)
        printf 'enabled\n'
        exit 0
        ;;
    is-failed)
        [[ "$(cat "$state_file")" == "new" ]]
        ;;
    try-restart)
        if [[ "${BH_TEST_BINARY_SUCCESS:-0}" == "1" ]]; then
            printf 'success\n' >"$state_file"
        else
            printf 'new\n' >"$state_file"
            : >"$count_file"
        fi
        exit 0
        ;;
    restart)
        printf 'rollback\n' >"$state_file"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF_SYSTEMCTL
chmod +x "$FAKE_BIN/systemctl"

export PATH="$FAKE_BIN:$PATH"
export BH_SKIP_ROOT_CHECK=1
export BH_NO_SYSTEMD=0
export BH_SERVICE_HEALTH_ATTEMPTS=4
export BH_SERVICE_STABLE_CHECKS=3
export BH_SERVICE_HEALTH_DELAY=0
export BH_BIN="$TEST_ROOT/usr/local/bin/backhaul"
export BH_CONFIG_DIR="$TEST_ROOT/etc/backhaul"
export BH_SYSTEMD_DIR="$TEST_ROOT/etc/systemd/system"
export BH_PROJECT_DIR="$ROOT_DIR"
export BH_MANAGER_BIN="$ROOT_DIR/bin/backhaul-manager"
export BH_TEST_SYSTEMCTL_STATE="$STATE_FILE"
export BH_TEST_SYSTEMCTL_COUNT="$COUNT_FILE"

printf 'before\n' >"$STATE_FILE"
printf '#!/usr/bin/env bash\nprintf "old-binary\\n"\n' >"$BH_BIN"
chmod 755 "$BH_BIN"
printf '[Service]\nExecStart=%s -c %s/test.toml\n' "$BH_BIN" "$BH_CONFIG_DIR" \
    >"$BH_SYSTEMD_DIR/backhaul-test-client.service"
printf '#!/usr/bin/env bash\nprintf "new-binary\\n"\n' >"$TEST_ROOT/new-backhaul"
chmod 755 "$TEST_ROOT/new-backhaul"

output_file="$TEST_ROOT/failure-output"
if "$BH_MANAGER_BIN" binary install --version v0.7.2 --file "$TEST_ROOT/new-backhaul" \
    >"$output_file" 2>&1; then
    printf 'Binary rollback test failed: unstable update unexpectedly succeeded.\n' >&2
    exit 1
fi
grep -Fq 'previous binary and active service state were restored' "$output_file" || {
    cat "$output_file" >&2
    printf 'Binary rollback test failed: rollback confirmation is missing.\n' >&2
    exit 1
}
grep -Fq 'old-binary' "$BH_BIN" || {
    printf 'Binary rollback test failed: old binary was not restored.\n' >&2
    exit 1
}
[[ "$(cat "$STATE_FILE")" == "rollback" ]] || {
    printf 'Binary rollback test failed: active service was not restarted after rollback.\n' >&2
    exit 1
}

printf 'before\n' >"$STATE_FILE"
BH_TEST_BINARY_SUCCESS=1 "$BH_MANAGER_BIN" binary install \
    --version v0.7.2 --file "$TEST_ROOT/new-backhaul" >/dev/null
grep -Fq 'new-binary' "$BH_BIN" || {
    printf 'Binary rollback test failed: stable update did not install the new binary.\n' >&2
    exit 1
}

printf 'Binary rollback tests passed.\n'
