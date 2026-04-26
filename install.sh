#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ArchDroid — install.sh                                         ║
# ║  Clones repo and sets up the archdroid CLI                      ║
# ╚══════════════════════════════════════════════════════════════════╝
# Usage:
#   su
#   curl -fsSL https://raw.githubusercontent.com/AmnAnon/archdroid/main/install.sh | bash

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; exit 1; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }

REPO_URL="https://github.com/AmnAnon/archdroid.git"
INSTALL_DIR="/data/local/archdroid"
BIN_PATH="/data/local/bin/archdroid"

echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║  ArchDroid — Deterministic Arch Linux Runtime    ║"
echo "  ║  github.com/AmnAnon/archdroid                    ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# Root check
[ "$(id -u)" -eq 0 ] || fail "Run as root: su → then re-run"

# Find git
GIT_BIN=""
for g in /data/data/com.termux/files/usr/bin/git /usr/bin/git; do
  [ -x "$g" ] && GIT_BIN="$g" && break
done
[ -z "$GIT_BIN" ] && fail "git not found. In Termux: pkg install git"

# Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
  info "Updating existing ArchDroid install..."
  "$GIT_BIN" -C "$INSTALL_DIR" pull origin main \
    && ok "Updated to latest" \
    || warn "Update failed — continuing with existing version"
else
  info "Cloning ArchDroid → $INSTALL_DIR"
  "$GIT_BIN" clone "$REPO_URL" "$INSTALL_DIR" \
    || fail "Clone failed. Check your internet connection."
  ok "Cloned"
fi

# Make everything executable
chmod +x "$INSTALL_DIR/archdroid"
chmod +x "$INSTALL_DIR/core/"*.sh
chmod +x "$INSTALL_DIR/test/"*.sh 2>/dev/null || true

# Install CLI to PATH
mkdir -p /data/local/bin
ln -sf "$INSTALL_DIR/archdroid" "$BIN_PATH"
chmod +x "$BIN_PATH"
ok "CLI installed → $BIN_PATH"

# Add /data/local/bin to PATH — write to shell config automatically
if ! echo "$PATH" | grep -q "/data/local/bin"; then
  warn "/data/local/bin not in your PATH — fixing automatically..."

  # Detect which shell config to write to
  SHELL_CONFIG=""
  # Check Termux home explicitly (HOME may resolve to /root when running as su)
  TERMUX_HOME="/data/data/com.termux/files/home"
  for candidate in \
    "${TERMUX_HOME}/.bashrc" \
    "${TERMUX_HOME}/.bash_profile" \
    "$HOME/.bashrc" \
    "$HOME/.bash_profile" \
    "$HOME/.profile"; do
    if [ -f "$candidate" ]; then
      SHELL_CONFIG="$candidate"
      break
    fi
  done

  PATH_LINE='export PATH=/data/local/bin:$PATH'

  if [ -n "$SHELL_CONFIG" ]; then
    # Only add if not already present
    if ! grep -qF '/data/local/bin' "$SHELL_CONFIG" 2>/dev/null; then
      echo "" >> "$SHELL_CONFIG"
      echo "# Added by ArchDroid install" >> "$SHELL_CONFIG"
      echo "$PATH_LINE" >> "$SHELL_CONFIG"
      ok "Added PATH to $SHELL_CONFIG"
    else
      ok "PATH entry already present in $SHELL_CONFIG"
    fi
    info "Reload with: source $SHELL_CONFIG"
  else
    warn "Could not detect shell config — add manually:"
    info "  $PATH_LINE"
  fi

  # Apply to current session regardless
  export PATH="/data/local/bin:$PATH"
  ok "PATH updated for this session"
fi

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║      ArchDroid installed successfully! 🎉        ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo ""

if [ -t 0 ]; then
    printf "  Run full setup now? (bootstrap + enter + pacman -Syu) [Y/n]: "
    read -r run_now </dev/tty
    if [ "${run_now:-Y}" != "n" ] && [ "${run_now:-Y}" != "N" ]; then
        echo ""
        exec "$BIN_PATH" up
    fi
fi

info "To set up manually, run:"
echo -e "  ${BOLD}archdroid up${RESET}        # Full setup in one command"
echo ""
echo "  Or step by step:"
echo -e "  ${BOLD}archdroid bootstrap${RESET}   # Install Arch rootfs"
echo -e "  ${BOLD}archdroid start${RESET}       # Enter chroot"
echo ""
