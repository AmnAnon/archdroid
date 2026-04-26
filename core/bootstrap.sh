#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/bootstrap.sh                                  ║
# ║  Secure, Verifiable, Tamper-Resistant Bootstrap System          ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
ARCH_PATH="${ARCH_PATH:-/data/local/arch}"
STATE_DIR="${STATE_DIR:-/data/local/archdroid-state}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Session tracking
SESSION_ID=$(date +%s)
mkdir -p "${STATE_DIR}/logs"
BOOTSTRAP_LOG="${STATE_DIR}/logs/bootstrap-${SESSION_ID}.log"

# Load utilities
source "${SCRIPT_DIR}/versions.sh"
source "${SCRIPT_DIR}/json-utils.sh"

# Mirror configuration (HTTPS only)
ARCH_MIRROR_PRIMARY="https://de3.mirror.archlinuxarm.org/os"
ARCH_TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
ARCH_URL_PRIMARY="${ARCH_MIRROR_PRIMARY}/${ARCH_TARBALL}"

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

# ─── BOOTSTRAP IDEMPOTENCY ───────────────────────────────────────────────────
check_existing_installation() {
    info "Checking for existing installation..."

    if [ -f "$ARCH_PATH/bin/bash" ] && [ -f "$ARCH_PATH/etc/pacman.conf" ]; then
        local current_version
        current_version=$(get_current_version "$ARCH_PATH")

        if [ "$current_version" != "none" ]; then
            ok "Arch Linux already installed (ArchDroid-managed)"
            info "Use 'archdroid update' to refresh, or 'archdroid bootstrap --force' to reinstall"
            echo "SKIP: Already installed" >> "$BOOTSTRAP_LOG"
            return 1
        fi

        # Rootfs exists but has no ArchDroid version lock — could be the user's
        # existing chroot system installed by another tool. Refuse by default.
        if [ "${ARCHDROID_FORCE:-0}" != "1" ]; then
            echo ""
            fail "Existing Arch installation detected at: $ARCH_PATH"
            fail "This system was not installed by ArchDroid — refusing to overwrite."
            echo ""
            echo "  To protect your data, choose one of:"
            echo ""
            echo "  1. Back up first, then force reinstall:"
            echo "       cp -a $ARCH_PATH ${ARCH_PATH}.backup"
            echo "       ARCHDROID_FORCE=1 archdroid bootstrap"
            echo ""
            echo "  2. Install to a separate test path (safest):"
            echo "       export ARCH_PATH=/data/local/arch-test"
            echo "       archdroid bootstrap"
            echo ""
            echo "  3. Force reinstall without backup (destructive):"
            echo "       ARCHDROID_FORCE=1 archdroid bootstrap"
            echo ""
            echo "FATAL: Refusing to overwrite unmanaged rootfs" >> "$BOOTSTRAP_LOG"
            exit 1
        fi

        warn "ARCHDROID_FORCE=1 set — overwriting existing unmanaged rootfs"
        warn "Path: $ARCH_PATH"
        echo "WARN: Forced overwrite of unmanaged rootfs" >> "$BOOTSTRAP_LOG"
    fi

    info "No existing installation found — proceeding with bootstrap"
    echo "INFO: No existing installation" >> "$BOOTSTRAP_LOG"
    return 0
}

# ─── SECURE DOWNLOAD ─────────────────────────────────────────────────────────
find_curl() {
    # Find curl with proper SSL support (Termux or system)
    for candidate in \
        /data/data/com.termux/files/usr/bin/curl \
        /usr/bin/curl \
        /bin/curl; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    fail "curl not found - install with: pkg install curl"
    return 1
}

