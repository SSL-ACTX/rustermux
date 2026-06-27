# Complete Guide to Rustup on Termux (Android)                
**Author:** Seuriin

This guide provides a comprehensive reference for installing, configuring, patching, and using `rustup` natively inside Termux. Standard Rustup toolchain installations fail in Termux because Android uses Bionic libc instead of glibc, and lacks the FHS file paths expected by Linux executables. By employing Termux's custom Glibc packages, ELF header patching, environment wrapper isolation, and certificate redirection, we can achieve a fully functional and native Rust compiler suite.

---

## Target Version Baseline
This guide was tested and verified using the following system components:
*   **Android Version**: 12
*   **Android API Target**: 28
*   **Termux Version**: 0.119.0-beta.3
*   **Rustup Version**: 1.29.0
*   **Rust & Cargo Version**: 1.96.0
*   **Host Triple**: `aarch64-unknown-linux-gnu`
*   **Glibc Version**: 2.42

## Patch Registry

| Issue / Patch | Required? | Affects | Description / Scope |
| :--- | :--- | :--- | :--- |
| **`$HOME` directory mismatch** | Yes | `rustup-init` | Bionic `getpwuid_r` returns `/data` instead of Termux `$HOME`. Bypassed via `-y` flag. |
| **`rustls-platform-verifier` JNI panic** | Yes | Network calls | Android-target toolchains try to verify certificates via Java JNI. Resolved by using standard GNU target. |
| **Glibc Loader mismatch** | Yes | Compiler suite | Executables expect `/lib/ld-linux-aarch64.so.1`. Patched to use Termux's glibc loader prefix. |
| **Wrapper `ld.so` self-copy bug** | Yes | Rustup install | Running under `grun` redirects `/proc/self/exe` to `ld.so`. Resolved by manually copying installer. |
| **`LD_PRELOAD` conflict** | Yes | Native runtime | Bionic's `libtermux-exec.so` pulls in Bionic `libc.so`, causing glibc binaries to crash. Unset via wrapper script. |
| **`-lgcc_s` Linker error** | Yes | Cargo builds | Default clang compiles for Android. Prepend `gcc-glibc` to path to link with glibc by default. |
| **OpenSSL CA file verification (20)** | Yes | Cargo network | Glibc openssl searches `/etc/ssl/certs/ca-certificates.crt`. Redirected via `SSL_CERT_FILE`. |
| **Toolchain Update Persistence** | Yes | Toolchain Updates | Updates replace compiler binaries with unpatched ones. Resolved via self-healing post-exec wrapper hook. |

---

## 1. Prerequisites and Setup

Before installing Rustup, ensure your Termux has the Glibc repository enabled and all required dynamic loaders and compilers are installed:

```bash
pkg update
pkg install glibc-repo
pkg install glibc glibc-runner patchelf-glibc binutils-glibc gcc-glibc ca-certificates-glibc
```

*   **`glibc-repo`**: Registers the Termux Glibc package pool.
*   **`glibc` / `glibc-runner`**: Installs the GNU C Library (v2.42) and the `grun` execution wrapper.
*   **`patchelf-glibc`**: Utility for rewriting ELF interpreter headers and RPATH runpaths.
*   **`gcc-glibc`**: Native Glibc compiler toolchain required for cargo build-scripts and C-dependencies.
*   **`ca-certificates-glibc`**: Certificate authority bundle compiled for the glibc environment.

---

## 2. Compilation and Linkage Reference

Android's Bionic C library and directory structure differ significantly from Linux glibc. Understanding these differences allows us to patch the binaries for native execution.

### A. The `$HOME` Mismatch Check
By default, `rustup-init` checks if `$HOME` matches the database entry for the current UID. On Android, `getpwuid_r` returns `/data` as the home directory, leading to a fatal mismatch warning.
Passing `-y` to the installer downgrades this condition to a warning, allowing the installation to proceed.

### B. Bypassing Java JNI Panic (`rustls-platform-verifier`)
On Android targets, Rust networking packages rely on `rustls-platform-verifier` which calls Android's platform trust APIs using JNI (Java Native Interface). Since native terminal processes run without an active Dalvik/ART JVM, this call panics immediately.
*   **Solution**: Do not install target `aarch64-linux-android`. Use the standard GNU target `aarch64-unknown-linux-gnu` instead.

### C. Rewriting ELF Headers
Because `/lib/ld-linux-aarch64.so.1` is not present in standard Android, the kernel will fail to run GNU binaries with a "No such file or directory" error. We must patch the interpreter and library runpath (`RPATH`) of the executables to use Termux's glibc files:
```bash
patchelf --set-interpreter /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 \
         --set-rpath /data/data/com.termux/files/usr/glibc/lib \
         /path/to/binary
```

