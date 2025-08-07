#!/bin/bash
# Check documentation quality and consistency
# Validates generated HTML and checks for common issues

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Script-specific variables
DOCS_DIR="docs/html"

# Show help
show_help() {
    cat << EOF
Usage: $0 [options]

Options:
  --generated-docs DIR Directory containing generated HTML docs (default: docs/html)
  --ci                 Run in CI mode (no colors, structured output)
  --verbose, -v        Show detailed output
  --help, -h           Show this help

Examples:
  $0 --generated-docs build/docs --verbose
  $0 --ci
EOF
}

# Parse script-specific arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --generated-docs)
            DOCS_DIR="$2"
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

# Check HTML structure
check_html_structure() {
    local file="$1"
    local issues=0
    
    log_debug "Checking HTML structure: $file"
    
    # Check for basic HTML structure
    if ! grep -q "<html" "$file"; then
        log_error "$file: Missing <html> tag"
        issues=$((issues + 1))
    fi
    
    if ! grep -q "</html>" "$file"; then
        log_error "$file: Missing </html> closing tag"
        issues=$((issues + 1))
    fi
    
    if ! grep -q "<head>" "$file" && ! grep -q "<head " "$file"; then
        log_warning "$file: Missing <head> section"
        issues=$((issues + 1))
    fi
    
    if ! grep -q "<title>" "$file"; then
        log_warning "$file: Missing <title> tag"
        issues=$((issues + 1))
    fi
    
    return $issues
}

# Check for broken internal links
check_internal_links() {
    local file="$1"
    local issues=0
    
    log_debug "Checking internal links: $file"
    
    # Extract href attributes pointing to local files
    local links
    links=$(grep -o 'href="[^"]*"' "$file" 2>/dev/null | sed 's/href="//;s/"//' | grep -v '^http' | grep -v '^#' || true)
    
    for link in $links; do
        # Skip external links and fragments
        if [[ "$link" =~ ^http ]] || [[ "$link" =~ ^# ]]; then
            continue
        fi
        
        local target_file
        if [[ "$link" =~ ^/ ]]; then
            # Absolute path within docs
            target_file="$DOCS_DIR${link}"
        else
            # Relative path
            target_file="$(dirname "$file")/${link}"
        fi
        
        if [ ! -f "$target_file" ]; then
            log_warning "$(basename "$file"): Broken internal link: $link"
            issues=$((issues + 1))
        fi
    done
    
    return $issues
}

# Check writing quality
check_writing_quality() {
    local total_issues=0
    
    log_info "Checking writing quality in documentation"
    
    # Check for TODO items
    if grep -r "TODO\|FIXME\|XXX" "$DOCS_DIR/" README.md 2>/dev/null | grep -v Binary; then
        log_warning "Found TODO items in documentation"
        total_issues=$((total_issues + 1))
    fi
    
    # Check for consistent terminology (fix the regex bug from architect review)
    if grep -r "utilit[yi]" README.md 2>/dev/null | grep -v "utilities"; then
        log_warning "Check utility/utilities consistency in README"
        total_issues=$((total_issues + 1))
    fi
    
    # Check for proper capitalization
    if grep -r "github" README.md 2>/dev/null | grep -v "GitHub"; then
        log_warning "Use 'GitHub' instead of 'github' for consistency"
        total_issues=$((total_issues + 1))
    fi
    
    return $total_issues
}

# Validate required files
validate_required_files() {
    local missing_files=()
    local required_files=("index.html")
    
    log_info "Validating required documentation files"
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$DOCS_DIR/$file" ]; then
            missing_files+=("$file")
            log_error "Required file not generated: $file"
        else
            log_debug "Found required file: $file"
        fi
    done
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        log_error "Missing ${#missing_files[@]} required files"
        return 1
    fi
    
    log_success "All required files present"
    return 0
}

# Check file sizes
check_file_sizes() {
    local issues=0
    
    log_info "Checking generated file sizes"
    
    find "$DOCS_DIR" -name "*.html" | while read file; do
        local size
        size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
        
        if [ "$size" -eq 0 ]; then
            log_error "Empty file: $(basename "$file")"
            issues=$((issues + 1))
        elif [ "$size" -lt 100 ]; then
            log_warning "Very small file (${size} bytes): $(basename "$file")"
            issues=$((issues + 1))
        else
            log_debug "File size OK: $(basename "$file") (${size} bytes)"
        fi
    done
    
    return $issues
}

# Main execution
main() {
    log_info "Checking documentation quality"
    log_info "Documentation directory: $DOCS_DIR"
    
    if [ ! -d "$DOCS_DIR" ]; then
        fatal "Documentation directory not found: $DOCS_DIR"
    fi
    
    local total_issues=0
    local total_files=0
    
    # Validate required files first
    validate_required_files || total_issues=$((total_issues + 1))
    
    # Check file sizes
    check_file_sizes
    local size_issues=$?
    total_issues=$((total_issues + size_issues))
    
    # Check each HTML file
    find "$DOCS_DIR" -name "*.html" | while read file; do
        total_files=$((total_files + 1))
        
        # Check HTML structure
        check_html_structure "$file"
        local html_issues=$?
        total_issues=$((total_issues + html_issues))
        
        # Check internal links
        check_internal_links "$file"
        local link_issues=$?
        total_issues=$((total_issues + link_issues))
    done
    
    # Check writing quality
    check_writing_quality
    local writing_issues=$?
    total_issues=$((total_issues + writing_issues))
    
    # Summary
    log_info "Quality check complete"
    log_info "Files checked: $total_files"
    log_info "Total issues: $total_issues"
    
    if [ $total_issues -eq 0 ]; then
        log_success "Documentation quality check passed"
    else
        log_warning "Found $total_issues quality issues"
        # Don't fail on quality issues, just warn
    fi
}

# Run main function
main