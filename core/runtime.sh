#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/runtime.sh                                    ║
# ║  Deterministic Runtime System - Forces Reality to Match State   ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
ARCH_PATH="${ARCH_PATH:-/data/local/arch}"
STATE_DIR="${STATE_DIR:-/data/local/archdroid-state}"
RUNTIME_JSON="${STATE_DIR}/runtime-snapshot.json"
LAST_GOOD_JSON="${STATE_DIR}/runtime-last-good.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Session tracking
SESSION_ID=$(date +%s)
mkdir -p "${STATE_DIR}/logs"
LOG_FILE="${STATE_DIR}/logs/runtime-${SESSION_ID}.log"

# Load utilities
source "${SCRIPT_DIR}/json-utils.sh"

# ─── CHROOT FAILURE DIAGNOSIS ────────────────────────────────────────────────
diagnose_chroot_failure() {
    echo ""
    echo "  ═══ Chroot Failure Analysis ═══"
    echo ""

    # SELinux detection with user-approval fix
    if command -v getenforce >/dev/null 2>&1; then
        local selinux_mode
        selinux_mode=$(getenforce 2>/dev/null || echo "unknown")
        info "SELinux mode: $selinux_mode"

        if [ "$selinux_mode" = "Enforcing" ]; then
            warn "SELinux is Enforcing — most likely cause of chroot failure"
            echo ""
            echo "  Setting to Permissive is safe and temporary (resets on reboot)."
            echo ""
            if [ -t 0 ]; then
                printf "  Apply fix now? (setenforce 0) [y/N]: "
                read -r selinux_answer </dev/tty
                if [ "$selinux_answer" = "y" ] || [ "$selinux_answer" = "Y" ]; then
                    if setenforce 0 2>/dev/null; then
                        ok "SELinux set to Permissive — re-run: archdroid start"
                    else
                        warn "setenforce 0 failed — are you root?"
                    fi
                else
                    info "Skipped. To apply manually:  setenforce 0"
                fi
            else
                warn "Run manually to fix:  setenforce 0"
            fi
        else
            ok "SELinux: $selinux_mode — not the cause"
        fi
    fi

    echo ""

    # ELF interpreter check
    local bash_bin="$ARCH_PATH/bin/bash"
    if [ -f "$bash_bin" ]; then
        local interp
        interp=$(readelf -l "$bash_bin" 2>/dev/null | awk '/interpreter/ {gsub(/[\[\]]/,""); print $NF}')
        if [ -n "$interp" ] && [ ! -f "$ARCH_PATH$interp" ]; then
            fail "ELF interpreter missing inside rootfs: $interp"
            echo "     Rootfs may be incomplete — re-run: archdroid bootstrap"
        fi
    fi

    echo ""
    info "Next steps (in order):"
    echo ""
    echo "    1. Fix SELinux (temporary, resets on reboot):"
    echo "       setenforce 0 && archdroid start"
    echo ""
    echo "    2. Bypass validation (for debugging only):"
    echo "       ARCHDROID_SAFE_MODE=1 archdroid start"
    echo ""
    echo "    3. Test manually to see the real error message:"
    echo "       chroot $ARCH_PATH /bin/bash -c 'echo ok'"
    echo ""
    echo "    4. If rootfs is broken — fresh install to a test path:"
    echo "       export ARCH_PATH=/data/local/arch-test"
    echo "       archdroid bootstrap"
    echo ""
}

# ─── TAMPER-AWARE LOGGING ────────────────────────────────────────────────────
add_log_integrity() {
    local log_file="$1"
    local message="${2:-LOG_ENTRY}"

    # Create tamper-evident chain, not just snapshot
    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        # Get previous hash from chain (if exists)
        local prev_hash
        prev_hash=$(tail -n 1 "$log_file" 2>/dev/null | grep "LOG_CHAIN=" | cut -d= -f2 | cut -d: -f2)

        # If no previous hash, this is first entry
        if [ -z "$prev_hash" ]; then
            prev_hash="GENESIS"
        fi

        # Compute current log state hash
        local current_hash
        current_hash=$(sha256sum "$log_file" | awk '{print $1}')

        # Create tamper-evident chain link
        echo "${message}_LOG_CHAIN=${prev_hash}:${current_hash}" >> "$log_file"
    else
        # Initialize chain for new log
        echo "${message}_LOG_CHAIN=GENESIS:INIT" >> "$log_file"
    fi
}

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }

banner() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    printf "  ║  %-48s║\n" "$*"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ─── PREPARE EXEC ENVIRONMENT ───────────────────────────────────────────────
# Must run BEFORE any chroot attempt or bind-mount setup.
# Order matters: noexec remount → symlink fix → then bind mounts.
prepare_exec_environment() {
    echo "=== exec environment preparation ===" >> "$LOG_FILE"

    # Remount /data exec — do this first, before any bind-mounts, so noexec
    # doesn't propagate into the mount namespace.
    local data_mount
    data_mount=$(mount 2>/dev/null | awk '$3 == "/data" {print}' | head -1)
    if echo "$data_mount" | grep -q "noexec"; then
        mount -o remount,exec /data 2>/dev/null || {
            echo "WARN: /data remount exec failed" >> "$LOG_FILE"
        }
    fi

    # Symlink convergence: bin→usr/bin, lib→usr/lib, sbin→usr/bin
    for link in lib lib64 bin sbin; do
        local target="usr/$link"
        local lpath="$ARCH_PATH/$link"
        if [ -d "$ARCH_PATH/$target" ]; then
            if [ -L "$lpath" ] && [ "$(readlink "$lpath" 2>/dev/null)" != "$target" ]; then
                ln -sf "$target" "$lpath" 2>/dev/null || true
            elif [ ! -e "$lpath" ]; then
                ln -sf "$target" "$lpath" 2>/dev/null || true
            fi
        fi
    done

    # Validate ELF interpreter — fail immediately with a clear message
    # instead of a cryptic "No such file or directory" from chroot.
    local bash_bin="$ARCH_PATH/bin/bash"
    if [ -f "$bash_bin" ]; then
        local interp
        interp=$(readelf -l "$bash_bin" 2>/dev/null \
            | awk '/interpreter/ {gsub(/[\[\]]/,""); print $NF}')
        if [ -n "$interp" ] && [ ! -f "$ARCH_PATH$interp" ]; then
            fail "ELF interpreter missing inside rootfs: $interp"
            fail "Re-run: archdroid bootstrap"
            exit 1
        fi
    fi

    mkdir -p "$ARCH_PATH/etc"
    echo "SUCCESS: exec environment prepared" >> "$LOG_FILE"
}


adaptive_gate_startup() {
    banner "ArchDroid Runtime with Auto-Fix"

    # Enable auto-fix by default for better compatibility
    export ARCHDROID_AUTO_FIX="${ARCHDROID_AUTO_FIX:-1}"

    # Log session start
    {
        echo "=== Runtime Session Started ==="
        echo "Session ID: $SESSION_ID"
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Arch Path: $ARCH_PATH"
        echo "Auto-fix: $ARCHDROID_AUTO_FIX"
        echo "Safe Mode: ${ARCHDROID_SAFE_MODE:-disabled}"
        echo ""
    } > "$LOG_FILE"

    info "Session ID: $SESSION_ID"
    info "Validating and auto-fixing system issues..."

    # Run inspection with auto-fix enabled
    local inspection_exit_code=0
    "${SCRIPT_DIR}/inspect-runtime.sh" || inspection_exit_code=$?

    # Get overall status after auto-fixes.
    # When jq is not available, fall back to inspect-runtime.sh's exit code.
    local status
    if command -v jq >/dev/null 2>&1; then
        status=$(safe_json_int "$RUNTIME_JSON" ".overall_status" "2")
    else
        # inspect-runtime.sh exits with its computed overall_status
        status="$inspection_exit_code"
    fi

    case "$status" in
        0|1)
            ok "System validation: PASSED"
            cp "$RUNTIME_JSON" "$LAST_GOOD_JSON" 2>/dev/null || true
            return 0
            ;;
        2)
            # Critical — only filesystem failure is fatal
            local fs_status
            if command -v jq >/dev/null 2>&1; then
                fs_status=$(safe_json_int "$RUNTIME_JSON" ".components.filesystem" "2")
            else
                fs_status="$inspection_exit_code"
            fi

            if [ "$fs_status" -gt 1 ]; then
                fail "Chroot execution failed — rootfs cannot execute"
                echo ""
                diagnose_chroot_failure
                echo "FATAL: Filesystem validation failed" >> "$LOG_FILE"
                exit 2
            fi

            ok "System validation: PASSED"
            return 0
            ;;
        *)
            if [ "${ARCHDROID_SAFE_MODE:-}" = "1" ]; then
                warn "SAFE MODE — bypassing validation"
                return 0
            fi
            fail "System in unknown state"
            fail "Run 'archdroid doctor' to diagnose"
            echo "FATAL: Unknown system status: $status" >> "$LOG_FILE"
            exit 2
            ;;
    esac
}

