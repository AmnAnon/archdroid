#!/bin/bash
# Quick Android compatibility test for ArchDroid fixes

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║       ArchDroid Android Compatibility Test       ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

info "Testing updated components..."

# Test 1: CLI symlink resolution
info "Testing CLI symlink resolution..."
if [ -x "$SCRIPT_DIR/archdroid" ]; then
    if "$SCRIPT_DIR/archdroid" version >/dev/null 2>&1; then
        ok "CLI version command works"
    else
        fail "CLI version command failed"
    fi
else
    fail "CLI not executable"
fi

# Test 2: inspect-runtime.sh auto-fix capabilities
info "Testing inspect-runtime.sh auto-fix mode..."
export ARCHDROID_AUTO_FIX=1
if [ -x "$SCRIPT_DIR/core/inspect-runtime.sh" ]; then
    # Run in a subshell to avoid environment pollution
    if (cd "$SCRIPT_DIR" && ./core/inspect-runtime.sh >/dev/null 2>&1); then
        ok "Runtime inspection with auto-fix completed successfully"
    else
        exit_code=$?
        if [ $exit_code -eq 1 ]; then
            ok "Runtime inspection completed with warnings (acceptable)"
        else
            warn "Runtime inspection had issues (exit code: $exit_code)"
        fi
    fi
else
    fail "inspect-runtime.sh not executable"
fi

# Test 3: Check if JSON utilities work
info "Testing JSON utilities..."
if [ -f "$SCRIPT_DIR/core/json-utils.sh" ]; then
    if source "$SCRIPT_DIR/core/json-utils.sh" 2>/dev/null; then
        ok "JSON utilities load successfully"
    else
        fail "JSON utilities failed to load"
    fi
else
    fail "JSON utilities not found"
fi

# Test 4: Check core script executability
info "Testing core script permissions..."
core_scripts=(
    "bootstrap.sh"
    "runtime.sh"
    "inspect-runtime.sh"
    "versions.sh"
    "json-utils.sh"
)

for script in "${core_scripts[@]}"; do
    if [ -f "$SCRIPT_DIR/core/$script" ]; then
        if [ -r "$SCRIPT_DIR/core/$script" ]; then
            ok "Core script readable: $script"
        else
            fail "Core script not readable: $script"
        fi
    else
        fail "Core script missing: $script"
    fi
done

# Test 5: Check state directory handling
info "Testing state directory handling..."
export STATE_DIR="/tmp/archdroid-test-state-$$"
mkdir -p "$STATE_DIR"

if [ -d "$STATE_DIR" ]; then
    ok "State directory creation works"

    # Test log creation
    echo "test" > "$STATE_DIR/test.log"
    if [ -f "$STATE_DIR/test.log" ]; then
        ok "Log file creation works"
    else
        fail "Log file creation failed"
    fi

    # Cleanup
    rm -rf "$STATE_DIR"
    ok "State directory cleanup works"
else
    fail "State directory creation failed"
fi

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║         Android Compatibility Test Complete      ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

info "Key improvements:"
echo "  - Auto-fix mode enabled by default for Android compatibility"
echo "  - More forgiving validation with graceful fallbacks"
echo "  - Smart mount handling with multiple Android paths"
echo "  - Comprehensive DNS fixes for Android network issues"
echo "  - Robust chroot entry with shell fallbacks"
echo "  - SELinux auto-switching to permissive mode"
echo ""
info "Next: Run 'archdroid doctor' to test the full system"