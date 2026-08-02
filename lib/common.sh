#!/usr/bin/env bash

# Shared by the installer, CLI manager, and interactive menu.
# The color variables are intentionally consumed by scripts that source this file.
# shellcheck disable=SC2034

BH_MANAGER_VERSION="${BH_MANAGER_VERSION:-1.1.13}"
BH_VERSION_DEFAULT="${BH_VERSION_DEFAULT:-v0.7.2}"
BH_UPSTREAM_REPO="${BH_UPSTREAM_REPO:-Musixal/Backhaul}"
BH_GITHUB_API_BASE="${BH_GITHUB_API_BASE:-https://api.github.com}"
BH_GITHUB_RELEASE_BASE="${BH_GITHUB_RELEASE_BASE:-https://github.com}"
BH_REQUIRE_RELEASE_DIGEST="${BH_REQUIRE_RELEASE_DIGEST:-1}"
BH_BIN="${BH_BIN:-/usr/local/bin/backhaul}"
BH_CONFIG_DIR="${BH_CONFIG_DIR:-/etc/backhaul}"
BH_STATE_DIR="${BH_STATE_DIR:-/etc/backhaul-manager}"
BH_SYSTEMD_DIR="${BH_SYSTEMD_DIR:-/etc/systemd/system}"
BH_PROJECT_DIR="${BH_PROJECT_DIR:-/opt/backhaul-tunnel-manager}"
BH_MANAGER_BIN="${BH_MANAGER_BIN:-/usr/local/sbin/backhaul-manager}"
BH_MENU_BIN="${BH_MENU_BIN:-/usr/local/sbin/backhaul-menu}"
BH_SHORTCUT_BIN="${BH_SHORTCUT_BIN:-/usr/local/bin/homa}"
BH_LEGACY_SHORTCUT_BIN="${BH_LEGACY_SHORTCUT_BIN:-/usr/local/bin/bh}"
BH_CRON_FILE="${BH_CRON_FILE:-/etc/cron.d/backhaul-manager-health}"
BH_BACKUP_DIR="${BH_BACKUP_DIR:-/var/backups/backhaul-manager}"
BH_RAW_BASE="${BH_RAW_BASE:-https://raw.githubusercontent.com/radar-kx/Backhaul-homa-ghost-tunnel-manager/main}"

if [[ -t 1 ]]; then
    BH_RED=$'\033[0;31m'
    BH_GREEN=$'\033[0;32m'
    BH_YELLOW=$'\033[0;33m'
    BH_BLUE=$'\033[0;34m'
    BH_CYAN=$'\033[0;36m'
    BH_RESET=$'\033[0m'
else
    BH_RED=""
    BH_GREEN=""
    BH_YELLOW=""
    BH_BLUE=""
    BH_CYAN=""
    BH_RESET=""
fi

info() {
    printf '%s[INFO]%s %s\n' "$BH_BLUE" "$BH_RESET" "$*"
}

success() {
    printf '%s[OK]%s %s\n' "$BH_GREEN" "$BH_RESET" "$*"
}

warn() {
    printf '%s[WARN]%s %s\n' "$BH_YELLOW" "$BH_RESET" "$*" >&2
}

die() {
    printf '%s[ERROR]%s %s\n' "$BH_RED" "$BH_RESET" "$*" >&2
    exit 1
}

require_root() {
    # تست‌های خودکار می‌توانند بررسی root را به‌صورت صریح غیرفعال کنند.
    [[ "${BH_SKIP_ROOT_CHECK:-0}" == "1" ]] && return 0
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This command must be run as root or with sudo."
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

systemctl_state() {
    local query="$1"
    local unit="$2"
    local state=""
    if ! command -v systemctl >/dev/null 2>&1; then
        printf 'unknown\n'
        return 0
    fi
    state="$(
        systemctl "$query" "$unit" 2>/dev/null |
            awk 'NF { print; exit }' || true
    )"
    case "$query:$state" in
        is-active:active|is-active:reloading|is-active:inactive|\
        is-active:failed|is-active:activating|is-active:deactivating|\
        is-active:maintenance|is-enabled:enabled|is-enabled:enabled-runtime|\
        is-enabled:linked|is-enabled:linked-runtime|is-enabled:alias|\
        is-enabled:masked|is-enabled:masked-runtime|is-enabled:static|\
        is-enabled:indirect|is-enabled:disabled|is-enabled:generated|\
        is-enabled:transient)
            printf '%s\n' "$state"
            ;;
        *)
            printf 'unknown\n'
            ;;
    esac
}

