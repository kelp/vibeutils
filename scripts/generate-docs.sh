#!/bin/bash
# Generate documentation locally for testing and debugging
# This script is used both locally and in GitHub Actions CI

set -e  # Exit on error

# Check if running in CI
CI_MODE=false
if [ "$1" = "--ci" ] || [ "$CI" = "true" ]; then
    CI_MODE=true
fi

# Colors for output (disable in CI for cleaner logs)
if [ "$CI_MODE" = true ]; then
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
fi

echo -e "${GREEN}=== vibeutils Documentation Generator ===${NC}"
echo "Mode: $([ "$CI_MODE" = true ] && echo "CI" || echo "Local")"
echo ""

# Check for required tools
echo "Checking required tools..."
for tool in mandoc zig; do
    if ! command -v $tool &> /dev/null; then
        echo -e "${RED}❌ Error: $tool is not installed${NC}"
        echo "Please install $tool before running this script"
        exit 1
    fi
done
echo -e "${GREEN}✅ All required tools found${NC}"
echo ""

# Create output directories
echo "Creating documentation directories..."
mkdir -p docs/html/man
mkdir -p zig-out/docs
echo -e "${GREEN}✅ Directories created${NC}"
echo ""

# Generate Zig documentation
echo "Generating Zig API documentation..."
if zig build docs; then
    echo -e "${GREEN}✅ Zig documentation generated${NC}"
    # Copy generated docs to output directory
    if [ -d "zig-out/docs" ]; then
        cp -r zig-out/docs/* docs/html/ 2>/dev/null || true
    fi
else
    echo -e "${YELLOW}⚠️  Warning: Zig documentation generation failed${NC}"
fi
echo ""

# Convert man pages to HTML
echo "Converting man pages to HTML..."
for manpage in man/man1/*.1; do
    if [ -f "$manpage" ]; then
        utility=$(basename "$manpage" .1)
        echo -n "  Converting ${utility}.1... "
        
        # Use mandoc for HTML output
        if mandoc -T html -O style=../style.css "$manpage" > "docs/html/man/${utility}.html" 2>/dev/null; then
            # Verify the HTML file was created and has content
            if [ -f "docs/html/man/${utility}.html" ]; then
                file_size=$(stat -f%z "docs/html/man/${utility}.html" 2>/dev/null || stat -c%s "docs/html/man/${utility}.html" 2>/dev/null || echo "0")
                if [ "$file_size" -gt "0" ]; then
                    echo -e "${GREEN}✅ (${file_size} bytes)${NC}"
                else
                    echo -e "${RED}❌ (empty file)${NC}"
                fi
            else
                echo -e "${RED}❌ (file not created)${NC}"
            fi
        else
            echo -e "${RED}❌ (conversion failed)${NC}"
        fi
    fi
done
echo ""

# Create CSS file
echo "Creating stylesheet..."
cat > docs/html/style.css << 'EOF'
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    line-height: 1.6;
    max-width: 800px;
    margin: 0 auto;
    padding: 20px;
    color: #333;
}

h1, h2, h3 { color: #2c3e50; }

code {
    background-color: #f4f4f4;
    padding: 2px 4px;
    border-radius: 3px;
    font-family: 'Monaco', 'Consolas', monospace;
}

pre {
    background-color: #f8f8f8;
    border: 1px solid #ddd;
    border-radius: 5px;
    padding: 15px;
    overflow-x: auto;
}

blockquote {
    border-left: 4px solid #3498db;
    margin: 0;
    padding-left: 20px;
    font-style: italic;
}

table {
    border-collapse: collapse;
    width: 100%;
}

th, td {
    border: 1px solid #ddd;
    padding: 8px;
    text-align: left;
}

th {
    background-color: #f2f2f2;
}

.utility-list {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 10px;
}

.utility-card {
    border: 1px solid #ddd;
    padding: 10px;
    border-radius: 5px;
}

.utility-card h3 {
    margin-top: 0;
}

a {
    color: #0066cc;
    text-decoration: none;
}

a:hover {
    text-decoration: underline;
}

footer {
    margin-top: 50px;
    padding-top: 20px;
    border-top: 1px solid #ddd;
    color: #666;
    font-size: 0.9em;
}
EOF
echo -e "${GREEN}✅ Stylesheet created${NC}"
echo ""

# Create documentation index
echo "Creating documentation index..."
cat > docs/html/index.html << 'EOF'
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
    
    <h2>Quick Links</h2>
    <ul>
        <li><a href="https://github.com/kelp/vibeutils">Source Code</a></li>
        <li><a href="https://github.com/kelp/vibeutils/blob/main/README.md">README</a></li>
        <li><a href="index.html">API Documentation</a></li>
    </ul>
    
    <h2>Utilities</h2>
    <div class="utility-list">
EOF

# Add utility cards
for utility in echo cat ls cp mv rm mkdir rmdir touch pwd chmod chown ln; do
    if [ -f "man/man1/${utility}.1" ]; then
        # Extract description from man page
        description=$(grep "^\.Nd" "man/man1/${utility}.1" | sed 's/^\.Nd //' || echo "Core utility")
        
        cat >> docs/html/index.html << EOF
        <div class="utility-card">
            <h3><a href="man/${utility}.html">${utility}</a></h3>
            <p>${description}</p>
        </div>
EOF
    fi
done

# Add footer with current date
cat >> docs/html/index.html << EOF
    </div>
    
    <footer>
        <p><em>Documentation generated on $(date)</em></p>
        <p><a href="https://github.com/kelp/vibeutils">View on GitHub</a></p>
    </footer>
</body>
</html>
EOF
echo -e "${GREEN}✅ Index page created${NC}"
echo ""

# Summary
echo -e "${GREEN}=== Documentation Generation Complete ===${NC}"
echo ""

if [ "$CI_MODE" = true ]; then
    echo "Documentation has been generated in: docs/html/"
    echo "Files will be uploaded as artifacts and deployed to GitHub Pages"
else
    echo "Documentation has been generated in: docs/html/"
    echo ""
    echo "To view the documentation locally:"
    echo "  1. Open docs/html/index.html in your browser"
    echo "  2. Or run a local server:"
    echo "     cd docs/html && python3 -m http.server 8000"
    echo "     Then visit http://localhost:8000"
    echo ""
    
    # Check if we should open in browser
    if [ "$1" = "--open" ]; then
        if command -v open &> /dev/null; then
            echo "Opening documentation in browser..."
            open docs/html/index.html
        elif command -v xdg-open &> /dev/null; then
            echo "Opening documentation in browser..."
            xdg-open docs/html/index.html
        fi
    fi
fi