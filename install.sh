#!/data/data/com.termux/files/usr/bin/bash
# install.sh - Automated Rustup Installer for Termux with Glibc Support

# UI helpers
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    _B='\033[1m' _G='\033[92m' _Y='\033[33m' _R='\033[31m' _D='\033[2m' _0='\033[0m'
else
    _B='' _G='' _Y='' _R='' _D='' _0=''
fi
status() { printf "${_B}${_G}%12s${_0} %s\n" "$1" "$2"; }
warn()   { printf "${_B}${_Y}warning${_0}: %s\n" "$1" >&2; }
err()    { printf "${_B}${_R}error${_0}: %s\n" "$1" >&2; }
note()   { printf "${_B}${_G}note${_0}: %s\n" "$1"; }

set -e

# Get the absolute path of the directory containing this script before any cd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GitHub Raw Content base URL (for downloading files in remote-execution/pipe mode)
GITHUB_RAW_URL="${GITHUB_RAW_URL:-https://raw.githubusercontent.com/SSL-ACTX/rustermux/main}"

# Configurable variables
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CARGO_BIN="$HOME_DIR/.cargo"
CARGO_BIN_DIR="$CARGO_BIN/bin"
RUSTUP_WORK_DIR="${TMPDIR:-$PREFIX/tmp}/rustermux"

