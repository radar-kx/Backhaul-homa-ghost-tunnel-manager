#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap installer for both local packages and direct HTTPS installation.

PROJECT_VERSION="1.1.13"
RAW_BASE="${BH_RAW_BASE:-https://raw.githubusercontent.com/radar-kx/Backhaul-homa-ghost-tunnel-manager/main}"
PROJECT_DIR="${BH_PROJECT_DIR:-/opt/backhaul-tunnel-manager}"
MANAGER_BIN="${BH_MANAGER_BIN:-/usr/local/sbin/backhaul-manager}"
MENU_BIN="${BH_MENU_BIN:-/usr/local/sbin/backhaul-menu}"
SHORTCUT_BIN="${BH_SHORTCUT_BIN:-/usr/local/bin/homa}"
LEGACY_SHORTCUT_BIN="${BH_LEGACY_SHORTCUT_BIN:-/usr/local/bin/bh}"
BACKHAUL_BIN="${BH_BIN:-/usr/local/bin/backhaul}"
VERSION="${BH_VERSION_DEFAULT:-v0.7.2}"
VERSION_EXPLICIT=0
USE_LATEST=0
ALLOW_UNVERIFIED_DOWNLOAD=0
BINARY_FILE=""
SKIP_BINARY=0
FORCE_BINARY=0
ENABLE_HEALTH_CRON=0
HEALTH_INTERVAL=5
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FORWARD_ARGS=()

die_bootstrap() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

download_bootstrap() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --ipv4 --fail --location --silent --show-error \
            --connect-timeout 15 --retry 3 --output "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -4 --quiet --tries=3 --timeout=30 --output-document="$output" "$url"
    else
        die_bootstrap "curl or wget is required."
    fi
}

atomic_install_bootstrap() {
    local source="$1"
    local destination="$2"
    local mode="$3"
    local staged
    staged="$(mktemp "$(dirname "$destination")/.homa-install.XXXXXX")"
    if ! install -o root -g root -m "$mode" "$source" "$staged"; then
        rm -f -- "$staged"
        return 1
    fi
    if ! mv -f -- "$staged" "$destination"; then
        rm -f -- "$staged"
        return 1
    fi
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] ||
    die_bootstrap "The installer must be run as root or with sudo."

# گزینه‌های نصاب در ابتدای فرمان خوانده می‌شوند؛ بقیه مستقیم به Manager می‌روند.
while (($#)); do
    case "$1" in
        --version)
            if (($# < 2)) || [[ -z "${2:-}" ]]; then
                die_bootstrap "--version requires a value."
            fi
            VERSION="$2"
            VERSION_EXPLICIT=1
            shift 2
            ;;
        --latest)
            USE_LATEST=1
            shift
            ;;
        --allow-unverified-download)
            ALLOW_UNVERIFIED_DOWNLOAD=1
            shift
            ;;
        --binary-file)
            if (($# < 2)) || [[ -z "${2:-}" ]]; then
                die_bootstrap "--binary-file requires a path."
            fi
            BINARY_FILE="$2"
            shift 2
            ;;
        --skip-binary)
            SKIP_BINARY=1
            shift
            ;;
        --force-binary)
            FORCE_BINARY=1
            shift
            ;;
        --enable-health-cron)
            ENABLE_HEALTH_CRON=1
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                HEALTH_INTERVAL="$2"
                shift 2
            else
                shift
            fi
            ;;
        menu|server|client|binary|list|status|health|cron|backup|mapping|retire|doctor|logs|restart|remove|version)
            FORWARD_ARGS=("$@")
            break
            ;;
        -h|--help)
            cat <<'EOF'
Usage:
  sudo ./install.sh [--latest | --version v0.7.2 | --binary-file PATH]
                    [--skip-binary|--force-binary]
                    [--allow-unverified-download]
                    [--enable-health-cron [MINUTES]]
  curl .../install.sh | sudo bash -s -- server add [options]
  curl .../install.sh | sudo bash -s -- client add [options]
EOF
            exit 0
            ;;
        *)
            die_bootstrap "Unknown installer option: $1"
            ;;
    esac
done

if ((SKIP_BINARY == 1 && FORCE_BINARY == 1)); then
    die_bootstrap "--skip-binary and --force-binary cannot be used together."
