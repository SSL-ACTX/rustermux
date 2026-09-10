# Rustermux: Troubleshooting Guide

This guide covers common issues, root causes, and fixes when using Rustermux inside Termux.

## 1. Invalid ELF Header (`libc.so`)

### Symptoms

When running `rustup` or `cargo`, you see:

```text
/data/data/com.termux/files/usr/glibc/lib/libc.so: invalid ELF header
```

### Cause

This is caused by Bionic's `LD_PRELOAD` hooks (like `libtermux-exec.so`) remaining active in your environment. When a glibc-compiled binary launches, it attempts to load preloaded Bionic libraries, which in turn pull in Bionic's `libc.so`. The loader searches the binary's `RPATH` first, finds the glibc `libc.so` (which is a GNU linker ASCII text script, not an ELF file), and crashes.

### Solution

Always execute `rustup` and `cargo` using the wrappers installed in `~/.cargo/bin`, which automatically unset `LD_PRELOAD`. Ensure that `~/.cargo/bin` appears early in your `$PATH`.

---

## 2. SSL CA Certificate Verification Failed (Error 20)

### Symptoms

`cargo` commands fail when downloading crates with:

```text
unable to get local issuer certificate (20)
```

### Cause

The Glibc-linked OpenSSL implementation inside cargo does not check Termux's default Android CA certificate locations.

### Solution

Ensure the `SSL_CERT_FILE` environment variable is exported and points to the Glibc CA certificate bundle:

```bash
export SSL_CERT_FILE="/data/data/com.termux/files/usr/glibc/etc/ssl/certs/ca-certificates.crt"
```

This is configured automatically when you source `~/.cargo/env`.

---

## 3. Linker Error: Unable to find `-lgcc_s`

### Symptoms

Compiling any package fails at the link stage with:

```text
/data/data/com.termux/files/usr/bin/ld: cannot find -lgcc_s
```

### Cause

The compiler is using the system linker/compiler instead of the Glibc-compatible one, or the `$PATH` is not set up to prefer the Glibc toolchain binaries for build-time compilation.

### Solution

Make sure the Glibc binary path is prepended to your `$PATH`:

```bash
export PATH="/data/data/com.termux/files/usr/glibc/bin:$PATH"
```

---

## 4. Maturin Builds: `ImportError: dlopen failed: library "libz3.so" not found`

### Symptoms

When trying to import a Python extension compiled with Maturin, it fails with:

```text
ImportError: dlopen failed: library "libz3.so" not found (or similar library)
```

### Cause

Android's Bionic dynamic linker ignores `RPATH` headers on shared libraries and expects `RUNPATH` headers instead.

### Solution

Ensure the compiled `.so` extension has its `RUNPATH` patched to point to `$PREFIX/lib`:

```bash
patchelf --set-rpath /data/data/com.termux/files/usr/lib python/your_extension.so
```

Our `wrappers/maturin` script handles this auto-patching step automatically post-build.

---

## 5. `cargo audit` Panics: `Expect rustls-platform-verifier to be initialized`

### Symptoms

Running `cargo audit` crashes immediately with:

```text
The application panicked (crashed).
Message:  Expect rustls-platform-verifier to be initialized
Location: .../rustls-platform-verifier-.../src/android.rs:90
...
error: couldn't fetch advisory database: git operation failed
```

### Cause

`cargo-audit` bundles `reqwest` as its HTTP client, which uses `rustls-platform-verifier` for TLS certificate verification on Android. That library requires the Android JVM to be initialized — something that never happens inside a Termux shell session — so it panics when `cargo audit` tries to fetch the RustSec advisory database over HTTPS.

### Solution

Rustermux automatically installs a `cargo-audit` wrapper that uses `git` (which has its own working TLS stack in Termux) to maintain a local clone of the advisory database, then runs `cargo audit --no-fetch --db ~/.cargo/advisory-db`. No user action is needed — just run `cargo audit` normally.

If you installed `cargo-audit` **before** running the Rustermux installer, re-run the installer to pick it up, or wrap it manually:

```bash
# One-time fix (if you already have cargo-audit installed)
mv ~/.cargo/bin/cargo-audit ~/.cargo/bin/cargo-audit-real
cp ~/.cargo/bin/cargo-audit-wrapper ~/.cargo/bin/cargo-audit
```

For future `cargo install cargo-audit` runs, the `auto-patcher.sh` startup hook will automatically detect and re-wrap the new binary.
