const std = @import("std");
const testing = std.testing;

/// Test-only seam for injecting a fake stdin into `promptYesNo`.
///
/// In production this is always null and `promptYesNo` reads real stdin.
/// Tests set this to a caller-supplied reader so prompts can be answered
/// from an in-memory stream without a TTY. The implementer must wire
/// `promptYesNo` to consult this seam AND hold a single persistent reader
/// reused across calls (the fix). This declaration is only the stub
/// surface the test needs; it carries no persistent-reader logic itself.
var test_input_reader: ?*std.Io.Reader = null;

/// Install a fake stdin reader for the duration of a test.
pub fn setTestInputReader(reader: *std.Io.Reader) void {
    test_input_reader = reader;
}

/// Remove any installed fake stdin reader.
pub fn clearTestInputReader() void {
    test_input_reader = null;
}

/// Persistent real-stdin reader, lazily initialized on first prompt.
///
/// Module-level mutable state is acceptable here because it mirrors the
/// single, process-wide real stdin: there is exactly one stdin, so one
/// reader (and one read-ahead buffer) is the correct model. Recreating a
/// reader per call would lose any bytes the previous call buffered past
/// its line — under piped stdin the first read drains the whole pipe into
/// a throwaway buffer, so later prompts would wrongly hit EndOfStream.
/// Reusing this single reader preserves the buffered remainder across
/// sequential prompts.
var stdin_buffer: [8192]u8 = undefined;
var stdin_file_reader: ?std.Io.File.Reader = null;

/// Return the persistent real-stdin reader interface, initializing it once.
fn persistentStdinReader(io: std.Io) *std.Io.Reader {
    if (stdin_file_reader == null) {
        stdin_file_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    }
    std.debug.assert(stdin_file_reader != null);
    const reader = &stdin_file_reader.?.interface;
    std.debug.assert(reader.buffer.ptr == &stdin_buffer);
    std.debug.assert(reader.buffer.len == stdin_buffer.len);
    return reader;
}

/// Prompt the user with a yes/no question and read response from stdin.
///
/// Writes the formatted prompt to the given writer, flushes it, then reads
/// one line from stdin. Returns true if the first character is 'y' or 'Y'.
/// Returns false on EOF, empty input, or any other first character.
///
/// The caller is responsible for checking whether stdin is a TTY and whether
/// prompting is appropriate (e.g., not in CI, not in test mode).
pub fn promptYesNo(
    io: std.Io,
    writer: anytype,
    comptime fmt: []const u8,
    args: anytype,
) !bool {
    writer.print(fmt, args) catch return false;

    // Flush to ensure the prompt is visible before reading stdin
    const WriterType = @TypeOf(writer);
    const is_pointer = @typeInfo(WriterType) == .pointer;
    const ActualType = if (is_pointer) std.meta.Child(WriterType) else WriterType;
    if (comptime @hasDecl(ActualType, "flush")) {
        writer.flush() catch {};
    }

    // Use the injected test seam when present, otherwise the single
    // persistent real-stdin reader so read-ahead survives across calls.
    const stdin = test_input_reader orelse persistentStdinReader(io);
    std.debug.assert(@intFromPtr(stdin) != 0);

    return readYesNoLine(stdin);
}

/// Read one newline-terminated line and decide yes/no from its first char.
///
/// Uses `takeDelimiterInclusive` (which CONSUMES the delimiter) rather than
/// `takeDelimiterExclusive` (which leaves it buffered): with a persistent
/// reader an un-consumed '\n' would stall every subsequent prompt at an
/// empty line, defeating sequential prompts on one stream. On a final line
/// with no trailing newline, EndOfStream still leaves the typed bytes
/// buffered, so fall back to those. Returns true iff the first char is y/Y.
fn readYesNoLine(reader: *std.Io.Reader) !bool {
    std.debug.assert(@intFromPtr(reader) != 0);

    const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
        // No trailing newline before EOF: the typed bytes remain buffered.
        error.EndOfStream => reader.buffered(),
        error.StreamTooLong => return false,
        else => return err,
    };

    std.debug.assert(line.len <= reader.buffer.len);
    if (line.len > 0) {
        return std.ascii.toLower(line[0]) == 'y';
    }

    return false;
}

// Sequential prompts answered from a SINGLE piped stream must each get
// their OWN answer. Methodology: feed one fixed input stream
// "y\nn\ny\n" through the test seam and call promptYesNo three times,
// expecting true, false, true in order. This guards the
// recreate-reader-per-call data-loss bug: the buggy code builds a fresh
// stdin reader with a local buffer on every call, so the first call
// drains the whole stream into that throwaway buffer and later calls hit
// EndOfStream and wrongly return false. With a persistent reader the
// remaining lines survive and each prompt reads its own answer.
test "sequential prompts each consume their own answer from one stream" {
    const io = testing.io;

    var input_reader: std.Io.Reader = .fixed("y\nn\ny\n");
    setTestInputReader(&input_reader);
    defer clearTestInputReader();

    var output_buffer: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output_buffer);

    const first = try promptYesNo(io, &output_writer, "remove a? ", .{});
    const second = try promptYesNo(io, &output_writer, "remove b? ", .{});
    const third = try promptYesNo(io, &output_writer, "remove c? ", .{});

    // 'y' then 'n' then 'y' — the middle answer proves the stream is not
    // exhausted by the first call, and a non-default true at the end
    // avoids the falsy default-value trap.
    try testing.expect(first);
    try testing.expect(!second);
    try testing.expect(third);
}
