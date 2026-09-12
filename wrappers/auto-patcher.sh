#!/data/data/com.termux/files/usr/bin/bash
# wrappers/auto-patcher.sh - Background startup checker for environment configuration and wrapping

# Safeguard: Only run if executing inside Termux
if [ -z "$TERMUX_VERSION" ] && [ ! -d /data/data/com.termux ]; then
    exit 0
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    _B='\033[1m' _G='\033[92m' _Y='\033[33m' _R='\033[31m' _0='\033[0m'
else
    _B='' _G='' _Y='' _R='' _0=''
fi
status() { printf "${_B}${_G}%12s${_0} %s\n" "$1" "$2"; }
warn()   { printf "${_B}${_Y}warning${_0}: %s\n" "$1" >&2; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CARGO_HOME="${CARGO_HOME:-$HOME_DIR/.cargo}"
CARGO_BIN_DIR="$CARGO_HOME/bin"

# 1. Manage sitecustomize.py and _sysconfigdata symlinks for platform spoofing
find "$PREFIX/lib" -maxdepth 2 -type d -name "python3.*" 2>/dev/null | while read -r py_dir; do
    # Deploy sitecustomize.py to both standard library root and site-packages
    for target_dir in "$py_dir" "$py_dir/site-packages"; do
        if [ -d "$target_dir" ]; then
            site_cust="$target_dir/sitecustomize.py"
            if [ ! -f "$site_cust" ] || ! grep -q "sys.platform = 'linux'" "$site_cust"; then
                cat << 'EOF' > "$site_cust"
import sys
sys.platform = 'linux'
import platform
platform.system = lambda: 'Linux'
try:
    m = __import__('_sysconfigdata__android_aarch64-linux-android')
    sys.modules['_sysconfigdata__linux_aarch64-linux-android'] = m
    sys.modules['_sysconfigdata__linux_aarch64-linux-gnu'] = m
    sys.modules['_sysconfigdata__aarch64-linux-android'] = m
except ImportError:
    pass
EOF
            fi
        fi
    done

    # Ensure compatibility symlinks for _sysconfigdata
    if [ -f "$py_dir/_sysconfigdata__android_aarch64-linux-android.py" ]; then
        for alias in "_sysconfigdata__linux_aarch64-linux-android.py" "_sysconfigdata__linux_aarch64-linux-gnu.py" "_sysconfigdata__aarch64-linux-android.py"; do
            [ -e "$py_dir/$alias" ] || ln -sf "_sysconfigdata__android_aarch64-linux-android.py" "$py_dir/$alias" 2>/dev/null || true
        done
    fi
done

# Manage PyO3 configuration for CPython builds
PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "")
if [ -n "$PY_VER" ]; then
    PYO3_CFG="$HOME_DIR/.cargo/pyo3.config"
    # Only rewrite if version changed or file is missing.
    if ! grep -q "^version=$PY_VER$" "$PYO3_CFG" 2>/dev/null; then
        cat << EOF > "$PYO3_CFG"
implementation=CPython
version=$PY_VER
shared=true
abi3=false
lib_name=python$PY_VER
lib_dir=$PREFIX/lib
pointer_width=64
build_flags=
suppress_build_script_link_lines=false
EOF
    fi
fi

# Find and patch site-packages in any active or local virtualenvs dynamically
VENV_BASES=()
# Only check PWD-relative venvs if we're inside a project directory, not $HOME.
if [ "$PWD" != "$HOME_DIR" ]; then
    VENV_BASES+=("$PWD/.venv" "$PWD/venv" "$PWD/env")
fi
[ -n "$VIRTUAL_ENV" ] && VENV_BASES+=("$VIRTUAL_ENV")
[ -d "$HOME_DIR/.virtualenvs" ] && VENV_BASES+=("$HOME_DIR/.virtualenvs")
[ -d "$HOME_DIR/.cache/pypoetry/virtualenvs" ] && VENV_BASES+=("$HOME_DIR/.cache/pypoetry/virtualenvs")
[ -d "$HOME_DIR/.local/share/virtualenvs" ] && VENV_BASES+=("$HOME_DIR/.local/share/virtualenvs")
[ -d "$HOME_DIR/.cache/hatch/env/virtual" ] && VENV_BASES+=("$HOME_DIR/.cache/hatch/env/virtual")

for base in "${VENV_BASES[@]}"; do
    if [ -d "$base" ]; then
        find "$base" -maxdepth 4 -type d -path "*/site-packages" 2>/dev/null | while read -r site_pkg_dir; do
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
    fi
done

# 2. Manage glibc binaries wrapping (e.g. maturin, cargo-audit)
BINARIES=(
    "$PREFIX/bin/maturin|maturin-real"
)

