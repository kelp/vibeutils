#!/bin/sh
# Generate index.html for documentation root

set -e

DOCS_DIR="zig-out/docs"

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
        .utilities-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
            gap: 1rem;
            margin-bottom: 2rem;
        }
        .utility-link {
            display: block;
            padding: 0.75rem;
            background: var(--code-bg);
            border: 1px solid var(--border);
            border-radius: 4px;
            text-decoration: none;
            color: var(--link);
            font-family: monospace;
            font-size: 1rem;
            transition: all 0.2s ease;
        }
        .utility-link:hover {
            background: var(--border);
            color: var(--link-hover);
            transform: translateY(-2px);
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
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
    <a href="common/" class="special-link">📚 Common Library Documentation</a>
    <p>Shared utilities and abstractions used across all commands.</p>

    <h2>Utilities</h2>
    <div class="utilities-grid">
        <a href="basename/" class="utility-link">basename</a>
        <a href="cat/" class="utility-link">cat</a>
        <a href="chmod/" class="utility-link">chmod</a>
        <a href="chown/" class="utility-link">chown</a>
        <a href="cp/" class="utility-link">cp</a>
        <a href="dirname/" class="utility-link">dirname</a>
        <a href="echo/" class="utility-link">echo</a>
        <a href="false/" class="utility-link">false</a>
        <a href="head/" class="utility-link">head</a>
        <a href="ln/" class="utility-link">ln</a>
        <a href="ls/" class="utility-link">ls</a>
        <a href="mkdir/" class="utility-link">mkdir</a>
        <a href="mv/" class="utility-link">mv</a>
        <a href="pwd/" class="utility-link">pwd</a>
        <a href="rm/" class="utility-link">rm</a>
        <a href="rmdir/" class="utility-link">rmdir</a>
        <a href="sleep/" class="utility-link">sleep</a>
        <a href="tail/" class="utility-link">tail</a>
        <a href="test/" class="utility-link">test</a>
        <a href="touch/" class="utility-link">touch</a>
        <a href="true/" class="utility-link">true</a>
        <a href="yes/" class="utility-link">yes</a>
    </div>

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