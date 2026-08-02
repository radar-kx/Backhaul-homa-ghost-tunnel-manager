#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
API_ROOT="$TEST_ROOT/api"
RELEASE_ROOT="$TEST_ROOT/releases"
ARCH="amd64"
VERSION="v9.9.9"
ASSET="backhaul_linux_${ARCH}.tar.gz"

mkdir -p \
    "$API_ROOT/repos/Musixal/Backhaul/releases/tags" \
    "$RELEASE_ROOT/Musixal/Backhaul/releases/download/$VERSION" \
    "$TEST_ROOT/package" "$TEST_ROOT/usr/local/bin"

cat >"$TEST_ROOT/package/backhaul" <<'EOF_BINARY'
#!/usr/bin/env bash
printf 'backhaul test v9.9.9\n'
EOF_BINARY
chmod 755 "$TEST_ROOT/package/backhaul"
tar -czf "$RELEASE_ROOT/Musixal/Backhaul/releases/download/$VERSION/$ASSET" \
    -C "$TEST_ROOT/package" backhaul
DIGEST="$(sha256sum "$RELEASE_ROOT/Musixal/Backhaul/releases/download/$VERSION/$ASSET" | awk '{print $1}')"

cat >"$API_ROOT/repos/Musixal/Backhaul/releases/latest" <<EOF_LATEST
{"tag_name":"$VERSION"}
EOF_LATEST
cat >"$API_ROOT/repos/Musixal/Backhaul/releases/tags/$VERSION" <<EOF_RELEASE
{"assets":[{"name":"$ASSET","digest":"sha256:$DIGEST"}]}
EOF_RELEASE

export BH_SKIP_ROOT_CHECK=1
export BH_NO_SYSTEMD=1
export BH_BIN="$TEST_ROOT/usr/local/bin/backhaul"
export BH_PROJECT_DIR="$ROOT_DIR"
export BH_MANAGER_BIN="$ROOT_DIR/bin/backhaul-manager"
export BH_GITHUB_API_BASE="file://$API_ROOT"
export BH_GITHUB_RELEASE_BASE="file://$RELEASE_ROOT"

"$BH_MANAGER_BIN" binary install --latest >/dev/null
grep -Fq 'backhaul test v9.9.9' "$BH_BIN" || {
    printf 'Release update test failed: latest verified binary was not installed.\n' >&2
    exit 1
}

# The checksum parser must also work on minimal systems without Python or jq.
BH_DISABLE_JSON_TOOLS=1 "$BH_MANAGER_BIN" binary install --latest >/dev/null
grep -Fq 'backhaul test v9.9.9' "$BH_BIN" || {
    printf 'Release update test failed: dependency-free digest parsing failed.\n' >&2
    exit 1
}

BINARY_DIGEST="$(sha256sum "$TEST_ROOT/package/backhaul" | awk '{print $1}')"
UPPER_BINARY_DIGEST="$(printf '%s' "$BINARY_DIGEST" | tr '[:lower:]' '[:upper:]')"
"$BH_MANAGER_BIN" binary install --version "$VERSION" \
    --file "$TEST_ROOT/package/backhaul" --sha256 "sha256:$UPPER_BINARY_DIGEST" >/dev/null
if "$BH_MANAGER_BIN" binary install --version "$VERSION" \
    --file "$TEST_ROOT/package/backhaul" --sha256 invalid >/dev/null 2>&1; then
    printf 'Release update test failed: invalid SHA-256 syntax was accepted.\n' >&2
    exit 1
fi

# A correctly hashed archive must still be rejected if its tar entries are unsafe.
malicious_dir="$TEST_ROOT/malicious-release"
mkdir -p "$malicious_dir"
printf 'malicious\n' >"$malicious_dir/backhaul"
tar -czf "$RELEASE_ROOT/Musixal/Backhaul/releases/download/$VERSION/$ASSET" \
    --transform='s#backhaul#../backhaul#' -C "$malicious_dir" backhaul
MALICIOUS_DIGEST="$(sha256sum "$RELEASE_ROOT/Musixal/Backhaul/releases/download/$VERSION/$ASSET" | awk '{print $1}')"
cat >"$API_ROOT/repos/Musixal/Backhaul/releases/tags/$VERSION" <<EOF_MALICIOUS
{"assets":[{"name":"$ASSET","digest":"sha256:$MALICIOUS_DIGEST"}]}
EOF_MALICIOUS
if "$BH_MANAGER_BIN" binary install --latest >/dev/null 2>&1; then
    printf 'Release update test failed: path-traversal release archive was accepted.\n' >&2
    exit 1
