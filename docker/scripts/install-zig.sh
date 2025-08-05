#!/bin/bash
# Install Zig with community mirror support and fallback
# Usage: install-zig.sh <version> [arch]

set -euo pipefail

# Default values
ZIG_VERSION="${1:-0.14.1}"
ZIG_ARCH="${2:-}"

# Auto-detect architecture if not provided
if [ -z "$ZIG_ARCH" ]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        "aarch64") ZIG_ARCH="aarch64" ;;
        "x86_64") ZIG_ARCH="x86_64" ;;
        *) 
            echo "Error: Unsupported architecture: $ARCH" >&2
            exit 1
            ;;
    esac
fi

# Zig uses different naming conventions for architectures
if [ "$ZIG_ARCH" = "aarch64" ]; then
    FILENAME="zig-aarch64-linux-${ZIG_VERSION}.tar.xz"
    SYMLINK_PATH="/opt/zig-aarch64-linux-${ZIG_VERSION}/zig"
else
    FILENAME="zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
    SYMLINK_PATH="/opt/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}/zig"
fi

# Configuration
FALLBACK_MIRRORS="https://ziglang.org/download"
MAX_ATTEMPTS=3
CONNECT_TIMEOUT=10
DOWNLOAD_TIMEOUT=300

# Install directory
INSTALL_DIR="/opt"
BIN_DIR="/usr/local/bin"

echo "Installing Zig ${ZIG_VERSION} for ${ZIG_ARCH} architecture..."

# Function to get community mirrors
get_community_mirrors() {
    # Silently fetch community mirrors (don't echo status messages)
    curl -s --connect-timeout "$CONNECT_TIMEOUT" --max-time 30 \
        "https://ziglang.org/download/community-mirrors.txt" 2>/dev/null \
        | grep -E '^https?://' \
        | head -10 \
        | tr '\n' ' ' || echo ""
}

# Function to try downloading from a URL
try_download() {
    local url="$1"
    echo "Attempting download from: $url"
    
    if curl -L --fail --connect-timeout "$CONNECT_TIMEOUT" --max-time "$DOWNLOAD_TIMEOUT" \
        "$url" | tar -xJ -C "$INSTALL_DIR"; then
        echo "Successfully downloaded Zig from: $url"
        return 0
    else
        echo "Failed to download from: $url"
        return 1
    fi
}

# Main installation function
install_zig() {
    # Get community mirrors list
    local mirrors_list
    mirrors_list=$(get_community_mirrors)
    
    # Combine community mirrors with fallback
    local all_mirrors="$mirrors_list $FALLBACK_MIRRORS"
    
    # If no mirrors found, use only fallback
    if [ -z "$all_mirrors" ] || [ "$all_mirrors" = " $FALLBACK_MIRRORS" ]; then
        echo "No community mirrors available, using official mirror only"
        all_mirrors="$FALLBACK_MIRRORS"
    fi
    
    local attempt=0
    for mirror in $all_mirrors; do
        # Skip empty entries
        if [ -z "$mirror" ]; then
            continue
        fi
        
        if [ $attempt -ge $MAX_ATTEMPTS ]; then
            echo "Maximum attempts ($MAX_ATTEMPTS) reached."
            break
        fi
        
        echo "Mirror attempt $((attempt + 1))/$MAX_ATTEMPTS: Using mirror base: ${mirror}"
        
        # Generate URLs based on mirror type
        local urls=""
        if echo "$mirror" | grep -q "ziglang.org/download"; then
            # Official mirror uses version subdirectory
            urls="${mirror}/${ZIG_VERSION}/${FILENAME}"
        else
            # Community mirrors typically use simple pattern
            urls="${mirror}/${FILENAME}"
        fi
        
        # Try each URL for this mirror
        for url in $urls; do
            if try_download "$url"; then
                return 0
            fi
        done
        
        attempt=$((attempt + 1))
    done
    
    echo "Error: Failed to download Zig from any mirror after $MAX_ATTEMPTS attempts" >&2
    return 1
}

# Verify installation directory exists
if [ ! -d "$INSTALL_DIR" ]; then
    echo "Creating installation directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
fi

# Install Zig
if install_zig; then
    # Create symlink
    echo "Creating symlink: $BIN_DIR/zig -> $SYMLINK_PATH"
    ln -sf "$SYMLINK_PATH" "$BIN_DIR/zig"
    
    # Verify installation
    if "$BIN_DIR/zig" version | grep -q "$ZIG_VERSION"; then
        echo "Zig $ZIG_VERSION installed successfully!"
        "$BIN_DIR/zig" version
    else
        echo "Warning: Zig installed but version check failed" >&2
        exit 1
    fi
else
    echo "Error: Zig installation failed" >&2
    exit 1
fi