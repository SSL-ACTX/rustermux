#!/data/data/com.termux/files/usr/bin/bash
# tests/validate.sh - Automated verification suite for Rustup on Termux Glibc

set -e

echo "=== Running Rustermux Verification Suite ==="

# Source the cargo environment
if [ -f ~/.cargo/env ]; then
    echo "Sourcing ~/.cargo/env..."
    . ~/.cargo/env
else
    echo "Warning: ~/.cargo/env not found, using current environment."
fi

# Ensure cargo bin is in path
export PATH="$HOME/.cargo/bin:$PATH"

# Test 1: Verify binaries exist
echo "Test 1: Verifying binaries exist..."
for cmd in rustup cargo rustc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "FAIL: $cmd is not available in PATH" >&2
        exit 1
    fi
    echo "  $cmd found at: $(command -v "$cmd")"
done

# Test 2: Run rustup show
echo "Test 2: Verifying 'rustup show' works..."
rustup show

# Test 3: Test rustup update
echo "Test 3: Testing 'rustup update'..."
rustup update

# Test 4: cargo new
echo "Test 4: Creating temporary project..."
TEST_DIR=$(mktemp -d -t rust-test-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

cd "$TEST_DIR"
cargo new test_proj
cd test_proj

# Test 5: cargo run
echo "Test 5: Testing 'cargo run'..."
cargo run

# Test 6: cargo test
echo "Test 6: Testing 'cargo test'..."
cargo test

# Test 7: target add
echo "Test 7: Testing 'rustup target add'..."
rustup target add aarch64-unknown-linux-gnu

# Test 8: cargo clippy
if cargo clippy --help >/dev/null 2>&1; then
    echo "Test 8: Testing 'cargo clippy'..."
    cargo clippy
else
    echo "Test 8: cargo clippy not installed, skipping."
fi

# Test 9: cargo fmt
if cargo fmt --help >/dev/null 2>&1; then
    echo "Test 9: Testing 'cargo fmt'..."
    cargo fmt -- --check
else
    echo "Test 9: cargo fmt not installed, skipping."
fi

# Test 10: cargo install
echo "Test 10: Testing 'cargo install' (via local dummy binary)..."
# Create a dummy bin package to install
mkdir -p "$TEST_DIR/dummy_install"
cd "$TEST_DIR/dummy_install"
cargo init --bin --name dummy_install
cargo install --path . --force
if [ -f "$HOME/.cargo/bin/dummy_install" ]; then
    echo "  Successfully installed dummy_install to ~/.cargo/bin"
    cargo uninstall dummy_install
else
    echo "FAIL: dummy_install binary was not found in ~/.cargo/bin" >&2
    exit 1
fi

echo "=== All Tests Passed Successfully! ==="
