// Harness: abstracts how the fuzzer feeds mutated input to a child process.
// Three modes: stdin (pass input via stdin), argv (template with {INPUT}
// placeholder substituted), file_arg (write input to temp file, pass path).

const std = @import("std");

pub const Mode = enum { stdin, argv, file_arg };

pub const ArgvConfig = struct {
    template: []const []const u8,
};

pub const FileArgConfig = struct {
    template: []const []const u8,
};

pub const Harness = union(Mode) {
    stdin: void,
    argv: ArgvConfig,
    file_arg: FileArgConfig,
};

pub const PreparedSpawn = struct {
    argv: []const []const u8,
    stdin_bytes: ?[]const u8,
    temp_file_path: ?[]const u8,
};

pub const TemplateError = error{ MissingInputPlaceholder, MultipleInputPlaceholders };

pub fn validateTemplate(template: []const []const u8) TemplateError!void {
    var count: usize = 0;
    for (template) |token| {
        if (std.mem.eql(u8, token, "{INPUT}")) count += 1;
    }
    if (count == 0) return error.MissingInputPlaceholder;
    if (count > 1) return error.MultipleInputPlaceholders;
}

pub fn prepare(
    arena: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    harness: Harness,
    mutated_input: []const u8,
) !PreparedSpawn {
    switch (harness) {
        .stdin => {
            return .{
                .argv = try arena.dupe([]const u8, &.{target}),
                .stdin_bytes = mutated_input,
                .temp_file_path = null,
            };
        },
        .argv => |cfg| {
            try validateTemplate(cfg.template);
            const argv = try arena.alloc([]const u8, 1 + cfg.template.len);
            argv[0] = target;
            for (cfg.template, 1..) |token, i| {
                argv[i] = if (std.mem.eql(u8, token, "{INPUT}")) mutated_input else token;
            }
            return .{
                .argv = argv,
                .stdin_bytes = null,
                .temp_file_path = null,
            };
        },
        .file_arg => |cfg| {
            try validateTemplate(cfg.template);
            var path: []const u8 = undefined;
            var retries: u8 = 0;
            while (retries < 8) : (retries += 1) {
                var rand_bytes: [8]u8 = undefined;
                io.random(&rand_bytes);
                const hex = std.fmt.bytesToHex(rand_bytes, .lower);
                path = try std.fmt.allocPrint(arena, "/tmp/fuzz-harness-{s}", .{&hex});
                const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true, .exclusive = true }) catch |err| {
                    if (err == error.PathAlreadyExists) continue;
                    return err;
                };
                file.writeStreamingAll(io, mutated_input) catch |err| {
                    file.close(io);
                    return err;
                };
                file.close(io);
                break;
            } else {
                return error.PathAlreadyExists;
            }
            const argv = try arena.alloc([]const u8, 1 + cfg.template.len);
            argv[0] = target;
            for (cfg.template, 1..) |token, i| {
                argv[i] = if (std.mem.eql(u8, token, "{INPUT}")) path else token;
            }
            return .{
                .argv = argv,
                .stdin_bytes = null,
                .temp_file_path = path,
            };
        },
    }
}

pub fn cleanup(io: std.Io, ps: PreparedSpawn) void {
    if (ps.temp_file_path) |path| {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }
}

// ----------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "validateTemplate accepts template with exactly one {INPUT}" {
    // Stub returns error.MissingInputPlaceholder; real impl must succeed (no error).
    try validateTemplate(&.{ "-r", "{INPUT}", "--" });
}

test "validateTemplate rejects template with no {INPUT}" {
    try testing.expectError(error.MissingInputPlaceholder, validateTemplate(&.{ "-r", "foo" }));
}

test "validateTemplate rejects empty template" {
    try testing.expectError(error.MissingInputPlaceholder, validateTemplate(&.{}));
}

test "validateTemplate rejects template with multiple {INPUT}" {
    try testing.expectError(
        error.MultipleInputPlaceholders,
        validateTemplate(&.{ "{INPUT}", "-x", "{INPUT}" }),
    );
}

test "prepare stdin mode passes input as stdin_bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const ps = try prepare(arena, io, "/bin/wc", .{ .stdin = {} }, "hello\n");
    try testing.expectEqual(@as(usize, 1), ps.argv.len);
    try testing.expectEqualStrings("/bin/wc", ps.argv[0]);
    try testing.expect(ps.stdin_bytes != null);
    try testing.expectEqualStrings("hello\n", ps.stdin_bytes.?);
    try testing.expect(ps.temp_file_path == null);
}

test "prepare argv mode substitutes {INPUT}" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const template = [_][]const u8{ "-r", "{INPUT}", "--" };
    const ps = try prepare(arena, io, "/bin/printf", .{ .argv = .{ .template = &template } }, "abc");
    defer cleanup(io, ps);

    try testing.expectEqual(@as(usize, 4), ps.argv.len);
    try testing.expectEqualStrings("/bin/printf", ps.argv[0]);
    try testing.expectEqualStrings("-r", ps.argv[1]);
    try testing.expectEqualStrings("abc", ps.argv[2]);
    try testing.expectEqualStrings("--", ps.argv[3]);
    try testing.expect(ps.stdin_bytes == null);
    try testing.expect(ps.temp_file_path == null);
}

test "prepare argv mode preserves null bytes in input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const template = [_][]const u8{"{INPUT}"};
    const input = "a\x00b\x00c";
    const ps = try prepare(arena, io, "/bin/foo", .{ .argv = .{ .template = &template } }, input);
    defer cleanup(io, ps);

    try testing.expectEqual(@as(usize, 2), ps.argv.len);
    try testing.expectEqual(@as(usize, 5), ps.argv[1].len);
    try testing.expectEqualSlices(u8, input, ps.argv[1]);
}

test "prepare argv mode preserves token order with multiple tokens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const template = [_][]const u8{ "a", "{INPUT}", "b", "c" };
    const ps = try prepare(arena, io, "/bin/foo", .{ .argv = .{ .template = &template } }, "X");
    defer cleanup(io, ps);

    try testing.expectEqual(@as(usize, 5), ps.argv.len);
    try testing.expectEqualStrings("/bin/foo", ps.argv[0]);
    try testing.expectEqualStrings("a", ps.argv[1]);
    try testing.expectEqualStrings("X", ps.argv[2]);
    try testing.expectEqualStrings("b", ps.argv[3]);
    try testing.expectEqualStrings("c", ps.argv[4]);
}

test "prepare file_arg mode writes input to temp file and substitutes path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const template = [_][]const u8{"{INPUT}"};
    const input = "file contents\n";
    const ps = try prepare(arena, io, "/bin/cat", .{ .file_arg = .{ .template = &template } }, input);
    defer cleanup(io, ps);

    try testing.expectEqual(@as(usize, 2), ps.argv.len);
    try testing.expect(ps.stdin_bytes == null);
    try testing.expect(ps.temp_file_path != null);
    try testing.expectEqualStrings(ps.temp_file_path.?, ps.argv[1]);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, ps.temp_file_path.?, arena, .unlimited);
    try testing.expectEqualStrings(input, contents);
}

test "prepare file_arg mode generates unique temp paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const template = [_][]const u8{"{INPUT}"};
    const ps1 = try prepare(arena, io, "/bin/cat", .{ .file_arg = .{ .template = &template } }, "input1");
    defer cleanup(io, ps1);
    const ps2 = try prepare(arena, io, "/bin/cat", .{ .file_arg = .{ .template = &template } }, "input2");
    defer cleanup(io, ps2);

    try testing.expect(ps1.temp_file_path != null);
    try testing.expect(ps2.temp_file_path != null);
    try testing.expect(!std.mem.eql(u8, ps1.temp_file_path.?, ps2.temp_file_path.?));
}

test "cleanup removes the temp file when temp_file_path is non-null" {
    const io = testing.io;

    // Generate a unique path per test invocation to avoid races and stale files.
    var suffix_bytes: [8]u8 = undefined;
    io.random(&suffix_bytes);
    var hex_buf: [16]u8 = undefined;
    const hex = std.fmt.bytesToHex(suffix_bytes, .lower);
    @memcpy(&hex_buf, &hex);
    var path_buf: [64]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&path_buf, "/tmp/harness-cleanup-{s}", .{hex_buf});

    // Hygiene defer: removes the file if the assertion below fails before cleanup() runs.
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // Create a temp file directly — independent of prepare's implementation.
    {
        const f = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "data");
    }

    const ps = PreparedSpawn{
        .argv = &.{},
        .stdin_bytes = null,
        .temp_file_path = tmp_path,
    };
    cleanup(io, ps);

    // File should be gone; statFile should return an error.
    const stat_result = std.Io.Dir.cwd().statFile(io, tmp_path, .{});
    try testing.expect(stat_result == error.FileNotFound);
}

test "cleanup is a no-op when temp_file_path is null" {
    const io = testing.io;

    const ps = PreparedSpawn{
        .argv = &.{},
        .stdin_bytes = null,
        .temp_file_path = null,
    };
    // Must not crash.
    cleanup(io, ps);
}
