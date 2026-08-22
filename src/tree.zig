//! tree — list contents of a directory as a tree.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;
const FileKind = std.Io.File.Kind;

const prog_name = "tree";
const branch_mid = "├── ";
const branch_end = "└── ";
const pipe_pad = "│   ";
const space_pad = "    ";
const args_len_max: u32 = 1 << 20;
const walk_entries_max: u64 = 1 << 24;
const walk_calls_max: u64 = walk_entries_max + 1;
const print_steps_max: u64 = 2 * walk_entries_max + 2;

const When = enum { always, auto, never };

const TreeArgs = struct {
    help: bool = false,
    version: bool = false,
    all: bool = false,
    directories_only: bool = false,
    level: ?[]const u8 = null,
    ignore: ?[]const u8 = null,
    color: ?[]const u8 = null,
    icons: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .all = .{ .short = 'a', .desc = "Include hidden entries" },
        .directories_only = .{
            .short = 'd',
            .desc = "List directories only",
        },
        .level = .{
            .short = 'L',
            .desc = "Descend only depth N",
            .value_name = "N",
        },
        .ignore = .{
            .short = 'I',
            .desc = "Exclude names matching PATTERN",
            .value_name = "PATTERN",
        },
        .color = .{
            .short = 0,
            .desc = "When to use color (always, auto, never)",
            .value_name = "WHEN",
        },
        .icons = .{
            .short = 0,
            .desc = "When to show icons (always, auto, never)",
            .value_name = "WHEN",
        },
    };
};

const Node = struct {
    name: []const u8,
    kind: FileKind,
    children: std.ArrayListUnmanaged(*Node) = .empty,
};

const WalkFilter = struct {
    all: bool,
    directories_only: bool,
    max_level: ?u16,
    ignore_patterns: []const []const u8,
};

const Counts = struct {
    directories: u32 = 0,
    files: u32 = 0,
};

const TreeStyle = common.style.Style(*std.Io.Writer);

pub fn runTree(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    std.debug.assert(args.len < args_len_max);
    std.debug.assert(@intFromPtr(stdout_writer) != 0);
    std.debug.assert(@intFromPtr(stderr_writer) != 0);
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    return runTreeArena(
        allocator,
        arena_inst.allocator(),
        io,
        args,
        stdout_writer,
        stderr_writer,
    );
}

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runTree);
}

