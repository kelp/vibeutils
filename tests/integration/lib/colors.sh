#!/usr/bin/env bash
# Color output handling for shell integration testing framework
# Supports NO_COLOR environment variable and terminal capability detection

# Color codes - will be set by init_colors()
RED=""
GREEN=""
YELLOW=""
BLUE=""
MAGENTA=""
CYAN=""
WHITE=""
BOLD=""
DIM=""
NC=""  # No Color

# Color state
COLORS_ENABLED=false
COLORS_INITIALIZED=false

# Initialize color support
# Respects NO_COLOR environment variable and terminal capabilities
init_colors() {
    # If already initialized, skip
    if [[ "$COLORS_INITIALIZED" == "true" ]]; then
        return 0
    fi
    
    COLORS_ENABLED=false
    
    # Check NO_COLOR environment variable (https://no-color.org/)
    if [[ -n "${NO_COLOR:-}" ]]; then
        COLORS_ENABLED=false
    # Check if terminal supports colors
    elif [[ -t 1 ]] && [[ -t 2 ]]; then
        # Check if we have a terminal that supports colors
        local term="${TERM:-}"
        if [[ -n "$term" ]] && [[ "$term" != "dumb" ]]; then
            # Check if tput is available and terminal supports colors
            if command -v tput >/dev/null 2>&1; then
                local colors
                colors=$(tput colors 2>/dev/null) || colors=0
                if [[ "$colors" -ge 8 ]]; then
                    COLORS_ENABLED=true
                fi
            else
                # Fallback: assume color support for common terminals
                case "$term" in
                    *color*|*256*|xterm*|screen*|tmux*)
                        COLORS_ENABLED=true
                        ;;
                esac
            fi
        fi
    fi
    
    # Set color codes if colors are enabled
    if [[ "$COLORS_ENABLED" == "true" ]]; then
        RED=$'\033[0;31m'
        GREEN=$'\033[0;32m'
        YELLOW=$'\033[1;33m'
        BLUE=$'\033[0;34m'
        MAGENTA=$'\033[0;35m'
        CYAN=$'\033[0;36m'
        WHITE=$'\033[1;37m'
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
        NC=$'\033[0m'
    else
        # No colors - set all to empty
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        MAGENTA=""
        CYAN=""
        WHITE=""
        BOLD=""
        DIM=""
        NC=""
    fi
    
    COLORS_INITIALIZED=true
}

# Force enable colors (override NO_COLOR and terminal detection)
force_enable_colors() {
    COLORS_ENABLED=true
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
    COLORS_INITIALIZED=true
}

# Force disable colors
force_disable_colors() {
    COLORS_ENABLED=false
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    MAGENTA=""
    CYAN=""
    WHITE=""
    BOLD=""
    DIM=""
    NC=""
    COLORS_INITIALIZED=true
}

# Check if colors are enabled
colors_enabled() {
    [[ "$COLORS_ENABLED" == "true" ]]
}

# Basic colored output functions
print_red() {
    printf "%s%s%s\\n" "$RED" "$1" "$NC"
}

print_green() {
    printf "%s%s%s\\n" "$GREEN" "$1" "$NC"
}

print_yellow() {
    printf "%s%s%s\\n" "$YELLOW" "$1" "$NC"
}

print_blue() {
    printf "%s%s%s\\n" "$BLUE" "$1" "$NC"
}

print_magenta() {
    printf "%s%s%s\\n" "$MAGENTA" "$1" "$NC"
}

print_cyan() {
    printf "%s%s%s\\n" "$CYAN" "$1" "$NC"
}

print_white() {
    printf "%s%s%s\\n" "$WHITE" "$1" "$NC"
}

print_bold() {
    printf "%s%s%s\\n" "$BOLD" "$1" "$NC"
}

print_dim() {
    printf "%s%s%s\\n" "$DIM" "$1" "$NC"
}

# Semantic output functions for testing
print_success() {
    printf "%s✓ %s%s\\n" "$GREEN$BOLD" "$1" "$NC"
}

print_error() {
    printf "%s✗ %s%s\\n" "$RED$BOLD" "$1" "$NC" >&2
}

print_warning() {
    printf "%s⚠ %s%s\\n" "$YELLOW$BOLD" "$1" "$NC" >&2
}

print_info() {
    printf "%sℹ %s%s\\n" "$BLUE" "$1" "$NC"
}

print_debug() {
    if [[ "${TEST_VERBOSE:-false}" == "true" ]]; then
        printf "%s🐛 %s%s\\n" "$DIM" "$1" "$NC" >&2
    fi
}

# Test status functions
print_test_pass() {
    local test_name="$1"
    printf "%s[PASS]%s %s\\n" "$GREEN$BOLD" "$NC" "$test_name"
}

print_test_fail() {
    local test_name="$1"
    printf "%s[FAIL]%s %s\\n" "$RED$BOLD" "$NC" "$test_name"
}

