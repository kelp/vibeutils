const std = @import("std");

/// Match a pattern against a string (case-sensitive).
pub fn globMatch(pattern: []const u8, string: []const u8) bool {
    return globMatchImpl(pattern, string, false);
}

/// Match a pattern against a string (case-insensitive).
pub fn globMatchInsensitive(pattern: []const u8, string: []const u8) bool {
    return globMatchImpl(pattern, string, true);
}

fn globMatchImpl(pattern: []const u8, string: []const u8, case_insensitive: bool) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: ?usize = null;

    while (si < string.len or pi < pattern.len) {
        // si and pi are slice indices; their real ceiling is the slice
        // length, not the usize maximum. These hold on every iteration.
        std.debug.assert(si <= string.len);
        std.debug.assert(pi <= pattern.len);

        if (globMatchImpl_step(
            pattern,
            string,
            case_insensitive,
            &pi,
            &si,
            &star_pi,
            &star_si,
        )) continue;

        switch (globMatchImpl_backtrack(string, &pi, &si, &star_pi, &star_si)) {
            .again => continue,
            .fail => return false,
        }
    }

    return true;
}

/// Consume one pattern token, advancing the cursors in place. Returns true
/// when an arm matched and the parent should continue; false when control
/// must fall through to backtracking.
fn globMatchImpl_step(
    pattern: []const u8,
    string: []const u8,
    case_insensitive: bool,
    pi_ptr: *usize, // tiger:allow:usize-arch slice index into pattern
    si_ptr: *usize, // tiger:allow:usize-arch slice index into string
    star_pi_ptr: *?usize, // tiger:allow:usize-arch slice index into pattern
    star_si_ptr: *?usize, // tiger:allow:usize-arch slice index into string
) bool {
    // Cursors are slice indices; their ceiling is the slice length.
    std.debug.assert(pi_ptr.* <= pattern.len);
    std.debug.assert(si_ptr.* <= string.len);

    if (pi_ptr.* >= pattern.len) return false;

    switch (pattern[pi_ptr.*]) {
        '*' => {
            star_pi_ptr.* = pi_ptr.*;
            star_si_ptr.* = si_ptr.*;
            pi_ptr.* += 1;
            return true;
        },
        '?' => {
            if (si_ptr.* < string.len) {
                pi_ptr.* += 1;
                si_ptr.* += 1;
                return true;
            }
        },
        '[' => {
            if (si_ptr.* < string.len) {
                if (matchBracket(pattern, pi_ptr.*, string[si_ptr.*], case_insensitive)) |new_pi| {
                    pi_ptr.* = new_pi;
                    si_ptr.* += 1;
                    return true;
                }
            }
        },
        '\\' => {
            if (pi_ptr.* + 1 < pattern.len) {
                pi_ptr.* += 1;
                if (si_ptr.* < string.len and
                    charEq(pattern[pi_ptr.*], string[si_ptr.*], case_insensitive))
                {
                    pi_ptr.* += 1;
                    si_ptr.* += 1;
                    return true;
                }
            }
        },
        else => {
            if (si_ptr.* < string.len and
                charEq(pattern[pi_ptr.*], string[si_ptr.*], case_insensitive))
            {
                pi_ptr.* += 1;
                si_ptr.* += 1;
                return true;
            }
        },
    }

    return false;
}

const GlobBacktrack = enum { again, fail };

/// Backtrack to the last recorded '*', advancing the star match window.
/// Returns .again when the parent should continue, .fail when no star
/// remains or the string is exhausted.
fn globMatchImpl_backtrack(
    string: []const u8,
    pi_ptr: *usize, // tiger:allow:usize-arch slice index into pattern
    si_ptr: *usize, // tiger:allow:usize-arch slice index into string
    star_pi_ptr: *?usize, // tiger:allow:usize-arch slice index into pattern
    star_si_ptr: *?usize, // tiger:allow:usize-arch slice index into string
) GlobBacktrack {
    if (star_pi_ptr.*) |sp| {
        // star_pi and star_si are written together in the '*' arm, so a
        // non-null star_pi guarantees a non-null star_si here.
        std.debug.assert(star_si_ptr.* != null);
        pi_ptr.* = sp + 1;
        star_si_ptr.* = star_si_ptr.*.? + 1;
        si_ptr.* = star_si_ptr.*.?;
        if (si_ptr.* > string.len) return .fail;
        return .again;
    }

    // No star recorded: nothing left to match against, so report failure.
    std.debug.assert(star_si_ptr.* == null);
    return .fail;
}

