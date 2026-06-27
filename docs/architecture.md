# Rustermux: Architecture Overview

This document explains the technical architecture, design decisions, and mechanics of the Rustermux Glibc environment.

## 1. Why Use the GNU Host Toolchain?

Android's default system libraries (Bionic `libc`) differ significantly from standard Linux libraries (GNU `libc` or `glibc`). While Android-targeted binaries can run natively on Android devices, compiling Rust *on* the device (host compilation) requires toolchains that are not easily built or distributed for the Bionic environment. 

By targeting `aarch64-unknown-linux-gnu` as the host toolchain:
- We can download and run official, pre-compiled Rust compiler toolchains (`rustc`, `cargo`, `rustup`) directly.
- We avoid compiling the Rust compiler itself from source, which is extremely resource-intensive.
- We leverage Termux's high-quality Glibc package repository (`glibc-repo`).

## 2. Why Avoid Android Host Toolchains?

Standard host-targeted compiler suites assume a Linux FHS (Filesystem Hierarchy Standard) environment.
- Android lacks standard paths like `/lib`, `/usr/bin`, and `/etc`.
- Termux targets Bionic libc, which lacks support for features like `pthread_cancel` or certain dynamic linking properties expected by modern build tools, causing compiler plugins, proc-macros, and cargo subcommands to fail or panic.
- Many crates compile custom build scripts (`build.rs`) using the host compiler. If the host compiler is Bionic, compiling these helper tools becomes extremely fragile.

## 3. How Glibc Integrates with Termux

To execute GNU binaries natively inside Termux's Bionic environment, we use a hybrid model:

```mermaid
graph TD
    A[Bionic / Termux Shell] -->|Invoke rustup| B[~/.cargo/bin/rustup Wrapper]
    B -->|Unsets LD_PRELOAD| C[~/.cargo/bin/rustup-real ELF]
    C -->|Dynamic Linker| D[/usr/glibc/lib/ld-linux-aarch64.so.1]
    D -->|Loads Glibc Libraries| E[/usr/glibc/lib/libc.so.6]
    C -->|Executes rustc / cargo| F[Toolchain compilers]
    F -->|Patched with RPATH| E
```

1. **Glibc Loader and Libraries**: The `glibc` package provides a fully-functional GNU dynamic loader (`ld-linux-aarch64.so.1`) and basic library directory at `/data/data/com.termux/files/usr/glibc`.
2. **Interpreter Patching**: Standard ELF binaries have their interpreter header set to `/lib/ld-linux-aarch64.so.1`. We rewrite this header to point to Termux's glibc loader path using `patchelf`.
3. **Library RPATH**: We set the `RPATH` of the patched binaries to `/data/data/com.termux/files/usr/glibc/lib` so the loader can locate GNU versions of `libc`, `libm`, `libpthread`, and other dependencies.
4. **Environment Wrapper Isolation**: Termux injects `libtermux-exec.so` using `LD_PRELOAD` to transparently rewrite paths. However, this helper library is compiled for Bionic, causing dynamic linking errors inside GNU binaries. The wrapper script solves this by unsetting `LD_PRELOAD` before forwarding executions to the GNU binaries.

## 4. Hook Investigation & Alternatives

We investigated if there are cleaner alternatives to intercepting the `rustup` binary via a custom script in `~/.cargo/bin/rustup`:
- **Shell Aliases/Functions**: Setting `alias rustup='...'` works only in interactive shell environments. Subshells, build scripts, editor LSP servers (like Rust Analyzer), and cargo plugins would bypass the alias and launch the raw glibc binary directly, causing instant crashes due to `LD_PRELOAD` conflicts.
- **Upstream Hooks**: Rustup currently does not support any native client-side config hooks (e.g. `post-update` or `post-install` hooks).
- **Conclusion**: The entry point wrapper script at `~/.cargo/bin/rustup` remains the only robust mechanism to intercept calls from all frontends (interactive, non-interactive, and LSP integrations) and run self-healing patches cleanly.

## 5. Multi-Architecture Support

- **aarch64 (64-bit ARM)**: Fully supported natively via Termux's official `glibc-repo`.
- **x86_64 (64-bit Intel/AMD)**: Partially supported. Termux provides x86_64 glibc libraries, but execution requires an x86_64 host or emulator environment (e.g. inside PRoot or on x86_64 ChromeOS/Android devices).
- **armv7 (32-bit ARM)**: Unsupported. Official Termux glibc packages do not target 32-bit ARM due to library limitations.

