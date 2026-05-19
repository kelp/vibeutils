const std = @import("std");

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
    const ActualType = if (@typeInfo(WriterType) == .pointer) std.meta.Child(WriterType) else WriterType;
    if (comptime @hasDecl(ActualType, "flush")) {
        writer.flush() catch {};
    }

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };

    if (line.len > 0) {
        return std.ascii.toLower(line[0]) == 'y';
    }

    return false;
}
