const std = @import("std");
const build_mod = @import("../build.zig");

// This script introspects build.zig to discover all utility executables
// It's used by GitHub Actions to dynamically determine what utilities to test

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a mock builder to introspect build.zig
    const builder = try std.Build.create(
        allocator,
        ".",
        ".cache/zig",
        .{ .path = ".", .handle = std.fs.cwd() },
        .{ .path = ".cache/zig", .handle = std.fs.cwd() },
        .{},
    );
    defer builder.destroy();

    // Call the build function to register all steps
    build_mod.build(builder);

    // Collect all executable names
    var utilities = std.ArrayList([]const u8).init(allocator);
    defer utilities.deinit();

    // Iterate through all top-level steps
    var it = builder.top_level_steps.iterator();
    while (it.next()) |entry| {
        const step = entry.value_ptr.*;
        
        // Check if this is an InstallArtifact step
        if (step.id == .install_artifact) {
            const install_artifact = @fieldParentPtr(std.Build.Step.InstallArtifact, "step", step);
            
            // Check if the artifact is an executable
            if (install_artifact.artifact.kind == .exe) {
                const name = install_artifact.artifact.name;
                
                // Skip test executables and other non-utilities
                if (!std.mem.endsWith(u8, name, "_test") and
                    !std.mem.endsWith(u8, name, "_fuzz") and
                    !std.mem.eql(u8, name, "build_runner")) {
                    try utilities.append(name);
                }
            }
        }
    }

    // Sort the utilities
    std.mem.sort([]const u8, utilities.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Output as JSON for GitHub Actions
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("[");
    for (utilities.items, 0..) |utility, i| {
        if (i > 0) try stdout.writeAll(",");
        try stdout.print("\"{s}\"", .{utility});
    }
    try stdout.writeAll("]\n");
}