fn charEq(a: u8, b: u8, case_insensitive: bool) bool {
    if (case_insensitive) {
        return std.ascii.toLower(a) == std.ascii.toLower(b);
    }
    return a == b;
}

/// Match a bracket expression [abc], [a-z], [!abc].
/// Returns the new pattern index past ']' on match, null otherwise.
fn matchBracket(pattern: []const u8, start: usize, ch: u8, case_insensitive: bool) ?usize {
    // The sole caller passes its current pattern index, reached only under
    // pi < pattern.len and pattern[pi] == '[', so start points at the '['.
    std.debug.assert(start < pattern.len);
    std.debug.assert(pattern[start] == '[');

    var pi = start + 1; // skip '['
    if (pi >= pattern.len) return null;

    var negate = false;
    if (pattern[pi] == '!' or pattern[pi] == '^') {
        negate = true;
        pi += 1;
    }

    var matched = false;
    var first = true;

    while (pi < pattern.len and (first or pattern[pi] != ']')) {
        first = false;
        if (pi + 2 < pattern.len and pattern[pi + 1] == '-' and pattern[pi + 2] != ']') {
            // Range
            const lo = if (case_insensitive) std.ascii.toLower(pattern[pi]) else pattern[pi];
            const hi = if (case_insensitive) std.ascii.toLower(pattern[pi + 2]) else pattern[pi + 2];
            const test_ch = if (case_insensitive) std.ascii.toLower(ch) else ch;
            if (test_ch >= lo and test_ch <= hi) {
                matched = true;
            }
            pi += 3;
        } else {
            if (charEq(pattern[pi], ch, case_insensitive)) {
                matched = true;
            }
            pi += 1;
        }
    }

    if (pi < pattern.len and pattern[pi] == ']') {
        pi += 1; // skip ']'
        if (negate) matched = !matched;
        if (matched) return pi;
    }

    return null;
}

const testing = std.testing;

test "glob: basic star" {
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("*.txt", "hello.txt"));
    try testing.expect(!globMatch("*.txt", "hello.md"));
    try testing.expect(globMatch("hello*", "helloworld"));
    try testing.expect(globMatch("he*ld", "helloworld"));
    try testing.expect(!globMatch("he*ld", "helloworlds"));
}

test "glob: question mark" {
    try testing.expect(globMatch("?.txt", "a.txt"));
    try testing.expect(!globMatch("?.txt", "ab.txt"));
    try testing.expect(globMatch("a?c", "abc"));
    try testing.expect(!globMatch("a?c", "ac"));
}

test "glob: bracket expression" {
    try testing.expect(globMatch("[abc].txt", "a.txt"));
    try testing.expect(globMatch("[abc].txt", "b.txt"));
    try testing.expect(!globMatch("[abc].txt", "d.txt"));
    try testing.expect(globMatch("[a-z].txt", "m.txt"));
    try testing.expect(!globMatch("[a-z].txt", "M.txt"));
    try testing.expect(globMatch("[!abc].txt", "d.txt"));
    try testing.expect(!globMatch("[!abc].txt", "a.txt"));
}

test "glob: escape" {
    try testing.expect(globMatch("\\*.txt", "*.txt"));
    try testing.expect(!globMatch("\\*.txt", "a.txt"));
}

test "glob: empty pattern and string" {
    try testing.expect(globMatch("", ""));
    try testing.expect(!globMatch("", "a"));
    try testing.expect(!globMatch("a", ""));
    try testing.expect(globMatch("*", ""));
}

test "glob: case insensitive" {
    try testing.expect(globMatchInsensitive("*.TXT", "hello.txt"));
    try testing.expect(globMatchInsensitive("*.txt", "hello.TXT"));
    try testing.expect(globMatchInsensitive("Hello*", "helloworld"));
    try testing.expect(globMatchInsensitive("[A-Z]", "a"));
}

test "glob: complex patterns" {
    try testing.expect(globMatch("*.[ch]", "main.c"));
    try testing.expect(globMatch("*.[ch]", "main.h"));
    try testing.expect(!globMatch("*.[ch]", "main.o"));
    try testing.expect(globMatch("*.tar.gz", "archive.tar.gz"));
}
