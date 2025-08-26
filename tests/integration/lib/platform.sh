#!/usr/bin/env bash
# Platform detection and compatibility utilities for shell integration testing
# Supports Linux, macOS, Windows (WSL/MSYS2), and various Unix variants

# Platform detection variables
PLATFORM=""
PLATFORM_VERSION=""
PLATFORM_ARCH=""
PLATFORM_KERNEL=""
PLATFORM_DISTRO=""
PLATFORM_INITIALIZED=false

# Platform capability flags
HAS_GNU_COREUTILS=false
HAS_BSD_COREUTILS=false
HAS_FAKEROOT=false
HAS_TIMEOUT=false
HAS_REALPATH=false
HAS_GSTAT=false
HAS_GDATE=false
HAS_STAT=false
HAS_DATE=false

# Initialize platform detection
init_platform() {
    if [[ "$PLATFORM_INITIALIZED" == "true" ]]; then
        return 0
    fi
    
    # Detect kernel/OS
    local uname_s
    uname_s=$(uname -s 2>/dev/null) || uname_s="Unknown"
    PLATFORM_KERNEL="$uname_s"
    
    # Detect architecture
    PLATFORM_ARCH=$(uname -m 2>/dev/null || echo "unknown")
    
    # Platform-specific detection
    case "$uname_s" in
        Linux*)
            PLATFORM="linux"
            detect_linux_distro
            ;;
        Darwin*)
            PLATFORM="macos"
            PLATFORM_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
            ;;
        CYGWIN*|MINGW*|MSYS*)
            PLATFORM="windows"
            PLATFORM_VERSION=$(cmd //c ver 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
            ;;
        FreeBSD*)
            PLATFORM="freebsd"
            PLATFORM_VERSION=$(uname -r 2>/dev/null | cut -d'-' -f1)
            ;;
        OpenBSD*)
            PLATFORM="openbsd"
            PLATFORM_VERSION=$(uname -r 2>/dev/null)
            ;;
        NetBSD*)
            PLATFORM="netbsd"
            PLATFORM_VERSION=$(uname -r 2>/dev/null)
            ;;
        SunOS*)
            PLATFORM="solaris"
            PLATFORM_VERSION=$(uname -r 2>/dev/null)
            ;;
        *)
            PLATFORM="unknown"
            PLATFORM_VERSION="unknown"
            ;;
    esac
    
    # Detect tool capabilities
    detect_tool_capabilities
    
    PLATFORM_INITIALIZED=true
}

# Detect Linux distribution
detect_linux_distro() {
    local distro="unknown"
    local version="unknown"
    
    # Try /etc/os-release first (systemd standard)
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        distro="${ID:-unknown}"
        version="${VERSION_ID:-unknown}"
    # Try /etc/lsb-release (Ubuntu/derivatives)
    elif [[ -f /etc/lsb-release ]]; then
        source /etc/lsb-release
        distro=$(echo "${DISTRIB_ID:-unknown}" | tr '[:upper:]' '[:lower:]')
        version="${DISTRIB_RELEASE:-unknown}"
    # Try specific distribution files
    elif [[ -f /etc/redhat-release ]]; then
        if grep -q "CentOS" /etc/redhat-release; then
            distro="centos"
        elif grep -q "Red Hat" /etc/redhat-release; then
            distro="rhel"
        elif grep -q "Fedora" /etc/redhat-release; then
            distro="fedora"
        fi
        version=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1 || echo "unknown")
    elif [[ -f /etc/debian_version ]]; then
        distro="debian"
        version=$(cat /etc/debian_version)
    elif [[ -f /etc/arch-release ]]; then
        distro="arch"
        version="rolling"
    elif [[ -f /etc/alpine-release ]]; then
        distro="alpine"
        version=$(cat /etc/alpine-release)
    fi
    
    PLATFORM_DISTRO="$distro"
    PLATFORM_VERSION="$version"
}

# Detect tool capabilities and variants
detect_tool_capabilities() {
    # Check for GNU vs BSD coreutils
    if command -v ls >/dev/null 2>&1; then
        if ls --version 2>/dev/null | grep -q "GNU coreutils"; then
            HAS_GNU_COREUTILS=true
        elif ls -G . >/dev/null 2>&1; then  # BSD ls supports -G flag
            HAS_BSD_COREUTILS=true
        fi
    fi
    
    # Check for specific tools
    HAS_FAKEROOT=$(command -v fakeroot >/dev/null 2>&1 && echo true || echo false)
    HAS_TIMEOUT=$(command -v timeout >/dev/null 2>&1 && echo true || echo false)
    HAS_REALPATH=$(command -v realpath >/dev/null 2>&1 && echo true || echo false)
    HAS_STAT=$(command -v stat >/dev/null 2>&1 && echo true || echo false)
    HAS_DATE=$(command -v date >/dev/null 2>&1 && echo true || echo false)
    
    # Check for GNU variants on macOS (installed via Homebrew)
    if [[ "$PLATFORM" == "macos" ]]; then
        HAS_GSTAT=$(command -v gstat >/dev/null 2>&1 && echo true || echo false)
        HAS_GDATE=$(command -v gdate >/dev/null 2>&1 && echo true || echo false)
    fi
}

# Get platform string
get_platform() {
    [[ "$PLATFORM_INITIALIZED" == "false" ]] && init_platform
    echo "$PLATFORM"
}

# Get platform version
get_platform_version() {
    [[ "$PLATFORM_INITIALIZED" == "false" ]] && init_platform
    echo "$PLATFORM_VERSION"
}

# Get platform architecture
get_platform_arch() {
    [[ "$PLATFORM_INITIALIZED" == "false" ]] && init_platform
    echo "$PLATFORM_ARCH"
}

# Get Linux distribution (returns "unknown" for non-Linux)
get_linux_distro() {
    [[ "$PLATFORM_INITIALIZED" == "false" ]] && init_platform
    echo "${PLATFORM_DISTRO:-unknown}"
}

# Platform checking functions
is_linux() {
    [[ "$(get_platform)" == "linux" ]]
}

is_macos() {
    [[ "$(get_platform)" == "macos" ]]
}

is_windows() {
    [[ "$(get_platform)" == "windows" ]]
}

is_bsd() {
    local platform
    platform=$(get_platform)
    [[ "$platform" == "freebsd" ]] || [[ "$platform" == "openbsd" ]] || [[ "$platform" == "netbsd" ]]
}

is_unix() {
    local platform
    platform=$(get_platform)
    [[ "$platform" != "windows" ]] && [[ "$platform" != "unknown" ]]
}

# Distribution checking (Linux only)
is_ubuntu() {
    [[ "$(get_linux_distro)" == "ubuntu" ]]
}

is_debian() {
    local distro
    distro=$(get_linux_distro)
    [[ "$distro" == "debian" ]] || [[ "$distro" == "ubuntu" ]]  # Ubuntu is Debian-based
}

is_redhat() {
    local distro
    distro=$(get_linux_distro)
    [[ "$distro" == "rhel" ]] || [[ "$distro" == "centos" ]] || [[ "$distro" == "fedora" ]]
}

is_arch() {
    [[ "$(get_linux_distro)" == "arch" ]]
}

is_alpine() {
    [[ "$(get_linux_distro)" == "alpine" ]]
}

# Capability checking functions
has_gnu_coreutils() {
    [[ "$HAS_GNU_COREUTILS" == "true" ]]
}

has_bsd_coreutils() {
    [[ "$HAS_BSD_COREUTILS" == "true" ]]
}

has_fakeroot() {
    [[ "$HAS_FAKEROOT" == "true" ]]
}

has_timeout() {
    [[ "$HAS_TIMEOUT" == "true" ]]
}

has_realpath() {
    [[ "$HAS_REALPATH" == "true" ]]
}

# Get appropriate command for platform-specific operations
get_stat_cmd() {
    if [[ "$PLATFORM" == "macos" ]] && [[ "$HAS_GSTAT" == "true" ]]; then
        echo "gstat"
    elif [[ "$HAS_STAT" == "true" ]]; then
        echo "stat"
    else
        return 1
    fi
}

get_date_cmd() {
    if [[ "$PLATFORM" == "macos" ]] && [[ "$HAS_GDATE" == "true" ]]; then
        echo "gdate"
    elif [[ "$HAS_DATE" == "true" ]]; then
        echo "date"
    else
        return 1
    fi
}

get_timeout_cmd() {
    if [[ "$HAS_TIMEOUT" == "true" ]]; then
        echo "timeout"
    elif [[ "$PLATFORM" == "macos" ]] && command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout"
    else
        return 1
    fi
}

get_realpath_cmd() {
    if [[ "$HAS_REALPATH" == "true" ]]; then
        echo "realpath"
    elif [[ "$PLATFORM" == "macos" ]] && command -v grealpath >/dev/null 2>&1; then
        echo "grealpath"
    else
        # Fallback using readlink and pwd
        echo "_realpath_fallback"
    fi
}

# Fallback realpath implementation
_realpath_fallback() {
    local path="$1"
    if [[ -d "$path" ]]; then
        (cd "$path" && pwd)
    else
        local dir
        local file
        dir=$(dirname "$path")
        file=$(basename "$path")
        (cd "$dir" && printf "%s/%s\n" "$(pwd)" "$file")
    fi
}

# Get package manager for the platform
get_package_manager() {
    local platform
    platform=$(get_platform)
    
    case "$platform" in
        linux)
            local distro
            distro=$(get_linux_distro)
            case "$distro" in
                ubuntu|debian) echo "apt" ;;
                rhel|centos|fedora) echo "yum" ;;
                arch) echo "pacman" ;;
                alpine) echo "apk" ;;
                *) echo "unknown" ;;
            esac
            ;;
        macos)
            if command -v brew >/dev/null 2>&1; then
                echo "brew"
            elif command -v port >/dev/null 2>&1; then
                echo "macports"
            else
                echo "none"
            fi
            ;;
        freebsd) echo "pkg" ;;
        openbsd) echo "pkg_add" ;;
        netbsd) echo "pkgin" ;;
        *) echo "unknown" ;;
    esac
}

