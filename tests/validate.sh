#!/data/data/com.termux/files/usr/bin/bash
# tests/validate.sh - Automated verification suite for Rustup on Termux Glibc

set -e

# UI helpers (cargo-styled output)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    _B='\033[1m' _G='\033[92m' _Y='\033[33m' _R='\033[31m' _D='\033[2m' _0='\033[0m'
else
    _B='' _G='' _Y='' _R='' _D='' _0=''
fi
status() { printf "${_B}${_G}%12s${_0} %s\n" "$1" "$2"; }
warn()   { printf "${_B}${_Y}warning${_0}: %s\n" "$1" >&2; }
err()    { printf "${_B}${_R}error${_0}: %s\n" "$1" >&2; }
note()   { printf "${_B}${_G}note${_0}: %s\n" "$1"; }

status "Testing" "Rustermux verification suite"

# Source the cargo environment
if [ -f ~/.cargo/env ]; then
    status "Sourcing" "$HOME/.cargo/env"
    # shellcheck source=/dev/null
    . ~/.cargo/env
else
    warn "~/.cargo/env not found, using current environment"
fi

export PATH="$HOME/.cargo/bin:$PATH"

# Test 1: Verify core binaries exist
status "Verifying" "core binaries in PATH"
for cmd in rustup cargo rustc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        err "$cmd is not available in PATH"
        exit 1
    fi
    printf "             %s -> %s\n" "$cmd" "$(command -v "$cmd")"
done

# Test 2: Check wrappers
status "Verifying" "wrapper integration"
if [ -x "$HOME/.cargo/bin/rustc-wrapper" ]; then
    printf "             rustc-wrapper -> %s\n" "$HOME/.cargo/bin/rustc-wrapper"
fi
if command -v sccache >/dev/null 2>&1; then
    printf "             sccache -> %s\n" "$(command -v sccache)"
fi
if command -v mold >/dev/null 2>&1; then
    printf "             mold -> %s\n" "$(command -v mold)"
fi

# Test 3: Run rustup show
status "Checking" "toolchain status"
rustup show active-toolchain 2>/dev/null || rustup show

# Create isolated test scratch directory
TEST_DIR=$(mktemp -d -t rust-validate-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$TEST_DIR"

# Test 4: Cargo project creation
status "Creating" "test crate"
cargo new test_proj --quiet
cd test_proj

# Test 5: Incremental build & warning filter test
status "Compiling" "incremental build with warning filter"
cargo build --config 'build.incremental=true'
echo '// modification trigger' >> src/main.rs
# Incremental rebuild should not output the hard-link warning
BUILD_OUTPUT=$(cargo build --config 'build.incremental=true' 2>&1)
if echo "$BUILD_OUTPUT" | grep -q "hard linking files in the incremental compilation cache failed"; then
    err "incremental compilation emitted hard-link warning"
    exit 1
fi

# Test 6: Running the compiled binary
status "Running" "compiled binary"
cargo run --quiet

# Test 7: Cargo test runner
status "Testing" "test runner"
cargo test --quiet

# Test 8: Toolchain component checks
if cargo clippy --help >/dev/null 2>&1; then
    status "Checking" "cargo clippy"
    cargo clippy --quiet 2>/dev/null || true
fi

if cargo fmt --help >/dev/null 2>&1; then
    status "Checking" "cargo fmt"
    cargo fmt -- --check 2>/dev/null || true
fi

# Test 9: Local crate install & uninstall
status "Installing" "dummy package via cargo install"
mkdir -p "$TEST_DIR/dummy_install"
cd "$TEST_DIR/dummy_install"
cargo init --bin --name dummy_validate --quiet
cargo install --path . --force --quiet
if [ -f "$HOME/.cargo/bin/dummy_validate" ]; then
    cargo uninstall dummy_validate --quiet
else
    err "dummy_validate binary was not found in ~/.cargo/bin"
    exit 1
fi

printf "\n%b%b   Finished%b all verification tests passed successfully\n\n" "$_B" "$_G" "$_0"