fi
if ((USE_LATEST == 1 && VERSION_EXPLICIT == 1)); then
    die_bootstrap "--latest and --version cannot be used together."
fi
if ((USE_LATEST == 1)) && [[ -n "$BINARY_FILE" ]]; then
    die_bootstrap "--latest cannot be combined with --binary-file."
fi
if ((SKIP_BINARY == 1)) && [[ -n "$BINARY_FILE" ]]; then
    die_bootstrap "--skip-binary cannot be combined with --binary-file."
fi
if ((SKIP_BINARY == 1 && USE_LATEST == 1)); then
    die_bootstrap "--skip-binary cannot be combined with --latest."
fi
if ((SKIP_BINARY == 1 && ALLOW_UNVERIFIED_DOWNLOAD == 1)); then
    die_bootstrap "--allow-unverified-download has no effect with --skip-binary."
fi
if [[ -n "$BINARY_FILE" ]] && ((ALLOW_UNVERIFIED_DOWNLOAD == 1)); then
    die_bootstrap "--allow-unverified-download is only valid for online downloads."
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

STAGE_DIR="$TEMP_DIR/stage"
install -d -m 755 "$STAGE_DIR/lib" "$STAGE_DIR/bin"

if [[ -r "$SCRIPT_DIR/lib/common.sh" &&
      -r "$SCRIPT_DIR/bin/backhaul-manager" &&
      -r "$SCRIPT_DIR/bin/backhaul-menu" &&
      -r "$SCRIPT_DIR/bin/homa" &&
      -r "$SCRIPT_DIR/bin/bh" ]]; then
    install -m 644 "$SCRIPT_DIR/lib/common.sh" "$STAGE_DIR/lib/common.sh"
    install -m 755 "$SCRIPT_DIR/bin/backhaul-manager" \
        "$STAGE_DIR/bin/backhaul-manager"
    install -m 755 "$SCRIPT_DIR/bin/backhaul-menu" \
        "$STAGE_DIR/bin/backhaul-menu"
    install -m 755 "$SCRIPT_DIR/bin/homa" "$STAGE_DIR/bin/homa"
    install -m 755 "$SCRIPT_DIR/bin/bh" "$STAGE_DIR/bin/bh"
else
    download_bootstrap "$RAW_BASE/lib/common.sh" "$STAGE_DIR/lib/common.sh"
    download_bootstrap "$RAW_BASE/bin/backhaul-manager" "$STAGE_DIR/bin/backhaul-manager"
    download_bootstrap "$RAW_BASE/bin/backhaul-menu" "$STAGE_DIR/bin/backhaul-menu"
    download_bootstrap "$RAW_BASE/bin/homa" "$STAGE_DIR/bin/homa"
    download_bootstrap "$RAW_BASE/bin/bh" "$STAGE_DIR/bin/bh"
fi

for staged_script in \
    "$STAGE_DIR/lib/common.sh" \
    "$STAGE_DIR/bin/backhaul-manager" \
    "$STAGE_DIR/bin/backhaul-menu" \
    "$STAGE_DIR/bin/homa" \
    "$STAGE_DIR/bin/bh"; do
    [[ -s "$staged_script" ]] ||
        die_bootstrap "A required Manager file is empty: $staged_script"
    bash -n "$staged_script" ||
        die_bootstrap "Syntax validation failed: $staged_script"
done

grep -Fq "BH_MANAGER_VERSION=\"\${BH_MANAGER_VERSION:-$PROJECT_VERSION}\"" \
    "$STAGE_DIR/lib/common.sh" ||
    die_bootstrap "Installer and Manager versions do not match."

for destination_dir in \
    "$PROJECT_DIR" \
    "$PROJECT_DIR/lib" \
    "$PROJECT_DIR/bin" \
    "$(dirname "$MANAGER_BIN")" \
    "$(dirname "$MENU_BIN")" \
    "$(dirname "$SHORTCUT_BIN")" \
    "$(dirname "$LEGACY_SHORTCUT_BIN")"; do
    [[ -d "$destination_dir" ]] || install -d -m 755 "$destination_dir"
done