### D. Resolving `LD_PRELOAD` Library Conflicts
Termux preloads `/data/data/com.termux/files/usr/lib/libtermux-exec.so` globally. When a glibc binary executes:
1. The glibc dynamic linker starts up and reads the `LD_PRELOAD` variable.
2. It attempts to load Bionic's `libtermux-exec.so`, which requests `libc.so`.
3. The glibc linker searches the binary's `RPATH` (`/data/data/com.termux/files/usr/glibc/lib`) and finds `libc.so` (which is a GNU linker ASCII script instead of an ELF binary).
4. The loader attempts to parse it and fails with `invalid ELF header`.
*   **Solution**: Wrap the entry points in a shell script that unsets `LD_PRELOAD` before invoking the real binary.

### E. Persistence and Self-Healing Wrapper Hook
When you run `rustup update`, `rustup` downloads standard, unpatched GNU executables and overwrites your toolchain binaries (`rustc`, `cargo`, etc.), causing them to break on the next execution.
To achieve seamless persistence, we modify the `~/.cargo/bin/rustup` wrapper script to act as a **post-execution hook**. When it detects changes to your toolchains, targets, or updates, it scans `~/.rustup/toolchains/*/bin/*` and automatically patches any new or modified ELF binaries on the fly.

---

## 3. Step-by-Step Installation and Patching

### Step 1: Download the GNU Installer
Download the `aarch64-unknown-linux-gnu` target installer:
```bash
curl -sSf https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init -o rustup-init-gnu
chmod +x rustup-init-gnu
```

### Step 2: Install via `grun`
Run the installer inside the Glibc runner wrapper, overriding the host architecture:
```bash
grun ./rustup-init-gnu -y --default-host aarch64-unknown-linux-gnu
```
*(This downloads the rustup environment and toolchain, placing them in `~/.cargo/bin` and `~/.rustup`).*

### Step 3: Resolve the `/proc/self/exe` Copy Bug
Because the installer was run under `grun` (which executes `ld.so <binary>`), the installer's check to copy itself copy-pasted the `ld.so` binary over `~/.cargo/bin/rustup`. Manually replace it with the actual installer:
```bash
cp rustup-init-gnu ~/.cargo/bin/rustup-real
rm -f rustup-init-gnu
```

### Step 4: Configure the Entry Point Wrapper with Self-Healing Hook
Create the wrapper script at `~/.cargo/bin/rustup` that unsets `LD_PRELOAD`, forwards parameters, and triggers the `patchelf` self-healing hook on updates:
```bash
cat << 'EOF' > ~/.cargo/bin/rustup
#!/data/data/com.termux/files/usr/bin/bash
unset LD_PRELOAD

# Run the real rustup binary, preserving argv[0] via bash's exec -a
bash -c 'exec -a "$0" "/data/data/com.termux/files/home/.cargo/bin/rustup-real" "$@"' "$0" "$@"
EXIT_CODE=$?

# If the command was a toolchain update, install, target modification, or default change, auto-patch
case "$*" in
    *update*|*install*|*add*|*default*|*toolchain*)
        echo "Post-execution hook: Auto-patching toolchain binaries..."
        for f in ~/.rustup/toolchains/*/bin/*; do
            if [ -f "$f" ] && [ -x "$f" ]; then
                # Check if it is an ELF binary and does not point to Termux glibc yet
                if file "$f" 2>/dev/null | grep -q "ELF" && ! patchelf --print-interpreter "$f" 2>/dev/null | grep -q "glibc" ; then
                    patchelf --set-interpreter /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 \
                             --set-rpath /data/data/com.termux/files/usr/glibc/lib \
                             "$f" 2>/dev/null && echo "  Patched: $(basename "$f")" || true
                fi
            fi
        done
        ;;
esac

exit $EXIT_CODE
EOF
chmod +x ~/.cargo/bin/rustup
```

### Step 5: Patch the Initial Suite
Patch the real `rustup-real` manager and all downloaded compilers using `patchelf` for their first run:
```bash
# Patch the manager
patchelf --set-interpreter /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 \
         --set-rpath /data/data/com.termux/files/usr/glibc/lib \
         ~/.cargo/bin/rustup-real

# Patch the toolchain compiler binaries
for f in ~/.rustup/toolchains/stable-aarch64-unknown-linux-gnu/bin/*; do
  if [ -f "$f" ] && [ -x "$f" ]; then
    patchelf --set-interpreter /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 \
             --set-rpath /data/data/com.termux/files/usr/glibc/lib \
             "$f" || true
  fi
done
```