unit_runtime_is_active() {
    case "$1" in
        active|reloading|activating) return 0 ;;
        *) return 1 ;;
    esac
}

unit_startup_is_enabled() {
    case "$1" in
        enabled|enabled-runtime|linked|linked-runtime|alias|static|indirect|generated|transient)
            return 0
            ;;
        *) return 1 ;;
    esac
}

timestamp() {
    # Nanoseconds avoid backup/archive collisions when several operations run
    # within the same second.
    date +%Y%m%d_%H%M%S_%N
}

discover_backhaul_units() {
    # سرویس‌های قدیمی مانند backhaul-france.service نیز باید شناسایی شوند.
    find "$BH_SYSTEMD_DIR" -maxdepth 1 \( -type f -o -type l \) \
        -name 'backhaul-*.service' -printf '%f\n' 2>/dev/null | sort -u
}

unit_file_path() {
    printf '%s/%s\n' "$BH_SYSTEMD_DIR" "$1"
}

config_path_from_unit_file() {
    local unit_file="$1"
    [[ -r "$unit_file" ]] || return 1

    sed -nE '
        s#^[[:space:]]*ExecStart=.*[[:space:]]-c[[:space:]]+("[^"]+"|[^[:space:]]+).*$#\1#p
        s#^[[:space:]]*ExecStart=.*[[:space:]]-c=("[^"]+"|[^[:space:]]+).*$#\1#p
    ' "$unit_file" |
        head -n 1 |
        tr -d '"'
}

unit_config_path() {
    local unit="$1"
    config_path_from_unit_file "$(unit_file_path "$unit")"
}

unit_role_from_config() {
    local config="${1:-}"
    if [[ -n "$config" && -r "$config" ]]; then
        if grep -qE '^[[:space:]]*\[server\][[:space:]]*$' "$config"; then
            printf 'server\n'
            return 0
        fi
        if grep -qE '^[[:space:]]*\[client\][[:space:]]*$' "$config"; then
            printf 'client\n'
            return 0
        fi
    fi
    printf 'legacy\n'
}

unit_short_name() {
    local unit="$1"
    local role="${2:-legacy}"
    local name="${unit#backhaul-}"
    name="${name%.service}"
    case "$role" in
        server) name="${name%-server}" ;;
        client) name="${name%-client}" ;;
    esac
    printf '%s\n' "$name"
}

validate_unit_name() {
    [[ "$1" =~ ^backhaul-[A-Za-z0-9_.@-]+\.service$ ]] ||
        die "Invalid Backhaul service name: $1"
}

unit_is_managed() {
    local wanted="$1"
    local unit
    while IFS= read -r unit; do
        [[ "$unit" == "$wanted" ]] && return 0
    done < <(discover_backhaul_units)
    return 1
}

backup_file() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    cp -a -- "$path" "${path}.bak.$(timestamp)"
}

validate_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] ||
        die "Names may contain only lowercase English letters, numbers, hyphens, and underscores."
}

