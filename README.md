<div align="center">

# Rustermux

**Upstream Rustup Toolchain Integration for Termux**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE-MIT)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE-APACHE)
[![Rust](https://img.shields.io/badge/Rust-1.70+-orange.svg)](https://www.rust-lang.org/)
[![Platform](https://img.shields.io/badge/Platform-Termux%20%7C%20Android-green.svg)](https://termux.dev/)
[![CI](https://github.com/SSL-ACTX/rustermux/actions/workflows/ci.yml/badge.svg)](https://github.com/SSL-ACTX/rustermux/actions/workflows/ci.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/SSL-ACTX/rustermux)

<img src="https://github.com/SSL-ACTX/cdn_purposes/raw/refs/heads/main/demo.gif" width="200" alt="demo">
<p align="center"><i>Demo</i></p>

</div>

> [!WARNING]
> Rustermux patches ELF headers to execute GNU toolchains under Termux Glibc on Android (`aarch64`). Do not run this on standard Linux systems.

---

## Overview

Official `rustup` distributes GNU host toolchains (`aarch64-unknown-linux-gnu`) and lacks a native Android host release. Rustermux executes official GNU Rust toolchains inside Termux using Termux Glibc, patches ELF interpreters/RPATH on the fly, and configures the toolchain to compile native Android (`aarch64-linux-android`) binaries.

> [!NOTE]
> Rustermux runs official upstream toolchains via binary patching and shell wrappers. It is an independent community project and is not affiliated with the Rust Project or Termux.

---

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Features](#features)
- [Rustermux vs `pkg install rust`](#rustermux-vs-pkg-install-rust)
- [Limitations](#limitations)
- [Compatibility](#compatibility)
- [Project Structure](#project-structure)
- [How It Works](#how-it-works)
- [Documentation](#documentation)
- [License](#license)

---

## Quick Start

```bash
git clone https://github.com/SSL-ACTX/rustermux.git && cd rustermux && ./install.sh
```

Or install directly:

```bash
curl -fsSL https://github.com/SSL-ACTX/rustermux/raw/refs/heads/main/install.sh | bash
```

Load the environment:

```bash
source ~/.cargo/env
```

---

## Features

- **Automated Toolchain Setup**: Installs Termux Glibc prerequisites, downloads official `rustup-init`, patches dynamic loaders, and configures Android defaults.
- **Build Acceleration**: Integrates `sccache` caching and `mold` linker support, suppressing incremental hard-link cache warnings on Android filesystems.
- **Mobile Resource Tuning**: Caps `CARGO_BUILD_JOBS` based on CPU core count and enables unpacked dev debug info (`debug = 1`) to prevent link-time out-of-memory kills.
- **Cross-Compilation Toolchain Shims**: Exports `cc-rs` and `cmake` environment variables (`CC`, `CXX`, `AR`, `CFLAGS`) for native C dependencies.
- **Post-Execution Patching**: Intercepts `rustup update`, `install`, and `target add` to patch newly downloaded ELF binaries automatically.
- **Performance Cache**: Tracks binary modification timestamps (`mtime`) in `~/.cargo/.patch_cache` to bypass re-patching unchanged files.
- **Python Maturin Integration**: Normalizes Android wheel tags, sets library `RUNPATH`, and patches native `.so` Python extensions.
- **APT Conflict Prevention**: Provides a virtual `rust-dummy` package and `dpkg-divert` integration to prevent `pkg install maturin` from pulling the 150MB Termux Bionic Rust package.

---

## Rustermux vs `pkg install rust`

| Feature | `pkg install rust` | Rustermux |
|---|---|---|
| Upstream `rustup` | ❌ | ✅ |
| Stable / Nightly switching | Limited | ✅ |
| Multi-target support (`rustup target add`) | ❌ | ✅ |
| Official upstream binaries | ❌ (Termux rebuild) | ✅ |
| Toolchain self-updates | ❌ | ✅ |
| Works on Termux | ✅ | ✅ |

`pkg install rust` provides a Termux-recompiled Rust package with no `rustup` multi-toolchain support. Rustermux runs official Rust Project releases with full `rustup` channel and target management.

---

## Limitations

- Native support targets **aarch64 Termux** (64-bit ARM Android).
- Experimental **32-bit ARM** support uses `qemu-arm` (`RUSTERMUX_ARCH=arm32 ./install.sh`). See [docs/arm32-experimental.md](docs/arm32-experimental.md).
- Requires Termux Glibc packages (`glibc`, `glibc-runner`, `glibc-repo`).
- Patches binaries at the ELF level; not supported upstream by the Rust Project or Termux.
- Does not modify existing Bionic-compiled packages in `$PREFIX/bin`.

---

## Project Structure

```text
rustermux/
├── install.sh             # Main installer script
├── patch.sh               # ELF patcher with mtime performance caching
├── LICENSE-MIT            # MIT License
├── LICENSE-APACHE         # Apache 2.0 License
├── wrappers/
│   ├── rustup             # Rustup entry point wrapper with post-exec hooks
│   ├── rustc-wrapper      # Compiler wrapper for sccache and warning suppression
│   ├── maturin            # Maturin wrapper for Python native extensions
│   ├── cargo-audit        # cargo-audit wrapper (git fallback for advisory DB)
│   └── auto-patcher.sh    # Startup helper to repair sitecustomize and diversions
├── packaging/
│   └── tur/               # Packaging definitions for Termux User Repository (TUR)
├── docs/
│   ├── architecture.md    # Architecture and technical design decisions
│   ├── arm32-experimental.md # Experimental 32-bit ARM setup guide
│   ├── troubleshooting.md # Root causes and resolutions for common issues
│   └── usage.md           # Compilation, targets, and toolchain workflows
└── tests/
    └── validate.sh        # Automated test verification suite
```

---

## How It Works

Rustermux rewrites the ELF interpreter (`PT_INTERP`) of GNU Rust toolchain binaries from `/lib/ld-linux-aarch64.so.1` to the Termux Glibc dynamic loader (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`) using `patchelf`. 

A wrapper script in `~/.cargo/bin/rustup` intercepts update commands and patches new toolchain components immediately after download. Cargo is configured to output `aarch64-linux-android` binaries linked against Termux's system libraries.

See [docs/architecture.md](docs/architecture.md) for full implementation details.

---

## Compatibility

### Android Versions

| Android Version | Status |
|----------------|--------|
| Android 12 | ✅ Tested |
| Android 13 | ✅ Tested |
| Android 14 | ⚠️ Untested |
| Android 15 | ⚠️ Untested |

### Toolchain & Tooling

| Component | Status |
|-----------|--------|
| Stable Toolchain | ✅ Supported |
| Nightly Toolchain | ✅ Supported |
| `rustup update` | ✅ Auto-patched |
| `rustup self update` | ✅ Auto-patched |
| `cargo install` | ✅ Supported |
| `cargo build` | ✅ Supported |
| `cargo audit` | ✅ Supported (via wrapper) |
| Maturin | ✅ Supported (via wrapper) |
| 32-bit ARM | 🧪 Experimental (`qemu-arm`) |

---

## Documentation

| Document | Description |
|----------|-------------|
| [architecture.md](docs/architecture.md) | Technical architecture, dynamic linking mechanics, and wrapper hooks |
| [arm32-experimental.md](docs/arm32-experimental.md) | 32-bit ARM emulation configuration with `qemu-arm` |
| [usage.md](docs/usage.md) | Target management, cargo configuration, and Python extension workflows |
| [troubleshooting.md](docs/troubleshooting.md) | Solutions for linker errors, CA certificates, and dynamic loader issues |

---

## License

Dual-licensed under:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

---

<div align="center">

Built with 🦀 by [Seuriin](https://github.com/SSL-ACTX)

</div>