# Detect target architecture (aarch64 vs arm32)
ARCH="$(uname -m)"
if [ "$RUSTERMUX_ARCH" = "arm32" ] || [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armv8l" ] || [ "$ARCH" = "arm" ]; then
    TARGET_TRIPLE="armv7-unknown-linux-gnueabihf"
    ANDROID_TARGET="armv7-linux-androideabi"
    RUNNER="qemu-arm"
    IS_ARM32=1
else
    TARGET_TRIPLE="aarch64-unknown-linux-gnu"
    ANDROID_TARGET="aarch64-linux-android"
    RUNNER="grun"
    IS_ARM32=0
fi

# 1. Prerequisite Checks
status "Installing" "Rustermux ($TARGET_TRIPLE)"
status "Checking" "prerequisites"
REQUIRED_PKGS=(glibc glibc-runner patchelf-glibc binutils-glibc gcc-glibc ca-certificates-glibc curl file)
if [ "$IS_ARM32" -eq 1 ]; then
    REQUIRED_PKGS+=(qemu-user-arm glibc32 gcc-libs-dev-glibc32)
fi
MISSING_PKGS=()

# Check and install required prerequisites
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    status "Installing" "${MISSING_PKGS[*]}"
    pkg update -y
    # Ensure glibc-repo is installed
    if ! dpkg -s glibc-repo >/dev/null 2>&1; then
        pkg install -y glibc-repo
    fi
    pkg install -y "${MISSING_PKGS[@]}"
else
    status "Verified" "all prerequisites installed"
fi

# Optional acceleration packages (sccache for compilation caching, mold for fast linking)
OPTIONAL_PKGS=(sccache mold)
MISSING_OPTIONAL=()
for pkg in "${OPTIONAL_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_OPTIONAL+=("$pkg")
    fi
done

if [ ${#MISSING_OPTIONAL[@]} -gt 0 ]; then
    status "Optional" "installing accelerators: ${MISSING_OPTIONAL[*]}"
    pkg install -y "${MISSING_OPTIONAL[@]}" 2>/dev/null || true
fi

# Verify that packages are successfully installed
FAILED_INSTALL=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        FAILED_INSTALL+=("$pkg")
    fi
done

if [ ${#FAILED_INSTALL[@]} -gt 0 ]; then
    err "failed to install: ${FAILED_INSTALL[*]}"
    note "check your network and Termux repositories"
    exit 1
fi

# Ensure output directory exists
mkdir -p "$RUSTUP_WORK_DIR"
cd "$RUSTUP_WORK_DIR"

# 2. Download GNU Installer
status "Downloading" "rustup-init ($TARGET_TRIPLE)"
DOWNLOAD_URL="https://static.rust-lang.org/rustup/dist/$TARGET_TRIPLE/rustup-init"
if [ -t 1 ]; then
    curl -# -fL "$DOWNLOAD_URL" -o rustup-init-gnu 2>&1 | tr "\r" "\n" | while IFS= read -r line; do
        pct=$(echo "$line" | grep -oE '[0-9]+(\.[0-9]+)?%' | tr -d '%')
        if [ -n "$pct" ]; then
            int_pct=${pct%.*}
            [ -z "$int_pct" ] && int_pct=0
            width=30
            filled=$(( int_pct * width / 100 ))
            [ "$filled" -gt "$width" ] && filled=$width
            if [ "$filled" -gt 0 ] && [ "$filled" -lt "$width" ]; then
                bar=$(printf "%*s" $((filled - 1)) "" | tr " " "=")">"
            elif [ "$filled" -ge "$width" ]; then
                bar=$(printf "%*s" "$width" "" | tr " " "=")
            else
                bar=""
            fi
            printf "\r [%-30s] %3d%%" "$bar" "$int_pct"
        fi
    done
    printf "\n"
else
    curl -sSf "$DOWNLOAD_URL" -o rustup-init-gnu
fi
chmod +x rustup-init-gnu

# 3. Patch rustup-init-gnu interpreter and run via runner (grun or qemu-arm)
status "Installing" "rustup via $RUNNER"
if [ "$IS_ARM32" -eq 1 ]; then
    GLIBC32_PATH="$GLIBC_PREFIX/lib32"
    [ -d "$GLIBC32_PATH" ] || GLIBC32_PATH="$GLIBC_PREFIX"
    INTERP="$GLIBC32_PATH/ld-linux-armhf.so.3"
    if [ -f "$INTERP" ]; then
        patchelf --set-interpreter "$INTERP" --set-rpath "$GLIBC32_PATH" ./rustup-init-gnu 2>/dev/null || true
    fi
    # Filter out internal build script probe noise (cargo:rerun-if-env-changed, CC = None, etc.)
    qemu-arm -L "$GLIBC32_PATH" ./rustup-init-gnu -y --default-host "$TARGET_TRIPLE" 2>&1 | grep -vE '^(cargo:rerun-if-env-changed|CC_|HOST_CC|CC|CRATE_CC|CFLAGS|HOST_CFLAGS)' || true
else
    # Run under grun to use glibc on aarch64
    grun ./rustup-init-gnu -y --default-host "$TARGET_TRIPLE" 2>&1 | grep -vE '^(cargo:rerun-if-env-changed|CC_|HOST_CC|CC|CRATE_CC|CFLAGS|HOST_CFLAGS)' || true
fi

# 4. Resolve /proc/self/exe copy bug
status "Resolving" "ld.so self-copy"
mkdir -p "$CARGO_BIN_DIR"
cp rustup-init-gnu "$CARGO_BIN_DIR/rustup-real"
rm -f rustup-init-gnu

# 5. Copy or download scripts to target destination
status "Installing" "wrappers"

# Helper function to copy or download a file
install_file() {
    local src_rel_path="$1"
    local dest_path="$2"
    
    if [ -f "$SCRIPT_DIR/$src_rel_path" ]; then
        cp "$SCRIPT_DIR/$src_rel_path" "$dest_path"
    else
        local download_url="$GITHUB_RAW_URL/$src_rel_path"
        if ! curl -sSf "$download_url" -o "$dest_path"; then
            err "failed to download $src_rel_path"
            exit 1
        fi
    fi
    chmod +x "$dest_path"
}

install_file "patch.sh" "$CARGO_BIN_DIR/patch.sh"
install_file "wrappers/rustup" "$CARGO_BIN_DIR/rustup"
install_file "wrappers/auto-patcher.sh" "$CARGO_BIN_DIR/auto-patcher.sh"
install_file "wrappers/cargo-audit" "$CARGO_BIN_DIR/cargo-audit-wrapper"
install_file "wrappers/rustc-wrapper" "$CARGO_BIN_DIR/rustc-wrapper"

# 6. Patch the initial suite
status "Patching" "initial binaries"
"$CARGO_BIN_DIR/patch.sh" "$CARGO_BIN_DIR/rustup-real"

# Find and patch any toolchains already installed
for toolchain_dir in "$HOME_DIR"/.rustup/toolchains/*/bin; do
    if [ -d "$toolchain_dir" ]; then
        "$CARGO_BIN_DIR/patch.sh" "$toolchain_dir"
    fi
done

# Wrap cargo-audit if already installed (cargo-audit uses reqwest+rustls-platform-verifier
# which panics on Android; our wrapper uses git to fetch the advisory DB instead)
CARGO_AUDIT_BIN="$CARGO_BIN_DIR/cargo-audit"
if [ -f "$CARGO_AUDIT_BIN" ] && [ "$(head -c 4 "$CARGO_AUDIT_BIN" 2>/dev/null)" = $'\x7fELF' ]; then
    status "Wrapping" "cargo-audit"
    mv "$CARGO_AUDIT_BIN" "$CARGO_BIN_DIR/cargo-audit-real"
    cp "$CARGO_BIN_DIR/cargo-audit-wrapper" "$CARGO_AUDIT_BIN"
    chmod +x "$CARGO_AUDIT_BIN"
fi

# 7. Configure Environment
status "Configuring" "cargo environment"
CARGO_ENV="$CARGO_BIN/env"
touch "$CARGO_ENV"

if ! grep -q "Termux Glibc userland integration" "$CARGO_ENV" 2>/dev/null; then
    cat << 'EOF' >> "$CARGO_ENV"

# Termux Glibc userland integration
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
export CARGO_BUILD_TARGET="${CARGO_BUILD_TARGET:-aarch64-linux-android}"
export PYO3_CONFIG_FILE="${PYO3_CONFIG_FILE:-$HOME/.cargo/pyo3.config}"

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
# GLIBC_PREFIX/bin is intentionally NOT added to PATH to avoid glibc coreutils
# shadowing native Termux tools (libc.so there is a linker script, not an ELF).
EOF
fi

# Ensure global config.toml has native Android target configuration and caching
CARGO_CONFIG="$CARGO_BIN/config.toml"
if [ ! -f "$CARGO_CONFIG" ]; then
    status "Configuring" "$CARGO_CONFIG"
    if command -v mold >/dev/null 2>&1; then
        RUSTFLAGS='["-C", "link-arg=-fuse-ld=mold", "-C", "link-arg=-Wl,-rpath,'"$PREFIX"'/lib", "-C", "link-arg=-Wl,--enable-new-dtags"]'
    else
        RUSTFLAGS='["-C", "link-arg=-Wl,-rpath,'"$PREFIX"'/lib", "-C", "link-arg=-Wl,--enable-new-dtags"]'
    fi
    cat << EOF > "$CARGO_CONFIG"
[build]
target = "$ANDROID_TARGET"
rustc-wrapper = "$CARGO_BIN_DIR/rustc-wrapper"
incremental = false

[target.$ANDROID_TARGET]
linker = "$PREFIX/bin/clang"
rustflags = $RUSTFLAGS

[profile.dev]
debug = 1
split-debuginfo = "unpacked"
EOF
fi

# 8. Add Auto-Patcher to Shell Profile
status "Registering" "auto-patcher in shell profiles"
for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.zshrc"; do
    if [ -f "$rc" ]; then
        if ! grep -q "auto-patcher.sh" "$rc" 2>/dev/null; then
            echo '( [ -f ~/.cargo/bin/auto-patcher.sh ] && ~/.cargo/bin/auto-patcher.sh &>/dev/null & )' >> "$rc"
        fi
    fi
done

# Run auto-patcher once to make sure everything is in place
"$CARGO_BIN_DIR/auto-patcher.sh" || true

# Clean up temporary work directory
rm -rf "$RUSTUP_WORK_DIR"

printf "\n%b%b   Finished%b Rustermux installed successfully\n" "$_B" "$_G" "$_0"
note "restart your shell or run: source ~/.cargo/env"
printf "\n"
