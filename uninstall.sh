#!/usr/bin/env bash
set -Eeuo pipefail

# By default, remove only the Manager and preserve tunnels, configs, and core.

SYSTEMD_DIR="${BH_SYSTEMD_DIR:-/etc/systemd/system}"
CONFIG_DIR="${BH_CONFIG_DIR:-/etc/backhaul}"
PROJECT_DIR="${BH_PROJECT_DIR:-/opt/backhaul-tunnel-manager}"
CORE_BIN="${BH_BIN:-/usr/local/bin/backhaul}"
MANAGER_BIN="${BH_MANAGER_BIN:-/usr/local/sbin/backhaul-manager}"
MENU_BIN="${BH_MENU_BIN:-/usr/local/sbin/backhaul-menu}"
SHORTCUT_BIN="${BH_SHORTCUT_BIN:-/usr/local/bin/homa}"
LEGACY_SHORTCUT_BIN="${BH_LEGACY_SHORTCUT_BIN:-/usr/local/bin/bh}"
CRON_FILE="${BH_CRON_FILE:-/etc/cron.d/backhaul-manager-health}"
BACKUP_ROOT="${BH_BACKUP_DIR:-/var/backups/backhaul-manager}"

fail_uninstall() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

validate_absolute_target() {
    local path="$1"
    local label="$2"
    local normalized
    [[ "$path" == /* ]] ||
        fail_uninstall "$label must be an absolute path: $path"
    normalized="$(realpath -m -- "$path" 2>/dev/null)" ||
        fail_uninstall "$label could not be resolved safely: $path"
    [[ "$normalized" != "/" ]] ||
        fail_uninstall "Refusing to use the filesystem root as $label."
}

validate_tree_target() {
    local path="$1"
    local label="$2"
    local normalized relative
    validate_absolute_target "$path" "$label"
    normalized="$(realpath -m -- "$path")"
    relative="${normalized#/}"
    [[ "$relative" == */* ]] ||
        fail_uninstall "Refusing broad directory for $label: $normalized"
}

validate_tree_target "$SYSTEMD_DIR" "systemd directory"
validate_tree_target "$CONFIG_DIR" "config directory"
validate_tree_target "$PROJECT_DIR" "Manager project directory"
validate_tree_target "$BACKUP_ROOT" "backup directory"
validate_absolute_target "$CORE_BIN" "Backhaul core path"
validate_absolute_target "$MANAGER_BIN" "Manager executable path"
validate_absolute_target "$MENU_BIN" "menu executable path"
validate_absolute_target "$SHORTCUT_BIN" "shortcut executable path"
validate_absolute_target "$LEGACY_SHORTCUT_BIN" "legacy shortcut executable path"
validate_absolute_target "$CRON_FILE" "cron file path"

PURGE_ALL=0
if [[ "${1:-}" == "--purge-all" ]]; then
    PURGE_ALL=1
elif [[ -n "${1:-}" ]]; then
    printf '[ERROR] Valid option: --purge-all\n' >&2
    exit 1
fi

[[ "${BH_SKIP_ROOT_CHECK:-0}" == "1" ||
   "${EUID:-$(id -u)}" -eq 0 ]] || {
    printf '[ERROR] Uninstall must be run as root or with sudo.\n' >&2
    exit 1
}

STAMP="$(date +%Y%m%d_%H%M%S_%N)"
BACKUP_DIR="$BACKUP_ROOT/uninstall-$STAMP"
install -d -m 700 "$BACKUP_DIR"

if ((PURGE_ALL == 1)); then
    printf '[WARN] This option stops and removes all Backhaul services and configs.\n'
    read -r -p "Type PURGE to continue: " confirmation
    [[ "$confirmation" == "PURGE" ]] || {
        printf '[INFO] Operation cancelled.\n'
        exit 0
    }

    install -d -m 700 "$BACKUP_DIR/systemd" "$BACKUP_DIR/configs" \
        "$BACKUP_DIR/core"
    local_unit_paths=()
    active_units=()
    enabled_units=()
    while IFS= read -r unit_path; do
        [[ -n "$unit_path" ]] || continue
        unit="$(basename "$unit_path")"
        cp -a -- "$unit_path" "$BACKUP_DIR/systemd/"
        cmp -s -- "$unit_path" "$BACKUP_DIR/systemd/$unit" || {
            printf '[ERROR] Unit backup verification failed: %s\n' "$unit" >&2
            exit 1
        }
        local_unit_paths+=("$unit_path")
        if [[ "${BH_NO_SYSTEMD:-0}" != "1" ]]; then
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                active_units+=("$unit")
            fi
            if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                enabled_units+=("$unit")
            fi
        fi
    done < <(find "$SYSTEMD_DIR" -maxdepth 1 \( -type f -o -type l \) \
        -name 'backhaul-*.service' -print 2>/dev/null)

    if [[ -d "$CONFIG_DIR" ]]; then
        cp -a -- "$CONFIG_DIR"/. "$BACKUP_DIR/configs/"
    fi
    if [[ -e "$CORE_BIN" ]]; then
        cp -a -- "$CORE_BIN" "$BACKUP_DIR/core/backhaul"
        cmp -s -- "$CORE_BIN" "$BACKUP_DIR/core/backhaul" || {
            printf '[ERROR] Backhaul core backup verification failed.\n' >&2
            exit 1
        }
    fi

    for unit_path in "${local_unit_paths[@]}"; do
        unit="$(basename "$unit_path")"
        if [[ "${BH_NO_SYSTEMD:-0}" != "1" ]] &&
           { ! systemctl disable --now "$unit" >/dev/null 2>&1 ||
             systemctl is-active --quiet "$unit" 2>/dev/null; }; then
            printf '[ERROR] Could not stop %s. No files were removed.\n' "$unit" >&2
            for original_unit in "${enabled_units[@]}"; do
                systemctl enable "$original_unit" >/dev/null 2>&1 || true
            done
            for original_unit in "${active_units[@]}"; do
                systemctl start "$original_unit" >/dev/null 2>&1 || true
            done
            exit 1
        fi
    done

    for unit_path in "${local_unit_paths[@]}"; do
        rm -f -- "$unit_path"
    done
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf -- "$CONFIG_DIR"
    fi
    if [[ "${BH_NO_SYSTEMD:-0}" != "1" ]]; then
        systemctl daemon-reload
    fi
    rm -f -- "$CORE_BIN"
fi

if [[ -e "$CRON_FILE" ]]; then
    cp -a -- "$CRON_FILE" "$BACKUP_DIR/"
    rm -f -- "$CRON_FILE"
fi

rm -rf -- "$PROJECT_DIR"
rm -f -- "$MANAGER_BIN" "$MENU_BIN" "$SHORTCUT_BIN" "$LEGACY_SHORTCUT_BIN"

if ((PURGE_ALL == 1)); then
    printf '[OK] Manager, tunnels, and core were removed. Backup: %s\n' "$BACKUP_DIR"
else
    printf '[OK] Only the Manager was removed; tunnels, configs, and the core remain active.\n'
fi
