<div align="center">

# Rustermux

**Official Rustup Toolchains for Termux**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE-MIT)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE-APACHE)
[![Rust](https://img.shields.io/badge/Rust-1.70+-orange.svg)](https://www.rust-lang.org/)
[![Platform](https://img.shields.io/badge/Platform-Termux%20%7C%20Android-green.svg)](https://termux.dev/)
[![CI](https://github.com/SSL-ACTX/rustermux/actions/workflows/ci.yml/badge.svg)](https://github.com/SSL-ACTX/rustermux/actions/workflows/ci.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/SSL-ACTX/rustermux)

</div>

> [!WARNING]
> Rustermux patches ELF binaries at the OS level. It is designed for Termux on Android (aarch64) and should not be used on standard Linux systems.

---

## Why Rustermux?

Official `rustup` distributes GNU host toolchains but does not support Android as a native host environment. Rustermux provides a compatibility layer that allows the official GNU Rust toolchain distributed by `rustup` to run inside Termux's glibc environment — it does **not** add native Android host support to `rustup` itself.

> [!NOTE]
> Rustermux uses the official Rust toolchains distributed by `rustup` but relies on binary patching and wrapper scripts. It is an independent community project and is **not affiliated with or officially supported** by the Rust Project or the Termux maintainers.

---

This repository provides an automated installer and post-execution hook wrapper system to run standard `aarch64-unknown-linux-gnu` (glibc-linked) Rust toolchains natively inside Termux on Android.

Android targets usually crash on Android hosts because of differences in the C library (Bionic vs. Glibc) and preloaded runtime libraries. Rustermux makes native compilation for Android and GNU host execution seamless and stable.

## Table of Contents

- [Why Rustermux?](#why-rustermux)
- [Quick Start](#quick-start)
- [Features](#features)
- [Why not `pkg install rust`?](#why-not-pkg-install-rust)
- [Limitations](#limitations)
- [Compatibility](#compatibility)
- [Project Structure](#project-structure)
- [How It Works](#how-it-works)
- [Documentation](#documentation)
- [License](#license)

---

## Quick Start

Clone the repository and run the installer:

```bash
git clone https://github.com/SSL-ACTX/rustermux.git && cd rustermux && ./install.sh
```

Or run the installation script directly:

```bash
curl -fsSL https://github.com/SSL-ACTX/rustermux/raw/refs/heads/main/install.sh | bash
```

After the installer finishes, reload your environment:

```bash
source ~/.cargo/env
```

---

## Features

- **Automated Setup**: Installs Termux Glibc dependencies, downloads the compiler, patches the compiler interpreter, and configures the environment.
- **Self-Healing Patcher**: Post-execution hooks automatically intercept updates (`rustup update` or `rustup self update`) and patch newly downloaded executables.
- **Incremental Caching**: Binary patching uses modification timestamps (`mtime`) caching to avoid rescanning unchanged compiler binaries, running in less than 5 milliseconds.
- **Python Integration**: Maturin wrapper automatically fixes `RUNPATH` headers on Python native extension `.so` outputs.
- **Fresh Termux Support**: Automatically installs missing tools (`patchelf`, `glibc-runner`, etc.) on a clean Termux environment.
- **Graceful Fallbacks**: Detects and handles missing tools (`grun`, `glibc`, `patchelf`) with clear, actionable error messages.

---

## Why not `pkg install rust`?

You'll get this question a lot. Here's the direct answer:

| Feature | `pkg install rust` | Rustermux |
|---|---|---|
| Official upstream `rustup` | ❌ | ✅ |
| Stable / nightly switching | Limited | ✅ |
| `rustup target add` | ❌ | ✅ |
| Official toolchain binaries | ❌ (Termux rebuild) | ✅ |
| Automatic updates via `rustup` | ❌ | ✅ |
| Works out of the box on Termux | ✅ | ✅ (after install) |

`pkg install rust` ships a Termux-recompiled Rust toolchain that lags behind upstream and lacks `rustup` features. Rustermux runs the **actual** official toolchain distributed by the Rust Project — same binaries, same release schedule, same components.

---

## Limitations

- Supports **aarch64 Termux only** (64-bit ARM Android).
- Requires Termux's `glibc` packages (`glibc`, `glibc-repo`).
- Patches upstream Rust binaries at the ELF level and is therefore **unofficial** — not supported by the Rust Project or Termux maintainers.
- Does **not** provide a native Android host toolchain for `rustup`.
- Existing Bionic-compiled binaries are completely unaffected by Rustermux.

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
│   ├── maturin            # Maturin wrapper for Python native extensions
│   └── auto-patcher.sh    # Startup helper to repair sitecustomize & self-updates
├── docs/
│   ├── architecture.md    # Why we use the GNU target and how it works
│   ├── troubleshooting.md # Guide to fixing common errors
│   └── usage.md           # Instructions on building and usage
└── tests/
    └── validate.sh        # Automated test verification suite
```

---

## How It Works

Rustermux uses `patchelf` to rewrite the ELF interpreter (`PT_INTERP`) of each Rust toolchain binary from the standard glibc path (`/lib/ld-linux-aarch64.so.1`) to the Termux glibc path provided by `glibc-runner`. A post-execution hook wrapper intercepts every `rustup` invocation so that any newly downloaded binaries are automatically patched without user intervention.

For details, see [docs/architecture.md](docs/architecture.md).

---

## Compatibility

### Android Version

| Android Version | Status |
|----------------|--------|
| Android 12 | ✅ Tested |
| Android 13 | ✅ Tested |
| Android 14 | ⚠️ Untested |
| Android 15 | ⚠️ Untested |

### Rust Toolchain & Tooling

| Component | Status |
|-----------|--------|
| Stable Rust | ✅ Supported |
| Nightly Rust | ✅ Supported |
| `rustup update` | ✅ Auto-patched |
| `rustup self update` | ✅ Auto-patched |
| `cargo install` | ✅ Supported |
| `cargo build` | ✅ Supported |
| Maturin | ✅ Supported |

> [!NOTE]
> Only `aarch64` (64-bit ARM) Termux is supported. `x86_64` Android (emulators) and 32-bit ARM are not supported.

---

## Documentation

| Document | Description |
|----------|-------------|
| [architecture.md](docs/architecture.md) | Why we use the GNU target, how the ELF patcher works, and the wrapper hook design |
| [usage.md](docs/usage.md) | Building projects, running binaries, and Maturin integration |
| [troubleshooting.md](docs/troubleshooting.md) | Fixing common errors: missing tools, patchelf failures, RUNPATH issues |

---

## License

This project is dual-licensed under either:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

at your option.

---

<div align="center">

Built with 🦀 by [Seuriin](https://github.com/SSL-ACTX)

</div>
