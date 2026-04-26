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

# ─── ADAPTIVE GATE: VALIDATE AND AUTO-FIX SYSTEM READINESS ──────────────────
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

    # Get overall status after auto-fixes
    local status
    status=$(safe_json_int "$RUNTIME_JSON" ".overall_status" "2")

    case "$status" in
        0)
            ok "System validation: PASSED (all checks OK)"
            # Save as last known good state
            cp "$RUNTIME_JSON" "$LAST_GOOD_JSON" 2>/dev/null || true
            echo "SUCCESS: System validation passed" >> "$LOG_FILE"
            return 0
            ;;
        1)
            ok "System validation: MINOR WARNINGS (system usable)"
            info "Auto-fixes applied where possible"
            # Save as acceptable state (warnings are fine for runtime)
            cp "$RUNTIME_JSON" "$LAST_GOOD_JSON" 2>/dev/null || true
            echo "SUCCESS: System has minor warnings but usable" >> "$LOG_FILE"
            return 0
            ;;
        2)
            # Critical failures - check what failed and try to continue gracefully
            local fs_status network_status env_status sec_status
            fs_status=$(safe_json_int "$RUNTIME_JSON" ".components.filesystem" "2")
            network_status=$(safe_json_int "$RUNTIME_JSON" ".components.network" "2")
            env_status=$(safe_json_int "$RUNTIME_JSON" ".components.environment" "2")
            sec_status=$(safe_json_int "$RUNTIME_JSON" ".components.security" "2")

            # Filesystem is critical — can't proceed without it
            if [ "$fs_status" -gt 1 ]; then
                fail "Chroot execution failed — rootfs cannot execute"
                echo ""
                # Source the diagnose function from inspect-runtime if available
                if declare -f diagnose_chroot_failure >/dev/null 2>&1; then
                    diagnose_chroot_failure
                else
                    fail "Run 'archdroid doctor' for a full diagnosis"
                    echo ""
                    echo "  Quick fixes:"
                    echo "    setenforce 0 && archdroid start"
                    echo "    ARCHDROID_SAFE_MODE=1 archdroid start"
                fi
                echo "FATAL: Filesystem validation failed - chroot not working" >> "$LOG_FILE"
                exit 2
            fi

            # Other components can be worked around
            warn "Some components have issues but proceeding with caution"
            [ "$network_status" -gt 1 ] && warn "  - Network issues detected (may affect package management)"
            [ "$env_status" -gt 1 ] && warn "  - Environment issues detected (auto-fixing during startup)"
            [ "$sec_status" -gt 1 ] && warn "  - Security issues detected (applying auto-fixes)"

            info "Runtime enforcement will attempt to fix remaining issues"
            echo "WARN: Some components failed but proceeding with enforcement" >> "$LOG_FILE"
            return 0
            ;;
        *)
            # Unknown status - safe mode check
            if [ "${ARCHDROID_SAFE_MODE:-}" = "1" ]; then
                warn "SAFE MODE ENABLED - bypassing all validation"
                warn "Proceeding despite unknown system state"
                echo "SAFE_MODE: Bypassing validation with unknown status: $status" >> "$LOG_FILE"
                return 0
            fi

            fail "System in unknown state (status: $status)"
            fail "Run 'archdroid doctor' to diagnose issues"
            fail "Or use: ARCHDROID_SAFE_MODE=1 archdroid start (to force entry)"
            echo "FATAL: Unknown system status: $status" >> "$LOG_FILE"
            exit 2
            ;;
    esac
}