require_option_value() {
    local option="$1"
    local argument_count="$2"
    local value="${3:-}"
    ((argument_count >= 2)) || die "$option requires a value."
    [[ -n "$value" ]] || die "$option requires a non-empty value."
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port: $port"
    [[ "$port" != 0[0-9]* ]] ||
        die "Ports must not contain leading zeroes: $port"
    ((${#port} <= 5)) ||
        die "Port must be between 1 and 65535: $port"
    ((10#$port >= 1 && 10#$port <= 65535)) ||
        die "Port must be between 1 and 65535: $port"
}

validate_transport() {
    case "$1" in
        tcp|tcpmux|ws|wss|wsmux|wssmux) ;;
        *) die "Invalid transport: $1" ;;
    esac
}

validate_token() {
    [[ "$1" =~ ^[A-Za-z0-9._~-]{16,256}$ ]] ||
        die "The token must contain at least 16 characters and no spaces or quotation marks."
}

validate_ipv4() {
    local value="$1"
    local -a octets=()
    local octet
    IFS='.' read -r -a octets <<<"$value"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

validate_ipv6() {
    local value="$1"
    local left="" right="" remainder=""
    local -a groups=()
    local group

    [[ -n "$value" && "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:]+$ ]] ||
        return 1
    [[ "$value" != *:::* ]] || return 1

    if [[ "$value" == *::* ]]; then
        remainder="${value#*::}"
        [[ "$remainder" != *::* ]] || return 1
        left="${value%%::*}"
        right="$remainder"
        groups=()
        if [[ -n "$left" ]]; then
            IFS=':' read -r -a groups <<<"$left"
        fi
        if [[ -n "$right" ]]; then
            local -a right_groups=()
            IFS=':' read -r -a right_groups <<<"$right"
            groups+=("${right_groups[@]}")
        fi
        # The double colon must compress at least one 16-bit group.
        ((${#groups[@]} < 8)) || return 1
    else
        [[ "$value" != :* && "$value" != *: ]] || return 1
        IFS=':' read -r -a groups <<<"$value"
        ((${#groups[@]} == 8)) || return 1
    fi

    for group in "${groups[@]}"; do
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
}

validate_hostname() {
    local value="$1"
    local -a labels=()
    local label

    ((${#value} >= 1 && ${#value} <= 253)) || return 1
    [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    IFS='.' read -r -a labels <<<"$value"
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
            return 1
    done
}

validate_host() {
    local value="$1"
    if [[ "$value" =~ ^[0-9.]+$ ]]; then
        validate_ipv4 "$value" ||
            die "Invalid IPv4 address: $value"
        return 0
    fi
    if [[ "$value" == \[*\] ]]; then
        validate_ipv6 "${value:1:${#value}-2}" ||
            die "Invalid IPv6 address: $value"
        return 0
    fi
    if validate_hostname "$value"; then
        return 0
    fi
    die "Invalid IP address or domain. Write IPv6 addresses inside brackets: $value"
}

validate_absolute_path() {
    [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
        die "The path must be absolute and contain no spaces: $1"
}

validate_endpoint() {
    local value="$1"
    local host=""
    local port=""
    if [[ "$value" =~ ^(\[[0-9A-Fa-f:]+\]):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="${value%:*}"
        port="${value##*:}"
        [[ "$host" != "$value" ]] ||
            die "The address must use HOST:PORT format: $value"
    fi
    validate_host "$host"
    validate_port "$port"
}

validate_bind() {
    local value="$1"
    local host=""
    local port=""
    if [[ "$value" =~ ^(\[[0-9A-Fa-f:]+\]):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="${value%:*}"
        port="${value##*:}"
        [[ "$host" != "$value" ]] ||
            die "The bind address must use IP:PORT format: $value"
    fi
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        validate_ipv4 "$host" ||
            die "Invalid bind IPv4 address: $host"
    elif [[ "$host" == \[*\] ]]; then
        validate_ipv6 "${host:1:${#host}-2}" ||
            die "Invalid bind IPv6 address: $host"
    else
        die "Invalid bind IP address: $host"
    fi
    validate_port "$port"
}

validate_mapping() {
    # فرمت امن و روشن پروژه: PUBLIC_PORT=REMOTE_HOST:REMOTE_PORT
    local value="$1"
    [[ "$value" == *=*:* ]] ||
        die "The mapping must use a format such as 8300=127.0.0.1:8090: $value"
    local listen="${value%%=*}"
    local target="${value#*=}"
    local host="${target%:*}"
    local port="${target##*:}"
    validate_port "$listen"
    validate_host "$host"
    validate_port "$port"
}

generate_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    elif [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    else
        die "openssl or /dev/urandom is required to generate a secure token."
    fi
}

normalize_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        armv7l|armv7) printf 'armv7\n' ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

download_to() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --ipv4 --fail --location --silent --show-error \
            --connect-timeout 15 --retry 3 --output "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -4 --quiet --tries=3 --timeout=30 --output-document="$output" "$url"
    else
        die "curl or wget is required for downloads."
    fi
}

verify_sha256() {
    local file="$1"
    local expected="${2:-}"
    [[ -n "$expected" ]] || return 0
    expected="${expected#sha256:}"
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] ||
        die "Invalid SHA-256 value: $expected"
    expected="${expected,,}"
    need_cmd sha256sum
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] ||
        die "File hash mismatch. expected=$expected actual=$actual"
}

validate_release_archive() {
    local archive="$1"
    local entry normalized type total_bytes
    local maximum_bytes="${BH_RELEASE_MAX_UNCOMPRESSED_BYTES:-268435456}"
    local -a entries=()

    tar -tzf "$archive" >/dev/null 2>&1 || return 1
    mapfile -t entries < <(tar -tzf "$archive")
    ((${#entries[@]} >= 1 && ${#entries[@]} <= 1000)) || return 1
    [[ "$maximum_bytes" =~ ^[0-9]+$ ]] || maximum_bytes=268435456
    total_bytes="$(
        tar -tvzf "$archive" --numeric-owner 2>/dev/null |
            awk '{ total += $3 } END { printf "%.0f", total }'
    )"
    [[ "$total_bytes" =~ ^[0-9]+$ ]] || return 1
    ((total_bytes <= maximum_bytes)) || return 1

    for entry in "${entries[@]}"; do
        normalized="${entry#./}"
        [[ -n "$normalized" ]] || continue
        [[ "$normalized" != /* && "$normalized" != *'../'* &&
           "$normalized" != '..' && "$normalized" != *'/..' ]] || return 1
    done
    while IFS= read -r type; do
        case "$type" in
            -|d) ;;
            *) return 1 ;;
        esac
    done < <(tar -tvzf "$archive" | cut -c1)
}

latest_backhaul_version() {
    if [[ -n "${BH_LATEST_VERSION_OVERRIDE:-}" ]]; then
        [[ "$BH_LATEST_VERSION_OVERRIDE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
            return 1
        printf '%s\n' "$BH_LATEST_VERSION_OVERRIDE"
        return 0
    fi

    local temp tag
    temp="$(mktemp)"
    if ! download_to \
        "${BH_GITHUB_API_BASE}/repos/${BH_UPSTREAM_REPO}/releases/latest" \
        "$temp"; then
        rm -f -- "$temp"
        return 1
    fi
    tag="$(sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$temp" | head -n 1)"
    rm -f -- "$temp"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$tag"
}

release_asset_sha256() {
    local version="$1"
    local asset_name="$2"
    if [[ -n "${BH_RELEASE_DIGEST_OVERRIDE:-}" ]]; then
        local override="${BH_RELEASE_DIGEST_OVERRIDE#sha256:}"
        [[ "$override" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
        printf '%s\n' "${override,,}"
        return 0
    fi

    local temp digest=""
    temp="$(mktemp)"
    if ! download_to \
        "${BH_GITHUB_API_BASE}/repos/${BH_UPSTREAM_REPO}/releases/tags/${version}" \
        "$temp"; then
        rm -f -- "$temp"
        return 1
    fi

    if [[ "${BH_DISABLE_JSON_TOOLS:-0}" != "1" ]] &&
       command -v python3 >/dev/null 2>&1; then
        digest="$(python3 - "$temp" "$asset_name" <<'PYJSON' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
for asset in payload.get("assets", []):
    if asset.get("name") == sys.argv[2]:
        value = asset.get("digest") or ""
        if value.startswith("sha256:"):
            print(value.split(":", 1)[1])
        break
PYJSON
)"
    elif [[ "${BH_DISABLE_JSON_TOOLS:-0}" != "1" ]] &&
         command -v jq >/dev/null 2>&1; then
        digest="$(jq -r --arg name "$asset_name" \
            '.assets[]? | select(.name == $name) | .digest // empty' \
            "$temp" 2>/dev/null | sed -n 's/^sha256://p' | head -n 1)"
    else
        # Minimal dependency-free fallback for GitHub's release JSON. Remove
        # insignificant whitespace and split adjacent objects before selecting
        # the asset by its exact name. Release asset names used here contain no
        # JSON escape sequences.
        digest="$(
            tr -d '\n\r\t ' <"$temp" |
                sed 's/},{/}\n{/g' |
                awk -v wanted="\"name\":\"${asset_name}\"" '
                    index($0, wanted) { print; exit }
                ' |
                sed -nE 's/.*"digest":"sha256:([A-Fa-f0-9]{64})".*/\1/p'
        )"
    fi
    rm -f -- "$temp"
    [[ "$digest" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    printf '%s\n' "${digest,,}"
}

verify_release_asset_archive() {
    local version="$1"
    local asset_name="$2"
    local archive="$3"
    local digest=""

    if digest="$(release_asset_sha256 "$version" "$asset_name")"; then
        verify_sha256 "$archive" "$digest"
        success "Verified the official GitHub release digest for $asset_name."
        return 0
    fi

    if [[ "${BH_REQUIRE_RELEASE_DIGEST:-1}" == "1" ]]; then
        die "GitHub did not provide a SHA-256 digest for $asset_name. Re-run with --allow-unverified-download only if you accept this risk."
    fi
    warn "No published SHA-256 digest was available; continuing only because unverified download was explicitly allowed."
}

wait_for_unit_stable() {
    local unit="$1"
    local attempts="${BH_SERVICE_HEALTH_ATTEMPTS:-12}"
    local required_stable="${BH_SERVICE_STABLE_CHECKS:-3}"
    local delay="${BH_SERVICE_HEALTH_DELAY:-0.5}"
    local attempt stable=0

    [[ "$attempts" =~ ^[0-9]+$ ]] && ((attempts >= 1)) || attempts=12
    [[ "$required_stable" =~ ^[0-9]+$ ]] && ((required_stable >= 1)) ||
        required_stable=3

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
            stable=$((stable + 1))
            if ((stable >= required_stable)); then
                return 0
            fi
        else
            stable=0
        fi
        if ((attempt < attempts)); then
            sleep "$delay"
        fi
    done

    # Query failed state as a final diagnostic signal. The return status of
    # this helper remains non-zero for every non-stable service state.
    systemctl is-failed --quiet "$unit" >/dev/null 2>&1 || true
    return 1
}

install_backhaul_binary() {
    local version="$1"
    local source_file="${2:-}"
    local expected_sha="${3:-}"
    local temp_dir=""
    local candidate=""

    require_root
    [[ -d "$(dirname "$BH_BIN")" ]] ||
        install -d -m 755 "$(dirname "$BH_BIN")"

    if [[ -n "$source_file" ]]; then
        [[ -s "$source_file" ]] || die "Binary file not found: $source_file"
        candidate="$source_file"
    else
        need_cmd tar
        temp_dir="$(mktemp -d)"
        local arch
        arch="$(normalize_arch)"
        local archive="$temp_dir/backhaul.tar.gz"
        local asset_name="backhaul_linux_${arch}.tar.gz"
        local url="${BH_GITHUB_RELEASE_BASE}/${BH_UPSTREAM_REPO}/releases/download/${version}/${asset_name}"
        info "Downloading Backhaul ${version} for ${arch}"
        download_to "$url" "$archive"
        verify_release_asset_archive "$version" "$asset_name" "$archive"
        validate_release_archive "$archive" ||
            die "The Backhaul release archive is unsafe or corrupted."
        tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$temp_dir"
        candidate="$(find "$temp_dir" -maxdepth 2 -type f -name backhaul -print -quit)"
        [[ -n "$candidate" ]] || die "The backhaul binary was not found in the archive."
    fi

    verify_sha256 "$candidate" "$expected_sha"

    local backup=""
    if [[ -e "$BH_BIN" ]]; then
        backup="${BH_BIN}.bak.$(timestamp)"
        cp -a -- "$BH_BIN" "$backup"
    fi

    local -a units=()
    local -A expected_active=()
    local unit state
    if [[ "${BH_NO_SYSTEMD:-0}" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
        mapfile -t units < <(discover_backhaul_units)
        for unit in "${units[@]}"; do
            [[ -n "$unit" ]] || continue
            state="$(systemctl_state is-active "$unit")"
            case "$state" in
                active|reloading|activating) expected_active["$unit"]=1 ;;
                *) expected_active["$unit"]=0 ;;
            esac
        done
    fi

    install -o root -g root -m 755 "$candidate" "${BH_BIN}.new"
    mv -f -- "${BH_BIN}.new" "$BH_BIN"

    if ((${#units[@]} > 0)); then
        local failed=0
        for unit in "${units[@]}"; do
            [[ -n "$unit" ]] || continue
            if ! systemctl try-restart "$unit"; then
                warn "Restart command failed for $unit."
                failed=1
            fi
        done

        if ((failed == 0)); then
            for unit in "${units[@]}"; do
                [[ "${expected_active[$unit]:-0}" == "1" ]] || continue
                if ! wait_for_unit_stable "$unit"; then
                    warn "Service did not remain active after the binary update: $unit"
                    failed=1
                fi
            done
        fi

        if ((failed == 1)); then
            local rollback_failed=0
            if [[ -n "$backup" ]]; then
                warn "A service failed its post-update health check; restoring the previous binary."
                cp -a -- "$backup" "$BH_BIN" || rollback_failed=1
            else
                warn "A service failed its post-update health check; removing the new binary."
                rm -f -- "$BH_BIN" || rollback_failed=1
            fi

            for unit in "${units[@]}"; do
                [[ "${expected_active[$unit]:-0}" == "1" ]] || continue
                systemctl restart "$unit" || rollback_failed=1
            done
            if ((rollback_failed == 0)); then
                for unit in "${units[@]}"; do
                    [[ "${expected_active[$unit]:-0}" == "1" ]] || continue
                    wait_for_unit_stable "$unit" || rollback_failed=1
                done
            fi

            [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"
            if ((rollback_failed == 1)); then
                die "Binary update failed and automatic rollback was incomplete. Inspect the affected services immediately."
            fi
            die "Binary update failed. The previous binary and active service state were restored."
        fi
    fi

    [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"
    success "Binary installed at $BH_BIN."
}

atomic_install_file() {
    local source="$1"
    local destination="$2"
    local mode="$3"
    local create_backup="${4:-1}"
    local staged
    # Never chmod an existing system directory (for example /etc/systemd/system
    # or /etc/cron.d). Callers create sensitive private directories explicitly.
    [[ -d "$(dirname "$destination")" ]] ||
        install -d -m 755 "$(dirname "$destination")"
    staged="$(mktemp "$(dirname "$destination")/.install.XXXXXX")"
    if ! install -o root -g root -m "$mode" "$source" "$staged"; then
        rm -f -- "$staged"
        return 1
    fi
    if ((create_backup == 1)) && ! backup_file "$destination"; then
        rm -f -- "$staged"
        return 1
    fi
    if ! mv -f -- "$staged" "$destination"; then
        rm -f -- "$staged"
        return 1
    fi
}

atomic_install_stdin() {
    local destination="$1"
    local mode="$2"
    local temp
    [[ -d "$(dirname "$destination")" ]] ||
        install -d -m 755 "$(dirname "$destination")"
    temp="$(mktemp "$(dirname "$destination")/.input.XXXXXX")"
    if ! cat >"$temp"; then
        rm -f -- "$temp"
        return 1
    fi
    if ! atomic_install_file "$temp" "$destination" "$mode"; then
        rm -f -- "$temp"
        return 1
    fi
    rm -f -- "$temp"
}

systemd_reload_enable() {
    local unit="$1"
    if [[ "${BH_NO_SYSTEMD:-0}" == "1" ]]; then
        info "Test mode: systemd was not invoked ($unit)."
        return 0
    fi
    need_cmd systemctl
    systemctl daemon-reload
    systemctl enable --now "$unit"
    systemctl is-active --quiet "$unit" ||
        die "Service $unit did not become active. Logs: journalctl -u $unit -n 50"
}

open_ufw_port() {
    local spec="$1"
    if ! command -v ufw >/dev/null 2>&1; then
        warn "UFW is not installed. Check the system or datacenter firewall manually: $spec"
        return 0
    fi
    if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
        warn "UFW is disabled; no new rule was applied: $spec"
        return 0
    fi
    if ! ufw allow "$spec"; then
        warn "UFW could not add the rule. Check it manually: $spec"
        return 0
    fi
    success "UFW rule added: $spec"
}
