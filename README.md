# 🏛️ arch-android

**One-click Arch Linux aarch64 chroot for rooted Android devices.**  
(https://github.com/AmnAnon) — run a real Linux environment on your Android device with full pacman, zsh, and storage access.

---

## Requirements

- Rooted Android device (KernelSU or Magisk)
- [Termux](https://f-droid.org/packages/com.termux/) installed
- `aarch64` device (Snapdragon, Dimensity, Exynos — most modern Android phones)
- ~2GB free storage

---

## Quick Install

Open Termux and run:

```bash
su
curl -fsSL https://raw.githubusercontent.com/AmnAnon/arch-android/main/install.sh | bash
```

The installer will:
1. Ask where to install (`/data/local/arch` or Termux home or custom path)
2. Download the latest Arch Linux ARM rootfs (~930MB)
3. Extract and configure everything
4. Deploy `start-arch.sh` ready to use

---

## Starting the Chroot

Every time you want to enter Arch:

```bash
su
bash /data/local/start-arch.sh
```

On **first boot**, you'll see a success message and be asked if you want to run a full system upgrade. Recommended to say yes.

---

## What start-arch.sh Does

| Step | Action |
|---|---|
| SELinux | Sets to Permissive for the session |
| Namespace | Detects KernelSU vs Magisk, handles mount visibility |
| Mounts | dev, dev/pts, proc, sys, sdcard |
| DNS | Syncs from host, falls back to 8.8.8.8 / 1.1.1.1 |
| Shell | Auto-detects zsh → bash → sh |
| First boot | Shows success banner, prompts for system upgrade |

---

## Install Path Options

| Option | Path | Notes |
|---|---|---|
| Recommended | `/data/local/arch` | Survives Termux reinstalls |
| Termux home | `~/arch` | Easier permissions |
| Custom | Your choice | Full control |

---

## After First Boot

Install your essentials:
```bash
pacman -S zsh git vim python base-devel
```

---

## Tested On

| Device | Chipset | Root | Status |
|---|---|---|---|
| Poco X3 Pro | Snapdragon 860 | KernelSU-Next | ✅ Working |

> Got it working on your device? Open a PR to add it to the table.

---

## Troubleshooting

**pacman can't reach mirrors**  
→ Check DNS: `cat /etc/resolv.conf` — should show `8.8.8.8`  
→ Check connectivity: `ping -c 2 8.8.8.8`

**Landlock sandbox error**  
→ Add `DisableSandbox` under `[options]` in `/etc/pacman.conf`

**SSL errors downloading tarball**  
→ The installer uses Termux's curl which has proper certs. Make sure you're running from Termux, not Android shell.

---

## License

MIT — use freely, credit appreciated.

---

*by AkN*