fi

# Restore the valid release asset for the remaining tests.
tar -czf "$RELEASE_ROOT/Musixal/Backhaul/releases/download/$VERSION/$ASSET" \
    -C "$TEST_ROOT/package" backhaul
DIGEST="$(sha256sum "$RELEASE_ROOT/Musixal/Backhaul/releases/download/$VERSION/$ASSET" | awk '{print $1}')"
cat >"$API_ROOT/repos/Musixal/Backhaul/releases/tags/$VERSION" <<EOF_RESTORED
{"assets":[{"name":"$ASSET","digest":"sha256:$DIGEST"}]}
EOF_RESTORED

cat >"$API_ROOT/repos/Musixal/Backhaul/releases/tags/$VERSION" <<EOF_BAD
{"assets":[{"name":"$ASSET","digest":"sha256:$(printf '0%.0s' {1..64})"}]}
EOF_BAD
if "$BH_MANAGER_BIN" binary install --latest >/dev/null 2>&1; then
    printf 'Release update test failed: invalid release digest was accepted.\n' >&2
    exit 1
fi

cat >"$API_ROOT/repos/Musixal/Backhaul/releases/tags/$VERSION" <<EOF_NONE
{"assets":[{"name":"$ASSET","digest":null}]}
EOF_NONE
if "$BH_MANAGER_BIN" binary install --latest >/dev/null 2>&1; then
    printf 'Release update test failed: missing digest was accepted by default.\n' >&2
    exit 1
fi
"$BH_MANAGER_BIN" binary install --latest --allow-unverified-download >/dev/null

# Verify that the bootstrap installer forwards --latest and digest settings.
cat >"$API_ROOT/repos/Musixal/Backhaul/releases/tags/$VERSION" <<EOF_INSTALL
{"assets":[{"name":"$ASSET","digest":"sha256:$DIGEST"}]}
EOF_INSTALL
INSTALL_ROOT="$TEST_ROOT/installer"
mkdir -p "$INSTALL_ROOT"
env \
    BH_SKIP_ROOT_CHECK=1 \
    BH_NO_SYSTEMD=1 \
    BH_BIN="$INSTALL_ROOT/usr/local/bin/backhaul" \
    BH_CONFIG_DIR="$INSTALL_ROOT/etc/backhaul" \
    BH_STATE_DIR="$INSTALL_ROOT/etc/backhaul-manager" \
    BH_SYSTEMD_DIR="$INSTALL_ROOT/etc/systemd/system" \
    BH_PROJECT_DIR="$INSTALL_ROOT/opt/backhaul-tunnel-manager" \
    BH_MANAGER_BIN="$INSTALL_ROOT/usr/local/sbin/backhaul-manager" \
    BH_MENU_BIN="$INSTALL_ROOT/usr/local/sbin/backhaul-menu" \
    BH_SHORTCUT_BIN="$INSTALL_ROOT/usr/local/bin/homa" \
    BH_LEGACY_SHORTCUT_BIN="$INSTALL_ROOT/usr/local/bin/bh" \
    BH_CRON_FILE="$INSTALL_ROOT/etc/cron.d/backhaul-manager-health" \
    BH_BACKUP_DIR="$INSTALL_ROOT/var/backups/backhaul-manager" \
    BH_GITHUB_API_BASE="file://$API_ROOT" \
    BH_GITHUB_RELEASE_BASE="file://$RELEASE_ROOT" \
    "$ROOT_DIR/install.sh" --latest --force-binary >/dev/null
grep -Fq 'backhaul test v9.9.9' "$INSTALL_ROOT/usr/local/bin/backhaul" || {
    printf 'Release update test failed: installer did not forward --latest.\n' >&2
    exit 1
}

if "$ROOT_DIR/install.sh" --latest --version "$VERSION" >/dev/null 2>&1; then
    printf 'Release update test failed: installer accepted --latest with --version.\n' >&2
    exit 1
fi
if "$ROOT_DIR/install.sh" --skip-binary --allow-unverified-download >/dev/null 2>&1; then
    printf 'Release update test failed: installer accepted a meaningless bypass flag.\n' >&2
    exit 1
fi

printf 'Release update tests passed.\n'
