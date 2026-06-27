#!/data/data/com.termux/files/usr/bin/bash
# install.sh - Automated Rustup Installer for Termux with Glibc Support

set -e

# Get the absolute path of the directory containing this script before any cd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configurable variables
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CARGO_BIN="$HOME_DIR/.cargo"
CARGO_BIN_DIR="$CARGO_BIN/bin"
RUSTUP_WORK_DIR="${TMPDIR:-$PREFIX/tmp}/rustermux"

echo "=== Rustermux Installer ==="
echo "PREFIX: $PREFIX"
echo "GLIBC_PREFIX: $GLIBC_PREFIX"
echo "HOME: $HOME_DIR"
echo ""

# 1. Prerequisite Checks
echo "Step 1: Checking and installing prerequisites..."
REQUIRED_PKGS=(glibc glibc-runner patchelf-glibc binutils-glibc gcc-glibc ca-certificates-glibc curl file)
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing packages: ${MISSING_PKGS[*]}"
    pkg update -y
    # Ensure glibc-repo is installed
    if ! dpkg -s glibc-repo >/dev/null 2>&1; then
        pkg install -y glibc-repo
    fi
    pkg install -y "${MISSING_PKGS[@]}"
else
    echo "All prerequisite packages are already installed."
fi

# Verify that packages are successfully installed
FAILED_INSTALL=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        FAILED_INSTALL+=("$pkg")
    fi
done

if [ ${#FAILED_INSTALL[@]} -gt 0 ]; then
    echo "Error: Failed to install one or more required packages: ${FAILED_INSTALL[*]}" >&2
    echo "Please check your network connection and ensure your Termux repositories are reachable." >&2
    exit 1
fi

# Ensure output directory exists
mkdir -p "$RUSTUP_WORK_DIR"
cd "$RUSTUP_WORK_DIR"

# 2. Download GNU Installer
echo "Step 2: Downloading Rustup GNU installer..."
curl -sSf https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init -o rustup-init-gnu
chmod +x rustup-init-gnu

# 3. Run the installer via grun
echo "Step 3: Installing Rustup via grun..."
# Run under grun to use glibc
grun ./rustup-init-gnu -y --default-host aarch64-unknown-linux-gnu

# 4. Resolve /proc/self/exe copy bug
echo "Step 4: Resolving the ld.so self-copy bug..."
mkdir -p "$CARGO_BIN_DIR"
cp rustup-init-gnu "$CARGO_BIN_DIR/rustup-real"
rm -f rustup-init-gnu

# 5. Copy scripts to target destination
echo "Step 5: Installing patch.sh and wrappers..."
cp "$SCRIPT_DIR/patch.sh" "$CARGO_BIN_DIR/patch.sh"
chmod +x "$CARGO_BIN_DIR/patch.sh"

# Install wrappers
cp "$SCRIPT_DIR/wrappers/rustup" "$CARGO_BIN_DIR/rustup"
chmod +x "$CARGO_BIN_DIR/rustup"

cp "$SCRIPT_DIR/wrappers/auto-patcher.sh" "$CARGO_BIN_DIR/auto-patcher.sh"
chmod +x "$CARGO_BIN_DIR/auto-patcher.sh"

# 6. Patch the initial suite
echo "Step 6: Patching initial binaries..."
"$CARGO_BIN_DIR/patch.sh" "$CARGO_BIN_DIR/rustup-real"

# Find and patch any toolchains already installed
for toolchain_dir in "$HOME_DIR"/.rustup/toolchains/*/bin; do
    if [ -d "$toolchain_dir" ]; then
        "$CARGO_BIN_DIR/patch.sh" "$toolchain_dir"
    fi
done

# 7. Configure Environment
echo "Step 7: Configuring cargo environment..."
CARGO_ENV="$CARGO_BIN/env"
touch "$CARGO_ENV"

# Update ~/.cargo/env if not already present
# NOTE: We intentionally do NOT add $GLIBC_PREFIX/bin to PATH.
# The glibc coreutils (mv, wc, tail, find, etc.) in that directory shadow
# native Termux tools. Since libc.so there is a GNU linker script (not an ELF),
# those glibc-linked binaries crash at startup with "invalid ELF header".
# The wrappers (rustup, maturin) set GLIBC_PREFIX internally when needed.
if ! grep -q "Termux Glibc userland integration" "$CARGO_ENV" 2>/dev/null; then
    cat << 'EOF' >> "$CARGO_ENV"

# Termux Glibc userland integration
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
# GLIBC_PREFIX/bin is intentionally NOT added to PATH to avoid glibc coreutils
# shadowing native Termux tools (libc.so there is a linker script, not an ELF).
EOF
    echo "Updated $CARGO_ENV"
fi

# Ensure global config.toml has native Android target configuration
CARGO_CONFIG="$CARGO_BIN/config.toml"
if [ ! -f "$CARGO_CONFIG" ]; then
    echo "Creating global cargo configuration at $CARGO_CONFIG..."
    cat << EOF > "$CARGO_CONFIG"
[build]
target = "aarch64-linux-android"

[target.aarch64-linux-android]
linker = "$PREFIX/bin/clang"
rustflags = ["-C", "link-arg=-Wl,-rpath,$PREFIX/lib", "-C", "link-arg=-Wl,--enable-new-dtags"]
EOF
fi

# 8. Add Auto-Patcher to Shell Profile
echo "Step 8: Adding auto-patcher to shell profiles..."
for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.zshrc"; do
    if [ -f "$rc" ]; then
        if ! grep -q "auto-patcher.sh" "$rc" 2>/dev/null; then
            echo '[ -f ~/.cargo/bin/auto-patcher.sh ] && ~/.cargo/bin/auto-patcher.sh &>/dev/null &' >> "$rc"
            echo "Added auto-patcher to $rc"
        fi
    fi
done

# Run auto-patcher once to make sure everything is in place
"$CARGO_BIN_DIR/auto-patcher.sh" || true

# Clean up temporary work directory
rm -rf "$RUSTUP_WORK_DIR"

echo "=== Rustup Termux Glibc Setup Complete! ==="
echo "Please reload your shell or run: source ~/.cargo/env"
