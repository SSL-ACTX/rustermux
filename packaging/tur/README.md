# Packaging for Termux User Repository (TUR)

This directory contains the packaging files for submitting Rustermux to [TUR](https://github.com/termux-user-repository/tur).

## Files

- `packages/rustermux/build.sh`: The package build definition adhering to `termux-packages` standards.
- `packages/rustermux/postinst`: Post-installation hook configuring `dpkg-divert` for `maturin` and printing instructions.
- `packages/rustermux/prerm`: Pre-removal hook restoring diverted files if the package is uninstalled.

## Key Packaging Features

1. **`TERMUX_PKG_PROVIDES="rust, cargo"`**:
   Satisfies the package manager dependencies for packages like `maturin` without downloading the 150+ MB official Termux Bionic Rust package.
2. **`dpkg-divert` Integration**:
   Redirects `/data/data/com.termux/files/usr/bin/maturin` to `maturin-real` so `pkg install maturin` never overwrites our patched wrapper.
3. **Turnkey CLI**:
   Installs `/data/data/com.termux/files/usr/bin/rustermux` so users can simply type `rustermux` to initialize their toolchains.

## How to Test and Submit

1. Clone `termux-user-repository/tur`:
   ```bash
   git clone https://github.com/termux-user-repository/tur.git
   cd tur
   ```
2. Copy `packages/rustermux` into `tur/packages/`:
   ```bash
   cp -r /path/to/rustermux/packaging/tur/packages/rustermux packages/
   ```
3. Test build using Docker:
   ```bash
   ./build-package.sh -a aarch64 rustermux
   ```
4. Push to your fork and open a Pull Request with the title `rustermux: new package`.
