#!/usr/bin/env bash
# zig-knowledge-audit.sh - Validate Zig breaking change claims
#
# This script tests the claims in docs/ZIG_BREAKING_CHANGES.md by
# compiling small Zig code snippets ("probes"). Each probe checks
# whether a specific old API pattern still compiles.
#
# Usage:
#   ./scripts/zig-knowledge-audit.sh
#
# Interpreting results:
#   PASS - The probe result matched expectations. If the expected
#          result was "fail", the old API really is broken. If
#          "pass", the new API really works.
#   FAIL - Surprise! The result did not match expectations. This
#          means docs/ZIG_BREAKING_CHANGES.md has a wrong claim
#          and needs updating.
#
# Exit code:
#   0 - All probes matched expectations
#   1 - One or more surprises found (docs need updating)

set -euo pipefail

# Color support (respect NO_COLOR convention)
if [[ -z "${NO_COLOR:-}" ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    GREEN=''
    RED=''
    BOLD=''
    DIM=''
    RESET=''
fi

PASS_COUNT=0
FAIL_COUNT=0

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

probe() {
    local name="$1"
    local description="$2"
    local expected="$3"
    local code="$4"

    local file="$TMPDIR/${name}.zig"
    echo "$code" > "$file"

    if zig test "$file" --color off 2>/dev/null 1>/dev/null; then
        actual="pass"
    else
        actual="fail"
    fi

    if [[ "$actual" == "$expected" ]]; then
        printf "  ${GREEN}PASS${RESET}  %-35s %s\n" \
            "$name" "$description"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf "  ${RED}FAIL${RESET}  %-35s %s ${DIM}(expected %s, got %s)${RESET}\n" \
            "$name" "$description" "$expected" "$actual"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Header
echo ""
printf "${BOLD}Zig Knowledge Audit${RESET}\n"
printf "${DIM}Testing breaking change claims against zig $(zig version)${RESET}\n"

# ── I/O (Writergate) ──

printf "\n${BOLD}── I/O (Writergate) ──${RESET}\n"

probe "old_getStdOut" \
    "std.io.getStdOut() removed" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    const stdout = std.io.getStdOut().writer();
    _ = stdout;
}
ZIGEOF
)"

probe "old_getStdErr" \
    "std.io.getStdErr() removed" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    const stderr = std.io.getStdErr().writer();
    _ = stderr;
}
ZIGEOF
)"

probe "new_buffered_writer" \
    "Buffered writer pattern works" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.writeAll("hello\n");
    stdout.flush() catch {};
}
ZIGEOF
)"

probe "old_BufferedWriter" \
    "std.io.BufferedWriter removed" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    _ = std.io.BufferedWriter;
}
ZIGEOF
)"

# ── Collections ──

printf "\n${BOLD}── Collections ──${RESET}\n"

probe "old_arraylist_no_allocator" \
    "ArrayListUnmanaged without allocator args" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var list = std.ArrayListUnmanaged(u32){};
    defer list.deinit();
    list.append(42) catch {};
}
ZIGEOF
)"

probe "new_arraylist_unmanaged" \
    "ArrayListUnmanaged preferred pattern" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var list = std.ArrayListUnmanaged(u32){};
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 42);
}
ZIGEOF
)"

probe "old_arraylist_managed_init" \
    "ArrayList.init(allocator) removed" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var list = std.ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
}
ZIGEOF
)"

probe "old_BoundedArray" \
    "std.BoundedArray removed" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var arr = std.BoundedArray(u8, 64){};
    _ = &arr;
}
ZIGEOF
)"

probe "new_BoundedArray_replacement" \
    "ArrayListUnmanaged.initBuffer replacement" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var buffer: [64]u8 = undefined;
    var list = std.ArrayListUnmanaged(u8).initBuffer(&buffer);
    list.appendAssumeCapacity(42);
}
ZIGEOF
)"

# ── Language Features ──

printf "\n${BOLD}── Language Features ──${RESET}\n"

probe "old_usingnamespace" \
    "usingnamespace removed" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
const Mixin = struct {
    pub fn hello() void {}
};
const Foo = struct {
    pub usingnamespace Mixin;
};
test "probe" {
    Foo.hello();
}
ZIGEOF
)"

probe "old_async_await" \
    "async/await removed" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
fn asyncFn() !void {}
test "probe" {
    _ = async asyncFn();
}
ZIGEOF
)"

probe "old_division_signed" \
    "Runtime signed division with / operator" \
    "fail" \
    "$(cat <<'ZIGEOF'
test "probe" {
    var a: i32 = 10;
    var b: i32 = 3;
    _ = &a;
    _ = &b;
    const result = a / b;
    _ = result;
}
ZIGEOF
)"

probe "new_divTrunc" \
    "@divTrunc for runtime signed division" \
    "pass" \
    "$(cat <<'ZIGEOF'
test "probe" {
    var a: i32 = 10;
    var b: i32 = 3;
    _ = &a;
    _ = &b;
    const result = @divTrunc(a, b);
    _ = result;
}
ZIGEOF
)"

# ── Testing ──

printf "\n${BOLD}── Testing ──${RESET}\n"

probe "expectEqualStrings" \
    "expectEqualStrings still exists" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    try std.testing.expectEqualStrings("hello", "hello");
}
ZIGEOF
)"

probe "expectEqualSlices" \
    "expectEqualSlices works" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    try std.testing.expectEqualSlices(u8, "hello", "hello");
}
ZIGEOF
)"

# ── String Operations ──

printf "\n${BOLD}── String Operations ──${RESET}\n"

probe "old_mem_tokenize" \
    "std.mem.tokenize old name" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var it = std.mem.tokenize(u8, "hello world", " ");
    _ = it.next();
}
ZIGEOF
)"

probe "new_mem_tokenizeAny" \
    "std.mem.tokenizeAny replacement" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var it = std.mem.tokenizeAny(u8, "hello world", " ");
    _ = it.next();
}
ZIGEOF
)"

# ── Process ──

printf "\n${BOLD}── Process ──${RESET}\n"

probe "old_process_args" \
    "std.process.args() iterator" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var args = std.process.args();
    _ = args.next();
}
ZIGEOF
)"

probe "new_process_argsAlloc" \
    "std.process.argsAlloc pattern" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    const args = try std.process.argsAlloc(std.testing.allocator);
    defer std.process.argsFree(std.testing.allocator, args);
    try std.testing.expect(args.len > 0);
}
ZIGEOF
)"

# ── JSON ──

printf "\n${BOLD}── JSON ──${RESET}\n"

probe "old_json_parser" \
    "std.json.Parser old API" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var parser = std.json.Parser.init(std.testing.allocator, false);
    _ = &parser;
}
ZIGEOF
)"

probe "new_json_parseFromSlice" \
    "std.json.parseFromSlice new API" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
const T = struct { x: i32 };
test "probe" {
    const input = "{\"x\": 42}";
    const parsed = try std.json.parseFromSlice(T, std.testing.allocator, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 42), parsed.value.x);
}
ZIGEOF
)"

# ── Format Strings ──

printf "\n${BOLD}── Format Strings ──${RESET}\n"

probe "old_format_empty_braces" \
    "Empty {} format specifier for custom types" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
const Foo = struct {
    x: i32,
    pub fn format(self: Foo, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d}", .{self.x});
    }
};
test "probe" {
    const foo = Foo{ .x = 42 };
    var buf: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&buf, "{}", .{foo});
}
ZIGEOF
)"

probe "new_format_method" \
    "New format method signature with {f}" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
const Foo = struct {
    x: i32,
    pub fn format(self: Foo, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}", .{self.x});
    }
};
test "probe" {
    const foo = Foo{ .x = 42 };
    var buf: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&buf, "{f}", .{foo});
}
ZIGEOF
)"

# ── New Features ──

printf "\n${BOLD}── New Features ──${RESET}\n"

probe "new_destructuring" \
    "Destructuring assignments work" \
    "pass" \
    "$(cat <<'ZIGEOF'
test "probe" {
    const tuple = .{ @as(i32, 1), @as(i32, 2), @as(i32, 3) };
    const x, const y, const z = tuple;
    _ = x;
    _ = y;
    _ = z;
}
ZIGEOF
)"

probe "new_multi_for" \
    "Multi-object for loops work" \
    "pass" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };
    var sum: i32 = 0;
    for (a, b) |x, y| {
        sum += x + y;
    }
    try std.testing.expectEqual(@as(i32, 21), sum);
}
ZIGEOF
)"

probe "old_DoublyLinkedList" \
    "Generic DoublyLinkedList removed" \
    "fail" \
    "$(cat <<'ZIGEOF'
const std = @import("std");
test "probe" {
    var list = std.DoublyLinkedList(u32){};
    _ = &list;
}
ZIGEOF
)"

# Summary
total=$((PASS_COUNT + FAIL_COUNT))
echo ""
printf "${BOLD}Summary${RESET}: %d probes, " "$total"
printf "${GREEN}%d confirmed${RESET}, " "$PASS_COUNT"
if [[ $FAIL_COUNT -gt 0 ]]; then
    printf "${RED}%d surprises${RESET}" "$FAIL_COUNT"
else
    printf "0 surprises"
fi
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo ""
    echo "Surprises indicate docs/ZIG_BREAKING_CHANGES.md needs updating."
    exit 1
fi
