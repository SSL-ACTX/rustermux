# Rustermux: Usage Guide

This guide covers daily workflows, compiling binaries, target management, and virtual environment integration with Rustermux.

## 1. Quick Start

Ensure your environment is set up by sourcing the environment configuration:

```bash
source ~/.cargo/env
```

## 2. Managing Toolchains

The entry point wrapper for `rustup` intercepts updates and auto-patches newly downloaded binaries on the fly:

```bash
# Update the toolchain
rustup update

# Add a target
rustup target add aarch64-unknown-linux-gnu
```

## 3. Cargo Projects

By default, the installer configures Cargo (`~/.cargo/config.toml`) to compile for Bionic (`aarch64-linux-android`) natively.

### Creating a New Project

```bash
cargo new hello_world
cd hello_world
```

### Running and Building

```bash
cargo run
cargo build --release
```

### Cross-compiling back to Glibc

If you want to compile a binary to run specifically under the glibc runner (`grun`), override the build target:

```bash
cargo build --target aarch64-unknown-linux-gnu
```

## 4. Python Integration (Maturin)

When working on Python extensions:

1. Ensure the `auto-patcher.sh` is active (runs automatically on shell login).
2. Use `maturin` normally. The wrapper intercepts the build and patches the compiled `.so` output files.