fn runTreeArena(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    std.debug.assert(args.len < args_len_max);
    std.debug.assert(@intFromPtr(stdout_writer) != 0);
    const parsed = common.argparse.ArgParser.parseOrExit(
        TreeArgs,
        gpa,
        args,
        prog_name,
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer gpa.free(parsed.positionals);

    if (parsed.help) {
        try printHelp(gpa, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }
    if (parsed.version) {
        try stdout_writer.print("{s} ({s}) {s}\n", .{
            prog_name,
            common.name,
            common.version,
        });
        return @intFromEnum(common.ExitCode.success);
    }
    return runTreeConfigured(
        gpa,
        arena,
        io,
        args,
        parsed,
        stdout_writer,
        stderr_writer,
    );
}

fn runTreeConfigured(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    args: []const []const u8,
    parsed: TreeArgs,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    std.debug.assert(args.len < args_len_max);
    std.debug.assert(@intFromPtr(stdout_writer) != 0);
    const max_level = parseLevelArg(parsed.level) catch {
        common.printErrorWithProgram(
            gpa,
            stderr_writer,
            prog_name,
            "invalid -L value",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    };
    const color_when = parseWhenArg(parsed.color) catch {
        common.printErrorWithProgram(
            gpa,
            stderr_writer,
            prog_name,
            "invalid --color value",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    };
    const icon_when = parseWhenArg(parsed.icons) catch {
        common.printErrorWithProgram(
            gpa,
            stderr_writer,
            prog_name,
            "invalid --icons value",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    };
    var display = common.display_config.DisplayConfig.resolve(gpa);
    applyColorWhen(&display, color_when);
    applyIconWhen(&display, icon_when);
    const walk_opts = WalkFilter{
        .all = parsed.all,
        .directories_only = parsed.directories_only,
        .max_level = max_level,
        .ignore_patterns = try collectIgnorePatterns(arena, args),
    };
    if (parsed.ignore != null) {
        std.debug.assert(walk_opts.ignore_patterns.len > 0);
    }
    return emitTrees(
        gpa,
        arena,
        io,
        parsed.positionals,
        walk_opts,
        display,
        stdout_writer,
        stderr_writer,
    );
}

fn emitTrees(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    positionals: []const []const u8,
    walk_opts: WalkFilter,
    display: common.display_config.DisplayConfig,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    std.debug.assert(positionals.len < args_len_max);
    std.debug.assert(@intFromPtr(stdout_writer) != 0);
    const operands: []const []const u8 = if (positionals.len == 0)
        &.{"."}
    else
        positionals;
    std.debug.assert(operands.len >= 1);
    var counts: Counts = .{};
    var status: u8 = @intFromEnum(common.ExitCode.success);
    var style = try makeStyle(gpa, stdout_writer, display);
    for (operands) |operand| {
        if (operand.len == 0) {
            reportPathError(gpa, stderr_writer, operand, error.FileNotFound);
            status = @intFromEnum(common.ExitCode.general_error);
            continue;
        }
        const tree_status = emitOneOperand(
            gpa,
            arena,
            io,
            operand,
            walk_opts,
            display,
            &style,
            stdout_writer,
            stderr_writer,
            &counts,
        ) catch |err| {
            reportPathError(gpa, stderr_writer, operand, err);
            status = @intFromEnum(common.ExitCode.general_error);
            continue;
        };
        if (tree_status != 0) status = tree_status;
    }
    try writeSummary(stdout_writer, counts, walk_opts.directories_only);
    try stdout_writer.flush();
    return status;
}

fn emitOneOperand(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    operand: []const u8,
    walk_opts: WalkFilter,
    display: common.display_config.DisplayConfig,
    style: *TreeStyle,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    counts: *Counts,
) !u8 {
    std.debug.assert(operand.len > 0);
    std.debug.assert(@intFromPtr(stdout_writer) != 0);
    const kind = try preflightOperand(io, operand);
    const root = try makeNode(arena, operand, kind);
    countNode(counts, root.kind);
    var status: u8 = 0;
    if (kind == .directory) {
        status = try walkDirectory(
            gpa,
            arena,
            io,
            operand,
            root,
            walk_opts,
            stderr_writer,
            counts,
        );
    }
    try printTree(root, display, style, stdout_writer);
    return status;
}

fn reportPathError(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    path: []const u8,
    err: anyerror,
) void {
    std.debug.assert(@intFromPtr(stderr_writer) != 0);
    std.debug.assert(@intFromPtr(allocator.vtable) != 0);
    const shown = if (path.len == 0) "''" else path;
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        prog_name,
        "{s}: {s}",
        .{ shown, pathErrorString(err) },
    );
}

fn pathErrorString(err: anyerror) []const u8 {
    const msg = switch (err) {
        error.DepthLimitExceeded => "directory tree too deep",
        error.EntryLimitExceeded, error.TooManyEntries => "too many directory entries",
        error.DirectoryCycle => "filesystem cycle detected",
        else => common.posixErrorString(err),
    };
    std.debug.assert(msg.len > 0);
    return msg;
}

fn parseWhenArg(value: ?[]const u8) !?When {
    const text = value orelse return null;
    if (text.len == 0) return error.InvalidValue;
    std.debug.assert(text.len > 0);
    if (std.mem.eql(u8, text, "always")) return .always;
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "never")) return .never;
    return error.InvalidValue;
}

fn parseLevelArg(value: ?[]const u8) !?u16 {
    const text = value orelse return null;
    if (text.len == 0) return error.InvalidValue;
    std.debug.assert(text.len > 0);
    if (text[0] == '-' or text[0] == '+') return error.InvalidValue;
    const parsed = std.fmt.parseInt(u32, text, 10) catch return error.InvalidValue;
    if (parsed > std.math.maxInt(u16)) return error.InvalidValue;
    std.debug.assert(parsed <= std.math.maxInt(u16));
    return @intCast(parsed);
}

fn applyColorWhen(
    display: *common.display_config.DisplayConfig,
    when: ?When,
) void {
    std.debug.assert(@intFromPtr(display) != 0);
    if (when) |mode| {
        switch (mode) {
            .always => display.color = .on,
            .never => display.color = .off,
            .auto => {},
        }
    }
    if (common.env.getEnv("NO_COLOR") != null) display.color = .off;
}

fn applyIconWhen(
    display: *common.display_config.DisplayConfig,
    when: ?When,
) void {
    std.debug.assert(@intFromPtr(display) != 0);
    if (when) |mode| {
        switch (mode) {
            .always => display.icons = .on,
            .never => display.icons = .off,
            .auto => {},
        }
    }
}

fn makeStyle(
    allocator: Allocator,
    writer: *std.Io.Writer,
    display: common.display_config.DisplayConfig,
) !TreeStyle {
    std.debug.assert(@intFromPtr(writer) != 0);
    const detected = common.style.TerminalColorMode.detect(allocator) catch .basic;
    const color_mode: TreeStyle.ColorMode = if (display.color == .on)
        (if (detected == .none) .basic else detected)
    else
        .none;
    std.debug.assert(display.color == .off or color_mode != .none);
    return .{ .color_mode = color_mode, .writer = writer };
}

fn collectIgnorePatterns(
    arena: Allocator,
    args: []const []const u8,
) ![]const []const u8 {
    std.debug.assert(args.len < args_len_max);
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: u32 = 0;
    while (i < args.len) : (i += 1) {
        std.debug.assert(i < args.len);
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) break;
        i = try collectIgnoreAt(arena, args, i, &list);
    }
    return list.items;
}

fn collectIgnoreAt(
    arena: Allocator,
    args: []const []const u8,
    i: u32,
    list: *std.ArrayListUnmanaged([]const u8),
) !u32 {
    std.debug.assert(i < args.len);
    std.debug.assert(args.len < args_len_max);
    const arg = args[i];
    if (ignoreLongAttached(arg)) |pattern| {
        try list.append(arena, pattern);
        return i;
    }
    if (isIgnoreLongBare(arg)) {
        return try takeNextPattern(arena, args, i, list);
    }
    if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
        return try collectIgnoreCluster(arena, args, i, list);
    }
    return i;
}

fn ignoreLongAttached(arg: []const u8) ?[]const u8 {
    std.debug.assert(arg.len < args_len_max);
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    if (!isIgnoreLongName(arg[2..eq])) return null;
    std.debug.assert(eq + 1 <= arg.len);
    return arg[eq + 1 ..];
}

fn isIgnoreLongBare(arg: []const u8) bool {
    std.debug.assert(arg.len < args_len_max);
    if (!std.mem.startsWith(u8, arg, "--")) return false;
    return isIgnoreLongName(arg[2..]);
}

fn isIgnoreLongName(name: []const u8) bool {
    if (name.len == 0) return false;
    std.debug.assert(name.len > 0);
    if (!std.mem.startsWith(u8, "ignore", name)) return false;
    const others = [_][]const u8{
        "help",
        "version",
        "all",
        "directories-only",
        "level",
        "color",
        "icons",
    };
    for (others) |other| {
        if (std.mem.startsWith(u8, other, name)) return false;
    }
    return true;
}

fn takeNextPattern(
    arena: Allocator,
    args: []const []const u8,
    i: u32,
    list: *std.ArrayListUnmanaged([]const u8),
) !u32 {
    std.debug.assert(i < args.len);
    std.debug.assert(i + 1 < args.len);
    try list.append(arena, args[i + 1]);
    return i + 1;
}

fn collectIgnoreCluster(
    arena: Allocator,
    args: []const []const u8,
    i: u32,
    list: *std.ArrayListUnmanaged([]const u8),
) !u32 {
    std.debug.assert(i < args.len);
    const arg = args[i];
    std.debug.assert(arg.len > 1);
    var j: u32 = 1;
    while (j < arg.len) : (j += 1) {
        std.debug.assert(j < arg.len);
        const ch = arg[j];
        if (ch == 'I') return try takeClusterValue(arena, args, i, j, list);
        if (ch == 'L') return skipClusterValue(args, i, j);
        if (ch == '=') return i;
    }
    return i;
}

fn takeClusterValue(
    arena: Allocator,
    args: []const []const u8,
    i: u32,
    j: u32,
    list: *std.ArrayListUnmanaged([]const u8),
) !u32 {
    std.debug.assert(i < args.len);
    std.debug.assert(j < args[i].len);
    const arg = args[i];
    if (j + 1 < arg.len) {
        var value = arg[j + 1 ..];
        if (value.len > 0 and value[0] == '=') value = value[1..];
        try list.append(arena, value);
        return i;
    }
    return try takeNextPattern(arena, args, i, list);
}

fn skipClusterValue(args: []const []const u8, i: u32, j: u32) u32 {
    std.debug.assert(i < args.len);
    std.debug.assert(j < args[i].len);
    if (j + 1 < args[i].len) return i;
    if (i + 1 < args.len) return i + 1;
    return i;
}

fn preflightOperand(io: std.Io, path: []const u8) !FileKind {
    if (path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
    std.debug.assert(path.len <= std.Io.Dir.max_path_bytes);
    const info = try common.file.FileInfo.lstat(path);
    if (info.kind == .directory) {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        dir.close(io);
    }
    return info.kind;
}

fn makeNode(arena: Allocator, name: []const u8, kind: FileKind) !*Node {
    std.debug.assert(name.len > 0);
    std.debug.assert(@intFromPtr(arena.vtable) != 0);
    const node = try arena.create(Node);
    node.* = .{
        .name = try arena.dupe(u8, name),
        .kind = kind,
        .children = .empty,
    };
    return node;
}

fn countNode(counts: *Counts, kind: FileKind) void {
    std.debug.assert(@intFromPtr(counts) != 0);
    const before = counts.directories + counts.files;
    if (kind == .directory) {
        counts.directories += 1;
    } else {
        counts.files += 1;
    }
    std.debug.assert(counts.directories + counts.files == before + 1);
}

fn walkDirectory(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    operand: []const u8,
    root: *Node,
    walk_opts: WalkFilter,
    stderr_writer: *std.Io.Writer,
    counts: *Counts,
) !u8 {
    std.debug.assert(operand.len > 0);
    std.debug.assert(root.kind == .directory);
    var walker = try common.walker.Walker.init(gpa, .{
        .sort_children = true,
        .symlinks = .no_follow,
        .order = .pre,
    });
    defer walker.deinit(io);
    try walker.addRoot(operand);
    var parents: std.ArrayListUnmanaged(*Node) = .empty;
    try parents.append(arena, root);
    return drainWalker(
        gpa,
        arena,
        io,
        &walker,
        &parents,
        walk_opts,
        stderr_writer,
        counts,
    );
}

fn drainWalker(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    walker: *common.walker.Walker,
    parents: *std.ArrayListUnmanaged(*Node),
    walk_opts: WalkFilter,
    stderr_writer: *std.Io.Writer,
    counts: *Counts,
) !u8 {
    std.debug.assert(parents.items.len >= 1);
    std.debug.assert(@intFromPtr(walker) != 0);
    var status: u8 = 0;
    var n: u64 = 0;
    while (n < walk_calls_max) : (n += 1) {
        const maybe = walker.next(io) catch |err| {
            status = @intFromEnum(common.ExitCode.general_error);
            reportWalkerError(gpa, stderr_writer, walker, err);
            if (err == error.DepthLimitExceeded or err == error.EntryLimitExceeded) {
                return status;
            }
            continue;
        };
        const entry = maybe orelse return status;
        try consumeEntry(arena, walker, parents, walk_opts, entry, counts);
    }
    reportWalkerError(gpa, stderr_writer, walker, error.EntryLimitExceeded);
    return @intFromEnum(common.ExitCode.general_error);
}

fn reportWalkerError(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    walker: *common.walker.Walker,
    err: anyerror,
) void {
    std.debug.assert(@intFromPtr(stderr_writer) != 0);
    std.debug.assert(@intFromPtr(walker) != 0);
    const msg = pathErrorString(err);
    if (walker.errorPath()) |path| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "{s}: {s}",
            .{ path, msg },
        );
        return;
    }
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        prog_name,
        "{s}",
        .{msg},
    );
}

/// Readdir on filesystems that omit d_type reports `.unknown`. Classify
/// those with lstat on the parent fd so `-d`, summaries, and icons treat
/// real directories as directories. A failed lstat keeps `.unknown`.
fn resolveEntryKind(entry: common.walker.Entry) FileKind {
    std.debug.assert(entry.basename.len > 0);
    std.debug.assert(entry.basename.len <= std.Io.Dir.max_path_bytes);
    if (entry.kind != .unknown) return entry.kind;
    const parent = entry.parent_dir orelse return .unknown;
    var scratch: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const info = common.file.FileInfo.lstatDir(
        fba.allocator(),
        parent,
        entry.basename,
    ) catch return .unknown;
    return info.kind;
}

fn consumeEntry(
    arena: Allocator,
    walker: *common.walker.Walker,
    parents: *std.ArrayListUnmanaged(*Node),
    walk_opts: WalkFilter,
    entry: common.walker.Entry,
    counts: *Counts,
) !void {
    std.debug.assert(parents.items.len >= 1);
    std.debug.assert(entry.basename.len > 0);
    const kind = resolveEntryKind(entry);
    if (entry.depth == 0) {
        if (walk_opts.max_level) |max| {
            if (max == 0 and kind == .directory) walker.pruneCurrent();
        }
        return;
    }
    if (shouldSkip(entry, kind, walk_opts)) {
        if (kind == .directory) walker.pruneCurrent();
        return;
    }
    const node = try makeNode(arena, entry.basename, kind);
    try attachChild(arena, parents, node, entry.depth, counts);
    if (kind == .directory) {
        if (walk_opts.max_level) |max| {
            if (entry.depth >= max) walker.pruneCurrent();
        }
    }
}

fn shouldSkip(entry: common.walker.Entry, kind: FileKind, walk_opts: WalkFilter) bool {
    std.debug.assert(entry.basename.len > 0);
    std.debug.assert(entry.depth > 0);
    if (walk_opts.directories_only and kind != .directory) return true;
    if (!walk_opts.all and isHidden(entry.basename)) return true;
    if (nameIgnored(entry.basename, walk_opts.ignore_patterns)) return true;
    if (walk_opts.max_level) |max| {
        if (entry.depth > max) return true;
    }
    return false;
}

fn isHidden(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, name, 0) == null);
    return name[0] == '.' and !(std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."));
}

fn nameIgnored(name: []const u8, patterns: []const []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(patterns.len < args_len_max);
    for (patterns) |pattern| {
        if (patternMatches(name, pattern)) return true;
    }
    return false;
}

fn patternMatches(name: []const u8, pattern: []const u8) bool {
    std.debug.assert(name.len > 0);
    if (pattern.len == 0) return false;
    std.debug.assert(pattern.len > 0);
    var alts: u32 = 0;
    var it = std.mem.splitScalar(u8, pattern, '|');
    const alts_max = pattern.len + 1;
    while (alts < alts_max) : (alts += 1) {
        const alt = it.next() orelse return false;
        if (alt.len > 0 and common.glob.globMatch(alt, name)) return true;
    }
    return false;
}

fn attachChild(
    arena: Allocator,
    parents: *std.ArrayListUnmanaged(*Node),
    node: *Node,
    depth: u16,
    counts: *Counts,
) !void {
    std.debug.assert(depth >= 1);
    std.debug.assert(parents.items.len >= depth);
    const parent = parents.items[depth - 1];
    try parent.children.append(arena, node);
    countNode(counts, node.kind);
    if (node.kind == .directory) {
        try setParentAtDepth(arena, parents, node, depth);
    }
}

fn setParentAtDepth(
    arena: Allocator,
    parents: *std.ArrayListUnmanaged(*Node),
    node: *Node,
    depth: u16,
) !void {
    std.debug.assert(depth >= 1);
    std.debug.assert(node.kind == .directory);
    std.debug.assert(parents.items.len >= depth);
    if (parents.items.len > depth) {
        parents.items.len = depth;
    }
    std.debug.assert(parents.items.len == depth);
    try parents.append(arena, node);
}

const PrintFrame = struct {
    node: *const Node,
    next_child: u32,
    is_last: bool,
};

fn printTree(
    root: *const Node,
    display: common.display_config.DisplayConfig,
    style: *TreeStyle,
    writer: *std.Io.Writer,
) !void {
    std.debug.assert(root.name.len > 0);
    std.debug.assert(@intFromPtr(writer) != 0);
    try writeEntry(root, display, style, writer);
    try writer.writeByte('\n');
    var frames: [1024]PrintFrame = undefined;
    frames[0] = .{ .node = root, .next_child = 0, .is_last = true };
    var sp: u16 = 1;
    try printDescendants(&frames, &sp, display, style, writer);
}

fn printDescendants(
    frames: *[1024]PrintFrame,
    sp: *u16,
    display: common.display_config.DisplayConfig,
    style: *TreeStyle,
    writer: *std.Io.Writer,
) !void {
    std.debug.assert(sp.* >= 1);
    std.debug.assert(sp.* <= 1024);
    var n: u64 = 0;
    while (n < print_steps_max and sp.* > 0) : (n += 1) {
        const frame = &frames[sp.* - 1];
        if (frame.next_child >= frame.node.children.items.len) {
            sp.* -= 1;
            continue;
        }
        const index = frame.next_child;
        frame.next_child += 1;
        const child = frame.node.children.items[index];
        const is_last = index + 1 == frame.node.children.items.len;
        try writeConnectors(frames[0..sp.*], is_last, writer);
        try writeEntry(child, display, style, writer);
        try writer.writeByte('\n');
        if (child.children.items.len > 0) {
            std.debug.assert(sp.* < 1024);
            frames[sp.*] = .{ .node = child, .next_child = 0, .is_last = is_last };
            sp.* += 1;
        }
    }
    if (sp.* != 0) return error.TooManyEntries;
}

fn writeConnectors(
    frames: []const PrintFrame,
    child_is_last: bool,
    writer: *std.Io.Writer,
) !void {
    std.debug.assert(frames.len >= 1);
    std.debug.assert(frames.len <= 1024);
    var depth: u16 = 1;
    while (depth < frames.len) : (depth += 1) {
        std.debug.assert(depth < frames.len);
        try writer.writeAll(if (frames[depth].is_last) space_pad else pipe_pad);
    }
    try writer.writeAll(if (child_is_last) branch_end else branch_mid);
}

fn writeEntry(
    node: *const Node,
    display: common.display_config.DisplayConfig,
    style: *TreeStyle,
    writer: *std.Io.Writer,
) !void {
    std.debug.assert(node.name.len > 0);
    std.debug.assert(@intFromPtr(writer) != 0);
    if (display.icons == .on) try writeIcon(node, style, writer);
    if (display.color == .on) try colorizeKind(node.kind, style);
    try writer.writeAll(node.name);
    if (display.color == .on) try style.reset();
}

fn writeIcon(node: *const Node, style: *TreeStyle, writer: *std.Io.Writer) !void {
    std.debug.assert(node.name.len > 0);
    std.debug.assert(@intFromPtr(writer) != 0);
    const theme = common.icons.IconTheme{};
    const icon = common.icons.getIcon(
        &theme,
        node.name,
        node.kind == .directory,
        node.kind == .sym_link,
        false,
    );
    if (common.icons.getIconColorInfo(icon)) |c| {
        switch (style.color_mode) {
            .truecolor => try style.setRgb(c.r, c.g, c.b),
            .extended => try style.set256(c.c256),
            .basic => try style.setColor(c.basic),
            .none => {},
        }
    }
    try writer.print("{s} ", .{icon});
    if (style.color_mode != .none) try style.reset();
}

fn colorizeKind(kind: FileKind, style: *TreeStyle) !void {
    std.debug.assert(@intFromPtr(style) != 0);
    std.debug.assert(@intFromPtr(style.writer) != 0);
    switch (kind) {
        .directory => {
            try style.setBold();
            try style.setColor(.blue);
        },
        .sym_link => {
            try style.setBold();
            try style.setColor(.cyan);
        },
        else => {},
    }
}

fn writeSummary(
    writer: *std.Io.Writer,
    counts: Counts,
    directories_only: bool,
) !void {
    std.debug.assert(@intFromPtr(writer) != 0);
    try writer.writeByte('\n');
    if (directories_only) {
        try writer.print("{d} {s}\n", .{
            counts.directories,
            if (counts.directories == 1) "directory" else "directories",
        });
    } else {
        try writer.print("{d} {s}, {d} {s}\n", .{
            counts.directories,
            if (counts.directories == 1) "directory" else "directories",
            counts.files,
            if (counts.files == 1) "file" else "files",
        });
    }
}

fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    std.debug.assert(@intFromPtr(writer) != 0);
    std.debug.assert(prog_name.len > 0);
    const text =
        \\Usage: tree [OPTION]... [PATH]...
        \\List contents of directories in a tree-like format.
        \\
        \\  -a, --all                 include hidden entries
        \\  -d, --directories-only    list directories only
        \\  -L, --level=N             descend only N levels
        \\  -I, --ignore=PATTERN      exclude names matching PATTERN
        \\      --color=WHEN          colorize output (always, auto, never)
        \\      --icons=WHEN          show file-type icons (always, auto, never)
        \\  -h, --help                display this help and exit
        \\  -V, --version             output version information and exit
        \\
        \\WHEN defaults to 'auto'. Repeated -I patterns accumulate; '|'
        \\separates alternatives. Directory symlinks are not followed.
        \\A file operand is listed as a single-node tree.
        \\
    ;
    try common.help.printColorized(allocator, writer, text);
}

test "tree: test section begins" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(common.ExitCode.success));
    try testing.expect(prog_name.len > 0);
}

const tree_test_env = [_]common.env.Override{
    .{ .key = "VIBEUTILS_STYLE", .value = null },
    .{ .key = "VIBEUTILS_COLOR", .value = null },
    .{ .key = "VIBEUTILS_ICONS", .value = null },
    .{ .key = "LS_ICONS", .value = null },
    .{ .key = "NO_COLOR", .value = null },
    .{ .key = "TERM", .value = "xterm-256color" },
};

fn treeTestStageEnv() []const common.env.Override {
    const saved = common.env.test_overrides;
    common.env.test_overrides = &tree_test_env;
    return saved;
}

fn treeTestCreateFile(dir: std.Io.Dir, path: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len < std.Io.Dir.max_path_bytes);
    const file = try dir.createFile(testing.io, path, .{});
    file.close(testing.io);
}

const TreeTestFixture = struct {
    tmp_dir: testing.TmpDir,
    root_path: [:0]u8,

    fn init() !TreeTestFixture {
        var tmp_dir = testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();
        try tmp_dir.dir.createDirPath(testing.io, "root/beta/skipme");
        try tmp_dir.dir.createDirPath(testing.io, "root/.hidden");
        try treeTestCreateFile(tmp_dir.dir, "root/alpha");
        try treeTestCreateFile(tmp_dir.dir, "root/zed");
        try treeTestCreateFile(tmp_dir.dir, "root/beta/nested.txt");
        try treeTestCreateFile(tmp_dir.dir, "root/beta/z.log");
        try treeTestCreateFile(tmp_dir.dir, "root/beta/skipme/buried.txt");
        try treeTestCreateFile(tmp_dir.dir, "root/.dotfile");
        try treeTestCreateFile(tmp_dir.dir, "root/.hidden/visible.txt");
        const root_path = try tmp_dir.dir.realPathFileAlloc(
            testing.io,
            "root",
            testing.allocator,
        );
        std.debug.assert(root_path.len > 0);
        std.debug.assert(std.fs.path.isAbsolute(root_path));
        return .{ .tmp_dir = tmp_dir, .root_path = root_path };
    }

    fn deinit(self: *TreeTestFixture) void {
        std.debug.assert(self.root_path.len > 0);
        std.debug.assert(std.fs.path.isAbsolute(self.root_path));
        testing.allocator.free(self.root_path);
        self.tmp_dir.cleanup();
    }
};

const TreeTestRun = struct {
    stdout_aw: std.Io.Writer.Allocating,
    stderr_aw: std.Io.Writer.Allocating,
    exit_code: u8,

    fn init(args: []const []const u8) !TreeTestRun {
        std.debug.assert(args.len < 1 << 20);
        std.debug.assert(@sizeOf(TreeTestRun) > 0);
        var result = TreeTestRun{
            .stdout_aw = .init(testing.allocator),
            .stderr_aw = .init(testing.allocator),
            .exit_code = 255,
        };
        errdefer result.deinit();
        result.exit_code = try runTree(
            testing.allocator,
            testing.io,
            args,
            &result.stdout_aw.writer,
            &result.stderr_aw.writer,
        );
        return result;
    }

    fn deinit(self: *TreeTestRun) void {
        std.debug.assert(self.exit_code <= 255);
        std.debug.assert(@intFromPtr(self) != 0);
        self.stdout_aw.deinit();
        self.stderr_aw.deinit();
    }

    fn stdout(self: *const TreeTestRun) []const u8 {
        std.debug.assert(self.exit_code <= 255);
        std.debug.assert(@intFromPtr(self) != 0);
        return self.stdout_aw.writer.buffered();
    }

    fn stderr(self: *const TreeTestRun) []const u8 {
        std.debug.assert(self.exit_code <= 255);
        std.debug.assert(@intFromPtr(self) != 0);
        return self.stderr_aw.writer.buffered();
    }
};

fn treeTestChdir(tmp_dir: *testing.TmpDir) !std.Io.Dir {
    var saved_cwd = try std.Io.Dir.cwd().openDir(testing.io, ".", .{});
    errdefer saved_cwd.close(testing.io);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        ".",
        testing.allocator,
    );
    defer testing.allocator.free(tmp_path);
    std.debug.assert(tmp_path.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(tmp_path));
    try std.Io.Threaded.chdir(tmp_path);
    return saved_cwd;
}

fn treeTestRestoreCwd(saved_cwd: *std.Io.Dir) void {
    std.debug.assert(saved_cwd.handle >= 0);
    std.debug.assert(saved_cwd.handle != std.posix.AT.FDCWD);
    std.process.setCurrentDir(testing.io, saved_cwd.*) catch
        @panic("failed to restore tree test cwd");
    saved_cwd.close(testing.io);
}

test "tree plan 1: bare directory prints sorted topology and summary" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(&.{fixture.root_path});
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n" ++
            "├── alpha\n" ++
            "├── beta\n" ++
            "│   ├── nested.txt\n" ++
            "│   ├── skipme\n" ++
            "│   │   └── buried.txt\n" ++
            "│   └── z.log\n" ++
            "└── zed\n\n" ++
            "3 directories, 5 files\n",
        .{fixture.root_path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
    try testing.expectEqualStrings("", result.stderr());
}

test "tree plan 1b: empty root counts as one directory" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(testing.io, "empty");
    const path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "empty",
        testing.allocator,
    );
    defer testing.allocator.free(path);
    var result = try TreeTestRun.init(&.{path});
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n\n1 directory, 0 files\n",
        .{path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
}

test "tree plan 2: all includes hidden entries and default prunes hidden directories" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var plain = try TreeTestRun.init(&.{fixture.root_path});
    defer plain.deinit();
    var all = try TreeTestRun.init(&.{ "-a", fixture.root_path });
    defer all.deinit();

    try testing.expect(std.mem.find(u8, plain.stdout(), ".dotfile") == null);
    try testing.expect(std.mem.find(u8, plain.stdout(), ".hidden") == null);
    try testing.expect(std.mem.find(u8, plain.stdout(), "visible.txt") == null);
    try testing.expect(std.mem.find(u8, all.stdout(), ".dotfile") != null);
    try testing.expect(std.mem.find(u8, all.stdout(), ".hidden") != null);
    try testing.expect(std.mem.find(u8, all.stdout(), "visible.txt") != null);
}

test "tree plan 3: directories-only omits files and file summary clause" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(&.{ "-d", fixture.root_path });
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "beta") != null);
    try testing.expect(std.mem.find(u8, result.stdout(), "alpha") == null);
    try testing.expect(std.mem.endsWith(u8, result.stdout(), "\n3 directories\n"));
    try testing.expect(std.mem.find(u8, result.stdout(), "files") == null);
}

test "tree plan 4: level one succeeds and prunes grandchildren" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(&.{ "-L", "1", fixture.root_path });
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "beta") != null);
    try testing.expect(std.mem.find(u8, result.stdout(), "nested.txt") == null);
    try testing.expectEqualStrings("", result.stderr());
}

test "tree plan 5: level zero prints only the operand" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(&.{ "-L", "0", fixture.root_path });
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n\n1 directory, 0 files\n",
        .{fixture.root_path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
}

test "tree plan 6: invalid missing negative and overflowing levels exit one" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    const cases = [_][]const []const u8{
        &.{ "-L", "nope" },
        &.{"-L"},
        &.{ "-L", "-1" },
        &.{ "-L", "999999999999999999999999999999999999" },
    };
    for (cases) |args| {
        var result = try TreeTestRun.init(args);
        defer result.deinit();
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expect(result.stderr().len > 0);
    }
}

test "tree plan 7: ignore excludes matching files and prunes matching directory" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var logs = try TreeTestRun.init(&.{ "-I", "*.log", fixture.root_path });
    defer logs.deinit();
    var skipped = try TreeTestRun.init(&.{ "-I", "skipme", fixture.root_path });
    defer skipped.deinit();

    try testing.expect(std.mem.find(u8, logs.stdout(), "z.log") == null);
    try testing.expect(std.mem.find(u8, logs.stdout(), "nested.txt") != null);
    try testing.expect(std.mem.find(u8, skipped.stdout(), "skipme") == null);
    try testing.expect(std.mem.find(u8, skipped.stdout(), "buried.txt") == null);
}

test "tree plan 8: repeated ignore patterns accumulate" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(
        &.{ "-I", "skipme", "-I", "*.log", fixture.root_path },
    );
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "skipme") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "buried.txt") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "z.log") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "nested.txt") != null);
}

test "tree plan 8b: long aliases match their short forms" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    const short_args = [_][]const []const u8{
        &.{ "-I", "skipme", fixture.root_path },
        &.{ "-L", "1", fixture.root_path },
        &.{ "-d", fixture.root_path },
        &.{ "-a", fixture.root_path },
    };
    const long_args = [_][]const []const u8{
        &.{ "--ignore=skipme", fixture.root_path },
        &.{ "--level=1", fixture.root_path },
        &.{ "--directories-only", fixture.root_path },
        &.{ "--all", fixture.root_path },
    };
    for (short_args, long_args) |short, long| {
        var short_result = try TreeTestRun.init(short);
        defer short_result.deinit();
        var long_result = try TreeTestRun.init(long);
        defer long_result.deinit();
        try testing.expectEqual(@as(u8, 0), long_result.exit_code);
        try testing.expect(short_result.stdout().len > 0);
        try testing.expectEqualStrings(short_result.stdout(), long_result.stdout());
    }
}

test "tree plan 8c: clustered ignore options consume their patterns" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var all_ignore = try TreeTestRun.init(&.{ "-aI*.log", fixture.root_path });
    defer all_ignore.deinit();
    var dir_ignore = try TreeTestRun.init(&.{ "-dIskipme", fixture.root_path });
    defer dir_ignore.deinit();

    try testing.expectEqual(@as(u8, 0), all_ignore.exit_code);
    try testing.expect(std.mem.find(u8, all_ignore.stdout(), ".dotfile") != null);
    try testing.expect(std.mem.find(u8, all_ignore.stdout(), "z.log") == null);
    try testing.expectEqual(@as(u8, 0), dir_ignore.exit_code);
    try testing.expect(std.mem.find(u8, dir_ignore.stdout(), "skipme") == null);
    try testing.expect(std.mem.find(u8, dir_ignore.stdout(), "alpha") == null);
}

test "tree plan 9: pipe separates ignore alternatives" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(
        &.{ "-I", "skipme|*.log", fixture.root_path },
    );
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "skipme") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "buried.txt") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "z.log") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "nested.txt") != null);
}

test "tree plan 10: filtering recomputes the last-sibling connector" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var ignored = try TreeTestRun.init(&.{ "-I", "zed", fixture.root_path });
    defer ignored.deinit();
    var directories = try TreeTestRun.init(&.{ "-d", fixture.root_path });
    defer directories.deinit();

    try testing.expect(std.mem.find(u8, ignored.stdout(), "└── beta") != null);
    try testing.expect(std.mem.find(u8, ignored.stdout(), "├── beta") == null);
    try testing.expect(std.mem.find(u8, directories.stdout(), "└── beta") != null);
    try testing.expect(std.mem.find(u8, directories.stdout(), "├── beta") == null);
}

test "tree plan 11: no operand defaults to current directory" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try treeTestCreateFile(tmp_dir.dir, "only");
    var saved_cwd = try treeTestChdir(&tmp_dir);
    defer treeTestRestoreCwd(&saved_cwd);
    var result = try TreeTestRun.init(&.{});
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.startsWith(u8, result.stdout(), ".\n"));
    try testing.expect(std.mem.find(u8, result.stdout(), "└── only") != null);
    try testing.expect(std.mem.endsWith(u8, result.stdout(), "1 directory, 1 file\n"));
}

test "tree plan 11b: file operand is a single-node tree" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try treeTestCreateFile(tmp_dir.dir, "single.txt");
    const path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "single.txt",
        testing.allocator,
    );
    defer testing.allocator.free(path);
    var result = try TreeTestRun.init(&.{path});
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n\n0 directories, 1 file\n",
        .{path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
}

test "tree plan 12: multiple roots concatenate before one combined summary" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(testing.io, "one");
    try tmp_dir.dir.createDirPath(testing.io, "two");
    const one = try tmp_dir.dir.realPathFileAlloc(testing.io, "one", testing.allocator);
    defer testing.allocator.free(one);
    const two = try tmp_dir.dir.realPathFileAlloc(testing.io, "two", testing.allocator);
    defer testing.allocator.free(two);
    var result = try TreeTestRun.init(&.{ one, two });
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n{s}\n\n2 directories, 0 files\n",
        .{ one, two },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stdout(), "\n\n"));
}

test "tree plan 13: color modes honor never and NO_COLOR without hiding icons" {
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();

    common.env.test_overrides = &tree_test_env;
    var never = try TreeTestRun.init(&.{ "--color=never", fixture.root_path });
    defer never.deinit();
    try testing.expectEqual(@as(u8, 0), never.exit_code);
    try testing.expect(std.mem.find(u8, never.stdout(), "\x1b") == null);

    const no_color_env = [_]common.env.Override{
        .{ .key = "VIBEUTILS_STYLE", .value = null },
        .{ .key = "VIBEUTILS_COLOR", .value = null },
        .{ .key = "VIBEUTILS_ICONS", .value = null },
        .{ .key = "LS_ICONS", .value = null },
        .{ .key = "NO_COLOR", .value = "1" },
        .{ .key = "TERM", .value = "xterm-256color" },
    };
    common.env.test_overrides = &no_color_env;
    var always = try TreeTestRun.init(&.{ "--color=always", fixture.root_path });
    defer always.deinit();
    try testing.expectEqual(@as(u8, 0), always.exit_code);
    try testing.expect(std.mem.find(u8, always.stdout(), "\x1b") == null);

    var icons = try TreeTestRun.init(&.{ "--icons=always", fixture.root_path });
    defer icons.deinit();
    const theme = common.icons.IconTheme{};
    try testing.expect(std.mem.find(u8, icons.stdout(), theme.directory) != null);
    try testing.expect(std.mem.find(u8, icons.stdout(), theme.file) != null);
    try testing.expect(std.mem.find(u8, icons.stdout(), "\x1b") == null);
}

test "tree plan 13b: forced color emits escapes and icons distinguish kinds" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var color = try TreeTestRun.init(&.{ "--color=always", fixture.root_path });
    defer color.deinit();
    var icons = try TreeTestRun.init(&.{ "--icons=always", fixture.root_path });
    defer icons.deinit();
    const theme = common.icons.IconTheme{};
    const dir_icon = common.icons.getIcon(&theme, "beta", true, false, false);
    const file_icon = common.icons.getIcon(&theme, "alpha", false, false, false);

    try testing.expectEqual(@as(u8, 0), color.exit_code);
    try testing.expect(std.mem.find(u8, color.stdout(), "\x1b") != null);
    try testing.expect(!std.mem.eql(u8, dir_icon, file_icon));
    try testing.expect(std.mem.find(u8, icons.stdout(), dir_icon) != null);
    try testing.expect(std.mem.find(u8, icons.stdout(), file_icon) != null);
}

