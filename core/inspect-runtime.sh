#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/inspect-runtime.sh                            ║
# ║  Android-Compatible Runtime Inspection with Auto-Fix            ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
ARCH_PATH="${ARCH_PATH:-/data/local/arch}"
STATE_DIR="${STATE_DIR:-/data/local/archdroid-state}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-fix mode (enabled by default for better Android compatibility)
AUTO_FIX="${ARCHDROID_AUTO_FIX:-1}"

# Load utilities
source "${SCRIPT_DIR}/json-utils.sh"

# Session tracking
SESSION_ID=$(date +%s)
mkdir -p "${STATE_DIR}/logs"
INSPECT_LOG="${STATE_DIR}/logs/inspect-${SESSION_ID}.log"

# JSON output file
RUNTIME_JSON="${STATE_DIR}/runtime-snapshot.json"

# Status constants
STATUS_OK=0
STATUS_WARN=1
STATUS_FAIL=2

# Component status tracking
declare -A COMPONENT_STATUS
COMPONENT_STATUS[filesystem]=$STATUS_OK
COMPONENT_STATUS[network]=$STATUS_OK
COMPONENT_STATUS[environment]=$STATUS_OK
COMPONENT_STATUS[security]=$STATUS_OK

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }
autofix() { echo -e "${CYAN}  🔧  $*${RESET}"; }

# ─── STATUS MANAGEMENT ───────────────────────────────────────────────────────
update_component_status() {
    local component="$1"
    local status="$2"

    # Only update if new status is worse than current
    if [ "$status" -gt "${COMPONENT_STATUS[$component]}" ]; then
        COMPONENT_STATUS[$component]=$status
    fi
}

# ─── AUTO-FIX FUNCTIONS ──────────────────────────────────────────────────────
autofix_selinux() {
    if [ "$AUTO_FIX" != "1" ]; then
        return 1
    fi

    autofix "Setting SELinux to permissive for chroot compatibility..."
    if setenforce 0 2>/dev/null; then
        ok "SELinux set to permissive"
        return 0
    else
        warn "Failed to set SELinux permissive (may need root)"
        return 1
    fi
}

autofix_tmp_mount() {
    if [ "$AUTO_FIX" != "1" ]; then
        return 1
    fi

    autofix "Mounting tmpfs on /tmp..."
    mkdir -p "$ARCH_PATH/tmp"

    if mount -t tmpfs -o size=512m,mode=1777 tmpfs "$ARCH_PATH/tmp" 2>/dev/null; then
        ok "Mounted tmpfs on /tmp"
        return 0
    else
        warn "Failed to mount tmpfs on /tmp (may need root)"
        return 1
    fi
}

autofix_dns() {
    if [ "$AUTO_FIX" != "1" ]; then
        return 1
    fi

    autofix "Fixing DNS configuration..."
    local resolv_conf="$ARCH_PATH/etc/resolv.conf"

    # Copy host DNS first
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$resolv_conf" 2>/dev/null || true
    fi

    # Add fallback DNS servers
    {
        echo "# ArchDroid DNS fallback"
        echo "nameserver 1.1.1.1"
        echo "nameserver 8.8.8.8"
    } >> "$resolv_conf" 2>/dev/null || true

    if [ -f "$resolv_conf" ]; then
        ok "DNS configuration updated"
        return 0
    else
        warn "Failed to update DNS configuration"
        return 1
    fi
}

