#!/usr/bin/env bash
set -Eeuo pipefail

# تست‌ها هیچ تغییری در سیستم واقعی ایجاد نمی‌کنند و همه فایل‌ها داخل tmp ساخته می‌شوند.

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
export BH_SHORTCUT_BIN="$ROOT_DIR/bin/homa"
export BH_LEGACY_SHORTCUT_BIN="$ROOT_DIR/bin/bh"
export BH_CRON_FILE="$TEST_ROOT/etc/cron.d/backhaul-manager-health"
export BH_BACKUP_DIR="$TEST_ROOT/var/backups/backhaul-manager"

install -d "$(dirname "$BH_BIN")" "$BH_SYSTEMD_DIR"
install -m 755 /bin/true "$BH_BIN"

bash -n "$ROOT_DIR/install.sh"
bash -n "$ROOT_DIR/uninstall.sh"
bash -n "$ROOT_DIR/lib/common.sh"
bash -n "$ROOT_DIR/bin/backhaul-manager"
bash -n "$ROOT_DIR/bin/backhaul-menu"
bash -n "$ROOT_DIR/bin/homa"
bash -n "$ROOT_DIR/bin/bh"
bash -n "$ROOT_DIR/tests/health_repair.sh"
bash -n "$ROOT_DIR/tests/install_upgrade.sh"
bash -n "$ROOT_DIR/tests/manager_edges.sh"
bash -n "$ROOT_DIR/tests/deploy_rollback.sh"
bash -n "$ROOT_DIR/tests/menu_flow.sh"
bash -n "$ROOT_DIR/tests/uninstall.sh"
bash -n "$ROOT_DIR/tests/backup_restore.sh"
bash -n "$ROOT_DIR/tests/binary_rollback.sh"
bash -n "$ROOT_DIR/tests/release_update.sh"
python3 - "$ROOT_DIR/tests/menu_pty.py" "$ROOT_DIR/tests/tomllib_compat.py" <<'PY'
import pathlib
import sys

for argument in sys.argv[1:]:
    path = pathlib.Path(argument)
    compile(path.read_text(), str(path), "exec")
PY

"$ROOT_DIR/bin/homa" version | grep -q '1.1.13'
"$ROOT_DIR/bin/bh" version | grep -q '1.1.13'

"$ROOT_DIR/bin/backhaul-manager" server add \
    --name turkey \
    --bind 0.0.0.0:9300 \
    --public-host 203.0.113.10 \
    --transport wsmux \
    --token 0123456789abcdef0123456789abcdef \
    --map 8300=127.0.0.1:8090 \
    --map 8301=127.0.0.1:8091 \
    --map 8302=127.0.0.1:8092

"$ROOT_DIR/bin/backhaul-manager" client add \
    --name turkey \
    --remote 203.0.113.10:9300 \
    --transport wsmux \
    --token 0123456789abcdef0123456789abcdef

if "$ROOT_DIR/bin/backhaul-manager" client add \
    --name turkey \
    --remote 203.0.113.10:9300 \
    --transport wsmux \
    --token 0123456789abcdef0123456789abcdef 2>/dev/null; then
    printf 'Existing tunnel was overwritten without --replace.\n' >&2
    exit 1
fi

"$ROOT_DIR/bin/backhaul-manager" client add \
    --name ipv6 \
    --remote '[2001:db8::10]:9300' \
    --transport wsmux \
    --token 0123456789abcdef0123456789abcdef

printf 'test certificate\n' >"$TEST_ROOT/cert.pem"
printf 'test private key\n' >"$TEST_ROOT/key.pem"
"$ROOT_DIR/bin/backhaul-manager" server add \
    --name secure \
    --bind 0.0.0.0:9443 \
    --transport wssmux \
    --token abcdef0123456789abcdef0123456789 \
    --tls-cert "$TEST_ROOT/cert.pem" \
    --tls-key "$TEST_ROOT/key.pem" \
    --map 8500=127.0.0.1:8090