manager_sources=(
    "$STAGE_DIR/lib/common.sh"
    "$STAGE_DIR/bin/backhaul-manager"
    "$STAGE_DIR/bin/backhaul-menu"
    "$STAGE_DIR/bin/homa"
    "$STAGE_DIR/bin/bh"
    "$STAGE_DIR/bin/backhaul-manager"
    "$STAGE_DIR/bin/backhaul-menu"
    "$STAGE_DIR/bin/homa"
    "$STAGE_DIR/bin/bh"
)
manager_destinations=(
    "$PROJECT_DIR/lib/common.sh"
    "$PROJECT_DIR/bin/backhaul-manager"
    "$PROJECT_DIR/bin/backhaul-menu"
    "$PROJECT_DIR/bin/homa"
    "$PROJECT_DIR/bin/bh"
    "$MANAGER_BIN"
    "$MENU_BIN"
    "$SHORTCUT_BIN"
    "$LEGACY_SHORTCUT_BIN"
)
manager_modes=(644 755 755 755 755 755 755 755 755)
manager_previous=()
ROLLBACK_DIR="$TEMP_DIR/manager-rollback"
install -d -m 700 "$ROLLBACK_DIR"

for index in "${!manager_destinations[@]}"; do
    destination="${manager_destinations[$index]}"
    [[ ! -d "$destination" ]] ||
        die_bootstrap "A Manager file destination is a directory: $destination"
    if [[ -e "$destination" || -L "$destination" ]]; then
        cp -a -- "$destination" "$ROLLBACK_DIR/$index" ||
            die_bootstrap "Could not stage rollback data for: $destination"
        manager_previous[index]=1
    else
        manager_previous[index]=0
    fi
done

manager_install_failed=0
for index in "${!manager_destinations[@]}"; do
    if ! atomic_install_bootstrap \
        "${manager_sources[$index]}" \
        "${manager_destinations[$index]}" \
        "${manager_modes[$index]}"; then
        manager_install_failed=1
        break
    fi
done

if ((manager_install_failed == 1)); then
    manager_rollback_failed=0
    for index in "${!manager_destinations[@]}"; do
        destination="${manager_destinations[$index]}"
        if [[ "${manager_previous[$index]}" == "1" ]]; then
            rm -f -- "$destination" || manager_rollback_failed=1
            cp -a -- "$ROLLBACK_DIR/$index" "$destination" ||
                manager_rollback_failed=1
        else
            rm -f -- "$destination" || manager_rollback_failed=1
        fi
    done
    ((manager_rollback_failed == 0)) ||
        die_bootstrap "Manager installation failed and rollback was incomplete."
    die_bootstrap "Manager installation failed; the previous Manager files were restored."
fi

if ((SKIP_BINARY == 0)) && [[ ! -x "$BACKHAUL_BIN" || "$FORCE_BINARY" == "1" ||
                              -n "$BINARY_FILE" || "$USE_LATEST" == "1" ]]; then
    binary_install_args=(binary install)
    if [[ -n "$BINARY_FILE" ]]; then
        binary_install_args+=(--version "$VERSION" --file "$BINARY_FILE")
    elif ((USE_LATEST == 1)); then
        binary_install_args+=(--latest)
    else
        binary_install_args+=(--version "$VERSION")
    fi
    if ((ALLOW_UNVERIFIED_DOWNLOAD == 1)); then
        binary_install_args+=(--allow-unverified-download)
    fi
    "$MANAGER_BIN" "${binary_install_args[@]}"
elif [[ -x "$BACKHAUL_BIN" ]]; then
    printf '[OK] The existing Backhaul binary was preserved unchanged.\n'
fi

printf '[OK] Homa Ghost Tunnel Manager %s installed.\n' "$PROJECT_VERSION"

if ((ENABLE_HEALTH_CRON == 1)); then
    if [[ "${BH_NO_SYSTEMD:-0}" != "1" ]] &&
       ! command -v cron >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            printf '[INFO] Installing the cron dependency...\n'
            DEBIAN_FRONTEND=noninteractive apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y cron
        else
            die_bootstrap "cron is not installed and apt-get is unavailable."
        fi
    fi
    "$MANAGER_BIN" cron install --interval "$HEALTH_INTERVAL"
fi

if ((${#FORWARD_ARGS[@]} > 0)); then
    exec "$MANAGER_BIN" "${FORWARD_ARGS[@]}"
fi

printf 'Run menu: sudo homa\n'
printf '[INFO] Legacy alias preserved: sudo bh\n'
