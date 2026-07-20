#!/data/data/com.termux/files/usr/bin/bash
# patch.sh - Termux Glibc Binary Patcher with Parallel Execution and Performance Caching
# Patches ELF binaries to use Termux's glibc dynamic loader and library path.

set -e

# Default paths if not specified
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
RPATH="${RPATH:-$GLIBC_PREFIX/lib}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CARGO_HOME="${CARGO_HOME:-$HOME_DIR/.cargo}"
CACHE_FILE="$CARGO_HOME/.patch_cache"
NPROC=$(nproc 2>/dev/null || echo 4)

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

# Load mtime cache into associative array
declare -A PATCH_CACHE
if [ -f "$CACHE_FILE" ]; then
    while IFS="|" read -r path mtime; do
        if [ -n "$path" ] && [ -n "$mtime" ]; then
            PATCH_CACHE["$path"]="$mtime"
        fi
    done < "$CACHE_FILE"
fi

CACHE_MODIFIED=0

# Helper exported worker function for single-file processing
patch_single_file_worker() {
    local file="$1"
    local interp="$2"
    local rpath="$3"
    
    file=$(readlink -f "$file" 2>/dev/null || echo "$file")
    
    if [ -f "$file" ] && [ -x "$file" ]; then
        # Fast magic-bytes check for ELF header (\x7fELF)
        if [ "$(head -c 4 "$file" 2>/dev/null)" = $'\x7fELF' ]; then
            local current_interpreter
            current_interpreter=$(patchelf --print-interpreter "$file" 2>/dev/null || true)
            
            if [ "$current_interpreter" != "$interp" ]; then
                echo "  [Parallel] Patching: $(basename "$file")"
                patchelf --set-interpreter "$interp" \
                         --set-rpath "$rpath" \
                         "$file" 2>/dev/null || echo "Warning: Failed to patch $file" >&2
            fi
        fi
        
        local current_mtime
        current_mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0")
        echo "$file|$current_mtime"
    fi
}
export -f patch_single_file_worker

patch_file() {
    local file="$1"
    file=$(readlink -f "$file" 2>/dev/null || echo "$file")
    
    if [ -f "$file" ] && [ -x "$file" ]; then
        local current_mtime
        current_mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0")
        
        # Check cache
        if [ "${PATCH_CACHE["$file"]}" = "$current_mtime" ]; then
            return 0
        fi
        
        # Single file patch
        local res
        res=$(patch_single_file_worker "$file" "$INTERPRETER" "$RPATH")
        if [ -n "$res" ]; then
            IFS="|" read -r p m <<< "$res"
            PATCH_CACHE["$p"]="$m"
            CACHE_MODIFIED=1
        fi
    fi
}

patch_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        echo "Scanning directory (parallel pool: ${NPROC} workers): $dir"
        
        local needs_patching=()
        while read -r f; do
            local abs_f
            abs_f=$(readlink -f "$f" 2>/dev/null || echo "$f")
            local mtime
            mtime=$(stat -c %Y "$abs_f" 2>/dev/null || stat -f %m "$abs_f" 2>/dev/null || echo "0")
            
            if [ "${PATCH_CACHE["$abs_f"]}" != "$mtime" ]; then
                needs_patching+=("$abs_f")
            fi
        done < <(find "$dir" -maxdepth 3 -type f -executable 2>/dev/null)
        
        if [ ${#needs_patching[@]} -gt 0 ]; then
            local tmp_out
            tmp_out=$(mktemp)
            
            # shellcheck disable=SC2016
            printf "%s\n" "${needs_patching[@]}" | xargs -P "$NPROC" -n 1 -I {} bash -c 'patch_single_file_worker "$1" "$2" "$3"' _ {} "$INTERPRETER" "$RPATH" > "$tmp_out" 2>/dev/null
            
            while IFS="|" read -r path mtime; do
                if [ -n "$path" ] && [ -n "$mtime" ]; then
                    PATCH_CACHE["$path"]="$mtime"
                    CACHE_MODIFIED=1
                fi
            done < "$tmp_out"
            rm -f "$tmp_out"
        fi
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

# Save cache atomically if modified
if [ "$CACHE_MODIFIED" -eq 1 ]; then
    mkdir -p "$(dirname "$CACHE_FILE")"
    TMP_CACHE=$(mktemp)
    for path in "${!PATCH_CACHE[@]}"; do
        echo "$path|${PATCH_CACHE[$path]}"
    done > "$TMP_CACHE"
    mv "$TMP_CACHE" "$CACHE_FILE"
fi