# ─── ENFORCE ENVIRONMENT: Clean State ───────────────────────────────────────
enforce_environment() {
    echo "=== Environment Enforcement ===" >> "$LOG_FILE"

    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export HOME="/root"

    # Clear dangerous Android variables — silently, to log only
    for var in ANDROID_DATA ANDROID_ROOT BOOTCLASSPATH TERMUX PREFIX; do
        if [ -n "${!var:-}" ]; then
            echo "Cleared: $var=${!var}" >> "$LOG_FILE"
            unset "$var"
        fi
    done

    export LANG="${LANG:-C.UTF-8}"
    export LC_ALL="${LC_ALL:-C.UTF-8}"
    echo "Locale: LANG=$LANG LC_ALL=$LC_ALL" >> "$LOG_FILE"
}

# ─── SMART MOUNT ENFORCEMENT: Auto-fix Common Issues ────────────────────────
smart_enforce_mounts() {
    echo "=== Smart Mount Enforcement ===" >> "$LOG_FILE"

    local mount_dirs=("proc" "sys" "dev" "dev/pts" "tmp" "media/sdcard")
    for dir in "${mount_dirs[@]}"; do
        mkdir -p "$ARCH_PATH/$dir" 2>/dev/null || true
    done

    # Mount only if not already mounted. No verbose output — mounts were
    # already validated by inspect-runtime.sh. This is enforcement only.
    mountpoint -q "$ARCH_PATH/proc"    || mount -t proc  proc     "$ARCH_PATH/proc"    2>/dev/null || true
    mountpoint -q "$ARCH_PATH/sys"     || mount -t sysfs sysfs    "$ARCH_PATH/sys"     2>/dev/null || true
    mountpoint -q "$ARCH_PATH/dev"     || {
        mount --rbind /dev "$ARCH_PATH/dev" 2>/dev/null
        mount --make-rslave "$ARCH_PATH/dev" 2>/dev/null
    } || true
    mountpoint -q "$ARCH_PATH/dev/pts" || mount --rbind /dev/pts "$ARCH_PATH/dev/pts" 2>/dev/null || true
    mountpoint -q "$ARCH_PATH/tmp"     || mount -t tmpfs -o size=512m,mode=1777 tmpfs "$ARCH_PATH/tmp" 2>/dev/null || true

    # sdcard: best-effort, try common paths
    for sdcard_candidate in "/sdcard" "/storage/emulated/0"; do
        if [ -d "$sdcard_candidate" ] && [ -r "$sdcard_candidate" ]; then
            mountpoint -q "$ARCH_PATH/media/sdcard" || mount --bind "$sdcard_candidate" "$ARCH_PATH/media/sdcard" 2>/dev/null || true
            break
        fi
    done

    echo "Mount enforcement complete" >> "$LOG_FILE"
}

# ─── SMART DNS ENFORCEMENT: Fix Common Android DNS Issues ──────────────────
smart_enforce_dns() {
    echo "=== Smart DNS Enforcement ===" >> "$LOG_FILE"

    local resolv_conf="$ARCH_PATH/etc/resolv.conf"
    mkdir -p "$ARCH_PATH/etc"

    # If DNS is already working, skip entirely — no output, no noise.
    local dns_working=false
    for test_host in "google.com" "1.1.1.1"; do
        if timeout 3 getent hosts "$test_host" >/dev/null 2>&1; then
            dns_working=true
            break
        fi
    done

    if [ "$dns_working" = true ]; then
        echo "SUCCESS: DNS already working" >> "$LOG_FILE"
        return 0
    fi

    # Remove broken symlink (resolv.conf → /run/systemd/... which doesn't
    # exist in Android context), then write a deterministic file.
    if [ -L "$resolv_conf" ] && [ ! -e "$resolv_conf" ]; then
        rm -f "$resolv_conf"
    fi

    {
        echo "# ArchDroid DNS"
        echo "nameserver 1.1.1.1"
        echo "nameserver 8.8.8.8"
        echo "options timeout:2 attempts:3 rotate"
    } > "$resolv_conf"

    echo "DNS configured: $resolv_conf" >> "$LOG_FILE"
}

# ─── RESILIENT ENTRY: Robust Chroot with Fallbacks ─────────────────────────
resilient_entry() {
    # Single deterministic chroot entry. No fallbacks, no env -i wrapper.
    # --login provides clean environment; the outer script already cleared
    # Android env vars before calling this.
    echo ""
    echo "  Root Path: $ARCH_PATH"
    echo "  Shell: /bin/bash"
    echo ""

    export HOME="/root"
    export TERM="${TERM:-xterm-256color}"
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export LANG="C.UTF-8"
    export LC_ALL="C.UTF-8"

    add_log_integrity "$LOG_FILE" "RUNTIME_COMPLETE"
    exec chroot "$ARCH_PATH" /bin/bash --login
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
main() {
    prepare_exec_environment
    adaptive_gate_startup
    enforce_environment
    smart_enforce_mounts
    smart_enforce_dns
    resilient_entry
}

# Execute if called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi