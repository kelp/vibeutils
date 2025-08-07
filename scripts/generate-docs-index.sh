#!/bin/sh
# Generate index.html for documentation root and convert man pages

set -e

DOCS_DIR="zig-out/docs"
MAN_DIR="man/man1"

# Convert man pages to HTML if mandoc is available
if command -v mandoc >/dev/null 2>&1; then
    echo "Converting man pages to HTML..."
    mkdir -p "$DOCS_DIR/man"
    
    for manfile in "$MAN_DIR"/*.1; do
        if [ -f "$manfile" ]; then
            basename=$(basename "$manfile" .1)
            mandoc -T html -O style=man-style.css "$manfile" > "$DOCS_DIR/man/${basename}.html" 2>/dev/null || true
        fi
    done
    
    # Create a simple CSS file for man pages
    cat > "$DOCS_DIR/man/man-style.css" << 'MANCSS'
body { max-width: 80ch; margin: 2em auto; padding: 0 1em; font-family: monospace; line-height: 1.4; }
h1, h2 { border-bottom: 1px solid #ccc; padding-bottom: 0.3em; }
pre { background: #f4f4f4; padding: 1em; overflow-x: auto; }
@media (prefers-color-scheme: dark) {
    body { background: #1a1a1a; color: #e0e0e0; }
    pre { background: #2a2a2a; }
    h1, h2 { border-color: #444; }
    a { color: #66b3ff; }
}
MANCSS
    echo "Man pages converted to HTML in $DOCS_DIR/man/"
else
    echo "Note: mandoc not found, skipping man page HTML conversion"
fi

# Create index.html
cat > "$DOCS_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>vibeutils Documentation</title>
    <style>
        :root {
            --bg: #f7f7f7;
            --fg: #2a2a2a;
            --link: #0066cc;
            --link-hover: #0052a3;
            --border: #e0e0e0;
            --code-bg: #f0f0f0;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: #1a1a1a;
                --fg: #e0e0e0;
                --link: #66b3ff;
                --link-hover: #99ccff;
                --border: #333;
                --code-bg: #2a2a2a;
            }
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            line-height: 1.6;
            max-width: 900px;
            margin: 0 auto;
            padding: 2rem;
            background: var(--bg);
            color: var(--fg);
        }
        h1, h2 {
            border-bottom: 2px solid var(--border);
            padding-bottom: 0.5rem;
        }
        h1 {
            font-size: 2.5rem;
            margin-bottom: 1rem;
        }
        h2 {
            font-size: 1.5rem;
            margin-top: 2rem;
            margin-bottom: 1rem;
        }
        .description {
            font-size: 1.1rem;
            margin-bottom: 2rem;
            color: var(--fg);
            opacity: 0.9;
        }
        .utilities-table {
            width: 100%;
            border-collapse: collapse;
            margin-bottom: 2rem;
        }
        .utilities-table th {
            text-align: left;
            padding: 0.75rem;
            background: var(--code-bg);
            border-bottom: 2px solid var(--border);
            font-weight: 600;
        }
        .utilities-table td {
            padding: 0.75rem;
            border-bottom: 1px solid var(--border);
        }
        .utilities-table tr:hover {
            background: var(--code-bg);
        }
        .utility-name {
            font-family: monospace;
            font-weight: bold;
            color: var(--fg);
        }
        .doc-link {
            color: var(--link);
            text-decoration: none;
            padding: 0.25rem 0.5rem;
            margin-right: 0.5rem;
            background: var(--code-bg);
            border-radius: 3px;
            font-size: 0.9rem;
            transition: all 0.2s ease;
        }
        .doc-link:hover {
            background: var(--link);
            color: white;
        }
        .special-link {
            display: inline-block;
            padding: 1rem 1.5rem;
            background: var(--code-bg);
            border: 2px solid var(--border);
            border-radius: 4px;
            text-decoration: none;
            color: var(--link);
            font-weight: bold;
            margin-bottom: 2rem;
            transition: all 0.2s ease;
        }
        .special-link:hover {
            background: var(--border);
            color: var(--link-hover);
        }
        footer {
            margin-top: 3rem;
            padding-top: 1rem;
            border-top: 1px solid var(--border);
            text-align: center;
            opacity: 0.7;
            font-size: 0.9rem;
        }
        footer a {
            color: var(--link);
            text-decoration: none;
        }
        footer a:hover {
            text-decoration: underline;
        }
        code {
            background: var(--code-bg);
            padding: 0.2em 0.4em;
            border-radius: 3px;
            font-family: monospace;
        }
    </style>
</head>
<body>
    <h1>vibeutils Documentation</h1>
    
    <p class="description">
        A modern, clean-room implementation of POSIX and GNU core utilities in Zig, 
        focusing on correctness, performance, and user experience.
    </p>

    <h2>Core Library</h2>
    <a href="common/" class="special-link">📚 Common Library API Documentation</a>
    <p>Shared utilities and abstractions used across all commands.</p>

    <h2>Utilities</h2>
    <table class="utilities-table">
        <thead>
            <tr>
                <th>Command</th>
                <th>Description</th>
                <th>Documentation</th>
            </tr>
        </thead>
        <tbody>
            <tr>
                <td><span class="utility-name">basename</span></td>
                <td>Strip directory and suffix from filenames</td>
                <td>
                    <a href="basename/" class="doc-link">API</a>
                    <a href="man/basename.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">cat</span></td>
                <td>Concatenate and display files</td>
                <td>
                    <a href="cat/" class="doc-link">API</a>
                    <a href="man/cat.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">chmod</span></td>
                <td>Change file mode permissions</td>
                <td>
                    <a href="chmod/" class="doc-link">API</a>
                    <a href="man/chmod.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">chown</span></td>
                <td>Change file ownership</td>
                <td>
                    <a href="chown/" class="doc-link">API</a>
                    <a href="man/chown.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">cp</span></td>
                <td>Copy files and directories</td>
                <td>
                    <a href="cp/" class="doc-link">API</a>
                    <a href="man/cp.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">dirname</span></td>
                <td>Strip last component from file name</td>
                <td>
                    <a href="dirname/" class="doc-link">API</a>
                    <a href="man/dirname.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">echo</span></td>
                <td>Display a line of text</td>
                <td>
                    <a href="echo/" class="doc-link">API</a>
                    <a href="man/echo.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">false</span></td>
                <td>Exit with non-zero status</td>
                <td>
                    <a href="false/" class="doc-link">API</a>
                    <a href="man/false.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">head</span></td>
                <td>Display first lines of a file</td>
                <td>
                    <a href="head/" class="doc-link">API</a>
                    <a href="man/head.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">ln</span></td>
                <td>Create links between files</td>
                <td>
                    <a href="ln/" class="doc-link">API</a>
                    <a href="man/ln.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">ls</span></td>
                <td>List directory contents</td>
                <td>
                    <a href="ls/" class="doc-link">API</a>
                    <a href="man/ls.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">mkdir</span></td>
                <td>Create directories</td>
                <td>
                    <a href="mkdir/" class="doc-link">API</a>
                    <a href="man/mkdir.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">mv</span></td>
                <td>Move/rename files and directories</td>
                <td>
                    <a href="mv/" class="doc-link">API</a>
                    <a href="man/mv.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">pwd</span></td>
                <td>Print working directory</td>
                <td>
                    <a href="pwd/" class="doc-link">API</a>
                    <a href="man/pwd.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">rm</span></td>
                <td>Remove files and directories</td>
                <td>
                    <a href="rm/" class="doc-link">API</a>
                    <a href="man/rm.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">rmdir</span></td>
                <td>Remove empty directories</td>
                <td>
                    <a href="rmdir/" class="doc-link">API</a>
                    <a href="man/rmdir.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">sleep</span></td>
                <td>Delay for a specified time</td>
                <td>
                    <a href="sleep/" class="doc-link">API</a>
                    <a href="man/sleep.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">tail</span></td>
                <td>Display last lines of a file</td>
                <td>
                    <a href="tail/" class="doc-link">API</a>
                    <a href="man/tail.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">test / [</span></td>
                <td>Evaluate conditional expressions</td>
                <td>
                    <a href="test/" class="doc-link">API</a>
                    <a href="man/test.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">touch</span></td>
                <td>Change file timestamps</td>
                <td>
                    <a href="touch/" class="doc-link">API</a>
                    <a href="man/touch.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">true</span></td>
                <td>Exit with zero status</td>
                <td>
                    <a href="true/" class="doc-link">API</a>
                    <a href="man/true.html" class="doc-link">man page</a>
                </td>
            </tr>
            <tr>
                <td><span class="utility-name">yes</span></td>
                <td>Output a string repeatedly</td>
                <td>
                    <a href="yes/" class="doc-link">API</a>
                    <a href="man/yes.html" class="doc-link">man page</a>
                </td>
            </tr>
        </tbody>
    </table>

    <h2>Additional Resources</h2>
    <ul>
        <li><a href="https://github.com/kelp/vibeutils">GitHub Repository</a></li>
        <li><a href="https://github.com/kelp/vibeutils/blob/main/README.md">README</a></li>
        <li><a href="https://github.com/kelp/vibeutils/blob/main/TODO.md">Development Status</a></li>
        <li><a href="https://github.com/kelp/vibeutils/issues">Issue Tracker</a></li>
    </ul>

    <footer>
        <p>
            Generated with <code>zig build docs</code> | 
            <a href="https://github.com/kelp/vibeutils">vibeutils on GitHub</a> | 
            Built with <a href="https://ziglang.org/">Zig</a>
        </p>
    </footer>
</body>
</html>
EOF

echo "Generated documentation index at $DOCS_DIR/index.html"

# Handle the problematic "[" directory if it exists
if [ -d "$DOCS_DIR/[" ]; then
    echo "Note: Found '[' directory (test command alias), leaving as-is for Zig compatibility"
fi