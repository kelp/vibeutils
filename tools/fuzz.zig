//! Mutational fuzzer for vibeutils.
//!
//! Spawns a target utility, feeds it mutated bytes via one of three
//! harness modes (stdin, argv, file_arg), and classifies the result.
//! Crashes are saved to a per-utility directory keyed by SHA-256 of
//! the offending input so a flaky run can be reproduced.
//!
//! Single-file, std-only, no `common` import on purpose: the fuzzer is
//! a dev tool that must keep working when the rest of the tree is
//! broken. Imports its sibling tools/harness.zig and tools/fuzz_targets.zig.

const std = @import("std");
const harness = @import("harness.zig");
const fuzz_targets = @import("fuzz_targets.zig");

const Allocator = std.mem.Allocator;

const Options = struct {
    target: []const u8,
    util: []const u8,
    corpus_dir: []const u8,
    crashes_dir: []const u8,
    max_runs: u64 = 10_000,
    timeout_ms: u64 = 2000,
    max_input_size: usize = 65536,
    seed: u64 = 0,
    seed_explicit: bool = false,
};

const Crash = struct {
    label: []const u8, // e.g. "SIGSEGV", "timeout"
    run: u64,
    input: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(argv, stderr) catch |err| switch (err) {
        error.HelpRequested => return,
        else => std.process.exit(2),
    };

    const h = fuzz_targets.lookup(opts.util);
    // Surface template config errors at startup, not on the first crash.
    switch (h) {
        .stdin => {},
        .argv => |c| harness.validateTemplate(c.template) catch |err| {
            try stderr.print("fuzz: bad argv template for {s}: {s}\n", .{ opts.util, @errorName(err) });
            try stderr.flush();
            std.process.exit(2);
        },
        .file_arg => |c| harness.validateTemplate(c.template) catch |err| {
            try stderr.print("fuzz: bad file_arg template for {s}: {s}\n", .{ opts.util, @errorName(err) });
            try stderr.flush();
            std.process.exit(2);
        },
    }

    var seed = opts.seed;
    if (!opts.seed_explicit) {
        const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
        seed = @as(u64, @truncate(@as(u128, @bitCast(@as(i128, ns)))));
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    try stdout.print(
        "fuzz: target={s} util={s} mode={s} corpus={s} crashes={s} max_runs={d} timeout_ms={d} max_input={d} seed={d}\n",
        .{ opts.target, opts.util, @tagName(h), opts.corpus_dir, opts.crashes_dir, opts.max_runs, opts.timeout_ms, opts.max_input_size, seed },
    );
    try stdout.flush();

    var corpus = try loadCorpus(arena, io, opts.corpus_dir, opts.max_input_size, rand);
    try stdout.print("fuzz: loaded {d} seed input(s)\n", .{corpus.items.len});
    try stdout.flush();

    const start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    var crashes_found: u64 = 0;
    var seen_crashes: std.array_hash_map.String([]const u8) = .empty;
    defer seen_crashes.deinit(arena);

    var run: u64 = 0;
    while (run < opts.max_runs) : (run += 1) {
        const seed_idx = rand.uintLessThan(usize, corpus.items.len);
        const base = corpus.items[seed_idx];

        var mutant: std.ArrayList(u8) = .empty;
        defer mutant.deinit(arena);
        try mutant.appendSlice(arena, base);

        const num_mutations = rand.intRangeAtMost(u32, 1, 3);
        var m: u32 = 0;
        while (m < num_mutations) : (m += 1) {
            try mutate(arena, rand, &mutant, &corpus, opts.max_input_size);
        }

        const ps = harness.prepare(arena, io, opts.target, h, mutant.items) catch |err| {
            try stderr.print("fuzz: harness prep error on run {d}: {s}\n", .{ run, @errorName(err) });
            try stderr.flush();
            continue;
        };
        defer harness.cleanup(io, ps);

        const outcome = runOne(io, ps, opts.timeout_ms) catch |err| {
            try stderr.print("fuzz: spawn error on run {d}: {s}\n", .{ run, @errorName(err) });
            try stderr.flush();
            continue;
        };

        if (outcome.label) |label| {
            const hex = sha256Hex(mutant.items);
            const gop = try seen_crashes.getOrPut(arena, &hex);
            if (!gop.found_existing) {
                gop.key_ptr.* = try arena.dupe(u8, &hex);
                gop.value_ptr.* = try arena.dupe(u8, label);
                try saveCrash(io, arena, opts.crashes_dir, &hex, label, run, seed, mutant.items);
                crashes_found += 1;
                try stderr.print("fuzz: CRASH run={d} signal={s} sha256={s}\n", .{ run, label, &hex });
                try stderr.flush();
            }
        }

        if ((run + 1) % 1000 == 0) {
            const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            const elapsed_s = @as(f64, @floatFromInt(now_ns - start_ns)) / 1_000_000_000.0;
            const rate = if (elapsed_s > 0.0) @as(f64, @floatFromInt(run + 1)) / elapsed_s else 0.0;
            try stdout.print("fuzz: runs={d} crashes={d} elapsed={d:.1}s rate={d:.1}/s\n", .{ run + 1, crashes_found, elapsed_s, rate });
            try stdout.flush();
        }
    }

    const end_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const total_s = @as(f64, @floatFromInt(end_ns - start_ns)) / 1_000_000_000.0;
    const rate = if (total_s > 0.0) @as(f64, @floatFromInt(run)) / total_s else 0.0;
    try stdout.print(
        "fuzz: done runs={d} crashes={d} elapsed={d:.1}s rate={d:.1}/s seed={d}\n",
        .{ run, crashes_found, total_s, rate, seed },
    );
    try stdout.flush();

    if (crashes_found > 0) std.process.exit(1);
}

// ----------------------------------------------------------------------------
// CLI parsing

const help_text =
    \\fuzz <util-binary> --util NAME --corpus DIR --crashes DIR [options]
    \\
    \\Options:
    \\  --util NAME          Utility name for harness lookup (required)
    \\  --corpus DIR         Seed corpus directory (required)
    \\  --crashes DIR        Where to write crash artifacts (required)
    \\  --max-runs N         Iterations (default 10000)
    \\  --timeout-ms N       Per-run wall-clock timeout (default 2000)
    \\  --max-input-size N   Cap on mutated bytes (default 65536)
    \\  --seed N             PRNG seed (default wall-clock)
    \\  -h, --help           Show this message
    \\
;

fn parseArgs(argv: []const [:0]const u8, stderr: *std.Io.Writer) !Options {
    if (argv.len < 2) {
        try stderr.print("fuzz: missing target binary\n{s}", .{help_text});
        try stderr.flush();
        return error.MissingTarget;
    }

    var opts: Options = .{
        .target = argv[1],
        .util = "",
        .corpus_dir = "",
        .crashes_dir = "",
    };

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stderr.print("{s}", .{help_text});
            try stderr.flush();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--util")) {
            i += 1;
            if (i >= argv.len) return missing(stderr, arg);
            opts.util = argv[i];
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            i += 1;
            if (i >= argv.len) return missing(stderr, arg);
            opts.corpus_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--crashes")) {
            i += 1;
            if (i >= argv.len) return missing(stderr, arg);
            opts.crashes_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--max-runs")) {
            i += 1;
            if (i >= argv.len) return missing(stderr, arg);
            opts.max_runs = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            i += 1;
            if (i >= argv.len) return missing(stderr, arg);
            opts.timeout_ms = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--max-input-size")) {
            i += 1;
            if (i >= argv.len) return missing(stderr, arg);
            opts.max_input_size = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= argv.len) return missing(stderr, arg);
            opts.seed = try std.fmt.parseInt(u64, argv[i], 10);
            opts.seed_explicit = true;
        } else {
            try stderr.print("fuzz: unknown argument '{s}'\n{s}", .{ arg, help_text });
            try stderr.flush();
            return error.UnknownArgument;
        }
    }

    if (opts.util.len == 0 or opts.corpus_dir.len == 0 or opts.crashes_dir.len == 0) {
        try stderr.print("fuzz: --util, --corpus, and --crashes are required\n", .{});
        try stderr.flush();
        return error.MissingArgument;
    }

    if (opts.max_input_size == 0) {
        try stderr.print("fuzz: --max-input-size must be > 0\n", .{});
        try stderr.flush();
        return error.InvalidArgument;
    }

    if (opts.max_runs == 0) {
        try stderr.print("fuzz: --max-runs must be > 0\n", .{});
        try stderr.flush();
        return error.InvalidArgument;
    }

    return opts;
}