print_test_skip() {
    local test_name="$1"
    local reason="$2"
    printf "%s[SKIP]%s %s %s(%s)%s\\n" "$YELLOW$BOLD" "$NC" "$test_name" "$DIM" "$reason" "$NC"
}

print_test_timeout() {
    local test_name="$1"
    local timeout="$2"
    printf "%s[TIMEOUT]%s %s %s(${timeout}s)%s\\n" "$MAGENTA$BOLD" "$NC" "$test_name" "$DIM" "$NC"
}

# Suite formatting functions
print_suite_header() {
    local suite_name="$1"
    local separator_char="="
    local separator_width=60
    
    printf "\\n"
    printf "%s" "$BOLD$CYAN"
    printf "%*s\\n" "$separator_width" "" | sed "s/ /$separator_char/g"
    printf " %s\\n" "$suite_name"
    printf "%*s\\n" "$separator_width" "" | sed "s/ /$separator_char/g"
    printf "%s\\n" "$NC"
}

print_suite_footer() {
    local suite_name="$1"
    local duration="$2"
    local separator_char="-"
    local separator_width=60
    
    printf "\\n%s" "$DIM"
    printf "%*s\\n" "$separator_width" "" | sed "s/ /$separator_char/g"
    printf " %s completed in %ds\\n" "$suite_name" "$duration"
    printf "%*s\\n" "$separator_width" "" | sed "s/ /$separator_char/g"
    printf "%s\\n" "$NC"
}

# Progress indicators
print_progress() {
    local current="$1"
    local total="$2"
    local message="${3:-}"
    
    local percentage=$((current * 100 / total))
    local bar_width=20
    local filled_width=$((percentage * bar_width / 100))
    
    printf "\\r%s[" "$BOLD"
    printf "%*s" "$filled_width" "" | sed 's/ /█/g'
    printf "%*s" "$((bar_width - filled_width))" "" | sed 's/ /░/g'
    printf "] %3d%% %s%s" "$percentage" "$message" "$NC"
    
    if [[ $current -eq $total ]]; then
        printf "\\n"
    fi
}

# Spinner animation for long operations
print_spinner() {
    local pid="$1"
    local message="${2:-Processing}"
    local spinner_chars="⣾⣽⣻⢿⡿⣟⣯⣷"
    local i=0
    
    printf "%s" "$DIM"
    while kill -0 "$pid" 2>/dev/null; do
        printf "\\r%s %s..." "${spinner_chars:$((i % ${#spinner_chars})):1}" "$message"
        sleep 0.1
        ((i++))
    done
    printf "\\r%*s\\r%s" $((${#message} + 10)) "" "$NC"
}

# Formatting utilities
print_separator() {
    local char="${1:--}"
    local width="${2:-60}"
    printf "%s%*s%s\\n" "$DIM" "$width" "" "$NC" | sed "s/ /$char/g"
}

print_header() {
    local title="$1"
    local width=60
    
    printf "\\n%s" "$BOLD$WHITE"
    printf "%*s\\n" "$width" "" | sed 's/ /=/g'
    printf " %s\\n" "$title"
    printf "%*s\\n" "$width" "" | sed 's/ /=/g'
    printf "%s\\n" "$NC"
}

print_subheader() {
    local title="$1"
    printf "%s%s%s\\n" "$BOLD$CYAN" "$title" "$NC"
}

# Table formatting
print_table_row() {
    local -a columns=("$@")
    local -a widths=(20 15 10 30)  # Default column widths
    
    for i in "${!columns[@]}"; do
        local width=${widths[i]:-20}
        printf "%-${width}s" "${columns[i]}"
    done
    printf "\\n"
}

print_table_header() {
    local -a headers=("$@")
    print_table_row "${headers[@]}"
    
    # Print separator line
    for width in 20 15 10 30; do
        printf "%*s" "$width" "" | sed 's/ /-/g'
    done
    printf "\\n"
}

# Indentation utilities
print_indented() {
    local indent_level="${1:-1}"
    local message="$2"
    local indent_char=" "
    local indent_size=2
    
    local total_indent=$((indent_level * indent_size))
    printf "%*s%s\\n" "$total_indent" "$indent_char" "$message"
}

# Export color variables and functions
export RED GREEN YELLOW BLUE MAGENTA CYAN WHITE BOLD DIM NC
export COLORS_ENABLED COLORS_INITIALIZED
export -f init_colors force_enable_colors force_disable_colors colors_enabled
export -f print_red print_green print_yellow print_blue print_magenta print_cyan print_white print_bold print_dim
export -f print_success print_error print_warning print_info print_debug
export -f print_test_pass print_test_fail print_test_skip print_test_timeout
export -f print_suite_header print_suite_footer print_progress print_spinner
export -f print_separator print_header print_subheader
export -f print_table_row print_table_header print_indented