# Also wrap cargo-installed glibc binaries in ~/.cargo/bin
CARGO_BINARIES=(
    "$HOME_DIR/.cargo/bin/cargo-audit|cargo-audit-real"
)

for entry in "${BINARIES[@]}"; do
    IFS="|" read -r bin_path real_name <<< "$entry"
    if [ -f "$bin_path" ] && [ -x "$bin_path" ]; then
        if [ "$(head -c 4 "$bin_path" 2>/dev/null)" = $'\x7fELF' ]; then
            if patchelf --print-interpreter "$bin_path" 2>/dev/null | grep -q "glibc"; then
                dir_path=$(dirname "$bin_path")
                real_path="$dir_path/$real_name"
                mv "$bin_path" "$real_path"
                cat << EOF > "$bin_path"
#!/data/data/com.termux/files/usr/bin/bash
unset LD_PRELOAD
export CARGO_INCREMENTAL=0
export SSL_CERT_FILE="$GLIBC_PREFIX/etc/ssl/certs/ca-certificates.crt"
export PATH="$GLIBC_PREFIX/bin:\$PATH"

"$PREFIX/bin/maturin-real" "\$@"
EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ]; then
    find python -name "*.so" 2>/dev/null | while read -r f; do
        if [ -f "\$f" ] && [ -x "\$f" ]; then
            if [ "\$(head -c 4 "\$f" 2>/dev/null)" = $'\x7fELF' ]; then
                patchelf --set-rpath "$PREFIX/lib" "\$f" 2>/dev/null && \\
                echo "[Maturin Wrapper] Automatically patched RUNPATH of: \$(basename "\$f")" || true
            fi
        fi
    done
fi

exit \$EXIT_CODE
EOF
                chmod +x "$bin_path"
            fi
        fi
    fi
done

# Process cargo-installed binaries that need wrapping (e.g. cargo-audit)
for entry in "${CARGO_BINARIES[@]}"; do
    IFS="|" read -r bin_path real_name <<< "$entry"
    if [ -f "$bin_path" ] && [ -x "$bin_path" ]; then
        # Only act if it's an ELF (not already a shell wrapper)
        if [ "$(head -c 4 "$bin_path" 2>/dev/null)" = $'\x7fELF' ]; then
            dir_path=$(dirname "$bin_path")
            real_path="$dir_path/$real_name"
            wrapper_src="$CARGO_BIN_DIR/$(basename "$bin_path")-wrapper"
            # Check if wrapper script is available in cargo bin dir
            if [ -f "$wrapper_src" ]; then
                mv "$bin_path" "$real_path"
                cp "$wrapper_src" "$bin_path"
                chmod +x "$bin_path"
                status "Wrapped" "$(basename "$bin_path")"
            fi
        fi
    fi
done

# 3. Manage rustup self-update wrapping
RUSTUP_BIN="$CARGO_BIN_DIR/rustup"
RUSTUP_REAL="$CARGO_BIN_DIR/rustup-real"

