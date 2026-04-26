# ArchDroid

**Managed Arch Linux aarch64 runtime for rooted Android devices.**  
A proper CLI tool — not just scripts. Built and maintained by [AkN_Logic](https://x.com/AkN_Logic).

---

## Requirements

- Rooted Android (KernelSU or Magisk)
- [Termux](https://f-droid.org/packages/com.termux/) installed
- `aarch64` device (most modern Android phones)
- ~2GB free storage

---

## Install

```bash
su
curl -fsSL https://raw.githubusercontent.com/AmnAnon/archdroid/main/install.sh | bash
```

---

## Usage

```bash
archdroid init      # Download + install Arch Linux (first time only)
archdroid start     # Mount everything and enter chroot
archdroid stop      # Safely unmount all mounts
archdroid status    # Show mount status and chroot info
archdroid doctor    # Diagnose and auto-fix common issues
archdroid shell     # Re-enter chroot (if already mounted)
archdroid logs      # Show today's log
archdroid reset     # Wipe and start over
```

---

## First Boot Flow

```
archdroid init
  → Choose install path (recommended: /data/local/arch)
  → Downloads ~930MB Arch Linux ARM rootfs
  → Patches pacman.conf for kernel 4.x compatibility
  → Saves config to /data/local/archdroid.conf

archdroid start
  → Sets SELinux permissive
  → Detects KernelSU / Magisk namespace
  → Mounts dev, dev/pts, proc, sys, tmp (tmpfs), sdcard
  → Syncs DNS automatically
  → On first boot: asks if you want a full system upgrade
  → Enters chroot
```

---

## Architecture

```
archdroid/
├── core/
│   ├── env.sh          # Shared config, colors, logging
│   ├── mounts.sh       # All bind mount / unmount logic
│   ├── runtime.sh      # Chroot entry, namespace, shell detection
│   ├── bootstrap.sh    # Download, extract, pacman patch
│   └── doctor.sh       # Diagnose and self-heal
│
├── cli/
│   └── archdroid       # Main CLI dispatcher
│
├── state/
│   ├── sessions/       # Session tracking
│   └── logs/           # Daily logs at /data/local/archdroid-state/logs/
│
└── install.sh          # One-liner installer
```

---

## Troubleshooting

Run `archdroid doctor` first — it checks and auto-fixes most common issues.

**pacman fails with Landlock error:**
```bash
archdroid doctor  # auto-fixes DisableSandbox
```

**DNS not working inside chroot:**
```bash
archdroid stop && archdroid start  # re-syncs DNS on mount
```

**Mounts missing after reboot:**  
Mounts don't survive Android reboots — always run `archdroid start` after booting.

---

## Tested On

| Device | Chipset | Kernel | Root | Status |
|---|---|---|---|---|
| Poco X3 Pro | Snapdragon 860 | 4.14 | KernelSU-Next | ✅ Working |

> Got it working on your device? Open a PR to add it to the table.

---

## License

MIT — use freely, credit appreciated.

---

*by AkN*