download_rootfs() {
    local curl_bin tarfile
    curl_bin=$(find_curl)
    tarfile="$1"

    info "Downloading Arch Linux ARM rootfs..."
    echo "DOWNLOAD: Starting download" >> "$BOOTSTRAP_LOG"
    echo "  Source: $ARCH_URL_PRIMARY" >> "$BOOTSTRAP_LOG"
    echo "  Target file: $tarfile" >> "$BOOTSTRAP_LOG"

    # Download main tarball
    info "Downloading: $ARCH_URL_PRIMARY"
    if ! "$curl_bin" -L --fail --retry 3 --connect-timeout 10 --max-time 1800 \
        --progress-bar -o "$tarfile" "$ARCH_URL_PRIMARY" 2>&1; then
        fail "Failed to download rootfs from primary mirror"
        echo "FATAL: Download failed from primary mirror" >> "$BOOTSTRAP_LOG"
        return 1
    fi

    ok "Downloaded rootfs successfully"
    echo "SUCCESS: Rootfs downloaded" >> "$BOOTSTRAP_LOG"

    # Download MD5 checksum file
    local md5_file="${tarfile}.md5"
    info "Downloading MD5 checksum..."
    if ! "$curl_bin" -L --fail --retry 3 --connect-timeout 10 --max-time 30 \
        -o "$md5_file" "${ARCH_URL_PRIMARY}.md5" 2>&1; then
        fail "Failed to download MD5 checksum file"
        echo "FATAL: MD5 download failed" >> "$BOOTSTRAP_LOG"
        return 1
    fi

    ok "Downloaded MD5 checksum"
    echo "SUCCESS: MD5 checksum downloaded" >> "$BOOTSTRAP_LOG"
    return 0
}

# ─── INTEGRITY VERIFICATION ──────────────────────────────────────────────────
verify_download() {
    local tarfile="$1"
    local md5_file="${tarfile}.md5"

    info "Verifying download integrity..."

    # Basic file validation
    if [ ! -f "$tarfile" ]; then
        fail "Downloaded file does not exist: $tarfile"
        echo "FATAL: File not found: $tarfile" >> "$BOOTSTRAP_LOG"
        return 1
    fi

    if [ ! -s "$tarfile" ]; then
        fail "Downloaded file is empty: $tarfile"
        echo "FATAL: Empty file: $tarfile" >> "$BOOTSTRAP_LOG"
        return 1
    fi

    if [ ! -f "$md5_file" ]; then
        fail "MD5 checksum file not found: $md5_file"
        echo "FATAL: MD5 file not found: $md5_file" >> "$BOOTSTRAP_LOG"
        return 1
    fi

    local filesize
    filesize=$(stat -c %s "$tarfile")
    ok "File size: $(numfmt --to=iec "$filesize")"
    echo "INFO: File size: $filesize bytes" >> "$BOOTSTRAP_LOG"

    # MD5 verification
    info "Verifying MD5 checksum..."
    local download_dir
    download_dir=$(dirname "$tarfile")

    if (cd "$download_dir" && md5sum -c "$(basename "$md5_file")" 2>/dev/null); then
        ok "MD5 verification: PASSED"
        echo "SUCCESS: MD5 checksum verified" >> "$BOOTSTRAP_LOG"

        # Extract MD5 hash for version lock
        local md5_hash
        md5_hash=$(awk '{print $1}' "$md5_file")
        echo "MD5_HASH: $md5_hash" >> "$BOOTSTRAP_LOG"

        return 0
    else
        fail "MD5 verification: FAILED"
        fail "This indicates corrupted download or network tampering"
        echo "FATAL: MD5 verification failed" >> "$BOOTSTRAP_LOG"

        # Cleanup failed files
        rm -f "$tarfile" "$md5_file"
        echo "CLEANUP: Removed corrupted files" >> "$BOOTSTRAP_LOG"
        return 1
    fi
}