# Check if running in container/virtualized environment
is_container() {
    # Check for Docker
    [[ -f /.dockerenv ]] && return 0
    
    # Check for LXC
    [[ -f /proc/1/cgroup ]] && grep -q lxc /proc/1/cgroup && return 0
    
    # Check systemd container detection
    [[ -n "${container:-}" ]] && return 0
    
    # Check for WSL
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
    
    return 1
}

is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ "$(uname -r)" =~ Microsoft ]]
}

is_docker() {
    [[ -f /.dockerenv ]]
}

# Performance and resource information
get_cpu_count() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif [[ -f /proc/cpuinfo ]]; then
        grep -c ^processor /proc/cpuinfo
    elif [[ "$PLATFORM" == "macos" ]]; then
        sysctl -n hw.ncpu 2>/dev/null || echo 1
    elif [[ "$PLATFORM" == "freebsd" ]]; then
        sysctl -n hw.ncpu 2>/dev/null || echo 1
    else
        echo 1
    fi
}

get_memory_mb() {
    if [[ -f /proc/meminfo ]]; then
        awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
    elif [[ "$PLATFORM" == "macos" ]]; then
        echo $(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024))
    elif [[ "$PLATFORM" == "freebsd" ]]; then
        echo $(($(sysctl -n hw.physmem 2>/dev/null || echo 0) / 1024 / 1024))
    else
        echo 0
    fi
}

# Platform feature detection
supports_extended_attributes() {
    case "$PLATFORM" in
        linux) [[ -f /sys/fs/ext4 ]] || [[ -f /sys/fs/xfs ]] ;; 
        macos) true ;;  # macOS always supports extended attributes
        freebsd) true ;;
        *) false ;;
    esac
}

supports_acls() {
    case "$PLATFORM" in
        linux) command -v getfacl >/dev/null 2>&1 ;;
        macos) [[ -f /bin/ls ]] ;;  # macOS has basic ACL support
        freebsd) command -v getfacl >/dev/null 2>&1 ;;
        *) false ;;
    esac
}

supports_hardlinks() {
    # Most filesystems support hardlinks, but some network filesystems don't
    case "$PLATFORM" in
        windows) false ;;  # Generally not supported in MSYS2/Cygwin
        *) true ;;
    esac
}

supports_symlinks() {
    case "$PLATFORM" in
        windows) 
            # Windows 10+ with developer mode or admin privileges
            [[ -n "$WSL_DISTRO_NAME" ]] || [[ "$OSTYPE" == "msys" ]]
            ;;
        *) true ;;
    esac
}

# Print platform information (for debugging)
print_platform_info() {
    [[ "$PLATFORM_INITIALIZED" == "false" ]] && init_platform
    
    echo "Platform Information:"
    echo "  OS: $PLATFORM"
    echo "  Version: $PLATFORM_VERSION"
    echo "  Architecture: $PLATFORM_ARCH"
    echo "  Kernel: $PLATFORM_KERNEL"
    
    if [[ "$PLATFORM" == "linux" ]]; then
        echo "  Distribution: $PLATFORM_DISTRO"
    fi
    
    echo "Tool Capabilities:"
    echo "  GNU coreutils: $HAS_GNU_COREUTILS"
    echo "  BSD coreutils: $HAS_BSD_COREUTILS"
    echo "  fakeroot: $HAS_FAKEROOT"
    echo "  timeout: $HAS_TIMEOUT"
    echo "  realpath: $HAS_REALPATH"
    echo "  stat: $HAS_STAT"
    echo "  date: $HAS_DATE"
    
    if [[ "$PLATFORM" == "macos" ]]; then
        echo "  gstat: $HAS_GSTAT"
        echo "  gdate: $HAS_GDATE"
    fi
    
    echo "Environment:"
    echo "  Container: $(is_container && echo "yes" || echo "no")"
    echo "  WSL: $(is_wsl && echo "yes" || echo "no")"
    echo "  CPUs: $(get_cpu_count)"
    echo "  Memory: $(get_memory_mb)MB"
    echo "  Package Manager: $(get_package_manager)"
}

# Export platform variables and functions
export PLATFORM PLATFORM_VERSION PLATFORM_ARCH PLATFORM_KERNEL PLATFORM_DISTRO PLATFORM_INITIALIZED
export HAS_GNU_COREUTILS HAS_BSD_COREUTILS HAS_FAKEROOT HAS_TIMEOUT HAS_REALPATH HAS_GSTAT HAS_GDATE HAS_STAT HAS_DATE

export -f init_platform detect_linux_distro detect_tool_capabilities
export -f get_platform get_platform_version get_platform_arch get_linux_distro
export -f is_linux is_macos is_windows is_bsd is_unix
export -f is_ubuntu is_debian is_redhat is_arch is_alpine
export -f has_gnu_coreutils has_bsd_coreutils has_fakeroot has_timeout has_realpath
export -f get_stat_cmd get_date_cmd get_timeout_cmd get_realpath_cmd get_package_manager
export -f is_container is_wsl is_docker get_cpu_count get_memory_mb
export -f supports_extended_attributes supports_acls supports_hardlinks supports_symlinks
export -f print_platform_info _realpath_fallback