python3 - "$BH_CONFIG_DIR" "$ROOT_DIR/tests" <<'PY'
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.path.insert(0, sys.argv[2])
    import tomllib_compat as tomllib

config_dir = pathlib.Path(sys.argv[1])
server = tomllib.loads((config_dir / "turkey-server.toml").read_text())
client = tomllib.loads((config_dir / "turkey-client.toml").read_text())
secure = tomllib.loads((config_dir / "secure-server.toml").read_text())

assert server["server"]["bind_addr"] == "0.0.0.0:9300"
assert server["server"]["transport"] == "wsmux"
assert server["server"]["ports"] == [
    "8300=127.0.0.1:8090",
    "8301=127.0.0.1:8091",
    "8302=127.0.0.1:8092",
]
assert client["client"]["remote_addr"] == "203.0.113.10:9300"
assert client["client"]["transport"] == "wsmux"
ipv6 = tomllib.loads((config_dir / "ipv6-client.toml").read_text())
assert ipv6["client"]["remote_addr"] == "[2001:db8::10]:9300"
assert secure["server"]["transport"] == "wssmux"
assert secure["server"]["tls_cert"].endswith("/cert.pem")
assert secure["server"]["tls_key"].endswith("/key.pem")
PY

"$ROOT_DIR/bin/backhaul-manager" mapping add \
    backhaul-turkey-server.service \
    8303=127.0.0.1:8093
"$ROOT_DIR/bin/backhaul-manager" mapping list \
    backhaul-turkey-server.service |
    grep -q '8303=127.0.0.1:8093'
"$ROOT_DIR/bin/backhaul-manager" mapping remove \
    backhaul-turkey-server.service 8303
if "$ROOT_DIR/bin/backhaul-manager" mapping list \
    backhaul-turkey-server.service |
    grep -q '8303=127.0.0.1:8093'; then
    printf 'Removed mapping is still present.\n' >&2
    exit 1
fi

"$ROOT_DIR/bin/backhaul-manager" health
"$ROOT_DIR/bin/backhaul-manager" cron install --interval 5
grep -q '^\*/5 ' "$BH_CRON_FILE"
"$ROOT_DIR/bin/backhaul-manager" cron status
"$ROOT_DIR/bin/backhaul-manager" backup create
find "$BH_BACKUP_DIR" -maxdepth 1 -name 'backhaul-backup-*.tar.gz' |
    grep -q .

"$ROOT_DIR/bin/backhaul-manager" list
"$ROOT_DIR/bin/backhaul-manager" status turkey
"$ROOT_DIR/bin/backhaul-manager" retire backhaul-secure-server.service --yes
[[ ! -e "$BH_CONFIG_DIR/secure-server.toml" ]]
"$ROOT_DIR/bin/backhaul-manager" cron remove
[[ ! -e "$BH_CRON_FILE" ]]
"$ROOT_DIR/bin/backhaul-manager" remove client turkey
"$ROOT_DIR/bin/backhaul-manager" remove server turkey
"$ROOT_DIR/bin/backhaul-manager" remove client ipv6

[[ ! -e "$BH_CONFIG_DIR/turkey-client.toml" ]]
[[ ! -e "$BH_CONFIG_DIR/turkey-server.toml" ]]
[[ ! -e "$BH_CONFIG_DIR/ipv6-client.toml" ]]

printf 'All tests passed.\n'
"$ROOT_DIR/tests/health_repair.sh"
"$ROOT_DIR/tests/install_upgrade.sh"
"$ROOT_DIR/tests/manager_edges.sh"
"$ROOT_DIR/tests/deploy_rollback.sh"
"$ROOT_DIR/tests/menu_flow.sh"
python3 "$ROOT_DIR/tests/menu_pty.py"
"$ROOT_DIR/tests/uninstall.sh"
"$ROOT_DIR/tests/backup_restore.sh"
"$ROOT_DIR/tests/binary_rollback.sh"
"$ROOT_DIR/tests/release_update.sh"