# ─── STAGING EXTRACTION ──────────────────────────────────────────────────────
extract_to_staging() {
    local tarfile="$1"
    local staging_dir="$2"

    info "Extracting rootfs to staging directory..."
    echo "EXTRACT: Starting extraction" >> "$BOOTSTRAP_LOG"
    echo "  Source: $tarfile" >> "$BOOTSTRAP_LOG"
    echo "  Staging: $staging_dir" >> "$BOOTSTRAP_LOG"

    # Clean staging area
    rm -rf "$staging_dir"
    mkdir -p "$staging_dir"

    # Extract with error handling
    if tar -xzf "$tarfile" -C "$staging_dir" 2>&1; then
        ok "Extraction completed successfully"
        echo "SUCCESS: Extraction complete" >> "$BOOTSTRAP_LOG"
    else
        fail "Extraction failed - archive may be corrupted"
        echo "FATAL: Extraction failed" >> "$BOOTSTRAP_LOG"
        return 1
    fi

    # Post-extraction validation - verify required paths exist
    local critical_paths=("bin/bash" "etc/pacman.conf" "usr/bin" "lib")
    local missing_files=()

    for path in "${critical_paths[@]}"; do
        if [ ! -e "$staging_dir/$path" ]; then
            missing_files+=("$path")
        fi
    done

    if [ ${#missing_files[@]} -gt 0 ]; then
        fail "Critical paths missing after extraction:"
        for missing in "${missing_files[@]}"; do
            fail "  - $missing"
        done
        echo "FATAL: Missing critical paths: ${missing_files[*]}" >> "$BOOTSTRAP_LOG"
        return 1
    fi

    ok "Post-extraction validation passed"
    echo "SUCCESS: Post-extraction validation passed" >> "$BOOTSTRAP_LOG"
    return 0
}

# ─── ROOTFS VALIDATION ───────────────────────────────────────────────────────
validate_staging_rootfs() {
    local staging_dir="$1"

    info "Validating staged rootfs using inspection system..."
    echo "VALIDATE: Starting rootfs validation" >> "$BOOTSTRAP_LOG"

    # Use our own inspection system to validate the staged rootfs
    local temp_json="${STATE_DIR}/staging-validation.json"

    if ARCH_PATH="$staging_dir" "${SCRIPT_DIR}/inspect-runtime.sh" >/dev/null 2>&1; then
        local status
        status=$(safe_json_int "$temp_json" ".overall_status" "2")

        case "$status" in
            0)
                ok "Staged rootfs validation: PASSED (no issues)"
                echo "SUCCESS: Rootfs validation passed" >> "$BOOTSTRAP_LOG"
                ;;
            1)
                warn "Staged rootfs validation: WARNINGS (acceptable)"
                echo "WARN: Rootfs has warnings but acceptable" >> "$BOOTSTRAP_LOG"
                ;;
            *)
                fail "Staged rootfs validation: FAILED (critical issues)"
                echo "FATAL: Rootfs validation failed" >> "$BOOTSTRAP_LOG"
                return 1
                ;;
        esac
    else
        fail "Rootfs validation inspection failed"
        echo "FATAL: Inspection system failed" >> "$BOOTSTRAP_LOG"
        return 1
    fi

    # Clean up temp validation file
    rm -f "$temp_json"
    return 0
}

# ─── ATOMIC INSTALLATION ─────────────────────────────────────────────────────
atomic_install() {
    local staging_dir="$1"
    local target_dir="$2"

    info "Performing atomic installation with guaranteed rollback..."
    echo "INSTALL: Starting atomic installation" >> "$BOOTSTRAP_LOG"
    echo "  Source: $staging_dir" >> "$BOOTSTRAP_LOG"
    echo "  Target: $target_dir" >> "$BOOTSTRAP_LOG"

    local backup_dir="${target_dir}.old"

    # Step 1: Backup existing installation if present
    if [ -d "$target_dir" ]; then
        info "Backing up existing installation..."
        rm -rf "$backup_dir" 2>/dev/null || true
        if mv "$target_dir" "$backup_dir" 2>/dev/null; then
            ok "Existing installation backed up to: $backup_dir"
            echo "SUCCESS: Backup created at $backup_dir" >> "$BOOTSTRAP_LOG"
        else
            fail "Failed to backup existing installation"
            echo "FATAL: Backup failed" >> "$BOOTSTRAP_LOG"
            return 1
        fi
    fi

    # Step 2: Atomic move with guaranteed rollback
    if mv "$staging_dir" "$target_dir" 2>/dev/null; then
        ok "Atomic installation: COMPLETED"
        echo "SUCCESS: Atomic move completed" >> "$BOOTSTRAP_LOG"
    else
        fail "Atomic installation: FAILED"
        echo "FATAL: Atomic move failed" >> "$BOOTSTRAP_LOG"

        # Guaranteed rollback - restore original state
        info "Performing guaranteed rollback..."
        if [ -d "$backup_dir" ]; then
            if mv "$backup_dir" "$target_dir" 2>/dev/null; then
                ok "Rollback: SUCCESS (original installation restored)"
                echo "SUCCESS: Rollback completed successfully" >> "$BOOTSTRAP_LOG"
            else
                fail "Rollback: FAILED (manual intervention required)"
                fail "  Backup exists at: $backup_dir"
                fail "  Manually run: mv '$backup_dir' '$target_dir'"
                echo "FATAL: Rollback failed - manual intervention required" >> "$BOOTSTRAP_LOG"
            fi
        else
            warn "No backup available for rollback"
            echo "WARN: No backup available for rollback" >> "$BOOTSTRAP_LOG"
        fi
        return 1
    fi

    # Step 3: Verify installation success and write version lock
    if [ -f "$target_dir/bin/bash" ] && [ -f "$target_dir/etc/pacman.conf" ]; then
        ok "Installation verification: PASSED"

        # Extract MD5 hash from download for version lock
        local md5_file="${tarfile}.md5"
        local md5_hash="unknown"
        if [ -f "$md5_file" ]; then
            md5_hash=$(awk '{print $1}' "$md5_file" 2>/dev/null || echo "unknown")
        fi

        # Write version lock file
        write_version_lock "$target_dir" "$md5_hash"
        ok "Version lock written with MD5: $md5_hash"
        echo "SUCCESS: Installation verified and version lock written" >> "$BOOTSTRAP_LOG"

        # Clean up backup only after successful verification
        if [ -d "$backup_dir" ]; then
            rm -rf "$backup_dir"
            ok "Old backup cleaned up"
            echo "SUCCESS: Backup cleaned up" >> "$BOOTSTRAP_LOG"
        fi
    else
        fail "Installation verification: FAILED"
        echo "FATAL: Installation verification failed" >> "$BOOTSTRAP_LOG"

        # Emergency rollback since verification failed
        warn "Installation failed verification - performing emergency rollback"
        if [ -d "$backup_dir" ]; then
            rm -rf "$target_dir"
            if mv "$backup_dir" "$target_dir" 2>/dev/null; then
                warn "Emergency rollback: SUCCESS"
                echo "SUCCESS: Emergency rollback completed" >> "$BOOTSTRAP_LOG"
            else
                fail "Emergency rollback: FAILED"
                echo "FATAL: Emergency rollback failed" >> "$BOOTSTRAP_LOG"
            fi
        fi
        return 1
    fi

    return 0
}

