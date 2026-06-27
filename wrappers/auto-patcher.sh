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

# 1. Manage sitecustomize.py for platform spoofing
find "$PREFIX/lib" -maxdepth 3 -type d -path "*/python*/site-packages" 2>/dev/null | while read -r site_pkg_dir; do
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

# 2. Manage glibc binaries wrapping (e.g. maturin)
BINARIES=(
    "$PREFIX/bin/maturin|maturin-real"
)

for entry in "${BINARIES[@]}"; do
    IFS="|" read -r bin_path real_name <<< "$entry"
    if [ -f "$bin_path" ] && [ -x "$bin_path" ]; then
        if file "$bin_path" 2>/dev/null | grep -q "ELF"; then
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
            if file "\$f" 2>/dev/null | grep -q "ELF"; then
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

# 3. Manage rustup self-update wrapping
RUSTUP_BIN="$CARGO_BIN_DIR/rustup"
RUSTUP_REAL="$CARGO_BIN_DIR/rustup-real"

if [ -f "$RUSTUP_BIN" ] && [ -x "$RUSTUP_BIN" ]; then
    if file "$RUSTUP_BIN" 2>/dev/null | grep -q "ELF"; then
        # It was overwritten by self-update, rename it
        mv "$RUSTUP_BIN" "$RUSTUP_REAL"
        
        # Patch the new rustup-real
        if [ -f "$CARGO_BIN_DIR/patch.sh" ]; then
            "$CARGO_BIN_DIR/patch.sh" "$RUSTUP_REAL"
        else
            LOCAL_INTERPRETER=$(find "$GLIBC_PREFIX/lib" -maxdepth 1 -name "ld-linux-*.so.*" 2>/dev/null | head -n 1)
            LOCAL_INTERPRETER="${LOCAL_INTERPRETER:-$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1}"
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
if ! command -v grun >/dev/null 2>&1; then
    MISSING_DEPS+=("glibc-runner")
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

# Run the real rustup binary, preserving argv[0] via bash's exec -a
bash -c 'exec -a "$0" "'"$RUSTUP_REAL"'" "$@"' "$0" "$@"
EXIT_CODE=$?

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
            RPATH="$GLIBC_PREFIX/lib"
            INTERPRETER=$(find "$RPATH" -maxdepth 1 -name "ld-linux-*.so.*" 2>/dev/null | head -n 1)
            INTERPRETER="${INTERPRETER:-$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1}"
            
            while read -r toolchain_dir; do
                for f in "$toolchain_dir"/*; do
                    if [ -f "$f" ] && [ -x "$f" ]; then
                        if file "$f" 2>/dev/null | grep -q "ELF" && ! patchelf --print-interpreter "$f" 2>/dev/null | grep -q "glibc" ; then
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
