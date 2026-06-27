#!/data/data/com.termux/files/usr/bin/bash
# patch.sh - Termux Glibc Binary Patcher with Performance Caching
# Patches ELF binaries to use Termux's glibc dynamic loader and library path.

set -e

# Default paths if not specified
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
RPATH="${RPATH:-$GLIBC_PREFIX/lib}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CARGO_HOME="${CARGO_HOME:-$HOME_DIR/.cargo}"
CACHE_FILE="$CARGO_HOME/.patch_cache"

# Discover the dynamic loader interpreter dynamically if not provided
if [ -z "$INTERPRETER" ]; then
    # Look for ld-linux loader inside the glibc library dir (handles multiple architectures dynamically)
    INTERPRETER=$(find "$RPATH" -maxdepth 1 -name "ld-linux-*.so.*" 2>/dev/null | head -n 1)
    # Fallback to standard path if discovery fails
    INTERPRETER="${INTERPRETER:-$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1}"
fi

# Ensure patchelf is installed
if ! command -v patchelf >/dev/null 2>&1; then
    echo "Error: patchelf is not installed. Please run: pkg install patchelf-glibc" >&2
    exit 1
fi

# Load mtime cache
declare -A PATCH_CACHE
if [ -f "$CACHE_FILE" ]; then
    while IFS="|" read -r path mtime; do
        if [ -n "$path" ] && [ -n "$mtime" ]; then
            PATCH_CACHE["$path"]="$mtime"
        fi
    done < "$CACHE_FILE"
fi

CACHE_MODIFIED=0

patch_file() {
    local file="$1"
    
    # Resolve to absolute path
    file=$(readlink -f "$file")
    
    # Check if it is a regular file and executable
    if [ -f "$file" ] && [ -x "$file" ]; then
        local current_mtime
        current_mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0")
        
        # Check cache
        if [ "${PATCH_CACHE["$file"]}" = "$current_mtime" ]; then
            # File has not changed since last successful check/patch
            return 0
        fi
        
        # Check if it is an ELF binary
        if file "$file" 2>/dev/null | grep -q "ELF"; then
            # Get current interpreter
            local current_interpreter
            current_interpreter=$(patchelf --print-interpreter "$file" 2>/dev/null || true)
            
            # Patch if interpreter is different
            if [ "$current_interpreter" != "$INTERPRETER" ]; then
                echo "Patching: $(basename "$file")"
                patchelf --set-interpreter "$INTERPRETER" \
                         --set-rpath "$RPATH" \
                         "$file" 2>/dev/null || echo "Warning: Failed to patch $file" >&2
            fi
        fi
        
        # Update cache with the current mtime
        PATCH_CACHE["$file"]="$current_mtime"
        CACHE_MODIFIED=1
    fi
}

patch_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        echo "Scanning directory: $dir"
        # Use process substitution to run the loop in the parent shell context
        while read -r f; do
            patch_file "$f"
        done < <(find "$dir" -maxdepth 3 -type f -executable)
    fi
}

if [ -z "$1" ]; then
    echo "Usage: $0 <file_or_directory_to_patch>"
    exit 1
fi

TARGET="$1"

if [ -d "$TARGET" ]; then
    patch_dir "$TARGET"
elif [ -f "$TARGET" ]; then
    patch_file "$TARGET"
else
    echo "Error: Target '$TARGET' does not exist." >&2
    exit 1
fi

# Save cache if modified
if [ "$CACHE_MODIFIED" -eq 1 ]; then
    mkdir -p "$(dirname "$CACHE_FILE")"
    for path in "${!PATCH_CACHE[@]}"; do
        echo "$path|${PATCH_CACHE[$path]}"
    done > "$CACHE_FILE"
fi
