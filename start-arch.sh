#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║         AkN_Logic — Unified Arch Chroot Start Script            ║
# ║         github.com/AmnAnon/arch-android                         ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── CONFIG — auto-set by install.sh, or edit manually ──────────────────────
ARCH_PATH="/data/local/arch"

# Load path override from config if it exists
[ -f /data/local/arch-android.conf ] && source /data/local/arch-android.conf

# ─── COLORS ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✘  $*${RESET}"; }
info() { echo -e "${CYAN}  ▶  $*${RESET}"; }

# ─── BANNER ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║     AkN_Logic — Entering Sovereign Space  ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${RESET}"

# ─── ROOT CHECK ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}  ✘  Must be run as root. Run 'su' first.${RESET}"
  exit 1
fi

# ─── VALIDATE ARCH PATH ─────────────────────────────────────────────────────
if [ ! -d "$ARCH_PATH/etc" ]; then
  echo -e "${RED}  ✘  Arch rootfs not found at: $ARCH_PATH${RESET}"
  echo -e "${YELLOW}  ▶  Run install.sh first to set up the chroot.${RESET}"
  exit 1
fi

info "Chroot path: ${ARCH_PATH}"

# ─── 1. SELINUX → PERMISSIVE ────────────────────────────────────────────────
setenforce 0 2>/dev/null \
  && ok "SELinux → Permissive" \
  || warn "SELinux: already permissive or not applicable"

# ─── 2. NAMESPACE DETECTION ─────────────────────────────────────────────────
if [ -d "/data/adb/ksu" ]; then
  ok "KernelSU detected"
else
  info "Assuming Magisk — attempting nsenter..."
  if command -v nsenter &>/dev/null; then
    nsenter -t 1 -m -u -i -n -p -- /bin/true 2>/dev/null \
      && ok "Magisk global namespace active" \
      || warn "nsenter failed — mounts may not be globally visible"
  else
    warn "nsenter not found — skipping namespace breakout"
  fi
fi

# ─── 3. ENSURE MOUNT TARGET DIRS ────────────────────────────────────────────
mkdir -p \
  "$ARCH_PATH/dev" \
  "$ARCH_PATH/dev/pts" \
  "$ARCH_PATH/proc" \
  "$ARCH_PATH/sys" \
  "$ARCH_PATH/tmp" \
  "$ARCH_PATH/media/sdcard" \
  "$ARCH_PATH/etc"

# ─── 4. BIND MOUNTS ─────────────────────────────────────────────────────────
info "Setting up bind mounts..."

do_mount() {
  local label="$1" target="$2"
  shift 2
  if mountpoint -q "$target"; then
    warn "Already mounted: $label — skipping"
  else
    "$@" && ok "Mounted: $label" || fail "Failed to mount: $label"
  fi
}

do_mount "dev"     "$ARCH_PATH/dev"      mount --rbind /dev "$ARCH_PATH/dev"
mount --make-rslave "$ARCH_PATH/dev" 2>/dev/null

do_mount "dev/pts" "$ARCH_PATH/dev/pts"  mount --rbind /dev/pts "$ARCH_PATH/dev/pts"
mount --make-rslave "$ARCH_PATH/dev/pts" 2>/dev/null

do_mount "proc"    "$ARCH_PATH/proc"     mount -t proc proc "$ARCH_PATH/proc"
do_mount "sys"     "$ARCH_PATH/sys"      mount -t sysfs sysfs "$ARCH_PATH/sys"

# sdcard
SDCARD_SRC=""
[ -d "/sdcard" ]             && SDCARD_SRC="/sdcard"
[ -z "$SDCARD_SRC" ] && [ -d "/storage/emulated/0" ] && SDCARD_SRC="/storage/emulated/0"

if [ -n "$SDCARD_SRC" ]; then
  do_mount "sdcard" "$ARCH_PATH/media/sdcard" mount --bind "$SDCARD_SRC" "$ARCH_PATH/media/sdcard"
else
  warn "No sdcard source found — skipping"
fi

# /tmp as tmpfs — RAM-backed, big performance boost for llama.cpp / AI agents
do_mount "tmp" "$ARCH_PATH/tmp" mount -t tmpfs -o size=512m,mode=1777 tmpfs "$ARCH_PATH/tmp"

# ─── 5. DNS ─────────────────────────────────────────────────────────────────
info "Syncing DNS..."

DNS_WRITTEN=false

if [ -f /etc/resolv.conf ] && [ -s /etc/resolv.conf ]; then
  cp /etc/resolv.conf "$ARCH_PATH/etc/resolv.conf" 2>/dev/null \
    && ok "DNS synced from host" \
    && DNS_WRITTEN=true
fi

if [ "$DNS_WRITTEN" = false ]; then
  {
    echo "nameserver 8.8.8.8"
    echo "nameserver 1.1.1.1"
    echo "nameserver 208.67.222.222"
  } > "$ARCH_PATH/etc/resolv.conf" \
    && ok "Fallback DNS written (8.8.8.8 / 1.1.1.1 / OpenDNS)" \
    || fail "Could not write resolv.conf — DNS may not work"
fi

# ─── 6. SHELL DETECTION ─────────────────────────────────────────────────────
CHROOT_SHELL=""
for CANDIDATE in /usr/bin/zsh /bin/zsh /bin/bash /bin/sh; do
  if [ -x "$ARCH_PATH$CANDIDATE" ]; then
    CHROOT_SHELL="$CANDIDATE"
    break
  fi
done

if [ -z "$CHROOT_SHELL" ]; then
  echo -e "${RED}  ✘  No usable shell found in chroot.${RESET}"
  exit 1
fi
ok "Shell: $CHROOT_SHELL"

# ─── 7. FIRST BOOT DETECTION ────────────────────────────────────────────────
FIRST_BOOT=false
[ -f "${ARCH_PATH}/.akn_firstboot" ] && FIRST_BOOT=true

if [ "$FIRST_BOOT" = true ]; then
  echo ""
  echo -e "${BOLD}${GREEN}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║   🎉  Arch Linux Chroot Installed Successfully!  ║"
  echo "  ║                                                  ║"
  echo "  ║   Welcome to your Sovereign Space, Commander.   ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo ""
  echo -e "  ${BOLD}Would you like to run a full system upgrade now?${RESET}"
  echo -e "  ${CYAN}  This will initialize pacman keys and update all packages.${RESET}"
  echo -e "  ${YELLOW}  Recommended for first boot. Takes ~5-10 minutes.${RESET}"
  echo ""
  read -rp "  Run system upgrade? [Y/n]: " UPGRADE_CHOICE
  UPGRADE_CHOICE="${UPGRADE_CHOICE:-Y}"

  if [[ "$UPGRADE_CHOICE" =~ ^[Yy]$ ]]; then
    # Write an init script that runs inside chroot on first login
    cat > "${ARCH_PATH}/root/.akn_firstboot_init.sh" << 'INITEOF'
#!/bin/bash
GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

echo -e "\n${BOLD}${CYAN}  ▶  Initializing pacman keyring...${RESET}"
pacman-key --init
pacman-key --populate archlinuxarm

echo -e "\n${BOLD}${CYAN}  ▶  Running full system upgrade...${RESET}"
pacman --noconfirm -Syu

echo -e "\n${GREEN}  ✔  System upgrade complete! Your Arch chroot is ready.${RESET}\n"

# Clean up
rm -f /root/.akn_firstboot_init.sh
INITEOF
    chmod +x "${ARCH_PATH}/root/.akn_firstboot_init.sh"

    # Append auto-run to .bashrc / .zshrc inside chroot (runs once on first login)
    for RC in "${ARCH_PATH}/root/.bashrc" "${ARCH_PATH}/root/.zshrc"; do
      echo '[ -f /root/.akn_firstboot_init.sh ] && bash /root/.akn_firstboot_init.sh' >> "$RC"
    done

    ok "First-boot upgrade queued — will run automatically inside chroot"
  else
    info "Skipping upgrade. You can run it manually later:"
    echo "     pacman-key --init && pacman-key --populate archlinuxarm && pacman -Syu"
  fi

  # Remove first boot flag
  rm -f "${ARCH_PATH}/.akn_firstboot"
fi

# ─── 8. ENTER CHROOT ────────────────────────────────────────────────────────
echo ""
info "Entering Arch chroot → ${ARCH_PATH}"
echo ""

# Force clean PATH — prevents Android /system/bin leaking into chroot
# and causing binary conflicts with Arch's own tools
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

exec chroot "$ARCH_PATH" "$CHROOT_SHELL" -l
