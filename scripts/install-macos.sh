#!/bin/bash

# install-macos.sh - Installation script for vibeutils on macOS
# Supports multiple installation modes with safety by default

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
PREFIX="v"
INSTALL_DIR="/usr/local"
BUILD_MODE="ReleaseSafe"
DEFAULT_NAMES=false
CREATE_VIBEBIN=true

# Help function
show_help() {
    cat << EOF
vibeutils macOS Installation Script

Usage: $0 [OPTIONS]

Options:
    -h, --help              Show this help message
    -d, --dir DIR           Installation directory (default: /usr/local)
    --default-names         Install without prefix (WARNING: conflicts with system utils)
    --no-vibebin           Don't create vibebin directory with unprefixed symlinks
    --debug                 Build in debug mode
    --release-small         Build optimized for size

Examples:
    # Standard installation with 'v' prefix
    $0

    # Install to homebrew location on Apple Silicon
    $0 --dir /opt/homebrew

    # Install without any prefix (dangerous!)
    $0 --default-names

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --default-names)
            DEFAULT_NAMES=true
            PREFIX=""
            shift
            ;;
        --no-vibebin)
            CREATE_VIBEBIN=false
            shift
            ;;
        --debug)
            BUILD_MODE="Debug"
            shift
            ;;
        --release-small)
            BUILD_MODE="ReleaseSmall"
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Detect if we're in the right directory
if [[ ! -f "build.zig" ]]; then
    echo -e "${RED}Error: build.zig not found. Please run this script from the vibeutils root directory.${NC}"
    exit 1
fi

# Check for zig
if ! command -v zig &> /dev/null; then
    echo -e "${RED}Error: zig not found. Please install Zig 0.14.1 or later.${NC}"
    echo "Visit: https://ziglang.org/download/"
    exit 1
fi

# Warn about default names
if [[ "$DEFAULT_NAMES" == true ]]; then
    echo -e "${YELLOW}WARNING: Installing without prefix will override system utilities!${NC}"
    echo -e "${YELLOW}This may break system functionality. Are you sure? (y/N)${NC}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
fi

# Build
echo -e "${BLUE}Building vibeutils...${NC}"
BUILD_ARGS=("-Doptimize=$BUILD_MODE")

if ! zig build "${BUILD_ARGS[@]}"; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

# Create installation directories
echo -e "${BLUE}Creating installation directories...${NC}"
BIN_DIR="$INSTALL_DIR/bin"
LIBEXEC_DIR="$INSTALL_DIR/libexec/vibeutils"
VIBEBIN_DIR="$LIBEXEC_DIR/vibebin"

sudo mkdir -p "$BIN_DIR"
if [[ "$CREATE_VIBEBIN" == true ]]; then
    sudo mkdir -p "$VIBEBIN_DIR"
fi

# Install binaries
echo -e "${BLUE}Installing binaries...${NC}"
for binary in zig-out/bin/*; do
    if [[ -f "$binary" ]]; then
        base_name=$(basename "$binary")
        
        if [[ "$DEFAULT_NAMES" == true ]]; then
            # Install without prefix
            install_name="$base_name"
        else
            # Install with 'v' prefix
            install_name="v${base_name}"
        fi
        
        echo "  Installing $install_name..."
        sudo install -m 755 "$binary" "$BIN_DIR/$install_name"
        
        # Create unprefixed symlink in vibebin
        if [[ "$CREATE_VIBEBIN" == true && "$DEFAULT_NAMES" == false ]]; then
            sudo ln -sf "$BIN_DIR/$install_name" "$VIBEBIN_DIR/$base_name"
        fi
    fi
done

# Create activation script
if [[ "$CREATE_VIBEBIN" == true && "$DEFAULT_NAMES" == false ]]; then
    echo -e "${BLUE}Creating activation script...${NC}"
    
    ACTIVATE_SCRIPT="$LIBEXEC_DIR/activate"
    sudo tee "$ACTIVATE_SCRIPT" > /dev/null << 'EOF'
#!/bin/bash
# vibeutils activation script

if [[ -z "$VIBEUTILS_ORIGINAL_PATH" ]]; then
    export VIBEUTILS_ORIGINAL_PATH="$PATH"
    export PATH="VIBEBIN_DIR_PLACEHOLDER:$PATH"
    echo "vibeutils activated! Commands are now available without prefix."
    echo "Run 'deactivate-vibeutils' to restore original behavior."
    
    # Define deactivation function
    deactivate-vibeutils() {
        if [[ -n "$VIBEUTILS_ORIGINAL_PATH" ]]; then
            export PATH="$VIBEUTILS_ORIGINAL_PATH"
            unset VIBEUTILS_ORIGINAL_PATH
            unset -f deactivate-vibeutils
            echo "vibeutils deactivated. Original PATH restored."
        else
            echo "vibeutils is not currently activated."
        fi
    }
else
    echo "vibeutils is already activated."
fi
EOF
    
    # Replace placeholder with actual path
    sudo sed -i '' "s|VIBEBIN_DIR_PLACEHOLDER|$VIBEBIN_DIR|g" "$ACTIVATE_SCRIPT"
    sudo chmod +x "$ACTIVATE_SCRIPT"
fi

# Success message
echo -e "${GREEN}Installation complete!${NC}"
echo
echo "Installed to: $BIN_DIR"
if [[ "$DEFAULT_NAMES" == false ]]; then
    echo "Commands use 'v' prefix: vls, vcp, vmv, vrm, vmkdir, vtouch, etc."
    echo
    echo "To use without prefix:"
    echo "  1. Add to PATH: export PATH=\"$VIBEBIN_DIR:\$PATH\""
    echo "  2. Or source activation script: source $LIBEXEC_DIR/activate"
    echo "  3. Or create aliases: alias ls='vls'"
else
    echo -e "${YELLOW}Installed without prefix - system utilities have been replaced!${NC}"
fi