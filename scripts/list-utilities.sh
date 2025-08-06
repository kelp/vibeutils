#!/bin/bash
# List all utilities defined in build.zig
# This script uses zig build system to get the authoritative list

set -e

# Run zig build --help and extract utility names from run steps
# The build system lists all runnable utilities as "run-<utility>" steps
zig build --help 2>&1 | \
  awk '/^  run-/ { 
    sub(/^  run-/, "")  # Remove the "  run-" prefix
    sub(/ .*/, "")      # Remove everything after the first space
    print 
  }'