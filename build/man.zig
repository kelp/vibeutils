//! Man-page installation for the default install step.
//!
//! `zig build --prefix <p>` copies `man/man1/<name>.1` to
//! `<p>/share/man/man1/<name>.1` (the FHS layout) for every utility
//! registered in `utils.zig`, alongside the binaries under `bin/`.

const std = @import("std");
const utils = @import("utils.zig");

/// Attach every utility's man page to the default install step.
/// A missing page aborts configuration loudly: shipping a utility
/// without its documentation is a packaging bug, not a soft skip.
pub fn addInstall(b: *std.Build) void {
    std.debug.assert(utils.utilities.len > 0);

    var installed_count: u32 = 0;
    for (utils.utilities) |util| {
        const src_path = b.fmt("man/man1/{s}.1", .{util.name});
        const dest_path = b.fmt("share/man/man1/{s}.1", .{util.name});

        // The build runner's cwd is the build root at configure time
        // (utils.zig relies on the same invariant), so a relative
        // access() check here sees exactly what installFile will copy.
        std.Io.Dir.cwd().access(b.graph.io, src_path, .{}) catch {
            std.log.err("man page not found: {s} (required by utility '{s}')", .{
                src_path, util.name,
            });
            std.process.exit(1);
        };

        b.installFile(src_path, dest_path);
        installed_count += 1;
    }

    std.debug.assert(installed_count == utils.utilities.len);
}
