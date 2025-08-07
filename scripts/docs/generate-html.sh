#!/bin/bash
# Generate HTML documentation using templates
# Modern replacement for inline HTML generation

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Script-specific variables
UTILITIES=""
FORCE_REBUILD=false
OUTPUT_DIR="docs/html"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

# Show help
show_help() {
    cat << EOF
Usage: $0 [options]

Options:
  --utilities LIST     Space-separated list of utilities to document
  --force-rebuild      Force complete documentation rebuild
  --output-dir DIR     Output directory for HTML files (default: docs/html)
  --ci                 Run in CI mode (no colors, structured output)
  --verbose, -v        Show detailed output
  --help, -h           Show this help

Examples:
  $0 --utilities "echo cat ls" --output-dir build/docs
  $0 --force-rebuild --ci
EOF
}

# Parse script-specific arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --utilities)
            UTILITIES="$2"
            shift 2
            ;;
        --force-rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            parse_common_args "$1"
            if [ $? -eq 0 ]; then
                shift
            else
                fatal "Unknown option: $1"
            fi
            ;;
    esac
done

# Generate utility card HTML
generate_utility_card() {
    local utility="$1"
    local template="$TEMPLATE_DIR/utility-card.template"
    local man_file="man/man1/${utility}.1"
    
    # Extract description from man page
    local description="Core utility"
    if [ -f "$man_file" ]; then
        description=$(grep "^\.Nd" "$man_file" | sed 's/^\.Nd //' || echo "Core utility")
    fi
    
    # Use template if available, otherwise inline generation
    if [ -f "$template" ]; then
        sed -e "s/{{UTILITY}}/$utility/g" \
            -e "s/{{DESCRIPTION}}/$description/g" \
            -e "s/{{GITHUB_REPO}}/$GITHUB_REPOSITORY/g" \
            "$template"
    else
        cat << EOF
        <div class="utility-card">
            <h3><a href="man/${utility}.html">${utility}</a></h3>
            <p>${description}</p>
            <div><a href="https://github.com/${GITHUB_REPOSITORY}/blob/main/src/${utility}.zig">Source Code</a></div>
        </div>
EOF
    fi
}

# Generate main index.html
generate_index() {
    local template="$TEMPLATE_DIR/index.html.template"
    local output_file="$OUTPUT_DIR/index.html"
    local utility_count
    
    utility_count=$(echo "$UTILITIES" | wc -w)
    
    log_info "Generating main index page"
    
    if [ -f "$template" ]; then
        # Use template system
        {
            # Replace template variables
            sed -e "s/{{UTILITY_COUNT}}/$utility_count/g" \
                -e "s/{{BUILD_DATE}}/$(date -u)/g" \
                -e "s/{{ZIG_VERSION}}/${ZIG_VERSION:-0.14.1}/g" \
                -e "s/{{GITHUB_REPO}}/$GITHUB_REPOSITORY/g" \
                "$template"
            
            # Insert utility cards
            for utility in $UTILITIES; do
                if [ -f "man/man1/${utility}.1" ]; then
                    generate_utility_card "$utility"
                fi
            done
            
            # Close template
            echo '    </div>'
            echo '    <footer>'
            echo "        <p><em>Documentation generated on $(date -u)</em></p>"
            echo "        <p><a href=\"https://github.com/$GITHUB_REPOSITORY\">View on GitHub</a></p>"
            echo '    </footer>'
            echo '</body>'
            echo '</html>'
        } > "$output_file"
    else
        # Fallback inline generation
        log_warning "Template not found, using fallback generation"
        cat > "$output_file" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>vibeutils Documentation</title>
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <h1>vibeutils Documentation</h1>
    <p>Modern Zig implementation of GNU coreutils with enhanced UX features.</p>
    
    <div class="stats">
        <strong>Statistics:</strong>
        <ul>
            <li>Total Utilities: $utility_count</li>
            <li>Build Date: $(date -u)</li>
            <li>Zig Version: ${ZIG_VERSION:-0.14.1}</li>
        </ul>
    </div>
    
    <h2>Available Utilities</h2>
    <div class="utility-grid">
EOF
        
        for utility in $UTILITIES; do
            if [ -f "man/man1/${utility}.1" ]; then
                generate_utility_card "$utility" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" << EOF
    </div>
    
    <footer>
        <p><em>Documentation generated on $(date -u)</em></p>
        <p><a href="https://github.com/$GITHUB_REPOSITORY">View on GitHub</a></p>
    </footer>
</body>
</html>
EOF
    fi
    
    log_success "Generated: $output_file"
}

# Convert man pages to HTML
convert_man_pages() {
    local man_dir="$OUTPUT_DIR/man"
    
    ensure_dir "$man_dir"
    log_info "Converting man pages to HTML"
    
    for utility in $UTILITIES; do
        local man_file="man/man1/${utility}.1"
        local html_file="$man_dir/${utility}.html"
        
        if [ ! -f "$man_file" ]; then
            log_warning "No man page found for $utility"
            continue
        fi
        
        log_debug "Converting $man_file to HTML"
        
        if mandoc -T html -O style=../style.css "$man_file" > "$html_file" 2>/dev/null; then
            local file_size
            file_size=$(stat -f%z "$html_file" 2>/dev/null || stat -c%s "$html_file" 2>/dev/null || echo "0")
            if [ "$file_size" -gt 0 ]; then
                log_success "Converted $utility.1 (${file_size} bytes)"
            else
                log_error "Empty output for $utility.1"
            fi
        else
            log_error "Failed to convert $utility.1"
        fi
    done
}

# Copy CSS styles
copy_styles() {
    local css_template="$TEMPLATE_DIR/style.css"
    local css_output="$OUTPUT_DIR/style.css"
    
    if [ -f "$css_template" ]; then
        cp "$css_template" "$css_output"
        log_success "Copied stylesheet from template"
    else
        log_warning "CSS template not found, generating default styles"
        # Generate minimal CSS
        cat > "$css_output" << 'EOF'
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 2em; }
.utility-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 1em; }
.utility-card { border: 1px solid #ddd; padding: 1em; border-radius: 8px; }
EOF
    fi
}

# Main execution
main() {
    log_info "Generating HTML documentation"
    log_info "Output directory: $OUTPUT_DIR"
    log_info "Force rebuild: $([ "$FORCE_REBUILD" = true ] && echo "Yes" || echo "No")"
    
    # Require tools
    require_tool mandoc "Ubuntu/Debian: sudo apt-get install mandoc; macOS: brew install mandoc" || exit 1
    require_tool zig || exit 1
    
    # Get utilities list
    if [ -z "$UTILITIES" ]; then
        UTILITIES=$(find src -name "*.zig" -not -name "common*" -not -name "main.zig" \
            -exec basename {} .zig \; | sort | tr '\n' ' ')
        log_info "Auto-discovered utilities: $UTILITIES"
    fi
    
    # Set default GitHub repository if not set
    if [ -z "$GITHUB_REPOSITORY" ]; then
        GITHUB_REPOSITORY="kelp/vibeutils"
    fi
    
    # Create output directories
    ensure_dir "$OUTPUT_DIR"
    
    # Generate documentation
    copy_styles
    convert_man_pages
    generate_index
    
    log_success "HTML documentation generation complete"
    log_info "Documentation available in: $OUTPUT_DIR"
}

# Run main function
main