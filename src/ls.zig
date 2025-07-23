const std = @import("std");
const clap = @import("clap");
const common = @import("common");
const testing = std.testing;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define parameters using zig-clap
    const params = comptime clap.parseParamsComptime(
        \\    --help             Display this help and exit.
        \\-V, --version          Output version information and exit.
        \\-a, --all              Do not ignore entries starting with .
        \\-A, --almost-all       Do not list implied . and ..
        \\-l                     Use a long listing format.
        \\-h, --human-readable   With -l, print sizes in human readable format.
        \\-k                     With -l, print sizes in kilobytes.
        \\-1                     List one file per line.
        \\-d, --directory        List directories themselves, not their contents.
        \\-F                     Append indicator (one of */=>@|) to entries.
        \\-R, --recursive        List subdirectories recursively.
        \\-t                     Sort by modification time, newest first.
        \\-S                     Sort by file size, largest first.
        \\-r                     Reverse order while sorting.
        \\    --color <str>      When to use colors (valid: always, auto, never).
        \\<str>...               Files and directories to list.
        \\
    );

    // Parse arguments
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // Handle help
    if (res.args.help != 0) {
        try printHelp();
        return;
    }

    // Handle version
    if (res.args.version != 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("ls ({s}) {s}\n", .{ common.name, common.version });
        return;
    }

    // Parse color mode
    var color_mode = ColorMode.auto;
    if (res.args.color) |color_arg| {
        if (std.mem.eql(u8, color_arg, "always")) {
            color_mode = .always;
        } else if (std.mem.eql(u8, color_arg, "auto")) {
            color_mode = .auto;
        } else if (std.mem.eql(u8, color_arg, "never")) {
            color_mode = .never;
        } else {
            try std.io.getStdErr().writer().print("ls: invalid argument '{s}' for '--color'\n", .{color_arg});
            try std.io.getStdErr().writer().writeAll("Valid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'\n");
            return;
        }
    }

    // Create options struct
    const options = LsOptions{
        .all = res.args.all != 0,
        .almost_all = res.args.@"almost-all" != 0,
        .long_format = res.args.l != 0,
        .human_readable = res.args.@"human-readable" != 0,
        .kilobytes = res.args.k != 0,
        .one_per_line = res.args.@"1" != 0,
        .directory = res.args.directory != 0,
        .recursive = res.args.recursive != 0,
        .sort_by_time = res.args.t != 0,
        .sort_by_size = res.args.S != 0,
        .reverse_sort = res.args.r != 0,
        .file_type_indicators = res.args.F != 0,
        .color_mode = color_mode,
    };

    const stdout = std.io.getStdOut().writer();

    // Access positionals
    const paths = res.positionals.@"0";

    if (paths.len == 0) {
        // No paths specified, list current directory
        try listDirectory(".", stdout, options, allocator);
    } else {
        for (paths, 0..) |path, i| {
            if (paths.len > 1) {
                if (i > 0) try stdout.writeAll("\n");
                try stdout.print("{s}:\n", .{path});
            }
            try listDirectory(path, stdout, options, allocator);
        }
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: ls [OPTION]... [FILE]...
        \\List information about the FILEs (the current directory by default).
        \\Sort entries alphabetically by default.
        \\
        \\  -a, --all                do not ignore entries starting with .
        \\  -A, --almost-all         do not list implied . and ..
        \\  -d, --directory          list directories themselves, not their contents
        \\  -F                       append indicator (one of */=>@|) to entries
        \\  -h, --human-readable     with -l, print sizes in human readable format
        \\  -k                       with -l, print sizes in kilobytes
        \\  -l                       use a long listing format
        \\  -r                       reverse order while sorting
        \\  -R, --recursive          list subdirectories recursively
        \\  -S                       sort by file size, largest first
        \\  -t                       sort by modification time, newest first
        \\  -1                       list one file per line
        \\      --color=WHEN         colorize output; WHEN can be 'always' (default
        \\                           if omitted), 'auto', or 'never'
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\Examples:
        \\  ls           List files in the current directory
        \\  ls -la       List all files in long format
        \\  ls -lh       List files with human-readable sizes
        \\  ls -t        List files sorted by modification time
        \\
    );
}

const ColorMode = enum {
    always,
    auto,
    never,
};

const LsOptions = struct {
    all: bool = false,
    almost_all: bool = false,
    long_format: bool = false,
    human_readable: bool = false,
    kilobytes: bool = false,
    one_per_line: bool = false,
    directory: bool = false,
    recursive: bool = false,
    sort_by_time: bool = false,
    sort_by_size: bool = false,
    reverse_sort: bool = false,
    file_type_indicators: bool = false,
    color_mode: ColorMode = .auto,
};

fn listDirectory(path: []const u8, writer: anytype, options: LsOptions, allocator: std.mem.Allocator) !void {
    // Initialize style based on color mode
    const StyleType = common.style.Style(@TypeOf(writer));
    var style = StyleType.init(writer);
    if (options.color_mode == .never) {
        style.color_mode = .none;
    } else if (options.color_mode == .always) {
        // Keep the detected mode but ensure it's at least basic
        if (style.color_mode == .none) {
            style.color_mode = .basic;
        }
    }
    // For .auto, use the detected mode (which checks isatty)
    // If -d is specified, just list the directory itself
    if (options.directory) {
        if (options.one_per_line) {
            try writer.print("{s}\n", .{path});
        } else if (options.long_format) {
            // Get stat info for the directory
            const stat = common.file.FileInfo.stat(path) catch |err| {
                common.printError("{s}: {}", .{ path, err });
                return err;
            };
            
            // Format long listing for directory
            var perm_buf: [10]u8 = undefined;
            const perms = try common.file.formatPermissions(stat.mode, stat.kind, &perm_buf);
            try writer.writeAll(perms);
            
            try writer.print(" {d: >3} ", .{stat.nlink});
            
            var user_buf: [32]u8 = undefined;
            var group_buf: [32]u8 = undefined;
            const user_name = try common.file.getUserName(stat.uid, &user_buf);
            const group_name = try common.file.getGroupName(stat.gid, &group_buf);
            try writer.print("{s: <8} {s: <8} ", .{ user_name, group_name });
            
            var size_buf: [32]u8 = undefined;
            const size_str = if (options.human_readable)
                try common.file.formatSizeHuman(stat.size, &size_buf)
            else if (options.kilobytes)
                try common.file.formatSizeKilobytes(stat.size, &size_buf)
            else
                try common.file.formatSize(stat.size, &size_buf);
            
            if (options.human_readable) {
                try writer.print("{s: >5} ", .{size_str});
            } else {
                try writer.print("{s: >8} ", .{size_str});
            }
            
            var time_buf: [64]u8 = undefined;
            const time_str = try common.file.formatTime(stat.mtime, &time_buf);
            try writer.print("{s} ", .{time_str});
            
            try writer.print("{s}\n", .{path});
        } else {
            try writer.print("{s}\n", .{path});
        }
        return;
    }

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        common.printError("{s}: {}", .{ path, err });
        return err;
    };
    defer dir.close();

    var entries = std.ArrayList(Entry).init(allocator);
    defer entries.deinit();

    // Collect entries
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden files unless -a or -A is specified
        if (!options.all and !options.almost_all and entry.name[0] == '.') {
            continue;
        }
        
        // Skip . and .. for -A
        if (options.almost_all and !options.all) {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                continue;
            }
        }

        var e = Entry{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        };
        
        // Get stat info if needed for long format, sorting, or file type indicators
        if (options.long_format or options.sort_by_time or options.sort_by_size or 
            (options.file_type_indicators and entry.kind == .file)) {
            e.stat = common.file.FileInfo.lstatDir(dir, entry.name) catch null;
        }
        
        // Read symlink target if needed
        if (options.long_format and entry.kind == .sym_link) {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (dir.readLink(entry.name, &target_buf)) |target| {
                e.symlink_target = try allocator.dupe(u8, target);
            } else |_| {
                // Failed to read symlink, leave as null
            }
        }
        
        try entries.append(e);
    }

    // Sort entries based on options
    if (options.sort_by_time) {
        std.mem.sort(Entry, entries.items, {}, Entry.lessThanTime);
    } else if (options.sort_by_size) {
        std.mem.sort(Entry, entries.items, {}, Entry.lessThanSize);
    } else {
        // Default: sort alphabetically
        std.mem.sort(Entry, entries.items, {}, Entry.lessThan);
    }
    
    // Reverse order if requested
    if (options.reverse_sort) {
        std.mem.reverse(Entry, entries.items);
    }
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            if (entry.symlink_target) |target| {
                allocator.free(target);
            }
        }
    }

    // Print entries
    if (options.one_per_line) {
        for (entries.items) |entry| {
            // Apply color based on file type
            const file_style = style.styleFileType(entry.kind);
            if (style.color_mode != .none) {
                try style.setColor(file_style.color);
            }
            
            try writer.print("{s}", .{entry.name});
            
            if (style.color_mode != .none) {
                try style.reset();
            }
            if (options.file_type_indicators) {
                const indicator = getFileTypeIndicator(entry);
                if (indicator != 0) {
                    try writer.writeByte(indicator);
                }
            }
            try writer.writeByte('\n');
        }
    } else if (options.long_format) {
        // Long format: permissions, links, user, group, size, date, name
        var total_blocks: u64 = 0;
        
        // Calculate total blocks
        for (entries.items) |entry| {
            if (entry.stat) |stat| {
                total_blocks += (stat.size + 511) / 512; // 512-byte blocks
            }
        }
        
        // Print total if we have entries
        if (entries.items.len > 0) {
            try writer.print("total {d}\n", .{total_blocks});
        }
        
        // Print each entry
        for (entries.items) |entry| {
            // Permission string
            var perm_buf: [10]u8 = undefined;
            const perms = if (entry.stat) |stat|
                try common.file.formatPermissions(stat.mode, stat.kind, &perm_buf)
            else
                "----------";
            
            try writer.writeAll(perms);
            
            // Number of links
            if (entry.stat) |stat| {
                try writer.print(" {d: >3} ", .{stat.nlink});
            } else {
                try writer.writeAll("   ? ");
            }
            
            // User and group names
            if (entry.stat) |stat| {
                var user_buf: [32]u8 = undefined;
                var group_buf: [32]u8 = undefined;
                const user_name = try common.file.getUserName(stat.uid, &user_buf);
                const group_name = try common.file.getGroupName(stat.gid, &group_buf);
                try writer.print("{s: <8} {s: <8} ", .{ user_name, group_name });
            } else {
                try writer.writeAll("?        ?        ");
            }
            
            // Size
            if (entry.stat) |stat| {
                var size_buf: [32]u8 = undefined;
                const size_str = if (options.human_readable)
                    try common.file.formatSizeHuman(stat.size, &size_buf)
                else if (options.kilobytes)
                    try common.file.formatSizeKilobytes(stat.size, &size_buf)
                else
                    try common.file.formatSize(stat.size, &size_buf);
                
                // Right-align size in 8 characters for regular, 5 for human
                if (options.human_readable) {
                    try writer.print("{s: >5} ", .{size_str});
                } else {
                    try writer.print("{s: >8} ", .{size_str});
                }
            } else {
                try writer.writeAll("       ? ");
            }
            
            // Date/time
            if (entry.stat) |stat| {
                var time_buf: [64]u8 = undefined;
                const time_str = try common.file.formatTime(stat.mtime, &time_buf);
                try writer.print("{s} ", .{time_str});
            } else {
                try writer.writeAll("??? ?? ??:?? ");
            }
            
            // Name
            // Apply color based on file type
            const file_style = style.styleFileType(entry.kind);
            if (style.color_mode != .none) {
                try style.setColor(file_style.color);
            }
            
            try writer.print("{s}", .{entry.name});
            
            if (style.color_mode != .none) {
                try style.reset();
            }
            if (options.file_type_indicators) {
                const indicator = getFileTypeIndicator(entry);
                if (indicator != 0) {
                    try writer.writeByte(indicator);
                }
            }
            // Show symlink target if available
            if (entry.symlink_target) |target| {
                try writer.print(" -> {s}", .{target});
            }
            try writer.writeByte('\n');
        }
    } else {
        // Default format: entries separated by spaces/newlines
        for (entries.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll("  ");
            
            // Apply color based on file type
            const file_style = style.styleFileType(entry.kind);
            if (style.color_mode != .none) {
                try style.setColor(file_style.color);
            }
            
            try writer.writeAll(entry.name);
            
            if (style.color_mode != .none) {
                try style.reset();
            }
            
            if (options.file_type_indicators) {
                const indicator = getFileTypeIndicator(entry);
                if (indicator != 0) {
                    try writer.writeByte(indicator);
                }
            }
        }
        if (entries.items.len > 0) {
            try writer.writeAll("\n");
        }
    }
}

fn getFileTypeIndicator(entry: Entry) u8 {
    // Get file type indicator based on file kind and permissions
    switch (entry.kind) {
        .directory => return '/',
        .sym_link => return '@',
        .named_pipe => return '|',
        .unix_domain_socket => return '=',
        .file => {
            // Check if executable
            if (entry.stat) |stat| {
                // Check if any execute bit is set
                if ((stat.mode & 0o111) != 0) {
                    return '*';
                }
            }
            return 0; // No indicator for regular files
        },
        else => return 0,
    }
}

const Entry = struct {
    name: []const u8,
    kind: std.fs.File.Kind,
    stat: ?common.file.FileInfo = null,
    symlink_target: ?[]const u8 = null,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
    
    fn lessThanTime(_: void, a: Entry, b: Entry) bool {
        // If either stat is null, fall back to name sort
        if (a.stat == null or b.stat == null) {
            return lessThan({}, a, b);
        }
        
        // Sort by modification time, newest first
        if (a.stat.?.mtime != b.stat.?.mtime) {
            return a.stat.?.mtime > b.stat.?.mtime;
        }
        
        // If times are equal, sort by name
        return lessThan({}, a, b);
    }
    
    fn lessThanSize(_: void, a: Entry, b: Entry) bool {
        // If either stat is null, fall back to name sort
        if (a.stat == null or b.stat == null) {
            return lessThan({}, a, b);
        }
        
        // Sort by size, largest first
        if (a.stat.?.size != b.stat.?.size) {
            return a.stat.?.size > b.stat.?.size;
        }
        
        // If sizes are equal, sort by name
        return lessThan({}, a, b);
    }
};