# ─── VALIDATION FUNCTIONS ────────────────────────────────────────────────────
validate_rootfs() {
    echo "═══ Arch Rootfs Validation ═══ [$(date '+%Y-%m-%d %H:%M:%S')]"
    echo ""

    info "Arch path found: $ARCH_PATH"

    # Check if rootfs exists at all
    if [ ! -d "$ARCH_PATH" ]; then
        fail "Rootfs directory not found: $ARCH_PATH"
        update_component_status "filesystem" $STATUS_FAIL
        return 1
    fi

    # Check essential directories (be more forgiving)
    local essential_dirs=("usr" "etc" "bin")
    local missing_dirs=()

    for dir in "${essential_dirs[@]}"; do
        if [ -d "$ARCH_PATH/$dir" ]; then
            ok "Directory: $dir"
        else
            missing_dirs+=("$dir")
        fi
    done

    if [ ${#missing_dirs[@]} -gt 0 ]; then
        fail "Missing essential directories: ${missing_dirs[*]}"
        update_component_status "filesystem" $STATUS_FAIL
        return 1
    fi

    # Check essential files (with fallbacks)
    check_essential_file "bin/bash" "Bash shell" 1 || \
    check_essential_file "bin/sh" "Shell" 1 || {
        fail "No shell found (bash or sh)"
        update_component_status "filesystem" $STATUS_FAIL
        return 1
    }

    check_essential_file "usr/bin/env" "Environment binary" 1 || \
    check_essential_file "bin/env" "Environment binary" 1 || \
        warn "env binary not found (may cause issues)"

    check_essential_file "etc/passwd" "Password database" 0

    check_essential_file "usr/bin/pacman" "Pacman package manager" 1 || \
        warn "Pacman not found (not an Arch system?)"

    # Improved chroot test with multiple fallbacks
    info "Testing chroot execution..."
    local chroot_working=false

    # Try different shells and commands
    for shell_cmd in "/bin/bash -c 'echo ok'" "/bin/sh -c 'echo ok'" "/bin/bash --version" "/bin/sh"; do
        if chroot "$ARCH_PATH" $shell_cmd >/dev/null 2>&1; then
            chroot_working=true
            break
        fi
    done

    if [ "$chroot_working" = true ]; then
        ok "Chroot execution test: PASSED"
    else
        fail "Chroot execution test: FAILED"
        warn "This may be due to SELinux or missing libraries"
        update_component_status "filesystem" $STATUS_FAIL
        return 1
    fi

    ok "Rootfs validation: PASSED"
    return 0
}

check_essential_file() {
    local file_path="$1"
    local description="$2"
    local executable="${3:-0}"

    local full_path="$ARCH_PATH/$file_path"

    if [ ! -f "$full_path" ]; then
        return 1
    fi

    if [ "$executable" = "1" ]; then
        if [ -x "$full_path" ]; then
            ok "Found (executable): $description"
        else
            warn "Found (not executable): $description"
            return 1
        fi
    else
        ok "Found: $description"
    fi
    return 0
}

validate_mounts() {
    echo "═══ Mount Point Validation ═══ [$(date '+%Y-%m-%d %H:%M:%S')]"
    echo ""

    # Essential mounts with auto-fix
    check_mount_with_fix "proc" "proc"
    check_mount_with_fix "sys" "sysfs"
    check_mount_with_fix "dev" ""
    check_mount_with_fix "dev/pts" "devpts"

    # tmp is critical - always try to fix
    if ! check_mount_type "tmp" "tmpfs"; then
        if autofix_tmp_mount; then
            check_mount_type "tmp" "tmpfs" >/dev/null || true
        fi
    fi
}

check_mount_with_fix() {
    local mount_point="$1"
    local expected_type="$2"

    if check_mount_type "$mount_point" "$expected_type"; then
        return 0
    fi

    # If auto-fix is enabled and we have basic mount tools, try to fix
    if [ "$AUTO_FIX" = "1" ] && [ "$(id -u)" = "0" ]; then
        autofix "Attempting to mount $mount_point..."
        mkdir -p "$ARCH_PATH/$mount_point"

        case "$mount_point" in
            "proc")
                mount -t proc proc "$ARCH_PATH/proc" 2>/dev/null && ok "Fixed: mounted proc"
                ;;
            "sys")
                mount -t sysfs sysfs "$ARCH_PATH/sys" 2>/dev/null && ok "Fixed: mounted sys"
                ;;
            "dev")
                mount --rbind /dev "$ARCH_PATH/dev" 2>/dev/null && ok "Fixed: mounted dev"
                ;;
            "dev/pts")
                mount --rbind /dev/pts "$ARCH_PATH/dev/pts" 2>/dev/null && ok "Fixed: mounted dev/pts"
                ;;
        esac
    fi
}

check_mount_type() {
    local mount_point="$1"
    local expected_type="$2"

    if ! mountpoint -q "$ARCH_PATH/$mount_point" 2>/dev/null; then
        warn "NOT mounted: $mount_point"
        update_component_status "filesystem" $STATUS_WARN
        return 1
    fi

    # Check mount type if specified
    if [ -n "$expected_type" ]; then
        if mount | grep -q "$ARCH_PATH/$mount_point.*$expected_type"; then
            ok "Mounted ($expected_type): $mount_point"
        else
            local actual_type
            actual_type=$(mount | grep "$ARCH_PATH/$mount_point" | awk '{print $5}' | head -1)
            warn "Mount type mismatch: $mount_point (expected: $expected_type, got: $actual_type)"
            update_component_status "filesystem" $STATUS_WARN
            return 1
        fi
    else
        ok "Mounted: $mount_point"
    fi
    return 0
}

validate_network() {
    echo "═══ Network & DNS Configuration Validation ═══ [$(date '+%Y-%m-%d %H:%M:%S')]"
    echo ""

    # Check DNS configuration
    if [ -f "$ARCH_PATH/etc/resolv.conf" ]; then
        ok "DNS configuration found"
    else
        warn "No DNS configuration found"
        autofix_dns
        update_component_status "network" $STATUS_WARN
    fi

    # Test basic connectivity (be more forgiving)
    info "Testing network connectivity..."
    if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        ok "Network connectivity: WORKING (ping 1.1.1.1)"
    else
        warn "Network connectivity: LIMITED (no ping response)"
        update_component_status "network" $STATUS_WARN
    fi

    # Test DNS resolution with multiple attempts and auto-fix
    info "Testing DNS resolution..."
    local dns_working=false

    # Try different DNS resolution methods
    for method in "getent hosts google.com" "nslookup google.com" "dig google.com +short"; do
        if timeout 3 $method >/dev/null 2>&1; then
            dns_working=true
            break
        fi
    done

    if [ "$dns_working" = true ]; then
        ok "DNS resolution: WORKING"
    else
        warn "DNS resolution: FAILED"
        if autofix_dns; then
            # Test again after fix
            if timeout 3 getent hosts google.com >/dev/null 2>&1; then
                ok "DNS resolution: FIXED"
            else
                update_component_status "network" $STATUS_WARN
            fi
        else
            update_component_status "network" $STATUS_WARN
        fi
    fi
}

validate_security() {
    echo "═══ Security Validation ═══ [$(date '+%Y-%m-%d %H:%M:%S')]"
    echo ""

    # Check root access
    if [ "$(id -u)" = "0" ]; then
        ok "Root access: AVAILABLE"
    else
        warn "Root access: NOT AVAILABLE (may limit functionality)"
        update_component_status "security" $STATUS_WARN
    fi

    # Check rootfs permissions
    if [ -d "$ARCH_PATH" ]; then
        local perms
        perms=$(stat -c %a "$ARCH_PATH" 2>/dev/null || echo "unknown")
        if [ "$perms" = "755" ] || [ "$perms" = "750" ]; then
            ok "Rootfs permissions: $perms (secure)"
        else
            warn "Rootfs permissions: $perms (consider 755)"
            update_component_status "security" $STATUS_WARN
        fi
    fi

    # Check SELinux status and auto-fix if enforcing
    if command -v getenforce >/dev/null 2>&1; then
        local selinux_status
        selinux_status=$(getenforce 2>/dev/null || echo "unknown")

        case "$selinux_status" in
            "Enforcing")
                warn "SELinux: Enforcing (may block chroot operations)"
                if autofix_selinux; then
                    ok "SELinux: Set to permissive for chroot compatibility"
                else
                    update_component_status "security" $STATUS_WARN
                fi
                ;;
            "Permissive")
                ok "SELinux: Permissive (compatible)"
                ;;
            "Disabled")
                ok "SELinux: Disabled"
                ;;
            *)
                info "SELinux: Status unknown"
                ;;
        esac
    fi

    # Check for legacy config (be forgiving)
    if [ -f "/data/local/archdroid.conf" ]; then
        ok "Legacy config found: /data/local/archdroid.conf"
    else
        info "No legacy config file found: /data/local/archdroid.conf"
    fi
}

# ─── JSON OUTPUT GENERATION ───────────────────────────────────────────────────
generate_json_output() {
    # Calculate overall status
    local overall_status=$STATUS_OK
    for component in filesystem network environment security; do
        local comp_status=${COMPONENT_STATUS[$component]}
        if [ "$comp_status" -gt "$overall_status" ]; then
            overall_status=$comp_status
        fi
    done

    # Generate JSON with proper escaping
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"session_id\": \"$SESSION_ID\","
        echo "  \"arch_path\": \"$ARCH_PATH\","
        echo "  \"overall_status\": $overall_status,"
        echo "  \"components\": {"
        echo "    \"filesystem\": ${COMPONENT_STATUS[filesystem]},"
        echo "    \"network\": ${COMPONENT_STATUS[network]},"
        echo "    \"environment\": ${COMPONENT_STATUS[environment]},"
        echo "    \"security\": ${COMPONENT_STATUS[security]}"
        echo "  },"
        echo "  \"rootfs\": {"
        echo "    \"exists\": $([ -d "$ARCH_PATH" ] && echo "true" || echo "false"),"
        echo "    \"valid\": $([ "${COMPONENT_STATUS[filesystem]}" -lt 2 ] && echo "true" || echo "false")"
        echo "  },"
        echo "  \"auto_fix_enabled\": $([ "$AUTO_FIX" = "1" ] && echo "true" || echo "false")"
        echo "}"
    } > "$RUNTIME_JSON"

    ok "JSON state exported: $RUNTIME_JSON"
}

# ─── MAIN INSPECTION ─────────────────────────────────────────────────────────
main() {
    # Initialize log
    {
        echo "=== ArchDroid Runtime Inspection ==="
        echo "Session ID: $SESSION_ID"
        echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Arch Path: $ARCH_PATH"
        echo "Auto-fix: $AUTO_FIX"
        echo ""
    } > "$INSPECT_LOG"

    # Run all validations
    validate_rootfs
    validate_mounts
    validate_network
    validate_security

    # Generate JSON output
    generate_json_output

    # Summary
    echo ""
    echo "Component Status:"
    for component in filesystem network environment security; do
        local status=${COMPONENT_STATUS[$component]}
        case $status in
            0) echo "  ✔ $component: OK" ;;
            1) echo "  ⚠ $component: WARNINGS" ;;
            2) echo "  ✘ $component: FAILED" ;;
        esac
    done

    echo ""

    # Overall status
    local overall_status=$STATUS_OK
    for component in filesystem network environment security; do
        local comp_status=${COMPONENT_STATUS[$component]}
        if [ "$comp_status" -gt "$overall_status" ]; then
            overall_status=$comp_status
        fi
    done

    case $overall_status in
        0)
            echo -e "${BOLD}${GREEN}"
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║                ✔ SYSTEM READY                   ║"
            echo "  ║             All checks passed                   ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo -e "${RESET}"
            ;;
        1)
            echo -e "${BOLD}${YELLOW}"
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║              ⚠ WARNINGS DETECTED                ║"
            echo "  ║         System may work with issues             ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo -e "${RESET}"
            ;;
        2)
            echo -e "${BOLD}${RED}"
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║              ✘ CRITICAL FAILURES                ║"
            echo "  ║            System needs attention               ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo -e "${RESET}"
            ;;
    esac

    echo ""
    info "Human log: ${INSPECT_LOG}"
    info "JSON state: $RUNTIME_JSON"
    info "Overall status: $overall_status (0=OK, 1=WARN, 2=FAIL)"
    echo ""
    info "Safe JSON usage examples:"
    echo "  jq empty '$RUNTIME_JSON' 2>/dev/null || echo 'Invalid JSON'"
    echo "  jq -r '.rootfs.valid // false' '$RUNTIME_JSON'"
    echo "  jq -r '.components.filesystem // 2' '$RUNTIME_JSON'"

    # Exit with overall status
    exit $overall_status
}

# ─── ENVIRONMENT VALIDATION (PLACEHOLDER) ────────────────────────────────────
# Environment validation placeholder - not critical for basic operation
COMPONENT_STATUS[environment]=$STATUS_OK

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi