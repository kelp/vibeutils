# VS Code Configuration

This directory contains project-wide VS Code settings that help maintain consistent code style and developer experience across the vibeutils project.

## Files

- `settings.json` - Project-wide editor settings (shared)
- `extensions.json` - Recommended extensions (shared)
- `launch.json` - Debug configurations (user-specific, gitignored)
- `tasks.json` - Build tasks (user-specific, gitignored)

## Zig Language Support

The recommended Zig extension (`ziglang.vscode-zig`) provides:
- Syntax highlighting
- Code formatting with `zig fmt`
- Language server (ZLS) integration
- Error reporting

Make sure you have Zig and ZLS installed and available in your PATH.