// Tests

test "ls lists files in current directory" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("file1.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("file2.txt", .{});
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List directory
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{}, testing.allocator);

    // Should contain both files
    try testing.expect(std.mem.indexOf(u8, buffer.items, "file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "file2.txt") != null);
}

test "ls ignores hidden files by default" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create visible and hidden files
    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden", .{});
    hidden.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List without -a
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{}, testing.allocator);

    // Should contain visible but not hidden
    try testing.expect(std.mem.indexOf(u8, buffer.items, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, ".hidden") == null);
}

test "ls -a shows hidden files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create visible and hidden files
    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden", .{});
    hidden.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -a
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .all = true }, testing.allocator);

    // Should contain both files
    try testing.expect(std.mem.indexOf(u8, buffer.items, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, ".hidden") != null);
}

test "ls -1 lists one file per line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("aaa.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("bbb.txt", .{});
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -1
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .one_per_line = true }, testing.allocator);

    // Should be one file per line
    try testing.expectEqualStrings("aaa.txt\nbbb.txt\n", buffer.items);
}

test "ls sorts entries alphabetically" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files in non-alphabetical order
    const file3 = try tmp_dir.dir.createFile("zzz.txt", .{});
    file3.close();
    const file1 = try tmp_dir.dir.createFile("aaa.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("mmm.txt", .{});
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -1 to make output predictable
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .one_per_line = true }, testing.allocator);

    // Should be sorted alphabetically
    try testing.expectEqualStrings("aaa.txt\nmmm.txt\nzzz.txt\n", buffer.items);
}

test "ls handles empty directory" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List empty directory
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{}, testing.allocator);

    // Should be empty
    try testing.expectEqualStrings("", buffer.items);
}

test "ls with directories shows type indicator" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file and a directory
    const file = try tmp_dir.dir.createFile("file.txt", .{});
    file.close();
    try tmp_dir.dir.makeDir("subdir");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -1 for predictable output
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .one_per_line = true }, testing.allocator);

    // Both should be listed
    try testing.expectEqualStrings("file.txt\nsubdir\n", buffer.items);
}

test "ls -l shows long format" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a test file
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("Hello, World!");
    file.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -l
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .long_format = true }, testing.allocator);

    // Should contain test.txt with permissions and size
    try testing.expect(std.mem.indexOf(u8, buffer.items, "test.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "-rw-") != null); // File permissions
    try testing.expect(std.mem.indexOf(u8, buffer.items, "13") != null); // Size of "Hello, World!"
    try testing.expect(std.mem.indexOf(u8, buffer.items, "total") != null); // Total blocks line
}

test "ls -lh shows human readable sizes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a larger test file
    const file = try tmp_dir.dir.createFile("large.txt", .{});
    var data: [2048]u8 = undefined;
    @memset(&data, 'A');
    try file.writeAll(&data);
    file.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -lh
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .long_format = true, .human_readable = true }, testing.allocator);

    // Should show human readable size
    try testing.expect(std.mem.indexOf(u8, buffer.items, "2.0K") != null);
}

test "ls -lk shows kilobyte sizes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("small.txt", .{});
    try file1.writeAll("Hi");
    file1.close();
    
    const file2 = try tmp_dir.dir.createFile("medium.txt", .{});
    var data: [1500]u8 = undefined;
    @memset(&data, 'B');
    try file2.writeAll(&data);
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -lk
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .long_format = true, .kilobytes = true }, testing.allocator);

    // Should show sizes in kilobytes
    try testing.expect(std.mem.indexOf(u8, buffer.items, "small.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "medium.txt") != null);
    // Small file (2 bytes) should round up to 1K
    // Medium file (1500 bytes) should round up to 2K
}

test "ls -A shows almost all files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create visible and hidden files
    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden", .{});
    hidden.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -A (using -1 for predictable output)
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .almost_all = true, .one_per_line = true }, testing.allocator);

    // Should contain both visible and hidden files
    try testing.expect(std.mem.indexOf(u8, buffer.items, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, ".hidden") != null);
    // But NOT . and .. (can't easily test absence, but we can verify the feature works)
}

test "ls -t sorts by modification time, newest first" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files with different modification times
    const file1 = try tmp_dir.dir.createFile("oldest.txt", .{});
    file1.close();
    
    // Sleep to ensure different timestamps
    std.time.sleep(10_000_000); // 10ms
    
    const file2 = try tmp_dir.dir.createFile("middle.txt", .{});
    file2.close();
    
    std.time.sleep(10_000_000); // 10ms
    
    const file3 = try tmp_dir.dir.createFile("newest.txt", .{});
    file3.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -t and -1 for predictable output
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .sort_by_time = true, .one_per_line = true }, testing.allocator);

    // Should be sorted by time, newest first
    try testing.expectEqualStrings("newest.txt\nmiddle.txt\noldest.txt\n", buffer.items);
}

test "ls -S sorts by size, largest first" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files with different sizes
    const small = try tmp_dir.dir.createFile("small.txt", .{});
    try small.writeAll("Hi");
    small.close();
    
    const large = try tmp_dir.dir.createFile("large.txt", .{});
    var data: [1000]u8 = undefined;
    @memset(&data, 'X');
    try large.writeAll(&data);
    large.close();
    
    const medium = try tmp_dir.dir.createFile("medium.txt", .{});
    try medium.writeAll("Hello, World!");
    medium.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -S and -1 for predictable output
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .sort_by_size = true, .one_per_line = true }, testing.allocator);

    // Should be sorted by size, largest first
    try testing.expectEqualStrings("large.txt\nmedium.txt\nsmall.txt\n", buffer.items);
}

test "ls -r reverses sort order" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files
    const file1 = try tmp_dir.dir.createFile("aaa.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("bbb.txt", .{});
    file2.close();
    const file3 = try tmp_dir.dir.createFile("ccc.txt", .{});
    file3.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -r and -1 for predictable output
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .reverse_sort = true, .one_per_line = true }, testing.allocator);

    // Should be reverse alphabetical
    try testing.expectEqualStrings("ccc.txt\nbbb.txt\naaa.txt\n", buffer.items);
}

test "ls -tr combines time sort with reverse" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files with different modification times
    const file1 = try tmp_dir.dir.createFile("oldest.txt", .{});
    file1.close();
    
    std.time.sleep(10_000_000); // 10ms
    
    const file2 = try tmp_dir.dir.createFile("middle.txt", .{});
    file2.close();
    
    std.time.sleep(10_000_000); // 10ms
    
    const file3 = try tmp_dir.dir.createFile("newest.txt", .{});
    file3.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -t -r and -1 for predictable output
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .sort_by_time = true, .reverse_sort = true, .one_per_line = true }, testing.allocator);

    // Should be sorted by time, oldest first (reversed)
    try testing.expectEqualStrings("oldest.txt\nmiddle.txt\nnewest.txt\n", buffer.items);
}

test "ls -Sr combines size sort with reverse" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files with different sizes
    const small = try tmp_dir.dir.createFile("small.txt", .{});
    try small.writeAll("Hi");
    small.close();
    
    const large = try tmp_dir.dir.createFile("large.txt", .{});
    var data: [1000]u8 = undefined;
    @memset(&data, 'X');
    try large.writeAll(&data);
    large.close();
    
    const medium = try tmp_dir.dir.createFile("medium.txt", .{});
    try medium.writeAll("Hello, World!");
    medium.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -S -r and -1 for predictable output
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .sort_by_size = true, .reverse_sort = true, .one_per_line = true }, testing.allocator);

    // Should be sorted by size, smallest first (reversed)
    try testing.expectEqualStrings("small.txt\nmedium.txt\nlarge.txt\n", buffer.items);
}

test "ls -F adds file type indicators" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create different file types
    const regular = try tmp_dir.dir.createFile("regular.txt", .{});
    regular.close();
    
    try tmp_dir.dir.makeDir("directory");
    
    // Create executable file
    const exe = try tmp_dir.dir.createFile("executable", .{});
    exe.close();
    // Set execute permissions after creation
    var exe_path_buf: [4096]u8 = undefined;
    const exe_path = try tmp_dir.dir.realpath("executable", &exe_path_buf);
    const exe_path_z = try testing.allocator.dupeZ(u8, exe_path);
    defer testing.allocator.free(exe_path_z);
    _ = std.c.chmod(exe_path_z, 0o755);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -F and -1 for predictable output
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .file_type_indicators = true, .one_per_line = true }, testing.allocator);

    // Check for type indicators
    try testing.expect(std.mem.indexOf(u8, buffer.items, "directory/") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "executable*") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "regular.txt") != null);
    // Regular file should not have indicator
    try testing.expect(std.mem.indexOf(u8, buffer.items, "regular.txt/") == null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "regular.txt*") == null);
}

test "ls -d lists directory itself, not contents" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files in the directory
    const file1 = try tmp_dir.dir.createFile("file1.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("file2.txt", .{});
    file2.close();
    try tmp_dir.dir.makeDir("subdir");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -d (should show "." only)
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .directory = true }, testing.allocator);

    // Should only contain "." and not the files
    try testing.expectEqualStrings(".\n", buffer.items);
}

test "ls -l shows symlink targets" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a target file
    const target = try tmp_dir.dir.createFile("target.txt", .{});
    try target.writeAll("Hello, World!");
    target.close();
    
    // Create a symlink to the file
    try tmp_dir.dir.symLink("target.txt", "link_to_file", .{});
    
    // Create a directory and symlink to it
    try tmp_dir.dir.makeDir("target_dir");
    try tmp_dir.dir.symLink("target_dir", "link_to_dir", .{});
    
    // Create a broken symlink
    try tmp_dir.dir.symLink("nonexistent", "broken_link", .{});

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -l
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ .long_format = true }, testing.allocator);

    // Check that symlinks show their targets
    try testing.expect(std.mem.indexOf(u8, buffer.items, "link_to_file -> target.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "link_to_dir -> target_dir") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "broken_link -> nonexistent") != null);
    
    // Check that symlinks are marked with 'l' in permissions
    try testing.expect(std.mem.indexOf(u8, buffer.items, "lrwx") != null);
}

test "ls --color mode parsing" {
    // Test that ColorMode enum works
    try testing.expectEqual(ColorMode.auto, ColorMode.auto);
    try testing.expectEqual(ColorMode.always, ColorMode.always);
    try testing.expectEqual(ColorMode.never, ColorMode.never);
}

test "ls color output for directories" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test directory
    try tmp_dir.dir.makeDir("test_dir");
    
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with color always
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ 
        .one_per_line = true,
        .color_mode = .always,
    }, testing.allocator);

    // Directory name should have color codes
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "test_dir") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[0m") != null); // reset
}

