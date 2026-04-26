#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — core/versions.sh                                   ║
# ║  Version Tracking - Installation Version Management             ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── STRICT MODE ─────────────────────────────────────────────────────────────
set -euo pipefail

# ─── VERSION TRACKING ────────────────────────────────────────────────────────

# Current ArchDroid version
ARCH_VERSION="1.0.0-android-compatible"

get_current_version() {
    local arch_path="${1:-${ARCH_PATH:-/data/local/arch}}"
    local version_file="${arch_path}/.archdroid-version"

    if [ -f "$version_file" ]; then
        cat "$version_file"
    else
        echo "none"
    fi
}

write_version_lock() {
    local arch_path="${1:-${ARCH_PATH:-/data/local/arch}}"
    local md5_hash="${2:-unknown}"
    local version_file="${arch_path}/.archdroid-version"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Write version lockfile with metadata
    {
        echo "# ArchDroid Version Lock"
        echo "install_timestamp=$timestamp"
        echo "install_method=bootstrap"
        echo "rootfs_md5=$md5_hash"
        echo "system_verified=true"
    } > "$version_file"
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Called directly - show current version
    echo "Current version: $(get_current_version)"
fi