---

## 4. Environment Configuration

To allow `rustc` to call the glibc-linked C linker (`cc`/`gcc`) and verify SSL certs during cargo downloads, update your `~/.cargo/env` script with these entries:

```bash
# Append to ~/.cargo/env

# Termux Glibc userland integration
case ":${PATH}:" in
    *:"/data/data/com.termux/files/usr/glibc/bin":*)
        ;;
    *)
        export PATH="/data/data/com.termux/files/usr/glibc/bin:$PATH"
        ;;
esac
export SSL_CERT_FILE="/data/data/com.termux/files/usr/glibc/etc/ssl/certs/ca-certificates.crt"
```

To configure your current shell:
```bash
. "$HOME/.cargo/env"
```

---

## 5. Global Cargo & Python Extension Setup (Maturin)

When compiling Rust code or Python native extensions inside Termux, we want targets to default to the native Bionic target (`aarch64-linux-android`) and dynamically link libraries like `libz3.so` cleanly.

### A. Global Cargo Configuration
Create a global configuration file at `~/.cargo/config.toml` so that every cargo project defaults to the Bionic target and links correctly:

```toml
[build]
target = "aarch64-linux-android"

[target.aarch64-linux-android]
linker = "/data/data/com.termux/files/usr/bin/clang"
rustflags = ["-C", "link-arg=-Wl,-rpath,/data/data/com.termux/files/usr/lib", "-C", "link-arg=-Wl,--enable-new-dtags"]
```
*   **`target = "aarch64-linux-android"`**: Forces Cargo to compile for Bionic natively by default.
*   **`linker = ...`**: Directs Cargo to compile using Termux's system `clang` instead of glibc `gcc`.
*   **`--enable-new-dtags`**: Emits `RUNPATH` headers instead of `RPATH`, enabling Android's dynamic linker to search `/data/data/com.termux/files/usr/lib` for dependency libraries.

### B. Transparent Maturin Wrapper & Post-Build Hook
Maturin is a glibc binary when built under our toolchain, requiring `LD_PRELOAD` to be cleared. We wrap the global `/data/data/com.termux/files/usr/bin/maturin` binary. 
The wrapper also acts as a **post-build hook** that automatically scans the project for output `.so` files and runs `patchelf` to write the required Bionic `RUNPATH` tag:

```bash
#!/data/data/com.termux/files/usr/bin/bash
unset LD_PRELOAD
export CARGO_INCREMENTAL=0
export SSL_CERT_FILE="/data/data/com.termux/files/usr/glibc/etc/ssl/certs/ca-certificates.crt"
export PATH="/data/data/com.termux/files/usr/glibc/bin:$PATH"

/data/data/com.termux/files/usr/bin/maturin-real "$@"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    find python -name "*.so" 2>/dev/null | while read -r f; do
        if [ -f "$f" ] && [ -x "$f" ]; then
            if file "$f" 2>/dev/null | grep -q "ELF"; then
                patchelf --set-rpath /data/data/com.termux/files/usr/lib "$f" 2>/dev/null && \
                echo "[Maturin Wrapper] Automatically patched RUNPATH of: $(basename "$f")" || true
            fi
        fi
    done
fi

exit $EXIT_CODE
```

### C. Background Self-Healing Patcher
When pip upgrades or reinstalls `maturin`, it overwrites the wrapper with the raw ELF binary. Similarly, Python package upgrades can overwrite or remove `sitecustomize.py` platform spoofing settings. We use a background startup checker script at `~/.cargo/bin/auto-patcher.sh` to self-heal both:

```bash
#!/data/data/com.termux/files/usr/bin/bash

# Safeguard: Only run if executing inside Termux
if [ -z "$TERMUX_VERSION" ] && [ ! -d /data/data/com.termux ]; then
    exit 0
fi

# 1. Manage sitecustomize.py for platform spoofing (globally and in Lirien's virtualenv)
find /data/data/com.termux/files/usr/lib -maxdepth 3 -type d -path "*/python*/site-packages" 2>/dev/null | while read -r site_pkg_dir; do
    site_cust="$site_pkg_dir/sitecustomize.py"
    if [ ! -f "$site_cust" ] || ! grep -q "sys.platform = 'linux'" "$site_cust"; then
        cat << 'EOF' > "$site_cust"
import sys
sys.platform = 'linux'
import platform
platform.system = lambda: 'Linux'
try:
    m = __import__('_sysconfigdata__android_aarch64-linux-android')
    sys.modules['_sysconfigdata__linux_aarch64-linux-android'] = m
except ImportError:
    pass
EOF
    fi
done

# Find and patch site-packages in any active or local virtualenvs dynamically
VENVS=()
[ -n "$VIRTUAL_ENV" ] && VENVS+=("$VIRTUAL_ENV")
[ -d "$PWD/.venv" ] && VENVS+=("$PWD/.venv")
[ -d "$PWD/venv" ] && VENVS+=("$PWD/venv")
[ -d "$PWD/env" ] && VENVS+=("$PWD/env")

for venv_path in "${VENVS[@]}"; do
    find "$venv_path" -maxdepth 4 -type d -path "*/site-packages" 2>/dev/null | while read -r site_pkg_dir; do
        site_cust="$site_pkg_dir/sitecustomize.py"
        if [ ! -f "$site_cust" ] || ! grep -q "sys.platform = 'linux'" "$site_cust"; then
            cat << 'EOF' > "$site_cust"
import sys
sys.platform = 'linux'
import platform
platform.system = lambda: 'Linux'
try:
    m = __import__('_sysconfigdata__android_aarch64-linux-android')
    sys.modules['_sysconfigdata__linux_aarch64-linux-android'] = m
except ImportError:
    pass
EOF
        fi
    done
done

# 2. Manage glibc binaries wrapping (e.g. maturin)
BINARIES=(
    "/data/data/com.termux/files/usr/bin/maturin|maturin-real"
)

for entry in "${BINARIES[@]}"; do
    IFS="|" read -r bin_path real_name <<< "$entry"
    if [ -f "$bin_path" ] && [ -x "$bin_path" ]; then
        if file "$bin_path" 2>/dev/null | grep -q "ELF"; then
            if patchelf --print-interpreter "$bin_path" 2>/dev/null | grep -q "glibc"; then
                dir_path=$(dirname "$bin_path")
                real_path="$dir_path/$real_name"
                mv "$bin_path" "$real_path"
                cat << 'EOF' > "$bin_path"
#!/data/data/com.termux/files/usr/bin/bash
unset LD_PRELOAD
export CARGO_INCREMENTAL=0
export SSL_CERT_FILE="/data/data/com.termux/files/usr/glibc/etc/ssl/certs/ca-certificates.crt"
export PATH="/data/data/com.termux/files/usr/glibc/bin:$PATH"

/data/data/com.termux/files/usr/bin/maturin-real "$@"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    find python -name "*.so" 2>/dev/null | while read -r f; do
        if [ -f "$f" ] && [ -x "$f" ]; then
            if file "$f" 2>/dev/null | grep -q "ELF"; then
                patchelf --set-rpath /data/data/com.termux/files/usr/lib "$f" 2>/dev/null && \
                echo "[Maturin Wrapper] Automatically patched RUNPATH of: $(basename "$f")" || true
            fi
        fi
    done
fi

exit $EXIT_CODE
EOF
                chmod +x "$bin_path"
            fi
        fi
    fi
done
```

Enable the checker silently in `~/.bashrc` and `~/.zshrc`:
```bash
[ -f ~/.cargo/bin/auto-patcher.sh ] && ~/.cargo/bin/auto-patcher.sh &>/dev/null &
```

---

## 6. Troubleshooting & FAQs

### Q: Why does running `rustc` give `/data/data/com.termux/files/usr/glibc/lib/libc.so: invalid ELF header`?
**A**: This is caused by `LD_PRELOAD` carrying Bionic's `libtermux-exec.so` which tries to load `libc.so`. The loader resolves this to the ASCII linker script in the glibc lib folder. Make sure you run your commands through the `~/.cargo/bin/rustup` wrapper, which unsets `LD_PRELOAD`.

### Q: Why do cargo downloads fail with `unable to get local issuer certificate (20)`?
**A**: The glibc openssl build inside cargo does not check Termux's standard Bionic cert directories. Ensure that the `SSL_CERT_FILE` environment variable is exported and points to `/data/data/com.termux/files/usr/glibc/etc/ssl/certs/ca-certificates.crt`.

### Q: Why does my compilation fail with `unable to find library -lgcc_s`?
**A**: Rust is attempting to use the default Bionic compiler wrapper `cc`. Ensure `/data/data/com.termux/files/usr/glibc/bin` is prepended to your `$PATH` so the glibc-native GCC compiles and links the compilation binaries.

### Q: Why does Python import fail with `ImportError: dlopen failed: library "libz3.so" not found`?
**A**: Android's Bionic dynamic linker ignores standard `RPATH` headers on shared libraries. Ensure that the `.so` has been patched via `patchelf --set-rpath /data/data/com.termux/files/usr/lib <file>` to convert the tag to a `RUNPATH` header. The wrapper `maturin` handles this automatically post-build.