test "tree plan 14: help version and argument errors use documented exit codes" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    const success_cases = [_][]const u8{ "--help", "-h", "--version", "-V" };
    for (success_cases) |arg| {
        var result = try TreeTestRun.init(&.{arg});
        defer result.deinit();
        try testing.expectEqual(@as(u8, 0), result.exit_code);
        try testing.expect(result.stdout().len > 0);
    }
    const error_cases = [_][]const u8{
        "--unknown-tree-flag",
        "--color=bogus",
        "--icons=bogus",
    };
    for (error_cases) |arg| {
        var result = try TreeTestRun.init(&.{arg});
        defer result.deinit();
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expect(result.stderr().len > 0);
    }
}

test "tree plan 15: nonexistent operand reports a clean diagnostic" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var result = try TreeTestRun.init(
        &.{"/tmp/vibeutils-tree-definitely-missing-4d3f9b"},
    );
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(result.stderr().len > 0);
    try testing.expect(std.mem.find(u8, result.stderr(), "error.") == null);
    try testing.expect(std.mem.find(u8, result.stderr(), "FileNotFound") == null);
}

test "tree plan 15b: unreadable root reports a clean diagnostic" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(testing.io, "locked");
    try treeTestCreateFile(tmp_dir.dir, "locked/secret");
    const path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "locked",
        testing.allocator,
    );
    defer testing.allocator.free(path);
    try tmp_dir.dir.setFilePermissions(
        testing.io,
        "locked",
        std.Io.File.Permissions.fromMode(0o000),
        .{},
    );
    defer tmp_dir.dir.setFilePermissions(
        testing.io,
        "locked",
        std.Io.File.Permissions.fromMode(0o700),
        .{},
    ) catch {};
    var result = try TreeTestRun.init(&.{path});
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(result.stderr().len > 0);
    try testing.expect(std.mem.find(u8, result.stderr(), "error.AccessDenied") == null);
}

test "tree plan 16: directory symlink is listed but not followed" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(testing.io, "container/root");
    try tmp_dir.dir.createDirPath(testing.io, "target");
    try treeTestCreateFile(tmp_dir.dir, "target/secret.txt");
    tmp_dir.dir.symLink(
        testing.io,
        "../../target",
        "container/root/link",
        .{},
    ) catch |err| {
        if (err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    const root = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "container/root",
        testing.allocator,
    );
    defer testing.allocator.free(root);
    var result = try TreeTestRun.init(&.{root});
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "link") != null);
    try testing.expect(std.mem.find(u8, result.stdout(), "secret.txt") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), " -> ") == null);
}

fn walkerTestEntry(
    name: []const u8,
    kind: FileKind,
    parent: ?std.Io.Dir,
) common.walker.Entry {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= std.Io.Dir.max_path_bytes);
    return .{
        .path = name,
        .basename = name,
        .kind = kind,
        .depth = 1,
        .visit = .pre,
        .stat = null,
        .parent_dir = parent,
    };
}

const UnknownKindFixture = struct {
    tmp_dir: testing.TmpDir,
    parent: std.Io.Dir,

    fn init() !UnknownKindFixture {
        var tmp_dir = testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();
        try tmp_dir.dir.createDir(testing.io, "adir", .default_dir);
        try treeTestCreateFile(tmp_dir.dir, "afile");
        tmp_dir.dir.symLink(testing.io, "afile", "alink", .{}) catch |err| {
            if (err == error.AccessDenied) return error.SkipZigTest;
            return err;
        };
        const parent = try tmp_dir.dir.openDir(testing.io, ".", .{});
        return .{ .tmp_dir = tmp_dir, .parent = parent };
    }

    fn deinit(self: *UnknownKindFixture) void {
        std.debug.assert(self.parent.handle >= 0);
        std.debug.assert(self.tmp_dir.dir.handle >= 0);
        self.parent.close(testing.io);
        self.tmp_dir.cleanup();
    }

    fn unknown(self: *const UnknownKindFixture, name: []const u8) common.walker.Entry {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.parent.handle >= 0);
        return walkerTestEntry(name, .unknown, self.parent);
    }
};

test "tree: unknown dirent kind resolves directories via parent_dir lstat" {
    var fixture = try UnknownKindFixture.init();
    defer fixture.deinit();
    const dir_entry = fixture.unknown("adir");
    const file_entry = fixture.unknown("afile");
    try testing.expectEqual(FileKind.unknown, dir_entry.kind);
    try testing.expectEqual(FileKind.directory, resolveEntryKind(dir_entry));
    try testing.expectEqual(FileKind.unknown, file_entry.kind);
    try testing.expectEqual(FileKind.file, resolveEntryKind(file_entry));

    const dirs_only = WalkFilter{
        .all = true,
        .directories_only = true,
        .max_level = null,
        .ignore_patterns = &.{},
    };
    try testing.expect(!shouldSkip(dir_entry, resolveEntryKind(dir_entry), dirs_only));
    try testing.expect(shouldSkip(file_entry, resolveEntryKind(file_entry), dirs_only));

    var counts = Counts{};
    countNode(&counts, resolveEntryKind(dir_entry));
    countNode(&counts, resolveEntryKind(file_entry));
    try testing.expectEqual(@as(u32, 1), counts.directories);
    try testing.expectEqual(@as(u32, 1), counts.files);
}

test "tree: unknown dirent kind keeps known kinds and failed lstat" {
    var fixture = try UnknownKindFixture.init();
    defer fixture.deinit();
    const known_dir = walkerTestEntry("adir", .directory, null);
    const known_file = walkerTestEntry("afile", .file, null);
    try testing.expectEqual(FileKind.directory, resolveEntryKind(known_dir));
    try testing.expectEqual(FileKind.file, resolveEntryKind(known_file));

    const no_parent = walkerTestEntry("adir", .unknown, null);
    const missing = fixture.unknown("no-such-entry");
    try testing.expectEqual(FileKind.unknown, resolveEntryKind(no_parent));
    try testing.expectEqual(FileKind.unknown, resolveEntryKind(missing));

    const link_entry = fixture.unknown("alink");
    try testing.expectEqual(FileKind.unknown, link_entry.kind);
    try testing.expectEqual(FileKind.sym_link, resolveEntryKind(link_entry));
}
