#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║         AkN_Logic — Arch Chroot Safe Stop Script                ║
# ║         github.com/AmnAnon/arch-android                         ║
# ╚══════════════════════════════════════════════════════════════════╝
# ⚠  Always run this before deleting or modifying the chroot folder.
#    Unmounting while --rbind mounts are active can wipe Android's
#    real /dev or /sdcard.

# ─── COLORS ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }

# ─── LOAD CONFIG ────────────────────────────────────────────────────────────
ARCH_PATH="/data/local/arch"
[ -f /data/local/arch-android.conf ] && source /data/local/arch-android.conf

# ─── ROOT CHECK ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}  ✘  Must be run as root. Run 'su' first.${RESET}"
  exit 1
fi

echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║     AkN_Logic — Stopping Arch Chroot      ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${RESET}"

info "Unmounting chroot at: ${ARCH_PATH}"
echo ""

# ─── UNMOUNT — order matters (children before parents) ──────────────────────
# Unmount in reverse order to avoid busy-mount errors

MOUNT_POINTS=(
  "$ARCH_PATH/tmp"
  "$ARCH_PATH/media/sdcard"
  "$ARCH_PATH/dev/pts"
  "$ARCH_PATH/dev"
  "$ARCH_PATH/sys"
  "$ARCH_PATH/proc"
)

for mnt in "${MOUNT_POINTS[@]}"; do
  if mountpoint -q "$mnt" 2>/dev/null; then
    # -l = lazy unmount — detaches immediately even if busy,
    # kernel cleans up once all processes leave
    umount -l "$mnt" \
      && ok "Unmounted: $mnt" \
      || fail "Failed to unmount: $mnt (may still be in use)"
  else
    warn "Not mounted: $mnt — skipping"
  fi
done

echo ""

# ─── VERIFY ─────────────────────────────────────────────────────────────────
STILL_MOUNTED=$(mount | grep "$ARCH_PATH" | wc -l)
if [ "$STILL_MOUNTED" -eq 0 ]; then
  echo -e "${BOLD}${GREEN}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║   ✔  Arch chroot safely stopped.         ║"
  echo "  ║      Safe to delete or modify the folder.║"
  echo "  ╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
else
  warn "${STILL_MOUNTED} mount(s) still active under ${ARCH_PATH}:"
  mount | grep "$ARCH_PATH"
  echo ""
  warn "Do NOT delete the chroot folder until all mounts are clear."
  warn "Check for active sessions still inside the chroot."
fi