if [ -f "$RUSTUP_BIN" ] && [ -x "$RUSTUP_BIN" ]; then
    if [ "$(head -c 4 "$RUSTUP_BIN" 2>/dev/null)" = $'\x7fELF' ]; then
        # It was overwritten by self-update, rename it
        mv "$RUSTUP_BIN" "$RUSTUP_REAL"
        
        # Patch the new rustup-real
        if [ -f "$CARGO_BIN_DIR/patch.sh" ]; then
            "$CARGO_BIN_DIR/patch.sh" "$RUSTUP_REAL"
        else
            ARCH="$(uname -m)"
            [ "$RUSTERMUX_ARCH" = "arm32" ] || [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armv8l" ] || [ "$ARCH" = "arm" ] && DEFAULT_LOADER="ld-linux-armhf.so.3" || DEFAULT_LOADER="ld-linux-aarch64.so.1"
            LOCAL_INTERPRETER="$GLIBC_PREFIX/lib/$DEFAULT_LOADER"
            patchelf --set-interpreter "$LOCAL_INTERPRETER" \
                     --set-rpath "$GLIBC_PREFIX/lib" \
                     "$RUSTUP_REAL" 2>/dev/null || true
        fi
        
        # Recreate the wrapper
        cat << 'EOF_RUSTUP' > "$RUSTUP_BIN"
#!/data/data/com.termux/files/usr/bin/bash
# wrappers/rustup - Entry point wrapper for rustup with post-exec hook.

# Prevent LD_PRELOAD conflicts (e.g. libtermux-exec.so)
unset LD_PRELOAD

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    _B='\033[1m' _G='\033[92m' _Y='\033[33m' _R='\033[31m' _0='\033[0m'
else
    _B='' _G='' _Y='' _R='' _0=''
fi
status() { printf "${_B}${_G}%12s${_0} %s\n" "$1" "$2"; }
warn()   { printf "${_B}${_Y}warning${_0}: %s\n" "$1" >&2; }
err()    { printf "${_B}${_R}error${_0}: %s\n" "$1" >&2; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
export SSL_CERT_FILE="$GLIBC_PREFIX/etc/ssl/certs/ca-certificates.crt"
export PATH="$GLIBC_PREFIX/bin:$PATH"

# Determine user's home directory
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CARGO_HOME="${CARGO_HOME:-$HOME_DIR/.cargo}"
RUSTUP_HOME="${RUSTUP_HOME:-$HOME_DIR/.rustup}"
CARGO_BIN="$CARGO_HOME/bin"
RUSTUP_REAL="$CARGO_BIN/rustup-real"

# Verify prerequisites are available at runtime
MISSING_DEPS=()
if ! command -v grun >/dev/null 2>&1 && ! command -v qemu-arm >/dev/null 2>&1; then
    MISSING_DEPS+=("glibc-runner or qemu-user-arm")
fi
RPATH="$GLIBC_PREFIX/lib"
ARCH="$(uname -m)"
if [ "$RUSTERMUX_ARCH" = "arm32" ] || [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armv8l" ] || [ "$ARCH" = "arm" ]; then
    DEFAULT_LOADER="ld-linux-armhf.so.3"
else
    DEFAULT_LOADER="ld-linux-aarch64.so.1"
fi
if [ -f "$RPATH/$DEFAULT_LOADER" ]; then
    INTERPRETER="$RPATH/$DEFAULT_LOADER"
else
    INTERPRETER="${GLIBC_PREFIX}/lib/${DEFAULT_LOADER}"
fi
if [ ! -f "$INTERPRETER" ]; then
    MISSING_DEPS+=("glibc")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    err "missing dependencies: ${MISSING_DEPS[*]}"
    printf "  run: pkg install -y glibc glibc-runner patchelf-glibc\n" >&2
    echo ""
    exit 1
fi

BIN_NAME="$(basename "$0")"

# Detect whether RUSTUP_REAL is 32-bit ARM or 64-bit ARM (aarch64)
# If 32-bit ARM ELF, run through qemu-arm emulator
ELF_CLASS=$(file -b "$RUSTUP_REAL" 2>/dev/null || echo "")
if echo "$ELF_CLASS" | grep -q "32-bit"; then
    if command -v qemu-arm >/dev/null 2>&1; then
        GLIBC32_PATH="$GLIBC_PREFIX/lib32"
        [ -d "$GLIBC32_PATH" ] || GLIBC32_PATH="$GLIBC_PREFIX"
        if [ "$BIN_NAME" = "rustc" ]; then
            pipe=$(mktemp -u "$PREFIX/tmp/rustc_status.XXXXXX")
            mkfifo "$pipe"
            grep -v -F "hard linking files in the incremental compilation cache failed" < "$pipe" >&2 &
            filter_pid=$!
            qemu-arm -0 "$0" -L "$GLIBC32_PATH" "$RUSTUP_REAL" "$@" 2> "$pipe"
            EXIT_CODE=$?
            exec 2>&-
            wait "$filter_pid" 2>/dev/null || true
            rm -f "$pipe"
        else
            qemu-arm -0 "$0" -L "$GLIBC32_PATH" "$RUSTUP_REAL" "$@"
            EXIT_CODE=$?
        fi
    else
        err "32-bit ARM requires qemu-arm — pkg install qemu-user-arm"
        exit 1
    fi
else
    # 64-bit ARM (aarch64) - preserve argv[0] via bash's exec -a
    if [ "$BIN_NAME" = "rustc" ]; then
        pipe=$(mktemp -u "$PREFIX/tmp/rustc_status.XXXXXX")
        mkfifo "$pipe"
        grep -v -F "hard linking files in the incremental compilation cache failed" < "$pipe" >&2 &
        filter_pid=$!
        bash -c 'exec -a "$0" "'"$RUSTUP_REAL"'" "$@"' "$0" "$@" 2> "$pipe"
        EXIT_CODE=$?
        exec 2>&-
        wait "$filter_pid" 2>/dev/null || true
        rm -f "$pipe"
    else
        bash -c 'exec -a "$0" "'"$RUSTUP_REAL"'" "$@"' "$0" "$@"
        EXIT_CODE=$?
    fi
fi

# Post-execution hook: only meaningful when invoked as rustup, not as cargo/rustfmt/etc.
if [ "$(basename "$0")" = "rustup" ]; then
    case "$*" in
        *update*|*install*|*add*|*default*|*toolchain*)
            status "Patching" "toolchain binaries"

            if ! command -v patchelf >/dev/null 2>&1; then
                warn "patchelf not found, skipping patch — pkg install patchelf-glibc"
            elif [ -f "$CARGO_BIN/patch.sh" ]; then
                while read -r toolchain_dir; do
                    if [ -d "$toolchain_dir" ]; then
                        "$CARGO_BIN/patch.sh" "$toolchain_dir"
                    fi
                done < <(find "$RUSTUP_HOME/toolchains" -type d -name "bin" 2>/dev/null)
            else
                # Fallback inline patching logic if patch.sh is not found
                PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
                GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
                RPATH="$GLIBC_PREFIX/lib"
                INTERPRETER=$(find "$RPATH" -maxdepth 1 -name "ld-linux-*.so.*" 2>/dev/null | head -n 1)
                INTERPRETER="${INTERPRETER:-$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1}"

                while read -r toolchain_dir; do
                    for f in "$toolchain_dir"/*; do
                        if [ -f "$f" ] && [ -x "$f" ]; then
                            if [ "$(head -c 4 "$f" 2>/dev/null)" = $'\x7fELF' ] && ! patchelf --print-interpreter "$f" 2>/dev/null | grep -q "glibc" ; then
                                patchelf --set-interpreter "$INTERPRETER" \
                                         --set-rpath "$RPATH" \
                                         "$f" 2>/dev/null && status "Patched" "$(basename "$f")" || true
                            fi
                        fi
                    done
                done < <(find "$RUSTUP_HOME/toolchains" -type d -name "bin" 2>/dev/null)
            fi
            ;;
    esac
fi

exit $EXIT_CODE
EOF_RUSTUP
        chmod +x "$RUSTUP_BIN"
        status "Recovered" "rustup wrapper after self-update"
    fi
fi

# 4. Manage build accelerator integration in ~/.cargo/config.toml
CARGO_CONFIG="$CARGO_HOME/config.toml"
if [ -f "$CARGO_CONFIG" ]; then
    # If rustc-wrapper is installed but not configured, configure it
    if [ -f "$CARGO_BIN_DIR/rustc-wrapper" ] && ! grep -q "rustc-wrapper" "$CARGO_CONFIG" 2>/dev/null; then
        sed -i '/^\[build\]/a rustc-wrapper = "'"$CARGO_BIN_DIR"'/rustc-wrapper"' "$CARGO_CONFIG" 2>/dev/null || true
    fi
    # If mold is installed and not yet in rustflags, add -fuse-ld=mold
    if command -v mold >/dev/null 2>&1; then
        if grep -q "rustflags" "$CARGO_CONFIG" 2>/dev/null && ! grep -q -- "-fuse-ld=mold" "$CARGO_CONFIG" 2>/dev/null; then
            sed -i 's/rustflags = \[/rustflags = ["-C", "link-arg=-fuse-ld=mold", /' "$CARGO_CONFIG" 2>/dev/null || true
        fi
    fi
    # Ensure profile.dev optimizations are present
    if ! grep -q '\[profile\.dev\]' "$CARGO_CONFIG" 2>/dev/null; then
        cat << 'EOF' >> "$CARGO_CONFIG"

[profile.dev]
debug = 1
split-debuginfo = "unpacked"
EOF
    fi
fi

# 5. Ensure native C/C++ cross-compilation toolchain shims are active in ~/.cargo/env
CARGO_ENV="$CARGO_HOME/env"
if [ -f "$CARGO_ENV" ] && ! grep -q "CC_aarch64_linux_android" "$CARGO_ENV" 2>/dev/null; then
    cat << 'EOF' >> "$CARGO_ENV"

# Native C/C++ cross-compilation toolchain shims for cc-rs and cmake
export CC_aarch64_linux_android="$PREFIX/bin/clang"
export CXX_aarch64_linux_android="$PREFIX/bin/clang++"
export AR_aarch64_linux_android="$PREFIX/bin/llvm-ar"
export CFLAGS_aarch64_linux_android="-I$PREFIX/include"
export CXXFLAGS_aarch64_linux_android="-I$PREFIX/include"

# Auto-tune compiler parallelism for mobile big.LITTLE architectures (avoid thermal throttling)
if [ -z "$CARGO_BUILD_JOBS" ]; then
    _CORES=$(nproc 2>/dev/null || echo 4)
    if [ "$_CORES" -gt 4 ]; then
        export CARGO_BUILD_JOBS=$(( _CORES > 6 ? 6 : _CORES ))
    fi
fi

# Mobile-safe disk cache cap for sccache (default 2GB instead of 10GB)
export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-2G}"
export SCCACHE_DIR="${SCCACHE_DIR:-$HOME/.cache/sccache}"
EOF
fi

