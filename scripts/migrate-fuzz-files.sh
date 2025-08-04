#!/bin/bash
#
# migrate-fuzz-files.sh - Migration script for updating fuzz files to use unified builder
#
# This script demonstrates how to migrate existing fuzz files to use the new
# createUtilityFuzzTests builder, reducing duplication and standardizing patterns.
#
# Usage: ./scripts/migrate-fuzz-files.sh [utility_name]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Function to migrate a single fuzz file
migrate_fuzz_file() {
    local util_name="$1"
    local fuzz_file="$PROJECT_ROOT/src/${util_name}_fuzz.zig"
    
    if [[ ! -f "$fuzz_file" ]]; then
        echo "Error: Fuzz file not found: $fuzz_file"
        return 1
    fi
    
    echo "Migrating: $fuzz_file"
    
    # Create backup
    cp "$fuzz_file" "${fuzz_file}.backup"
    
    # Create new file content with unified builder pattern
    cat > "$fuzz_file" << EOF
//! Streamlined fuzz tests for $util_name utility
//!
//! These tests verify the utility handles various inputs gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const ${util_name}_util = @import("${util_name}.zig");

// Create standardized fuzz tests using the unified builder
const ${util_name^}FuzzTests = common.fuzz.createUtilityFuzzTests(${util_name}_util.runUtility);

test "$util_name fuzz basic" {
    try std.testing.fuzz(testing.allocator, ${util_name^}FuzzTests.testBasic, .{});
}

test "$util_name fuzz paths" {
    try std.testing.fuzz(testing.allocator, ${util_name^}FuzzTests.testPaths, .{});
}

test "$util_name fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, ${util_name^}FuzzTests.testDeterministic, .{});
}

// Add utility-specific fuzz tests below this line as needed
EOF
    
    echo "Migration complete. Original backed up to ${fuzz_file}.backup"
    echo "NOTE: Review the migrated file and add any utility-specific tests that were removed."
}

# Function to capitalize first letter
capitalize() {
    echo "$1" | sed 's/^./\U&/'
}

# If no argument provided, show usage
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <utility_name>"
    echo "       $0 all    # Migrate all remaining fuzz files"
    echo ""
    echo "This script migrates fuzz files to use the unified createUtilityFuzzTests builder."
    echo "The original files are backed up with a .backup extension."
    echo ""
    echo "Examples:"
    echo "  $0 pwd           # Migrate src/pwd_fuzz.zig"
    echo "  $0 all           # Migrate all files (demonstration only)"
    exit 1
fi

if [[ "$1" == "all" ]]; then
    echo "Demonstration: This would migrate all fuzz files to use the unified builder."
    echo "The following files would be updated:"
    echo ""
    
    for fuzz_file in "$PROJECT_ROOT"/src/*_fuzz.zig; do
        if [[ -f "$fuzz_file" ]]; then
            basename "$fuzz_file" | sed 's/_fuzz\.zig$//'
        fi
    done | while read -r util_name; do
        # Skip files that are already migrated (have the unified builder pattern)
        if grep -q "createUtilityFuzzTests" "$PROJECT_ROOT/src/${util_name}_fuzz.zig" 2>/dev/null; then
            echo "  $util_name (already migrated)"
        else
            echo "  $util_name"
        fi
    done
    echo ""
    echo "To actually perform the migration, run individual commands like:"
    echo "  $0 pwd"
    echo "  $0 rm"
    echo "etc."
else
    migrate_fuzz_file "$1"
fi