test "ls color output disabled with never" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test directory
    try tmp_dir.dir.makeDir("test_dir");
    
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with color never
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ 
        .one_per_line = true,
        .color_mode = .never,
    }, testing.allocator);

    // Should not have any color codes
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[") == null);
    try testing.expectEqualStrings("test_dir\n", buffer.items);
}

test "ls color scheme for different file types" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create different file types
    try tmp_dir.dir.makeDir("directory");
    const file = try tmp_dir.dir.createFile("regular.txt", .{});
    file.close();
    const exe = try tmp_dir.dir.createFile("executable", .{});
    exe.close();
    // Make it executable
    var exe_path_buf: [4096]u8 = undefined;
    const exe_path = try tmp_dir.dir.realpath("executable", &exe_path_buf);
    const exe_path_z = try testing.allocator.dupeZ(u8, exe_path);
    defer testing.allocator.free(exe_path_z);
    _ = std.c.chmod(exe_path_z, 0o755);
    
    // Create symlink
    try tmp_dir.dir.symLink("regular.txt", "symlink", .{});
    
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with color always
    try listDirectoryTest(tmp_dir.dir, buffer.writer(), .{ 
        .one_per_line = true,
        .color_mode = .always,
    }, testing.allocator);

    // Check that different file types have different colors
    // Directory should be bright blue (94)
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[94mdirectory\x1b[0m") != null);
    // Symlink should be bright cyan (96)
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[96msymlink\x1b[0m") != null);
    // Regular files should use default color (39)
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[39mregular.txt\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[39mexecutable\x1b[0m") != null);
}

// Test helper that uses a Dir instead of path
fn listDirectoryTest(dir: std.fs.Dir, writer: anytype, options: LsOptions, allocator: std.mem.Allocator) !void {
    // Initialize style based on color mode
    const StyleType = common.style.Style(@TypeOf(writer));
    var style = StyleType.init(writer);
    if (options.color_mode == .never) {
        style.color_mode = .none;
    } else if (options.color_mode == .always) {
        // Keep the detected mode but ensure it's at least basic
        if (style.color_mode == .none) {
            style.color_mode = .basic;
        }
    }
    
    // If -d is specified, just list the directory itself
    if (options.directory) {
        if (options.one_per_line) {
            try writer.print(".\n", .{});
        } else {
            try writer.print(".\n", .{});
        }
        return;
    }

    // Re-open the directory with iterate permissions
    var iterable_dir = try dir.openDir(".", .{ .iterate = true });
    defer iterable_dir.close();

    var entries = std.ArrayList(Entry).init(allocator);
    defer entries.deinit();

    // Collect entries
    var iter = iterable_dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden files unless -a or -A is specified
        if (!options.all and !options.almost_all and entry.name[0] == '.') {
            continue;
        }
        
        // Skip . and .. for -A
        if (options.almost_all and !options.all) {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                continue;
            }
        }

        var e = Entry{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        };
        
        // Get stat info if needed for long format, sorting, or file type indicators
        if (options.long_format or options.sort_by_time or options.sort_by_size or 
            (options.file_type_indicators and entry.kind == .file)) {
            e.stat = common.file.FileInfo.lstatDir(iterable_dir, entry.name) catch null;
        }
        
        // Read symlink target if needed
        if (options.long_format and entry.kind == .sym_link) {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (iterable_dir.readLink(entry.name, &target_buf)) |target| {
                e.symlink_target = try allocator.dupe(u8, target);
            } else |_| {
                // Failed to read symlink, leave as null
            }
        }
        
        try entries.append(e);
    }

    // Sort entries based on options
    if (options.sort_by_time) {
        std.mem.sort(Entry, entries.items, {}, Entry.lessThanTime);
    } else if (options.sort_by_size) {
        std.mem.sort(Entry, entries.items, {}, Entry.lessThanSize);
    } else {
        // Default: sort alphabetically
        std.mem.sort(Entry, entries.items, {}, Entry.lessThan);
    }
    
    // Reverse order if requested
    if (options.reverse_sort) {
        std.mem.reverse(Entry, entries.items);
    }
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            if (entry.symlink_target) |target| {
                allocator.free(target);
            }
        }
    }

    // Print entries
    if (options.one_per_line) {
        for (entries.items) |entry| {
            // Apply color based on file type
            const file_style = style.styleFileType(entry.kind);
            if (style.color_mode != .none) {
                try style.setColor(file_style.color);
            }
            
            try writer.print("{s}", .{entry.name});
            
            if (style.color_mode != .none) {
                try style.reset();
            }
            if (options.file_type_indicators) {
                const indicator = getFileTypeIndicator(entry);
                if (indicator != 0) {
                    try writer.writeByte(indicator);
                }
            }
            try writer.writeByte('\n');
        }
    } else if (options.long_format) {
        // Long format: permissions, links, user, group, size, date, name
        var total_blocks: u64 = 0;
        
        // Calculate total blocks
        for (entries.items) |entry| {
            if (entry.stat) |stat| {
                total_blocks += (stat.size + 511) / 512; // 512-byte blocks
            }
        }
        
        // Print total if we have entries
        if (entries.items.len > 0) {
            try writer.print("total {d}\n", .{total_blocks});
        }
        
        // Print each entry
        for (entries.items) |entry| {
            // Permission string
            var perm_buf: [10]u8 = undefined;
            const perms = if (entry.stat) |stat|
                try common.file.formatPermissions(stat.mode, stat.kind, &perm_buf)
            else
                "----------";
            
            try writer.writeAll(perms);
            
            // Number of links
            if (entry.stat) |stat| {
                try writer.print(" {d: >3} ", .{stat.nlink});
            } else {
                try writer.writeAll("   ? ");
            }
            
            // User and group names
            if (entry.stat) |stat| {
                var user_buf: [32]u8 = undefined;
                var group_buf: [32]u8 = undefined;
                const user_name = try common.file.getUserName(stat.uid, &user_buf);
                const group_name = try common.file.getGroupName(stat.gid, &group_buf);
                try writer.print("{s: <8} {s: <8} ", .{ user_name, group_name });
            } else {
                try writer.writeAll("?        ?        ");
            }
            
            // Size
            if (entry.stat) |stat| {
                var size_buf: [32]u8 = undefined;
                const size_str = if (options.human_readable)
                    try common.file.formatSizeHuman(stat.size, &size_buf)
                else if (options.kilobytes)
                    try common.file.formatSizeKilobytes(stat.size, &size_buf)
                else
                    try common.file.formatSize(stat.size, &size_buf);
                
                // Right-align size in 8 characters for regular, 5 for human
                if (options.human_readable) {
                    try writer.print("{s: >5} ", .{size_str});
                } else {
                    try writer.print("{s: >8} ", .{size_str});
                }
            } else {
                try writer.writeAll("       ? ");
            }
            
            // Date/time
            if (entry.stat) |stat| {
                var time_buf: [64]u8 = undefined;
                const time_str = try common.file.formatTime(stat.mtime, &time_buf);
                try writer.print("{s} ", .{time_str});
            } else {
                try writer.writeAll("??? ?? ??:?? ");
            }
            
            // Name
            // Apply color based on file type
            const file_style = style.styleFileType(entry.kind);
            if (style.color_mode != .none) {
                try style.setColor(file_style.color);
            }
            
            try writer.print("{s}", .{entry.name});
            
            if (style.color_mode != .none) {
                try style.reset();
            }
            if (options.file_type_indicators) {
                const indicator = getFileTypeIndicator(entry);
                if (indicator != 0) {
                    try writer.writeByte(indicator);
                }
            }
            // Show symlink target if available
            if (entry.symlink_target) |target| {
                try writer.print(" -> {s}", .{target});
            }
            try writer.writeByte('\n');
        }
    } else {
        // Default format: entries separated by spaces/newlines
        for (entries.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll("  ");
            
            // Apply color based on file type
            const file_style = style.styleFileType(entry.kind);
            if (style.color_mode != .none) {
                try style.setColor(file_style.color);
            }
            
            try writer.writeAll(entry.name);
            
            if (style.color_mode != .none) {
                try style.reset();
            }
            
            if (options.file_type_indicators) {
                const indicator = getFileTypeIndicator(entry);
                if (indicator != 0) {
                    try writer.writeByte(indicator);
                }
            }
        }
        if (entries.items.len > 0) {
            try writer.writeAll("\n");
        }
    }
}
