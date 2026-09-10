#!/data/data/com.termux/files/usr/bin/bash
# wrappers/auto-patcher.sh - Background startup checker for environment configuration and wrapping

# Safeguard: Only run if executing inside Termux
if [ -z "$TERMUX_VERSION" ] && [ ! -d /data/data/com.termux ]; then
    exit 0
fi

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CARGO_BIN_DIR="$HOME_DIR/.cargo/bin"

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

# Find and patch site-packages in any active or local virtualenvs dynamically
VENV_BASES=("$PWD/.venv" "$PWD/venv" "$PWD/env")
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
                echo "[auto-patcher] Wrapped $(basename "$bin_path") -> $real_name using $wrapper_src"
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
if ! command -v patchelf >/dev/null 2>&1; then
    MISSING_DEPS+=("patchelf-glibc")
fi
if ! command -v grun >/dev/null 2>&1 && ! command -v qemu-arm >/dev/null 2>&1; then
    MISSING_DEPS+=("glibc-runner or qemu-user-arm")
fi
RPATH="$GLIBC_PREFIX/lib"
INTERPRETER=$(find "$RPATH" -maxdepth 1 -name "ld-linux-*.so.*" 2>/dev/null | head -n 1)
if [ -z "$INTERPRETER" ]; then
    MISSING_DEPS+=("glibc")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Termux Rustup Glibc wrapper is missing required dependencies: ${MISSING_DEPS[*]}" >&2
    echo "Please run the installer again or install them manually:" >&2
    echo "  pkg install -y glibc glibc-runner patchelf-glibc" >&2
    echo ""
    exit 1
fi

# Detect whether RUSTUP_REAL is 32-bit ARM or 64-bit ARM (aarch64)
# If 32-bit ARM ELF, run through qemu-arm emulator
ELF_CLASS=$(file -b "$RUSTUP_REAL" 2>/dev/null || echo "")
if echo "$ELF_CLASS" | grep -q "32-bit"; then
    if command -v qemu-arm >/dev/null 2>&1; then
        GLIBC32_PATH="$GLIBC_PREFIX/lib32"
        [ -d "$GLIBC32_PATH" ] || GLIBC32_PATH="$GLIBC_PREFIX"
        qemu-arm -0 "$0" -L "$GLIBC32_PATH" "$RUSTUP_REAL" "$@"
        EXIT_CODE=$?
    else
        echo "ERROR: 32-bit ARM rustup-real requires qemu-arm (qemu-user-arm package)." >&2
        exit 1
    fi
else
    # 64-bit ARM (aarch64) - preserve argv[0] via bash's exec -a
    bash -c 'exec -a "$0" "'"$RUSTUP_REAL"'" "$@"' "$0" "$@"
    EXIT_CODE=$?
fi

# Post-execution hook: Auto-patch toolchain binaries if any update/install command was run
case "$*" in
    *update*|*install*|*add*|*default*|*toolchain*)
        echo "Post-execution hook: Auto-patching toolchain binaries..."
        
        # If the binary patcher script is available in the cargo bin, use it
        if [ -f "$CARGO_BIN/patch.sh" ]; then
            while read -r toolchain_dir; do
                if [ -d "$toolchain_dir" ]; then
                    "$CARGO_BIN/patch.sh" "$toolchain_dir"
                fi
            done < <(find "$RUSTUP_HOME/toolchains" -type d -name "bin" 2>/dev/null)
        else
            # Fallback inline patching logic if patch.sh is not found
            PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
            GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
            ARCH="$(uname -m)"
            [ "$RUSTERMUX_ARCH" = "arm32" ] || [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armv8l" ] || [ "$ARCH" = "arm" ] && DEFAULT_LOADER="ld-linux-armhf.so.3" || DEFAULT_LOADER="ld-linux-aarch64.so.1"
            INTERPRETER="$GLIBC_PREFIX/lib/$DEFAULT_LOADER"
            
            while read -r toolchain_dir; do
                for f in "$toolchain_dir"/*; do
                    if [ -f "$f" ] && [ -x "$f" ]; then
                        if [ "$(head -c 4 "$f" 2>/dev/null)" = $'\x7fELF' ] && ! patchelf --print-interpreter "$f" 2>/dev/null | grep -q "glibc" ; then
                            patchelf --set-interpreter "$INTERPRETER" \
                                     --set-rpath "$RPATH" \
                                     "$f" 2>/dev/null && echo "  Patched: $(basename "$f")" || true
                        fi
                    fi
                done
            done < <(find "$RUSTUP_HOME/toolchains" -type d -name "bin" 2>/dev/null)
        fi
        ;;
esac

exit $EXIT_CODE
EOF_RUSTUP
        chmod +x "$RUSTUP_BIN"
        echo "[auto-patcher] Recovered rustup wrapper after self-update."
    fi
fi
