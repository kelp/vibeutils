#!/bin/bash

# Script to benchmark a single utility
# Usage: ./benchmark_single_utility.sh <utility>

UTILITY=$1
ITERATIONS=1000

if [ -z "$UTILITY" ]; then
    echo "Usage: $0 <utility>"
    echo "Example: $0 echo"
    exit 1
fi

if [ ! -f "zig-out/bin/$UTILITY" ]; then
    echo "Error: Utility $UTILITY not found in zig-out/bin/"
    exit 1
fi

echo "Benchmarking $UTILITY"
echo "==================="
echo "Date: $(date)"
echo "Iterations: $ITERATIONS"
echo

# Binary size
SIZE=$(ls -l zig-out/bin/$UTILITY | awk '{print $5}')
SIZE_HUMAN=$(ls -lh zig-out/bin/$UTILITY | awk '{print $5}')
echo "Binary size: $SIZE bytes ($SIZE_HUMAN)"

# Check which parser is being used
if grep -q '@import("clap")' "src/$UTILITY.zig" 2>/dev/null; then
    echo "Parser: zig-clap"
else
    echo "Parser: custom argparse"
fi

echo -e "\nTiming common operations ($ITERATIONS iterations):"
echo "------------------------------------------------"

# Help flag timing
echo -n "Help flag (--help): "
HELP_TIME=$( { time -p for i in $(seq 1 $ITERATIONS); do
    ./zig-out/bin/$UTILITY --help > /dev/null 2>&1
done; } 2>&1 | grep real | awk '{print $2}')
echo "$HELP_TIME seconds total"
echo "  Per iteration: $(echo "scale=6; $HELP_TIME * 1000000 / $ITERATIONS" | bc) μs"

# Version flag timing
echo -n "Version flag (--version): "
VERSION_TIME=$( { time -p for i in $(seq 1 $ITERATIONS); do
    ./zig-out/bin/$UTILITY --version > /dev/null 2>&1
done; } 2>&1 | grep real | awk '{print $2}')
echo "$VERSION_TIME seconds total"
echo "  Per iteration: $(echo "scale=6; $VERSION_TIME * 1000000 / $ITERATIONS" | bc) μs"

# Invalid flag timing (error path)
echo -n "Invalid flag (--invalid): "
INVALID_TIME=$( { time -p for i in $(seq 1 $ITERATIONS); do
    ./zig-out/bin/$UTILITY --invalid > /dev/null 2>&1
done; } 2>&1 | grep real | awk '{print $2}')
echo "$INVALID_TIME seconds total"
echo "  Per iteration: $(echo "scale=6; $INVALID_TIME * 1000000 / $ITERATIONS" | bc) μs"

# Utility-specific tests
echo -e "\nUtility-specific tests:"
echo "----------------------"

case $UTILITY in
    echo)
        echo -n "Simple echo: "
        ECHO_TIME=$( { time -p for i in $(seq 1 $ITERATIONS); do
            ./zig-out/bin/$UTILITY "hello world" > /dev/null 2>&1
        done; } 2>&1 | grep real | awk '{print $2}')
        echo "$ECHO_TIME seconds total"
        ;;
    
    cat)
        echo -n "Cat with multiple flags: "
        CAT_TIME=$( { time -p for i in $(seq 1 $ITERATIONS); do
            echo "test" | ./zig-out/bin/$UTILITY -n > /dev/null 2>&1
        done; } 2>&1 | grep real | awk '{print $2}')
        echo "$CAT_TIME seconds total"
        ;;
    
    ls)
        echo -n "List /tmp with -la: "
        LS_TIME=$( { time -p for i in $(seq 1 $ITERATIONS); do
            ./zig-out/bin/$UTILITY -la /tmp > /dev/null 2>&1
        done; } 2>&1 | grep real | awk '{print $2}')
        echo "$LS_TIME seconds total"
        ;;
    
    pwd)
        echo -n "Print working directory: "
        PWD_TIME=$( { time -p for i in $(seq 1 $ITERATIONS); do
            ./zig-out/bin/$UTILITY > /dev/null 2>&1
        done; } 2>&1 | grep real | awk '{print $2}')
        echo "$PWD_TIME seconds total"
        ;;
    
    mkdir)
        echo -n "Mkdir help (dry run): "
        MKDIR_TIME=$( { time -p for i in $(seq 1 $ITERATIONS); do
            ./zig-out/bin/$UTILITY --help > /dev/null 2>&1
        done; } 2>&1 | grep real | awk '{print $2}')
        echo "$MKDIR_TIME seconds total"
        ;;
    
    *)
        echo "No specific tests for $UTILITY"
        ;;
esac

echo -e "\nMemory usage (RSS):"
echo "------------------"
# Run once and check memory
/usr/bin/time -v ./zig-out/bin/$UTILITY --help > /dev/null 2>&1 2> /tmp/time_output
MAX_RSS=$(grep "Maximum resident set size" /tmp/time_output | awk '{print $6}')
echo "Maximum RSS: $MAX_RSS KB"

echo -e "\nComplete!"