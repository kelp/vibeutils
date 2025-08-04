#!/bin/bash
# Create non-root user for Docker container security
# Usage: create-user.sh <username> [uid] [gid] [home_dir]

set -euo pipefail

# Parameters
USERNAME="${1:-vibeutils}"
USER_UID="${2:-1000}"
USER_GID="${3:-1000}"
USER_HOME="${4:-/home/$USERNAME}"

echo "Creating non-root user: $USERNAME (UID: $USER_UID, GID: $USER_GID)"

# Function to check if user already exists
user_exists() {
    id "$USERNAME" >/dev/null 2>&1
}

# Function to check if group already exists
group_exists() {
    getent group "$USER_GID" >/dev/null 2>&1
}

# Function to create group if it doesn't exist
create_group() {
    if ! group_exists; then
        echo "Creating group with GID $USER_GID..."
        groupadd -g "$USER_GID" "$USERNAME"
    else
        local existing_group
        existing_group=$(getent group "$USER_GID" | cut -d: -f1)
        echo "Group with GID $USER_GID already exists: $existing_group"
    fi
}

# Function to create user
create_user() {
    if user_exists; then
        echo "User $USERNAME already exists, updating configuration..."
        # Update user configuration if needed
        usermod -u "$USER_UID" -g "$USER_GID" -d "$USER_HOME" -s /bin/bash "$USERNAME" 2>/dev/null || true
    else
        echo "Creating user $USERNAME..."
        useradd \
            --uid "$USER_UID" \
            --gid "$USER_GID" \
            --home-dir "$USER_HOME" \
            --create-home \
            --shell /bin/bash \
            --comment "Non-root user for vibeutils testing" \
            "$USERNAME"
    fi
}

# Function to set up user home directory
setup_home_directory() {
    echo "Setting up home directory: $USER_HOME"
    
    # Ensure home directory exists with correct ownership
    if [ ! -d "$USER_HOME" ]; then
        mkdir -p "$USER_HOME"
    fi
    
    chown -R "$USER_UID:$USER_GID" "$USER_HOME"
    chmod 755 "$USER_HOME"
    
    # Create basic shell configuration
    cat > "$USER_HOME/.bashrc" << 'EOF'
# Basic bashrc for vibeutils testing user
export PS1='\u@\h:\w\$ '
export PATH="/usr/local/bin:$PATH"
export FORCE_COLOR=1

# Zig cache directory
export ZIG_GLOBAL_CACHE_DIR="/home/vibeutils/.cache/zig"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

# Aliases for common commands
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Git configuration for testing
git config --global user.name "vibeutils-test"
git config --global user.email "test@vibeutils.local"
git config --global init.defaultBranch main
EOF
    
    # Create .profile for non-bash shells
    cat > "$USER_HOME/.profile" << 'EOF'
# Basic profile for vibeutils testing user
export PATH="/usr/local/bin:$PATH"
export FORCE_COLOR=1
export ZIG_GLOBAL_CACHE_DIR="/home/vibeutils/.cache/zig"
EOF
    
    # Create cache directories
    mkdir -p "$USER_HOME/.cache/zig"
    
    # Set ownership for all created files
    chown -R "$USER_UID:$USER_GID" "$USER_HOME"
}

# Function to configure sudo access (if sudo is available)
setup_sudo_access() {
    if command -v sudo >/dev/null 2>&1; then
        echo "Setting up sudo access for $USERNAME..."
        
        # Add user to sudo group if it exists
        if getent group sudo >/dev/null 2>&1; then
            usermod -aG sudo "$USERNAME"
            echo "Added $USERNAME to sudo group"
        fi
        
        # Create sudoers rule for passwordless sudo (for testing purposes)
        cat > "/etc/sudoers.d/$USERNAME" << EOF
# Allow $USERNAME passwordless sudo for testing
$USERNAME ALL=(ALL) NOPASSWD:ALL
EOF
        
        chmod 440 "/etc/sudoers.d/$USERNAME"
        echo "Configured passwordless sudo for $USERNAME"
    else
        echo "sudo not available, skipping sudo configuration"
    fi
}

# Function to add user to useful groups
add_to_groups() {
    echo "Adding $USERNAME to useful groups..."
    
    # List of groups to add user to (if they exist)
    local groups=("users" "staff" "dialout" "cdrom" "audio" "video" "plugdev")
    
    for group in "${groups[@]}"; do
        if getent group "$group" >/dev/null 2>&1; then
            usermod -aG "$group" "$USERNAME" 2>/dev/null || true
            echo "Added $USERNAME to group: $group"
        fi
    done
}

# Function to verify user creation
verify_user() {
    echo "Verifying user creation..."
    
    if ! user_exists; then
        echo "Error: User $USERNAME was not created successfully" >&2
        exit 1
    fi
    
    # Check user properties
    local user_info
    user_info=$(id "$USERNAME")
    echo "User info: $user_info"
    
    # Check home directory
    if [ ! -d "$USER_HOME" ]; then
        echo "Error: Home directory $USER_HOME does not exist" >&2
        exit 1
    fi
    
    # Check ownership
    local home_owner
    home_owner=$(stat -c '%U:%G' "$USER_HOME")
    if [ "$home_owner" != "$USERNAME:$USERNAME" ]; then
        echo "Warning: Home directory ownership is $home_owner, expected $USERNAME:$USERNAME" >&2
    fi
    
    echo "User $USERNAME created and configured successfully!"
}

# Main execution
main() {
    # Validate input parameters
    if [ -z "$USERNAME" ]; then
        echo "Error: Username is required" >&2
        exit 1
    fi
    
    if ! [[ "$USER_UID" =~ ^[0-9]+$ ]] || [ "$USER_UID" -lt 1000 ]; then
        echo "Error: Invalid UID: $USER_UID (must be >= 1000)" >&2
        exit 1
    fi
    
    if ! [[ "$USER_GID" =~ ^[0-9]+$ ]] || [ "$USER_GID" -lt 1000 ]; then
        echo "Error: Invalid GID: $USER_GID (must be >= 1000)" >&2
        exit 1
    fi
    
    # Create group first
    create_group
    
    # Create user
    create_user
    
    # Set up home directory
    setup_home_directory
    
    # Configure sudo access
    setup_sudo_access
    
    # Add to useful groups
    add_to_groups
    
    # Verify everything worked
    verify_user
}

# Run main function
main "$@"