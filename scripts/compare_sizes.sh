#!/bin/bash

# Script to compare binary sizes before and after migration
# Usage: ./compare_sizes.sh baseline_sizes.txt final_sizes.txt

BEFORE_FILE=$1
AFTER_FILE=$2

if [ -z "$BEFORE_FILE" ] || [ -z "$AFTER_FILE" ]; then
    echo "Usage: $0 <before_sizes.txt> <after_sizes.txt>"
    exit 1
fi

if [ ! -f "$BEFORE_FILE" ] || [ ! -f "$AFTER_FILE" ]; then
    echo "Error: One or both files not found"
    exit 1
fi

echo "Binary Size Comparison Report"
echo "============================="
echo "Comparing: $BEFORE_FILE vs $AFTER_FILE"
echo
printf "%-15s | %10s | %10s | %10s | %8s\n" "Utility" "Before" "After" "Reduction" "Percent"
echo "----------------|------------|------------|------------|----------"

TOTAL_BEFORE=0
TOTAL_AFTER=0
COUNT=0

# List of utilities to compare
UTILITIES="echo cat pwd chmod chown cp ln ls mkdir mv rm rmdir touch"

for UTILITY in $UTILITIES; do
    # Extract sizes from both files
    BEFORE_SIZE=$(grep -E "^-.*$UTILITY$" "$BEFORE_FILE" 2>/dev/null | awk '{print $5}')
    AFTER_SIZE=$(grep -E "^-.*$UTILITY$" "$AFTER_FILE" 2>/dev/null | awk '{print $5}')
    
    if [ -n "$BEFORE_SIZE" ] && [ -n "$AFTER_SIZE" ]; then
        REDUCTION=$((BEFORE_SIZE - AFTER_SIZE))
        if [ "$BEFORE_SIZE" -gt 0 ]; then
            PERCENT=$(echo "scale=1; $REDUCTION * 100 / $BEFORE_SIZE" | bc)
        else
            PERCENT="0.0"
        fi
        
        # Convert to human-readable
        BEFORE_HUMAN=$(numfmt --to=iec-i --suffix=B "$BEFORE_SIZE" 2>/dev/null || echo "${BEFORE_SIZE}B")
        AFTER_HUMAN=$(numfmt --to=iec-i --suffix=B "$AFTER_SIZE" 2>/dev/null || echo "${AFTER_SIZE}B")
        REDUCTION_HUMAN=$(numfmt --to=iec-i --suffix=B "$REDUCTION" 2>/dev/null || echo "${REDUCTION}B")
        
        printf "%-15s | %10s | %10s | %10s | %7s%%\n" \
            "$UTILITY" "$BEFORE_HUMAN" "$AFTER_HUMAN" "$REDUCTION_HUMAN" "$PERCENT"
        
        TOTAL_BEFORE=$((TOTAL_BEFORE + BEFORE_SIZE))
        TOTAL_AFTER=$((TOTAL_AFTER + AFTER_SIZE))
        COUNT=$((COUNT + 1))
    fi
done

if [ "$COUNT" -gt 0 ]; then
    echo "----------------|------------|------------|------------|----------"
    
    TOTAL_REDUCTION=$((TOTAL_BEFORE - TOTAL_AFTER))
    TOTAL_PERCENT=$(echo "scale=1; $TOTAL_REDUCTION * 100 / $TOTAL_BEFORE" | bc)
    
    TOTAL_BEFORE_HUMAN=$(numfmt --to=iec-i --suffix=B "$TOTAL_BEFORE" 2>/dev/null || echo "${TOTAL_BEFORE}B")
    TOTAL_AFTER_HUMAN=$(numfmt --to=iec-i --suffix=B "$TOTAL_AFTER" 2>/dev/null || echo "${TOTAL_AFTER}B")
    TOTAL_REDUCTION_HUMAN=$(numfmt --to=iec-i --suffix=B "$TOTAL_REDUCTION" 2>/dev/null || echo "${TOTAL_REDUCTION}B")
    
    printf "%-15s | %10s | %10s | %10s | %7s%%\n" \
        "TOTAL" "$TOTAL_BEFORE_HUMAN" "$TOTAL_AFTER_HUMAN" "$TOTAL_REDUCTION_HUMAN" "$TOTAL_PERCENT"
    
    echo
    echo "Summary:"
    echo "--------"
    echo "Total utilities compared: $COUNT"
    echo "Average size before: $(echo "scale=0; $TOTAL_BEFORE / $COUNT" | bc) bytes"
    echo "Average size after: $(echo "scale=0; $TOTAL_AFTER / $COUNT" | bc) bytes"
    echo "Average reduction: $(echo "scale=1; $TOTAL_REDUCTION * 100 / $TOTAL_BEFORE" | bc)%"
fi