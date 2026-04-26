#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║       AkN_Logic — Arch Linux aarch64 Android Installer          ║
# ║       github.com/AmnAnon/arch-android                           ║
# ╚══════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ─── COLORS ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()      { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn()    { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail()    { echo -e "${RED}  ✘  $*${RESET}"; exit 1; }
info()    { echo -e "${CYAN}  ▶  $*${RESET}"; }
section() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}\n"; }

TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
MIRROR="http://de3.mirror.archlinuxarm.org/os/${TARBALL}"
SCRIPT_URL="https://raw.githubusercontent.com/AmnAnon/arch-android/main/start-arch.sh"

# ─── BANNER ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║     Arch Linux aarch64 — Android Installer       ║"
echo "  ║     by AkN_Logic  •  github.com/AmnAnon          ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ─── ROOT CHECK ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  fail "Run this as root. Open Termux → type 'su' → then re-run."
fi

# ─── ARCH CHECK ─────────────────────────────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
  fail "Unsupported architecture: $ARCH. This script is for aarch64 (ARMv8) devices only."
fi
ok "Architecture: aarch64 ✓"

# ─── PATH SELECTION ─────────────────────────────────────────────────────────
section "Installation Path"

TERMUX_HOME="/data/data/com.termux/files/home/arch"
DEFAULT_PATH="/data/local/arch"

echo -e "  Where would you like to install Arch Linux?\n"
echo -e "  ${BOLD}1)${RESET} ${CYAN}/data/local/arch${RESET}  ${YELLOW}(Recommended)${RESET}"
echo      "     → Persistent across Termux reinstalls"
echo      "     → Accessible from any root shell"
echo ""
echo -e "  ${BOLD}2)${RESET} ${CYAN}${TERMUX_HOME}${RESET}"
echo      "     → Inside Termux home directory"
echo      "     → Easier permission handling"
echo      "     → Lost if Termux is uninstalled"
echo ""
echo -e "  ${BOLD}3)${RESET} Custom path"
echo ""

while true; do
  read -rp "  Enter choice [1/2/3] (default: 1): " CHOICE
  CHOICE="${CHOICE:-1}"
  case "$CHOICE" in
    1)
      ARCH_PATH="$DEFAULT_PATH"
      break
      ;;
    2)
      ARCH_PATH="$TERMUX_HOME"
      break
      ;;
    3)
      read -rp "  Enter full path: " ARCH_PATH
      if [ -z "$ARCH_PATH" ]; then
        warn "Path cannot be empty. Try again."
        continue
      fi
      break
      ;;
    *)
      warn "Invalid choice. Enter 1, 2, or 3."
      ;;
  esac
done

echo ""
ok "Install path: ${ARCH_PATH}"

# ─── CONFIRM ────────────────────────────────────────────────────────────────
echo ""
warn "This will download ~930MB and extract a full Arch Linux rootfs."
read -rp "  Proceed? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# ─── PREPARE DIRECTORY ──────────────────────────────────────────────────────
section "Preparing Directory"
mkdir -p "$ARCH_PATH"
ok "Directory ready: $ARCH_PATH"

# ─── DOWNLOAD ───────────────────────────────────────────────────────────────
section "Downloading Arch Linux ARM"
info "Source: $MIRROR"
info "This may take a few minutes depending on your connection...\n"

# Use Termux curl if available (has proper certs), fall back to system curl -k
CURL_BIN=""
for candidate in \
    /data/data/com.termux/files/usr/bin/curl \
    /usr/bin/curl \
    /bin/curl; do
  if [ -x "$candidate" ]; then
    CURL_BIN="$candidate"
    break
  fi
done

[ -z "$CURL_BIN" ] && fail "curl not found. Install it in Termux: pkg install curl"

"$CURL_BIN" -L --progress-bar \
  -o "${ARCH_PATH}/${TARBALL}" \
  "$MIRROR" \
  || fail "Download failed. Check your internet connection."

ok "Download complete"

# ─── EXTRACT ────────────────────────────────────────────────────────────────
section "Extracting Rootfs"
info "Extracting ${TARBALL} → this will take a few minutes..."

tar -xzf "${ARCH_PATH}/${TARBALL}" -C "$ARCH_PATH" \
  || fail "Extraction failed. Archive may be corrupted — try re-running."

ok "Extraction complete"

# Clean up tarball to save space
rm -f "${ARCH_PATH}/${TARBALL}"
ok "Tarball removed (saved ~930MB)"

# ─── DEPLOY START SCRIPT ────────────────────────────────────────────────────
section "Installing start-arch.sh"

# Write the ARCH_PATH into the start script
SCRIPT_DEST="/data/local/start-arch.sh"

# Try to fetch latest from GitHub, fall back to bundled copy
if "$CURL_BIN" -fsSL "$SCRIPT_URL" -o "$SCRIPT_DEST.tmp" 2>/dev/null; then
  # Inject the chosen ARCH_PATH
  sed "s|^ARCH_PATH=.*|ARCH_PATH=\"${ARCH_PATH}\"|" "$SCRIPT_DEST.tmp" > "$SCRIPT_DEST"
  rm -f "$SCRIPT_DEST.tmp"
  ok "start-arch.sh fetched from GitHub"
else
  warn "Could not fetch start-arch.sh from GitHub — please download it manually:"
  echo "     https://github.com/AmnAnon/arch-android/blob/main/start-arch.sh"
  echo "     and place it at: $SCRIPT_DEST"
fi

chmod +x "$SCRIPT_DEST"
ok "start-arch.sh deployed → ${SCRIPT_DEST}"

# Write chosen path to a config file for start-arch.sh to read
echo "ARCH_PATH=\"${ARCH_PATH}\"" > /data/local/arch-android.conf
ok "Config saved → /data/local/arch-android.conf"

# Mark as fresh install so start-arch.sh triggers first-boot flow
touch "${ARCH_PATH}/.akn_firstboot"
ok "First-boot flag set"

# ─── DONE ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║           Installation Complete! 🎉              ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  Arch Linux installed at: ${CYAN}${ARCH_PATH}${RESET}"
echo ""
echo -e "  To enter your chroot, run:"
echo -e "  ${BOLD}${GREEN}  su${RESET}"
echo -e "  ${BOLD}${GREEN}  bash /data/local/start-arch.sh${RESET}"
echo ""