# ─── ENFORCE ENVIRONMENT: Clean State ───────────────────────────────────────
enforce_environment() {
    info "Enforcing clean runtime environment..."
    echo "=== Environment Enforcement ===" >> "$LOG_FILE"

    # Force clean PATH - ignore whatever Android/Termux gives us
    local old_path="$PATH"
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ok "PATH enforced: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "PATH: $old_path → $PATH" >> "$LOG_FILE"

    # Force clean HOME
    local old_home="${HOME:-unset}"
    export HOME="/root"
    ok "HOME enforced: /root"
    echo "HOME: $old_home → $HOME" >> "$LOG_FILE"

    # Force clean USER
    local old_user="${USER:-unset}"
    export USER="root"
    ok "USER enforced: root"
    echo "USER: $old_user → $USER" >> "$LOG_FILE"

    # Clear dangerous Android variables
    local android_vars=("ANDROID_DATA" "ANDROID_ROOT" "BOOTCLASSPATH" "TERMUX" "PREFIX")
    for var in "${android_vars[@]}"; do
        if [ -n "${!var:-}" ]; then
            echo "Cleared: $var=${!var}" >> "$LOG_FILE"
            unset "$var"
            ok "Cleared Android variable: $var"
        fi
    done

    # Set essential variables
    export LANG="${LANG:-C.UTF-8}"
    export LC_ALL="${LC_ALL:-C.UTF-8}"
    ok "Locale enforced: C.UTF-8"
    echo "Locale: LANG=$LANG LC_ALL=$LC_ALL" >> "$LOG_FILE"

    echo "" >> "$LOG_FILE"
}

# ─── SMART MOUNT ENFORCEMENT: Auto-fix Common Issues ────────────────────────
smart_enforce_mounts() {
    info "Smart mount enforcement with auto-fix capabilities..."
    echo "=== Smart Mount Enforcement ===" >> "$LOG_FILE"

    # Ensure mount point directories exist
    local mount_dirs=("proc" "sys" "dev" "dev/pts" "tmp" "media/sdcard")
    for dir in "${mount_dirs[@]}"; do
        mkdir -p "$ARCH_PATH/$dir" 2>/dev/null || true
    done

    # Helper function to attempt mount with fallback
    attempt_mount() {
        local mount_point="$1"
        local mount_type="$2"
        local mount_source="$3"
        local mount_options="$4"

        # Check if already mounted correctly
        if mountpoint -q "$ARCH_PATH/$mount_point" 2>/dev/null; then
            if [ -n "$mount_type" ] && mount | grep -q "$ARCH_PATH/$mount_point.*$mount_type"; then
                ok "Already mounted: $mount_point ($mount_type)"
                return 0
            elif [ -z "$mount_type" ]; then
                ok "Already mounted: $mount_point"
                return 0
            else
                warn "Mount type mismatch on $mount_point - remounting"
                umount -lf "$ARCH_PATH/$mount_point" 2>/dev/null || true
            fi
        fi

        # Attempt mount
        local mount_cmd="mount"
        [ -n "$mount_type" ] && mount_cmd="$mount_cmd -t $mount_type"
        [ -n "$mount_options" ] && mount_cmd="$mount_cmd -o $mount_options"
        mount_cmd="$mount_cmd $mount_source $ARCH_PATH/$mount_point"

        if eval "$mount_cmd" 2>/dev/null; then
            ok "Mounted: $mount_point ($mount_type)"
            echo "SUCCESS: $mount_cmd" >> "$LOG_FILE"
            return 0
        else
            warn "Failed to mount: $mount_point"
            echo "FAILED: $mount_cmd" >> "$LOG_FILE"
            return 1
        fi
    }

    # Essential mounts with smart fallbacks
    attempt_mount "proc" "proc" "proc" "" || warn "Proceeding without proc (may affect some tools)"
    attempt_mount "sys" "sysfs" "sysfs" "" || warn "Proceeding without sys (may affect some tools)"

    # dev mounts with rbind + rslave for proper propagation
    if attempt_mount "dev" "" "/dev" "rbind"; then
        mount --make-rslave "$ARCH_PATH/dev" 2>/dev/null || warn "Failed to set rslave on dev"
    else
        warn "Proceeding without dev bind (may affect device access)"
    fi

    if attempt_mount "dev/pts" "" "/dev/pts" "rbind"; then
        mount --make-rslave "$ARCH_PATH/dev/pts" 2>/dev/null || warn "Failed to set rslave on dev/pts"
    else
        warn "Proceeding without dev/pts bind (may affect terminal handling)"
    fi

    # tmpfs for /tmp - critical for many operations
    if ! attempt_mount "tmp" "tmpfs" "tmpfs" "size=512m,mode=1777"; then
        warn "Failed to mount tmpfs on /tmp - performance may be affected"
        # Ensure directory is writable at least
        chmod 1777 "$ARCH_PATH/tmp" 2>/dev/null || true
    fi

    # sdcard mount (best effort) - many Android devices have different layouts
    local sdcard_mounted=false
    for sdcard_candidate in "/sdcard" "/storage/emulated/0" "/storage/self/primary"; do
        if [ -d "$sdcard_candidate" ] && [ -r "$sdcard_candidate" ]; then
            if attempt_mount "media/sdcard" "" "$sdcard_candidate" "bind"; then
                sdcard_mounted=true
                break
            fi
        fi
    done

    if [ "$sdcard_mounted" = false ]; then
        info "No accessible sdcard found - skipping (normal on some devices)"
    fi

    echo "" >> "$LOG_FILE"
}

# ─── SMART DNS ENFORCEMENT: Fix Common Android DNS Issues ──────────────────
smart_enforce_dns() {
    info "Smart DNS enforcement with Android compatibility..."
    echo "=== Smart DNS Enforcement ===" >> "$LOG_FILE"

    local resolv_conf="$ARCH_PATH/etc/resolv.conf"
    local dns_backup_conf="$ARCH_PATH/etc/resolv.conf.archdroid-backup"

    # Ensure /etc directory exists
    mkdir -p "$ARCH_PATH/etc"

    # Backup existing DNS config if it exists and we haven't backed it up yet
    if [ -f "$resolv_conf" ] && [ ! -f "$dns_backup_conf" ]; then
        cp "$resolv_conf" "$dns_backup_conf" 2>/dev/null || true
        info "Backed up existing DNS configuration"
        echo "BACKUP: Saved existing resolv.conf" >> "$LOG_FILE"
    fi

    # Test current DNS resolution first
    local dns_working=false
    for test_host in "google.com" "1.1.1.1" "archlinux.org"; do
        if timeout 3 getent hosts "$test_host" >/dev/null 2>&1; then
            dns_working=true
            break
        fi
    done

    if [ "$dns_working" = true ]; then
        ok "DNS resolution working - keeping current configuration"
        echo "SUCCESS: DNS already working" >> "$LOG_FILE"
        return 0
    fi

    # DNS not working - apply smart fixes
    warn "DNS resolution failed - applying Android-compatible fixes"

    # Strategy 1: Try to preserve host DNS if available
    local host_dns_applied=false
    if [ -f "/etc/resolv.conf" ] && [ -s "/etc/resolv.conf" ]; then
        info "Copying host system DNS configuration..."
        if cp "/etc/resolv.conf" "$resolv_conf" 2>/dev/null; then
            host_dns_applied=true
            echo "Applied host DNS config" >> "$LOG_FILE"

            # Test if host DNS works
            sleep 1
            for test_host in "google.com" "1.1.1.1"; do
                if timeout 3 getent hosts "$test_host" >/dev/null 2>&1; then
                    ok "Host DNS configuration works - using it"
                    echo "SUCCESS: Host DNS working" >> "$LOG_FILE"
                    return 0
                fi
            done
            warn "Host DNS config copied but still not working"
        fi
    fi

    # Strategy 2: Apply robust fallback DNS with multiple providers
    info "Applying robust fallback DNS configuration..."
    {
        echo "# ArchDroid smart DNS configuration"
        echo "# Applied due to DNS resolution failure"
        echo "# Primary: Cloudflare"
        echo "nameserver 1.1.1.1"
        echo "nameserver 1.0.0.1"
        echo "# Secondary: Google"
        echo "nameserver 8.8.8.8"
        echo "nameserver 8.8.4.4"
        echo "# Tertiary: OpenDNS"
        echo "nameserver 208.67.222.222"
        echo "nameserver 208.67.220.220"
        echo ""
        echo "# Search domains for better resolution"
        echo "search local"
        echo ""
        echo "# Resolver options for Android compatibility"
        echo "options timeout:2 attempts:3 rotate"
    } > "$resolv_conf"

    ok "Applied comprehensive DNS fallback configuration"
    echo "SUCCESS: Applied fallback DNS config" >> "$LOG_FILE"

    # Test final configuration
    sleep 2
    local final_test_working=false
    for test_host in "google.com" "1.1.1.1" "archlinux.org"; do
        if timeout 5 getent hosts "$test_host" >/dev/null 2>&1; then
            final_test_working=true
            break
        fi
    done

    if [ "$final_test_working" = true ]; then
        ok "DNS resolution now working after smart fixes"
        echo "SUCCESS: Final DNS test passed" >> "$LOG_FILE"
    else
        warn "DNS still not working - network may be down or blocked"
        warn "Proceeding anyway - package operations may fail"
        echo "WARN: DNS still failing after all fixes" >> "$LOG_FILE"
    fi

    # Log what we applied
    {
        echo "DNS enforcement applied:"
        echo "  Host DNS tried: $host_dns_applied"
        echo "  Fallback applied: yes"
        echo "  Final working: $final_test_working"
        echo "  Config file: $resolv_conf"
    } >> "$LOG_FILE"

    echo "" >> "$LOG_FILE"
}

# ─── RESILIENT ENTRY: Robust Chroot with Fallbacks ─────────────────────────
resilient_entry() {
    info "Preparing resilient chroot entry with multiple fallbacks..."
    echo "=== Resilient Entry ===" >> "$LOG_FILE"

    # Validate essential paths exist
    local bash_path="$ARCH_PATH/bin/bash"
    local sh_path="$ARCH_PATH/bin/sh"
    local env_path=""

    # Find env binary with fallbacks
    for env_candidate in "$ARCH_PATH/usr/bin/env" "$ARCH_PATH/bin/env"; do
        if [ -x "$env_candidate" ]; then
            env_path="$env_candidate"
            break
        fi
    done

    # Check what shells are available
    local available_shell=""
    if [ -x "$bash_path" ]; then
        available_shell="bash"
        ok "Found executable bash shell"
    elif [ -x "$sh_path" ]; then
        available_shell="sh"
        warn "Using sh shell (bash not available)"
        bash_path="$sh_path"
    else
        fail "No executable shell found in chroot"
        echo "FATAL: No shell found - bash: $bash_path, sh: $sh_path" >> "$LOG_FILE"

        # Try to fix basic permissions as last resort
        chmod +x "$bash_path" 2>/dev/null || true
        chmod +x "$sh_path" 2>/dev/null || true

        if [ -x "$bash_path" ]; then
            ok "Fixed bash permissions - proceeding"
            available_shell="bash"
        elif [ -x "$sh_path" ]; then
            ok "Fixed sh permissions - proceeding"
            available_shell="sh"
            bash_path="$sh_path"
        else
            exit 2
        fi
    fi

    # Test basic chroot execution with multiple fallback methods
    info "Testing chroot execution with available shell ($available_shell)..."
    local chroot_working=false
    local test_methods=(
        "echo 'test' >/dev/null 2>&1"
        "true"
        "/bin/echo test >/dev/null 2>&1"
        "printf 'test' >/dev/null 2>&1"
    )

    for method in "${test_methods[@]}"; do
        local shell_to_test="${bash_path#$ARCH_PATH}"  # Remove arch path prefix
        if timeout 5 chroot "$ARCH_PATH" "$shell_to_test" -c "$method" 2>/dev/null; then
            chroot_working=true
            ok "Chroot execution test passed with: $shell_to_test -c '$method'"
            echo "SUCCESS: Chroot test passed - $shell_to_test -c '$method'" >> "$LOG_FILE"
            break
        fi
    done

    if [ "$chroot_working" = false ]; then
        # Last resort - try without any command
        if timeout 5 chroot "$ARCH_PATH" "${bash_path#$ARCH_PATH}" -c "exit 0" 2>/dev/null; then
            chroot_working=true
            ok "Basic chroot execution works"
        else
            warn "Chroot execution tests failed - proceeding anyway"
            warn "This may be due to SELinux, missing libraries, or permission issues"
            echo "WARN: All chroot tests failed but proceeding" >> "$LOG_FILE"
        fi
    fi

    # Setup final environment variables
    export TERM="${TERM:-xterm-256color}"
    export SHELL="${bash_path#$ARCH_PATH}"  # Remove arch path prefix for internal use

    # Prepare clean environment for entry
    local clean_env_vars=(
        "HOME=/root"
        "TERM=$TERM"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "LANG=C.UTF-8"
        "LC_ALL=C.UTF-8"
        "SHELL=$SHELL"
        "USER=root"
    )

    ok "Environment prepared for chroot entry"

    # Show entry information
    echo ""
    info "Entering chroot environment:"
    echo "  Root Path: $ARCH_PATH"
    echo "  Shell: $SHELL ($available_shell)"
    echo "  Environment: Clean (isolated from Android)"
    echo "  Mounts: Auto-fixed where possible"
    echo "  DNS: Configured with fallbacks"
    echo "  Entry Method: env -i with clean environment"
    echo ""

    # Log final environment
    {
        echo "Final environment for entry:"
        printf "  %s\n" "${clean_env_vars[@]}"
        echo ""
        echo "Entry command preparation:"
        echo "  Available shell: $available_shell"
        echo "  Shell path: $SHELL"
        echo "  Env binary: ${env_path:-builtin}"
        echo "  Chroot working: $chroot_working"
        echo ""
    } >> "$LOG_FILE"

    # Try multiple entry methods for maximum compatibility
    info "Attempting chroot entry with fallback methods..."

    # Method 1: Standard env -i approach (cleanest)
    if [ -n "$env_path" ]; then
        {
            echo "Attempting method 1: env -i approach"
            echo "Command: chroot $ARCH_PATH ${env_path#$ARCH_PATH} -i [clean env] $SHELL --login"
        } >> "$LOG_FILE"
        add_log_integrity "$LOG_FILE" "RUNTIME_COMPLETE"

        # Execute with clean isolated environment
        exec chroot "$ARCH_PATH" "${env_path#$ARCH_PATH}" -i \
            "${clean_env_vars[@]}" \
            "$SHELL" --login 2>/dev/null
    fi

    # Method 2: Direct shell approach
    {
        echo "Fallback method 2: direct shell approach"
        echo "Command: chroot $ARCH_PATH $SHELL --login"
    } >> "$LOG_FILE"
    add_log_integrity "$LOG_FILE" "RUNTIME_COMPLETE"

    # Export environment and try direct approach
    for env_var in "${clean_env_vars[@]}"; do
        export "$env_var"
    done

    exec chroot "$ARCH_PATH" "$SHELL" --login
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
main() {
    # Smart Runtime: Auto-fix issues while maintaining deterministic behavior
    # Philosophy: Fix what can be fixed automatically, warn about what can't,
    # but don't prevent usage of working installations

    adaptive_gate_startup          # Validate with auto-fixes
    enforce_environment           # Clean environment variables (deterministic)
    smart_enforce_mounts          # Smart mount handling with fallbacks
    smart_enforce_dns            # Smart DNS with Android compatibility
    resilient_entry              # Robust chroot entry with multiple methods
}

# Execute if called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi