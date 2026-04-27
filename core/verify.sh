#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/verify.sh                                     ║
# ║  Independent Verification and Trust Validation System           ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
ARCH_PATH="${ARCH_PATH:-/data/local/arch}"
STATE_DIR="${STATE_DIR:-/data/local/archdroid-state}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load utilities
source "${SCRIPT_DIR}/versions.sh"
source "${SCRIPT_DIR}/json-utils.sh"

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

# ─── VERSION VERIFICATION ────────────────────────────────────────────────────
verify_version_integrity() {
    info "Verifying version control integrity..."

    # Check version configuration
    if ! validate_version_config; then
        fail "Version configuration is invalid"
        return 1
    fi
    ok "Version configuration: VALID"

    # Check installed version
    local installed_version current_version
    installed_version=$(get_current_version "$STATE_DIR")
    current_version="$ARCH_VERSION"

    echo "  Expected version: $current_version"
    echo "  Installed version: $installed_version"

    if [ "$installed_version" = "$current_version" ]; then
        ok "Version consistency: VERIFIED"
    elif [ "$installed_version" = "none" ]; then
        warn "No installation found"
        return 1
    else
        warn "Version mismatch detected"
        return 1
    fi

    return 0
}

# ─── ROOTFS VERIFICATION ──────────────────────────────────────────────────────
verify_rootfs_integrity() {
    info "Verifying rootfs integrity..."

    # Check if installation exists
    if [ ! -d "$ARCH_PATH" ]; then
        fail "Installation directory not found: $ARCH_PATH"
        return 1
    fi

    # Critical file verification
    local critical_files=(
        "bin/bash"
        "usr/bin/env"
        "etc/passwd"
        "usr/bin/pacman"
        "etc/pacman.conf"
        "usr/lib/ld-linux-aarch64.so.1"
    )

    local missing_files=()
    for file in "${critical_files[@]}"; do
        if [ ! -f "$ARCH_PATH/$file" ]; then
            missing_files+=("$file")
        elif [ ! -r "$ARCH_PATH/$file" ]; then
            missing_files+=("$file (not readable)")
        fi
    done

    if [ ${#missing_files[@]} -gt 0 ]; then
        fail "Critical files missing or unreadable:"
        for missing in "${missing_files[@]}"; do
            fail "  - $missing"
        done
        return 1
    fi

    ok "Critical files: PRESENT"

    # Executability check
    local executables=("bin/bash" "usr/bin/env" "usr/bin/pacman")
    for exe in "${executables[@]}"; do
        if [ ! -x "$ARCH_PATH/$exe" ]; then
            fail "Not executable: $exe"
            return 1
        fi
    done

    ok "Executables: VERIFIED"

    # Directory structure check
    local required_dirs=("usr" "etc" "bin" "sbin" "var" "tmp" "proc" "sys" "dev")
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$ARCH_PATH/$dir" ]; then
            fail "Required directory missing: $dir"
            return 1
        fi
    done

    ok "Directory structure: VERIFIED"

    return 0
}

# ─── CONFIGURATION VERIFICATION ──────────────────────────────────────────────
verify_configuration() {
    info "Verifying system configuration..."

    # pacman.conf check
    local pacman_conf="$ARCH_PATH/etc/pacman.conf"
    if [ -f "$pacman_conf" ]; then
        if grep -q "^DisableSandbox" "$pacman_conf"; then
            ok "pacman.conf: DisableSandbox configured (kernel 4.x compat)"
        else
            warn "pacman.conf: DisableSandbox not found (may cause issues on kernel 4.x)"
        fi
    else
        fail "pacman.conf not found"
        return 1
    fi

    # resolv.conf check
    local resolv_conf="$ARCH_PATH/etc/resolv.conf"
    if [ -f "$resolv_conf" ] && [ -s "$resolv_conf" ]; then
        local nameserver_count
        nameserver_count=$(grep -c "^nameserver" "$resolv_conf" || true)
        if [ "$nameserver_count" -gt 0 ]; then
            ok "DNS configuration: $nameserver_count nameservers configured"
        else
            warn "DNS configuration: no nameservers found"
        fi
    else
        warn "DNS configuration: resolv.conf missing or empty"
    fi

    return 0
}

# ─── RUNTIME VERIFICATION ────────────────────────────────────────────────────
verify_runtime_capability() {
    info "Verifying runtime capability..."

    # Use our inspection system
    if ! "${SCRIPT_DIR}/inspect-runtime.sh" >/dev/null 2>&1; then
        warn "Runtime inspection had issues"
    fi

    local runtime_json="${STATE_DIR}/runtime-snapshot.json"
    if [ ! -f "$runtime_json" ]; then
        fail "Runtime inspection did not generate state file"
        return 1
    fi

    # Check overall status
    local status
    status=$(safe_json_int "$runtime_json" ".overall_status" "2")

    case "$status" in
        0)
            ok "Runtime capability: FULLY OPERATIONAL"
            ;;
        1)
            warn "Runtime capability: OPERATIONAL WITH WARNINGS"
            ;;
        *)
            fail "Runtime capability: NOT OPERATIONAL"
            return 1
            ;;
    esac

    # Component breakdown
    local components=("filesystem" "network" "environment" "security")
    for component in "${components[@]}"; do
        local comp_status
        comp_status=$(safe_json_int "$runtime_json" ".components.${component}" "2")
        case "$comp_status" in
            0) ok "  $component: OK" ;;
            1) warn "  $component: WARNINGS" ;;
            *) fail "  $component: FAILED" ;;
        esac
    done

    return 0
}

# ─── CHROOT EXECUTION TEST ───────────────────────────────────────────────────
verify_chroot_execution() {
    info "Verifying chroot execution capability..."

    if [ ! -x "$ARCH_PATH/bin/bash" ]; then
        fail "bash is not executable"
        return 1
    fi

    # Fix 4: Remount /data exec before chroot test (F2FS propagation fix)
    local _data_mnt
    _data_mnt=$(mount 2>/dev/null | awk '$3 == "/data" {print}' | head -1)
    if echo "$_data_mnt" | grep -q "noexec"; then
        mount -o remount,exec /data 2>/dev/null || true
    fi

    # Fix 1: Symlink convergence in case rootfs was just extracted
    for _lk in lib lib64 bin sbin; do
        local _tg="usr/$_lk"
        local _lp="$ARCH_PATH/$_lk"
        if [ -d "$ARCH_PATH/$_tg" ]; then
            if [ -L "$_lp" ]; then
                local _cu
                _cu=$(readlink "$_lp")
                if [ "$_cu" != "$_tg" ] && [ "$_cu" != "/usr/$_lk" ]; then
                    ln -sf "$_tg" "$_lp" 2>/dev/null || true
                fi
            elif [ ! -e "$_lp" ]; then
                ln -sf "$_tg" "$_lp" 2>/dev/null || true
            fi
        fi
    done

    # Fix 2: ELF interpreter check — bail early with clear message
    local _bash_path="$ARCH_PATH/bin/bash"
    if [ -f "$_bash_path" ]; then
        local _interp
        _interp=$(readelf -l "$_bash_path" 2>/dev/null \
            | awk '/interpreter/ {gsub(/[\[\]]/,""); print $NF}')
        if [ -n "$_interp" ] && [ ! -f "$ARCH_PATH$_interp" ]; then
            fail "ELF interpreter missing inside rootfs: $_interp"
            fail "This is why chroot says 'No such file or directory'"
            return 1
        fi
    fi

    # Fix 3: Ensure /etc exists before any DNS writes
    mkdir -p "$ARCH_PATH/etc"

    # Test basic chroot execution
    local test_output
    if test_output=$(timeout 10 chroot "$ARCH_PATH" /bin/bash -c "echo 'chroot_test_ok'" 2>&1); then
        if [[ "$test_output" == *"chroot_test_ok"* ]]; then
            ok "Chroot execution: WORKING"
        else
            fail "Chroot execution: unexpected output"
            return 1
        fi
    else
        fail "Chroot execution: FAILED"
        return 1
    fi

    # Test package manager
    if timeout 10 chroot "$ARCH_PATH" /usr/bin/env -i /bin/bash -c "/usr/bin/pacman --version" >/dev/null 2>&1; then
        ok "Package manager: ACCESSIBLE"
    else
        warn "Package manager: may not be working"
    fi

    return 0
}

# ─── SECURITY VERIFICATION ───────────────────────────────────────────────────
verify_security_posture() {
    info "Verifying security posture..."

    # Check file permissions
    local rootfs_perms
    rootfs_perms=$(stat -c "%a" "$ARCH_PATH" 2>/dev/null || echo "unknown")

    case "$rootfs_perms" in
        755|750|700)
            ok "Rootfs permissions: $rootfs_perms (secure)"
            ;;
        777)
            warn "Rootfs permissions: $rootfs_perms (world-writable - INSECURE)"
            ;;
        *)
            warn "Rootfs permissions: $rootfs_perms (unusual)"
            ;;
    esac

    # Check for dangerous files
    local dangerous_paths=(
        "etc/shadow"
        "etc/sudoers"
        "root/.ssh/id_rsa"
    )

    for path in "${dangerous_paths[@]}"; do
        if [ -f "$ARCH_PATH/$path" ]; then
            local perms
            perms=$(stat -c "%a" "$ARCH_PATH/$path")
            if [[ "$perms" =~ [4567]$ ]]; then  # world-readable
                warn "Security: $path is world-readable ($perms)"
            else
                ok "Security: $path permissions OK ($perms)"
            fi
        fi
    done

    return 0
}

# ─── COMPREHENSIVE VERIFICATION ──────────────────────────────────────────────
run_verification() {
    banner "ArchDroid Verification System"

    local overall_status=0
    local checks_run=0
    local checks_passed=0

    # Version verification
    ((checks_run++))
    if verify_version_integrity; then
        ((checks_passed++))
    else
        overall_status=1
    fi

    echo ""

    # Rootfs verification
    ((checks_run++))
    if verify_rootfs_integrity; then
        ((checks_passed++))
    else
        overall_status=2
    fi

    echo ""

    # Configuration verification
    ((checks_run++))
    if verify_configuration; then
        ((checks_passed++))
    else
        overall_status=1
    fi

    echo ""

    # Runtime verification
    ((checks_run++))
    if verify_runtime_capability; then
        ((checks_passed++))
    else
        overall_status=1
    fi

    echo ""

    # Execution verification
    ((checks_run++))
    if verify_chroot_execution; then
        ((checks_passed++))
    else
        overall_status=2
    fi

    echo ""

    # Security verification
    ((checks_run++))
    if verify_security_posture; then
        ((checks_passed++))
    else
        overall_status=1
    fi

    # Summary
    echo ""
    echo -e "${BOLD}Verification Summary:${RESET}"
    echo "  Checks run: $checks_run"
    echo "  Checks passed: $checks_passed"
    echo "  Checks failed: $((checks_run - checks_passed))"

    echo ""
    case "$overall_status" in
        0)
            echo -e "${BOLD}${GREEN}"
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║            ✔ ALL VERIFICATIONS PASSED            ║"
            echo "  ║              System is FULLY VERIFIED            ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo -e "${RESET}"
            ;;
        1)
            echo -e "${BOLD}${YELLOW}"
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║         ⚠ VERIFICATIONS PASSED WITH WARNINGS     ║"
            echo "  ║           System is OPERATIONAL but has issues   ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo -e "${RESET}"
            ;;
        *)
            echo -e "${BOLD}${RED}"
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║           ✘ CRITICAL VERIFICATION FAILURES       ║"
            echo "  ║              System is NOT TRUSTWORTHY           ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo -e "${RESET}"
            ;;
    esac

    return $overall_status
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    run_verification "$@"
fi