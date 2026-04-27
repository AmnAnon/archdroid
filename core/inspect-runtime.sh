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

# ─── CHROOT FAILURE DIAGNOSIS ────────────────────────────────────────────────
diagnose_chroot_failure() {
    echo ""
    echo "  ═══ Chroot Failure Analysis ═══"
    echo ""

    # 1. SELinux detection — offer to fix with user approval
    if command -v getenforce >/dev/null 2>&1; then
        local selinux_mode
        selinux_mode=$(getenforce 2>/dev/null || echo "unknown")
        info "SELinux mode: $selinux_mode"

        if [ "$selinux_mode" = "Enforcing" ]; then
            warn "SELinux is Enforcing — this is the most likely cause"
            echo ""
            echo "  SELinux prevents chroot execution in Enforcing mode."
            echo "  Setting it to Permissive is safe and temporary (resets on reboot)."
            echo ""

            if [ "${ARCHDROID_AUTO_SELINUX:-0}" = "1" ]; then
                # Non-interactive: auto-apply (user opted in via 'archdroid up' or env flag)
                if setenforce 0 2>/dev/null; then
                    ok "SELinux set to Permissive (auto)"
                else
                    warn "setenforce 0 failed — are you root?"
                fi
            elif [ -t 0 ]; then
                # Interactive: ask for approval
                printf "  Apply fix now? (setenforce 0) [y/N]: "
                read -r selinux_answer </dev/tty
                if [ "$selinux_answer" = "y" ] || [ "$selinux_answer" = "Y" ]; then
                    if setenforce 0 2>/dev/null; then
                        ok "SELinux set to Permissive — re-run archdroid start"
                    else
                        warn "setenforce 0 failed — are you root?"
                    fi
                else
                    info "Skipped. To apply manually:"
                    echo "     setenforce 0"
                fi
            else
                # Non-interactive, no flag: just print the fix
                warn "Run manually to fix:"
                echo "     setenforce 0"
            fi
        elif [ "$selinux_mode" = "Permissive" ] || [ "$selinux_mode" = "Disabled" ]; then
            ok "SELinux: $selinux_mode — not the cause"
        fi
    fi

    echo ""

    # 2. Library check — try to identify missing ELF deps
    local bash_bin="$ARCH_PATH/bin/bash"
    if [ -f "$bash_bin" ]; then
        info "Checking /bin/bash binary..."
        local interp
        interp=$(readelf -l "$bash_bin" 2>/dev/null | awk '/interpreter/ {gsub(/[\[\]]/,""); print $NF}')
        if [ -n "$interp" ]; then
            local interp_in_rootfs="$ARCH_PATH$interp"
            if [ ! -f "$interp_in_rootfs" ]; then
                fail "ELF interpreter missing inside rootfs: $interp"
                echo "     This means /bin/bash cannot execute — rootfs may be incomplete"

                # Fix 1: Check if this is just a broken symlink that we can warn about
                if [ -L "$ARCH_PATH/lib" ] && [ ! -e "$ARCH_PATH/lib" ]; then
                    warn "The /lib symlink points to a missing target."
                    warn "This is common on Android extractions. Run 'archdroid start' to auto-fix."
                fi
            else
                ok "ELF interpreter present: $interp"
            fi
        fi
    fi

    echo ""

    # 3. Actionable next steps
    info "Suggested fixes (in order):"
    echo ""
    echo "    1. Fix SELinux (temporary, resets on reboot):"
    echo "       setenforce 0 && archdroid start"
    echo ""
    echo "    2. Bypass validation and enter anyway:"
    echo "       ARCHDROID_SAFE_MODE=1 archdroid start"
    echo ""
    echo "    3. Manual chroot test to see the real error:"
    echo "       chroot $ARCH_PATH /bin/bash -c 'echo ok'"
    echo ""
    echo "    4. If rootfs is genuinely broken:"
    echo "       export ARCH_PATH=/data/local/arch-test"
    echo "       archdroid bootstrap"
}

# ─── SELINUX WITH APPROVAL ───────────────────────────────────────────────────
autofix_selinux() {
    if [ "$AUTO_FIX" != "1" ]; then
        return 1
    fi

    local selinux_mode
    selinux_mode=$(getenforce 2>/dev/null || echo "unknown")

    if [ "$selinux_mode" != "Enforcing" ]; then
        return 0  # Nothing to do
    fi

    warn "SELinux is Enforcing — chroot operations may be blocked"
    echo ""

    if [ "${ARCHDROID_AUTO_SELINUX:-0}" = "1" ]; then
        if setenforce 0 2>/dev/null; then
            ok "SELinux set to Permissive (auto)"
            return 0
        else
            warn "setenforce 0 failed (need root)"
            return 1
        fi
    elif [ -t 0 ]; then
        printf "  Set SELinux to Permissive temporarily? (resets on reboot) [y/N]: "
        read -r answer </dev/tty
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            if setenforce 0 2>/dev/null; then
                ok "SELinux set to Permissive"
                return 0
            else
                warn "setenforce 0 failed (need root)"
                return 1
            fi
        else
            info "SELinux left as-is — some operations may fail"
            return 1
        fi
    else
        warn "Non-interactive mode — skipping SELinux change"
        warn "Run manually: setenforce 0"
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

    local resolv_conf="$ARCH_PATH/etc/resolv.conf"
    mkdir -p "$ARCH_PATH/etc"

    # Remove broken symlink (resolv.conf → /run/systemd/... in Android
    # context where /run doesn't exist inside the rootfs)
    if [ -L "$resolv_conf" ] && [ ! -e "$resolv_conf" ]; then
        rm -f "$resolv_conf"
    fi

    # Deterministic overwrite: > not >>
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$resolv_conf"
    return 0
}

# ─── VALIDATION FUNCTIONS ────────────────────────────────────────────────────
validate_rootfs() {
    if [ ! -d "$ARCH_PATH" ]; then
        fail "Rootfs not found: $ARCH_PATH"
        update_component_status "filesystem" $STATUS_FAIL
        return 1
    fi

    # Check essential directories
    for dir in "usr" "etc" "bin"; do
        if [ ! -d "$ARCH_PATH/$dir" ]; then
            fail "Missing directory: $dir"
            update_component_status "filesystem" $STATUS_FAIL
            return 1
        fi
    done

    # Check essential files
    check_essential_file "bin/bash" "bash" 1 || \
    check_essential_file "bin/sh" "sh" 1 || {
        fail "No shell found"
        update_component_status "filesystem" $STATUS_FAIL
        return 1
    }

    check_essential_file "etc/passwd" "passwd" 0 || true
    check_essential_file "usr/bin/pacman" "pacman" 1 || true

    # Chroot execution test — mount essentials first so bash can actually run,
    # then clean up regardless of outcome.
    info "Testing chroot execution..."
    local chroot_working=false

    # Fix 4: F2FS Remount Propagation — remount exec BEFORE any bind-mounts.
    # On F2FS, if bind-mounts are set up first and /data is still noexec,
    # the noexec flag propagates into the bind-mount namespace and a later
    # remount won't fix it.
    local data_mount
    data_mount=$(mount 2>/dev/null | awk '$3 == "/data" {print}' | head -1)
    if echo "$data_mount" | grep -q "noexec"; then
        mount -o remount,exec /data 2>/dev/null || true
    fi

    # Fix 1: Symlink convergence — ensure /lib and /bin point to /usr counterparts
    # Android tar extractions often break these relative links into dangling paths.
    for _link in lib lib64 bin sbin; do
        local _target="usr/$_link"
        local _lpath="$ARCH_PATH/$_link"
        if [ -d "$ARCH_PATH/$_target" ]; then
            if [ -L "$_lpath" ]; then
                local _current
                _current=$(readlink "$_lpath")
                if [ "$_current" != "$_target" ] && [ "$_current" != "/usr/$_link" ]; then
                    ln -sf "$_target" "$_lpath" 2>/dev/null || true
                    autofix "Relinked $_link → $_target"
                fi
            elif [ ! -e "$_lpath" ]; then
                ln -sf "$_target" "$_lpath" 2>/dev/null || true
                autofix "Created symlink $_link → $_target"
            fi
        fi
    done

    # Fix 2: ELF interpreter validation — fail early with a clear message
    # instead of a cryptic "No such file or directory" from chroot.
    local _bash_bin="$ARCH_PATH/bin/bash"
    if [ -f "$_bash_bin" ]; then
        local _interp
        _interp=$(readelf -l "$_bash_bin" 2>/dev/null \
            | awk '/interpreter/ {gsub(/[\[\]]/,""); print $NF}')
        if [ -n "$_interp" ] && [ ! -f "$ARCH_PATH$_interp" ]; then
            fail "ELF interpreter not found inside rootfs: $_interp"
            fail "This is why chroot says 'No such file or directory'"
            fail "Re-run: archdroid bootstrap"
            update_component_status "filesystem" $STATUS_FAIL
            return 1
        fi
    fi

    # Fix 3: Ensure /etc exists before anything tries to write resolv.conf
    mkdir -p "$ARCH_PATH/etc"

    # Ensure required mount dirs exist
    mkdir -p "$ARCH_PATH/proc" "$ARCH_PATH/sys" "$ARCH_PATH/dev"

    # Fix 6: TTY — create /dev/tty if missing (cosmetic: prevents
    # "ttyname error: Inappropriate ioctl for device" in chroot)
    if [ ! -c "$ARCH_PATH/dev/tty" ]; then
        mknod -m 666 "$ARCH_PATH/dev/tty" c 5 0 2>/dev/null || true
    fi

    # Mount — ignore failures (they may already be mounted)
    mount -t proc  proc  "$ARCH_PATH/proc" 2>/dev/null || true
    mount -t sysfs sysfs "$ARCH_PATH/sys"  2>/dev/null || true
    mount --rbind  /dev  "$ARCH_PATH/dev"  2>/dev/null || true
    mount --make-rslave  "$ARCH_PATH/dev"  2>/dev/null || true

    # Canonical execution test — same across staging, final, and runtime
    if timeout 10 chroot "$ARCH_PATH" /bin/bash -c 'exit 0' >/dev/null 2>&1; then
        chroot_working=true
    elif timeout 10 chroot "$ARCH_PATH" /bin/sh -c 'exit 0' >/dev/null 2>&1; then
        chroot_working=true
    fi

    if [ "$chroot_working" = true ]; then
        ok "Chroot execution test: PASSED"
    else
        fail "Chroot execution test: FAILED"
        diagnose_chroot_failure
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
    for mp in proc sys dev dev/pts tmp; do
        if ! mountpoint -q "$ARCH_PATH/$mp" 2>/dev/null; then
            update_component_status "filesystem" $STATUS_WARN
        fi
    done
}

