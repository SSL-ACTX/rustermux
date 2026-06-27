# Rustermux: Troubleshooting Guide

This guide covers common issues, root causes, and fixes when using Rustermux inside Termux.

## 1. Invalid ELF Header (`libc.so`)

### Symptoms
When running `rustup` or `cargo`, you see:
```
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
```
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
```
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
```
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