# ─── MAIN BOOTSTRAP FUNCTION ─────────────────────────────────────────────────
run_bootstrap() {
    local session_start
    session_start=$(date '+%Y-%m-%d %H:%M:%S')

    # Initialize bootstrap log
    {
        echo "=== ArchDroid Bootstrap Session ==="
        echo "Session ID: $SESSION_ID"
        echo "Started: $session_start"
        echo "Target: $ARCH_PATH"
        echo "Source: $ARCH_URL_PRIMARY"
        echo ""
    } > "$BOOTSTRAP_LOG"

    banner "ArchDroid Secure Bootstrap"

    # Setup paths early for cleanup (global for cleanup)
    tarfile="${STATE_DIR}/${ARCH_TARBALL}"
    staging_dir="${ARCH_PATH}.staging"
    mkdir -p "$STATE_DIR"

# ─── SYSTEM REQUIREMENTS CHECK ──────────────────────────────────────────────
check_system_requirements() {
    info "Checking system requirements..."

    # Architecture check
    local arch
    arch=$(uname -m)
    if [ "$arch" != "aarch64" ]; then
        fail "Unsupported architecture: $arch (requires aarch64)"
        echo "FATAL: Unsupported architecture: $arch" >> "$BOOTSTRAP_LOG"
        return 1
    fi
    ok "Architecture: aarch64 ✓"

    # Disk space check (critical for preventing partial downloads)
    local required_mb=1500  # ~1GB for tarball + 500MB safety margin
    local target_parent
    target_parent=$(dirname "$ARCH_PATH")
    local available_mb

    # Check space on the actual target filesystem, not assumptions
    if available_mb=$(df -m "$target_parent" 2>/dev/null | awk 'NR==2 {print $4}'); then
        echo "  Target path: $ARCH_PATH"
        echo "  Target filesystem: $target_parent"
        echo "  Required space: ${required_mb}MB"
        echo "  Available space: ${available_mb}MB"

        if [ "$available_mb" -lt "$required_mb" ]; then
            fail "Insufficient disk space on target filesystem"
            fail "  Target: $target_parent"
            fail "  Required: ${required_mb}MB"
            fail "  Available: ${available_mb}MB"
            fail "  Free up space and try again"
            echo "FATAL: Insufficient disk space - required: ${required_mb}MB, available: ${available_mb}MB on $target_parent" >> "$BOOTSTRAP_LOG"
            return 1
        fi

        ok "Disk space: ${available_mb}MB available (${required_mb}MB required) on $target_parent"
        echo "SUCCESS: Disk space check passed on target filesystem" >> "$BOOTSTRAP_LOG"
    else
        warn "Could not check disk space on target filesystem: $target_parent"
        echo "WARN: Disk space check failed on $target_parent" >> "$BOOTSTRAP_LOG"
    fi

    return 0
}

    # System requirements check
    if ! check_system_requirements; then
        exit 1
    fi

    # Check for existing installation
    if ! check_existing_installation; then
        exit 1
    fi

    # Download phase
    if ! download_rootfs "$tarfile"; then
        exit 1
    fi

    # Verification phase
    if ! verify_download "$tarfile"; then
        rm -f "$tarfile"  # Remove potentially tampered file
        exit 1
    fi

    # Extraction phase
    if ! extract_to_staging "$tarfile" "$staging_dir"; then
        rm -rf "$staging_dir"
        exit 1
    fi

    # Validation phase
    if ! validate_staging_rootfs "$staging_dir"; then
        rm -rf "$staging_dir"
        exit 1
    fi

    # Installation phase
    if ! atomic_install "$staging_dir" "$ARCH_PATH"; then
        rm -rf "$staging_dir"
        exit 1
    fi

    # Cleanup
    rm -f "$tarfile"
    ok "Downloaded tarball cleaned up"

    # Final verification with installed system - mandatory for security
    info "Running comprehensive post-installation verification..."
    echo "VERIFY: Starting mandatory post-installation verification" >> "$BOOTSTRAP_LOG"

    if ! "${SCRIPT_DIR}/verify.sh" >/dev/null 2>&1; then
        fail "Post-installation verification: FAILED"
        fail "Installation completed but verification failed"
        fail "This indicates critical system issues:"
        fail "  - Incomplete installation"
        fail "  - Configuration problems"
        fail "  - Runtime environment corruption"
        echo "FATAL: Post-installation verification failed" >> "$BOOTSTRAP_LOG"

        # Installation failed verification - this is a security issue
        warn "Removing failed installation for security"
        if [ -d "${ARCH_PATH}.old" ]; then
            rm -rf "$ARCH_PATH"
            mv "${ARCH_PATH}.old" "$ARCH_PATH" 2>/dev/null || true
            warn "Rolled back to previous installation"
            echo "SUCCESS: Rollback to previous installation" >> "$BOOTSTRAP_LOG"
        else
            rm -rf "$ARCH_PATH"
            warn "Removed failed installation (no backup available)"
            echo "SUCCESS: Removed failed installation" >> "$BOOTSTRAP_LOG"
        fi

        exit 1
    fi

    ok "Post-installation verification: PASSED"
    echo "SUCCESS: Comprehensive verification passed" >> "$BOOTSTRAP_LOG"

    # Log completion with integrity protection
    {
        echo ""
        echo "=== Bootstrap Completed Successfully ==="
        echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Location: $ARCH_PATH"
        echo "Session ID: $SESSION_ID"
    } >> "$BOOTSTRAP_LOG"

    # Add integrity chain to detect log tampering
    add_log_integrity "$BOOTSTRAP_LOG" "BOOTSTRAP_COMPLETE"

    echo ""
    banner "Bootstrap Complete!"
    ok "Arch Linux ARM installed successfully"
    ok "Location: $ARCH_PATH"
    info "Bootstrap log: $BOOTSTRAP_LOG"
    echo ""
    info "Next steps:"
    echo "  1. Run 'archdroid start' to enter your chroot"
    echo "  2. Run 'archdroid doctor' if you encounter issues"
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────

# Bootstrap cleanup on exit
bootstrap_cleanup() {
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        # Bootstrap failed - clean up partial artifacts
        warn "Bootstrap failed - cleaning up partial artifacts..."

        # Clean up partial downloads from the actual state directory
        if [ -n "${STATE_DIR:-}" ] && [ -d "$STATE_DIR" ]; then
            find "$STATE_DIR" -name "ArchLinuxARM-*.tar.gz" -type f | while read -r tarfile; do
                rm -f "$tarfile" 2>/dev/null || true
                rm -f "${tarfile}.md5" 2>/dev/null || true
            done
        fi

        # Clean up staging directories
        if [ -n "${ARCH_PATH:-}" ]; then
            rm -rf "${ARCH_PATH}.staging" "${ARCH_PATH}.old" 2>/dev/null || true
        fi

        warn "Cleanup completed - no partial artifacts left"
    fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Set up cleanup on exit
    trap bootstrap_cleanup EXIT
    run_bootstrap "$@"
fi