fn missing(stderr: *std.Io.Writer, arg: []const u8) anyerror {
    stderr.print("fuzz: option {s} requires a value\n", .{arg}) catch {};
    stderr.flush() catch {};
    return error.MissingValue;
}

// ----------------------------------------------------------------------------
// Corpus

fn loadCorpus(
    arena: Allocator,
    io: std.Io,
    dir_path: []const u8,
    max_input_size: usize,
    rand: std.Random,
) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try appendBuiltinCorpus(arena, &list, rand);
            return list;
        },
        else => return err,
    };
    defer dir.close(io);

    const Entry = struct {
        name: []const u8,
        data: []const u8,
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(arena);

    var entry_buf: [std.Io.Dir.Reader.min_buffer_len]u8 align(@alignOf(usize)) = undefined;
    var reader = std.Io.Dir.Reader.init(dir, &entry_buf);
    while (try reader.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = dir.readFileAlloc(io, entry.name, arena, .limited(max_input_size)) catch |err| switch (err) {
            error.StreamTooLong => blk: {
                // Truncate to max_input_size by re-reading via a sized buffer.
                var file = try dir.openFile(io, entry.name, .{});
                defer file.close(io);
                const buf = try arena.alloc(u8, max_input_size);
                var f_reader = file.reader(io, &.{});
                const n = f_reader.interface.readSliceShort(buf) catch buf.len;
                break :blk buf[0..n];
            },
            else => return err,
        };
        // Dupe the name into the arena since `reader.next` reuses entry_buf.
        const name = try arena.dupe(u8, entry.name);
        try entries.append(arena, .{ .name = name, .data = data });
    }

    // Sort by filename so the same --seed reproduces the same run across
    // machines and after cache wipes (filesystem iteration order varies).
    const lessThan = struct {
        fn cmp(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.cmp;
    std.mem.sort(Entry, entries.items, {}, lessThan);

    for (entries.items) |e| try list.append(arena, e.data);

    if (list.items.len == 0) {
        try appendBuiltinCorpus(arena, &list, rand);
    }
    return list;
}

fn appendBuiltinCorpus(arena: Allocator, list: *std.ArrayList([]const u8), rand: std.Random) !void {
    try list.append(arena, "");
    try list.append(arena, "a");
    try list.append(arena, "0");
    try list.append(arena, "\n");
    const rnd = try arena.alloc(u8, 32);
    rand.bytes(rnd);
    try list.append(arena, rnd);
}

// ----------------------------------------------------------------------------
// Mutations

const interesting_bytes = [_]u8{ 0x00, 0x01, 0x7f, 0x80, 0xff, '\n', '\r', '\t', ' ', '0', '9', 0x1b };

fn mutate(
    arena: Allocator,
    rand: std.Random,
    buf: *std.ArrayList(u8),
    corpus: *std.ArrayList([]const u8),
    max_size: usize,
) !void {
    const pick = rand.uintLessThan(u8, 8);
    switch (pick) {
        0 => mutBitFlip(rand, buf.items),
        1 => mutByteXor(rand, buf.items),
        2 => mutByteRandom(rand, buf.items),
        3 => mutByteInteresting(rand, buf.items),
        4 => try mutInsertRandom(arena, rand, buf, max_size),
        5 => mutDelete(rand, buf),
        6 => try mutDuplicateSlice(arena, rand, buf, max_size),
        7 => try mutSplice(arena, rand, buf, corpus, max_size),
        else => unreachable,
    }
}

fn mutBitFlip(rand: std.Random, bytes: []u8) void {
    if (bytes.len == 0) return;
    const idx = rand.uintLessThan(usize, bytes.len);
    const bit: u3 = @intCast(rand.uintLessThan(u8, 8));
    bytes[idx] ^= @as(u8, 1) << bit;
}

fn mutByteXor(rand: std.Random, bytes: []u8) void {
    if (bytes.len == 0) return;
    const idx = rand.uintLessThan(usize, bytes.len);
    var v: u8 = rand.int(u8);
    if (v == 0) v = 1;
    bytes[idx] ^= v;
}

fn mutByteRandom(rand: std.Random, bytes: []u8) void {
    if (bytes.len == 0) return;
    const idx = rand.uintLessThan(usize, bytes.len);
    bytes[idx] = rand.int(u8);
}

fn mutByteInteresting(rand: std.Random, bytes: []u8) void {
    if (bytes.len == 0) return;
    const idx = rand.uintLessThan(usize, bytes.len);
    bytes[idx] = interesting_bytes[rand.uintLessThan(usize, interesting_bytes.len)];
}

fn mutInsertRandom(
    arena: Allocator,
    rand: std.Random,
    buf: *std.ArrayList(u8),
    max_size: usize,
) !void {
    if (buf.items.len >= max_size) return;
    const headroom = max_size - buf.items.len;
    const want = rand.intRangeAtMost(usize, 1, @min(@as(usize, 16), headroom));
    const offset = if (buf.items.len == 0) 0 else rand.uintAtMost(usize, buf.items.len);

    try buf.ensureUnusedCapacity(arena, want);
    buf.items.len += want;
    // Shift tail right.
    var i: usize = buf.items.len;
    while (i > offset + want) {
        i -= 1;
        buf.items[i] = buf.items[i - want];
    }
    // Fill new region.
    var j: usize = 0;
    while (j < want) : (j += 1) {
        buf.items[offset + j] = rand.int(u8);
    }
}

fn mutDelete(rand: std.Random, buf: *std.ArrayList(u8)) void {
    if (buf.items.len == 0) return;
    const want = rand.intRangeAtMost(usize, 1, @min(@as(usize, 16), buf.items.len));
    const offset = rand.uintAtMost(usize, buf.items.len - want);
    const tail_start = offset + want;
    var i: usize = offset;
    while (tail_start + (i - offset) < buf.items.len) : (i += 1) {
        buf.items[i] = buf.items[tail_start + (i - offset)];
    }
    buf.items.len -= want;
}

fn mutDuplicateSlice(
    arena: Allocator,
    rand: std.Random,
    buf: *std.ArrayList(u8),
    max_size: usize,
) !void {
    if (buf.items.len == 0 or buf.items.len >= max_size) return;
    const a = rand.uintLessThan(usize, buf.items.len);
    const b = rand.intRangeAtMost(usize, a + 1, buf.items.len);
    const slice_len = b - a;
    const headroom = max_size - buf.items.len;
    const copy_len = @min(slice_len, headroom);
    if (copy_len == 0) return;

    const insert_at = rand.uintAtMost(usize, buf.items.len);
    // Snapshot bytes first; the buffer may move on resize.
    const snapshot = try arena.dupe(u8, buf.items[a .. a + copy_len]);

    try buf.ensureUnusedCapacity(arena, copy_len);
    buf.items.len += copy_len;
    var i: usize = buf.items.len;
    while (i > insert_at + copy_len) {
        i -= 1;
        buf.items[i] = buf.items[i - copy_len];
    }
    @memcpy(buf.items[insert_at .. insert_at + copy_len], snapshot);
}

fn mutSplice(
    arena: Allocator,
    rand: std.Random,
    buf: *std.ArrayList(u8),
    corpus: *std.ArrayList([]const u8),
    max_size: usize,
) !void {
    if (corpus.items.len == 0) return;
    const other = corpus.items[rand.uintLessThan(usize, corpus.items.len)];
    if (other.len == 0 and buf.items.len == 0) return;

    const prefix_len = if (buf.items.len == 0) 0 else rand.uintAtMost(usize, buf.items.len);
    const suffix_start = if (other.len == 0) 0 else rand.uintAtMost(usize, other.len);
    const suffix_len = other.len - suffix_start;
    const total = @min(prefix_len + suffix_len, max_size);
    const new_buf = try arena.alloc(u8, total);
    const kept_prefix = @min(prefix_len, total);
    @memcpy(new_buf[0..kept_prefix], buf.items[0..kept_prefix]);
    const remaining = total - kept_prefix;
    const kept_suffix = @min(suffix_len, remaining);
    @memcpy(new_buf[kept_prefix .. kept_prefix + kept_suffix], other[suffix_start .. suffix_start + kept_suffix]);

    buf.clearRetainingCapacity();
    try buf.appendSlice(arena, new_buf[0..(kept_prefix + kept_suffix)]);
}

// ----------------------------------------------------------------------------
// Execution

const Outcome = struct {
    label: ?[]const u8,
};

const WatchdogCtx = struct {
    pid: std.posix.pid_t,
    timeout_ms: u64,
    io: std.Io,
    done: *std.atomic.Value(u8),
    killed: *std.atomic.Value(u8),
    mu: *std.Io.Mutex,
};

/// Watchdog: sleeps in 10ms slices, then performs a serialized
/// decide-and-kill under `ctx.mu`. Main acquires `ctx.mu` after `child.wait`
/// returns and sets `done=1` — so if the watchdog is mid-critical-section
/// calling posix.kill on `ctx.pid`, main blocks until it finishes.
///
/// Remaining theoretical race: between `child.wait` returning (reaping the
/// child, freeing the PID for kernel reuse) and main acquiring `ctx.mu`,
/// the watchdog could acquire the lock, observe `done == 0`, and SIGKILL
/// a recycled PID. The window is sub-microsecond on a real system and
/// requires the kernel to have already recycled the PID to another of our
/// processes in that span — effectively impossible in practice for a
/// short-lived fuzzer.
fn watchdog(ctx: WatchdogCtx) void {
    const slice_ns: i64 = 10 * std.time.ns_per_ms;
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < ctx.timeout_ms) {
        if (ctx.done.load(.acquire) != 0) return;
        ctx.io.sleep(std.Io.Duration.fromNanoseconds(slice_ns), .awake) catch {};
        elapsed_ms += 10;
    }
    ctx.mu.lockUncancelable(ctx.io);
    defer ctx.mu.unlock(ctx.io);
    if (ctx.done.load(.acquire) != 0) return;
    ctx.killed.store(1, .release);
    std.posix.kill(ctx.pid, .KILL) catch {};
}

fn runOne(io: std.Io, ps: harness.PreparedSpawn, timeout_ms: u64) !Outcome {
    var child = try std.process.spawn(io, .{
        .argv = ps.argv,
        .stdin = if (ps.stdin_bytes != null) .pipe else .close,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    var done = std.atomic.Value(u8).init(0);
    var killed = std.atomic.Value(u8).init(0);
    var mu: std.Io.Mutex = .init;

    // Spawn the watchdog BEFORE writing stdin: a utility that stalls
    // before consuming stdin (or stops on SIGSTOP) would otherwise block
    // the write forever with no timeout protection.
    var watchdog_thread: ?std.Thread = null;
    if (child.id) |pid| {
        watchdog_thread = std.Thread.spawn(.{}, watchdog, .{WatchdogCtx{
            .pid = pid,
            .timeout_ms = timeout_ms,
            .io = io,
            .done = &done,
            .killed = &killed,
            .mu = &mu,
        }}) catch |err| {
            // Don't silently disable the timeout — bail with a clear error.
            done.store(1, .release);
            child.kill(io);
            _ = child.wait(io) catch {};
            return err;
        };
    }

    if (ps.stdin_bytes) |bytes| {
        if (child.stdin) |*stdin| {
            stdin.writeStreamingAll(io, bytes) catch {};
            stdin.close(io);
            child.stdin = null;
        }
    }

    const term = child.wait(io) catch |err| {
        mu.lockUncancelable(io);
        done.store(1, .release);
        mu.unlock(io);
        if (watchdog_thread) |t| t.join();
        return err;
    };
    mu.lockUncancelable(io);
    done.store(1, .release);
    mu.unlock(io);
    if (watchdog_thread) |t| t.join();

    return classify(term, killed.load(.acquire) != 0);
}

fn classify(term: std.process.Child.Term, was_killed: bool) Outcome {
    return switch (term) {
        .exited => .{ .label = null },
        .signal => |sig| blk: {
            if (was_killed) break :blk .{ .label = "timeout" };
            break :blk .{ .label = signalName(sig) };
        },
        .stopped => .{ .label = null },
        .unknown => .{ .label = null },
    };
}

fn signalName(sig: std.posix.SIG) ?[]const u8 {
    // Treat fatal-by-default signals as crashes.
    if (sig == .SEGV) return "SIGSEGV";
    if (sig == .ABRT) return "SIGABRT";
    if (sig == .BUS) return "SIGBUS";
    if (sig == .ILL) return "SIGILL";
    if (sig == .FPE) return "SIGFPE";
    // Other signals (TERM, INT, PIPE, etc.) — not crashes.
    return null;
}

// ----------------------------------------------------------------------------
// Crash recording

fn saveCrash(
    io: std.Io,
    arena: Allocator,
    crashes_dir: []const u8,
    hex: []const u8,
    label: []const u8,
    run: u64,
    seed: u64,
    input: []const u8,
) !void {
    std.Io.Dir.cwd().createDirPath(io, crashes_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try std.Io.Dir.cwd().openDir(io, crashes_dir, .{});
    defer dir.close(io);

    const bin_name = try std.fmt.allocPrint(arena, "{s}.bin", .{hex});
    const meta_name = try std.fmt.allocPrint(arena, "{s}.txt", .{hex});

    {
        var bin_file = try dir.createFile(io, bin_name, .{ .truncate = true });
        defer bin_file.close(io);
        try bin_file.writeStreamingAll(io, input);
    }
    {
        var meta_file = try dir.createFile(io, meta_name, .{ .truncate = true });
        defer meta_file.close(io);
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "signal={s}\nrun={d}\nseed={d}\ninput_size={d}\n", .{ label, run, seed, input.len });
        try meta_file.writeStreamingAll(io, msg);
    }
}

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    var hex: [64]u8 = undefined;
    const chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = chars[b >> 4];
        hex[i * 2 + 1] = chars[b & 0xf];
    }
    return hex;
}