validate_network() {
    local dns_working=false
    for method in "getent hosts google.com" "nslookup google.com" "dig google.com +short"; do
        if timeout 3 $method >/dev/null 2>&1; then
            dns_working=true
            break
        fi
    done

    if [ "$dns_working" = false ]; then
        autofix_dns
        # Re-test after fix
        for method in "getent hosts google.com" "nslookup google.com" "dig google.com +short"; do
            if timeout 3 $method >/dev/null 2>&1; then
                dns_working=true
                break
            fi
        done
    fi

    if [ "$dns_working" = false ]; then
        update_component_status "network" $STATUS_WARN
    fi
}

validate_security() {
    if [ "$(id -u)" != "0" ]; then
        update_component_status "security" $STATUS_WARN
    fi

    if command -v getenforce >/dev/null 2>&1; then
        local selinux_status
        selinux_status=$(getenforce 2>/dev/null || echo "unknown")

        case "$selinux_status" in
            "Enforcing")
                autofix_selinux || update_component_status "security" $STATUS_WARN
                ;;
        esac
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

    # Run all validations — use || true so set -e doesn't abort on a failed
    # check; each validator updates COMPONENT_STATUS independently.
    validate_rootfs   || true
    validate_mounts   || true
    validate_network  || true
    validate_security || true

    # Generate JSON output
    generate_json_output

    # Overall status computation
    local overall_status=$STATUS_OK
    for component in filesystem network environment security; do
        local comp_status=${COMPONENT_STATUS[$component]}
        if [ "$comp_status" -gt "$overall_status" ]; then
            overall_status=$comp_status
        fi
    done

    echo ""
    case $overall_status in
        0)  ok "SYSTEM READY" ;;
        1)  ok "SYSTEM READY" ;;
        2)  fail "CHROOT EXECUTION FAILED"
            echo ""
            diagnose_chroot_failure
            ;;
    esac

    echo ""
    info "Log: ${INSPECT_LOG}"

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