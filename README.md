# ArchDroid

**Deterministic Arch Linux Runtime for Android (Root Required)**

Run Arch Linux on Android with **predictable behavior, verified installs, and safe updates** — no broken chroot states, no silent failures, no manual debugging loops.

---

## 🚀 Why ArchDroid?

Most Arch-on-Android setups fail in practice:

- environment gets polluted by Android/Termux  
- installs break halfway with no recovery  
- updates corrupt the system with no rollback  
- failures are silent and hard to debug  

**ArchDroid solves this by enforcing correctness instead of adapting to problems.**

- validates system state before execution  
- forces a clean, controlled runtime environment  
- installs and updates atomically (no partial states)  
- detects and recovers from failures automatically  

---

## ⚡ Quick Start

```bash
git clone https://github.com/AmnAnon/archdroid.git
cd archdroid

su
./archdroid bootstrap
./archdroid start
```

👉 If bootstrap succeeds, your system is guaranteed to be in a valid state.

---

## 🧠 How It Works (Simplified)

ArchDroid operates in a strict loop:

1. **Inspect** — validate system state  
2. **Enforce** — fix or block invalid conditions  
3. **Execute** — run in a clean, controlled environment  
4. **Verify** — confirm system integrity  

This ensures the system is never left in an unknown or partially broken state.

---

## ✨ Key Features

- **🎯 Deterministic Runtime**: Forces reality to match expected state, never adapts to broken environments
- **🔐 Secure Bootstrap**: Cryptographically verified downloads with checksum validation and external trust anchors
- **⚡ Atomic Updates**: Safe in-place updates with user data preservation and guaranteed rollback capability
- **🛡️ Tested Against Failures**: Validated against process kills, file corruption, resource exhaustion, and network failures
- **🔍 Comprehensive Validation**: Full system inspection (`doctor`), independent verification (`verify`), and real-time status monitoring
- **🧰 Complete CLI Interface**: Unified command-line tool for all operations with clear workflows
- **📊 Trust Model Documentation**: Explicit security boundaries and protection scope

---

## 🏗️ Architecture

ArchDroid implements a **5-phase system lifecycle** designed for operational reliability:

### Phase 1: Inspection
**Component**: `core/inspect-runtime.sh`  
**Purpose**: Comprehensive validation of all system components
- Filesystem integrity and structure validation
- Network connectivity and DNS resolution testing  
- Environment variable and mount point verification
- Security boundary and permission analysis
- JSON-structured status reporting with exit codes

### Phase 2: Runtime Enforcement  
**Component**: `core/runtime.sh`  
**Purpose**: Deterministic environment enforcement and clean execution
- Hard gate validation with configurable safe mode bypass
- Clean environment variable enforcement (PATH, HOME, USER)
- Mount state convergence with guaranteed cleanup
- Chroot entry with isolated execution context

### Phase 3: Secure Bootstrap
**Component**: `core/bootstrap.sh`  
**Purpose**: Secure, verifiable system provisioning  
- Rate-limited HTTPS downloads with multiple mirror support
- Cryptographic checksum verification with external trust anchors
- Comprehensive path traversal protection for tar archives
- Atomic installation with staging and rollback capabilities
- Mandatory post-installation verification

### Phase 4: Trust Model & Verification
**Components**: `core/verify.sh`, `core/trust-reset.sh`, `TRUST_MODEL.md`  
**Purpose**: Independent verification and trust boundary management
- Independent verification system separate from installation logic
- Trust reset mechanism for compromise recovery
- Explicit documentation of security boundaries and protection scope
- Tamper-evident logging with integrity chain validation

### Phase 5: Atomic Updates
**Component**: `core/atomic-update.sh`  
**Purpose**: Safe system transitions with preservation guarantees
- User data detection and backup with attribute preservation
- Atomic replacement with snapshot-based rollback
- Mandatory validation with automatic recovery on failure
- Version tracking and upgrade strategy analysis

---

## 🔐 Security Model

ArchDroid is designed to protect against **runtime inconsistency and supply-chain risks**, not full system compromise.

### ✅ Protected Against

- **Network Attacks**: MITM attacks, DNS hijacking, compromised download mirrors
- **Supply Chain Attacks**: Tampered rootfs archives, corrupted packages, modified checksums
- **Runtime Inconsistencies**: Environment contamination, mount point corruption, configuration drift  
- **Operational Errors**: Partial installations, incomplete upgrades, resource exhaustion
- **Process Failures**: Interrupted operations with automatic cleanup and state recovery

### ❌ Trust Boundaries (Out of Scope)

- **Root Environment Compromise**: System assumes Android root environment is not compromised
- **Kernel-Level Attacks**: Kernel and hardware-level attacks are outside the chroot boundary
- **Physical Access**: Physical device access and hardware tampering  
- **Time Manipulation**: System clock tampering for replay attacks

**Note**: For production deployments, external verification of checksum anchors is required. See `TRUST_MODEL.md` for detailed security analysis.

---

## ⚡ Installation

```bash
# Clone repository
git clone https://github.com/AmnAnon/archdroid.git
cd archdroid

# Initial system bootstrap (requires root)
su
./archdroid bootstrap
```

**External Verification Setup** (Recommended for Production):
```bash
# Verify checksums file against external sources
# See TRUST_MODEL.md for detailed verification procedures
git tag -s v1.0
git verify-tag v1.0
```

---

## 🧭 Usage Guide

### System Operations

```bash
# Start deterministic runtime
./archdroid start

# System status and health
./archdroid status
./archdroid doctor          # Comprehensive diagnostics

# Security verification  
./archdroid verify          # Independent integrity check

# Version and configuration
./archdroid version
```

### Update and Maintenance

```bash
# Atomic system update
./archdroid update

# Trust and recovery management  
./archdroid reset-trust     # Clear accumulated state, force fresh bootstrap
```

### Command Reference

| Command | Purpose | Use Case |
|---------|---------|----------|
| `bootstrap` | Initial installation with security verification | First-time setup |
| `start` | Enter secure chroot environment | Daily usage |
| `status` | Show system and installation status | Health monitoring |  
| `doctor` | Run comprehensive system diagnostics | Troubleshooting |
| `verify` | Independent verification of installation | Security auditing |
| `update` | Atomically update existing installation | Maintenance |
| `reset-trust` | Clear state and force fresh bootstrap | Security recovery |
| `version` | Show version and configuration information | Information |

---

## 🔄 Update & Recovery

### Atomic Update System

ArchDroid provides **zero-downtime atomic updates** with comprehensive safety guarantees:

- **User Data Preservation**: Automatic detection and backup of user configurations, SSH keys, package databases
- **Atomic Replacement**: Either complete success or complete rollback, no partial states
- **Validation Enforcement**: Mandatory post-update verification with automatic recovery
- **Strategy Analysis**: Intelligent version comparison and upgrade path determination

### Failure Recovery Guarantees

The system provides **guaranteed recovery** from all failure scenarios:

- **Process Termination**: Automatic cleanup of partial artifacts on abnormal exit
- **Resource Exhaustion**: Graceful failure with complete cleanup when disk/memory is exhausted  
- **Network Failures**: Retry logic with exponential backoff and mirror fallback
- **Corruption Detection**: Immediate failure and cleanup on checksum or integrity violations
- **Rollback Capability**: Atomic snapshot-based recovery to last known good state

---

## 🧪 Reliability & Testing

ArchDroid has been **tested under failure conditions** including process interruption, corrupted inputs, and resource exhaustion. In all tested cases, it either completed successfully or recovered to a known-good state.

### Testing Coverage
- **Process Termination**: Random kills during all phases of operation
- **File Corruption**: Header corruption, truncation, random byte injection
- **Resource Exhaustion**: Disk space filling, mount point blocking, network timeouts
- **Environment Poisoning**: Hostile PATH, Android variable contamination, permission issues
- **Concurrent Access**: Multiple process scenarios and locking validation

### Validation Results
- **9/9 Fuzz Tests Passed**: All failure injection scenarios handled correctly  
- **5/5 Recovery Tests Passed**: Complete state recovery validation
- **Zero Data Loss**: No partial artifacts or corrupted states in any failure mode

---

## 📁 Project Structure

```
archdroid/
├── core/                           # Core system components
│   ├── inspect-runtime.sh          # Comprehensive system validation
│   ├── runtime.sh                  # Deterministic runtime enforcement  
│   ├── bootstrap.sh                # Secure bootstrap and installation
│   ├── verify.sh                   # Independent verification system
│   ├── atomic-update.sh            # Safe atomic update system
│   ├── trust-reset.sh              # Trust recovery mechanism
│   ├── versions.sh                 # Version control and checksum management
│   └── json-utils.sh               # Safe JSON parsing utilities
│
├── test/                           # Testing and validation framework
│   ├── fuzz-framework.sh           # Comprehensive failure injection testing
│   └── recovery-validation.sh     # Recovery scenario validation
│
├── archdroid                       # Unified CLI interface
├── TRUST_MODEL.md                  # Security boundary documentation
└── README.md                       # This documentation
```

---

## ⚠️ Requirements

### System Requirements
- **Rooted Android**: KernelSU, Magisk, or equivalent root solution
- **Architecture**: `aarch64` (ARMv8) - covers most modern Android devices
- **Storage**: ~2GB available space for rootfs and operations
- **Network**: HTTPS connectivity for secure downloads

### Software Dependencies
- **Shell Environment**: Termux, Android Terminal, or equivalent
- **Core Utilities**: `curl`, `tar`, `sha256sum`, `jq`, standard POSIX tools
- **Permissions**: Root access for mount operations and chroot execution

### Verified Platforms
| Device | Chipset | Android | Root Method | Status |
|--------|---------|---------|-------------|--------|
| Poco X3 Pro | Snapdragon 860 | 11+ | KernelSU | ✅ Verified |
| *Add your device via PR* | | | | |

---

## 📌 Philosophy

ArchDroid is built on core engineering principles:

### Deterministic Enforcement
- **System defines its own truth** rather than adapting to inconsistent environments
- **Never compromise on correctness** - fail fast and fail clearly when reality doesn't match expectations  
- **Reproducible behavior** across different devices, Android versions, and root configurations

### Security by Design  
- **External verification requirements** for production deployments
- **Explicit trust boundaries** with clear documentation of protection scope
- **Defense in depth** through multiple validation layers and integrity checking

### Operational Excellence
- **Atomic operations** with guaranteed rollback capabilities
- **Comprehensive diagnostics** with actionable error messages and recovery guidance  
- **Tested reliability** through systematic failure injection and validation

---

## 📄 License

MIT License - See LICENSE file for details.

**Attribution appreciated but not required.**

---

*Built for reliability. Engineered for security. Tested against chaos.*