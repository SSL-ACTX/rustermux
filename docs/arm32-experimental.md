# Experimental 32-Bit ARM Support

Rustermux includes experimental support for 32-bit ARM environments (`armv7-unknown-linux-gnueabihf` host toolchain, targeting `armv7-linux-androideabi`).

## Requirements

- `qemu-user-arm` (provides `qemu-arm`)
- Termux 32-bit glibc packages (`glibc32`, `gcc-libs-dev-glibc32`)
- Termux 64-bit glibc packages (`glibc`, `glibc-runner`, `patchelf-glibc`, etc.)

## How to Activate

### On a 32-bit ARM Device
If Termux is running natively on a 32-bit ARM kernel/OS (`armv7l`), Rustermux will auto-detect the architecture during installation.

### On a 64-bit ARM (aarch64) Device with QEMU
You can force 32-bit ARM mode by setting `RUSTERMUX_ARCH=arm32`:

```bash
RUSTERMUX_ARCH=arm32 ./install.sh
```

## How It Works

1. **Prerequisite Check**: Automatically installs `qemu-user-arm`, `glibc32`, and `gcc-libs-dev-glibc32`.
2. **Host Toolchain**: Downloads `armv7-unknown-linux-gnueabihf` binaries from `rustup`.
3. **Interpreter Patching**: `patch.sh` updates the ELF interpreter to the 32-bit glibc loader (`ld-linux-armhf.so.3` in `$GLIBC_PREFIX/lib32`).
4. **Execution via QEMU**: `wrappers/rustup` detects 32-bit ARM ELF binaries and executes them using `qemu-arm -0 "$0" -L "$GLIBC_PREFIX/lib32"`.
5. **Target Setup**: Sets `armv7-linux-androideabi` as the default target in `~/.cargo/config.toml`.

## Limitations

- Performance is lower due to `qemu-arm` user-space emulation.
- Experimental feature — subtle ABI or emulation bugs may occur.
