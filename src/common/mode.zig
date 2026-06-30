//! Shared file permission mode parsing for vibeutils.
//!
//! Provides octal and symbolic mode parsing compatible with chmod/mkdir.
//! The symbolic parser supports the full POSIX/GNU chmod specification:
//! who-specifiers (u/g/o/a), operators (+/-/=), permission bits (r/w/x/X/s/t),
//! and permission copying (g=u, o+g, etc.).

const std = @import("std");
const testing = std.testing;

// ============================================================================
// Public API
// ============================================================================

/// Errors returned by mode parsing functions.
pub const ModeError = error{
    /// Invalid symbolic mode string (bad who-specifier, operator, or perm char).
    InvalidMode,
    /// Invalid octal mode (non-octal digits, value > 0o7777, or wrong length).
    InvalidOctalMode,
};

/// Context supplied to the symbolic mode parser.
pub const ModeContext = struct {
    /// True when the target is a directory; enables the `X` permission behaviour.
    is_directory: bool = false,
    /// Process umask. Applied to '+' and '=' operations when no explicit
    /// who-specifier is given (e.g. `+x`, `=rw`). Per POSIX §4.7, the umask
    /// limits which bits are set; '-' operations are never constrained.
    /// Callers should read the process umask via `umask(0)` + restore.
    umask: u32 = 0,
};

/// Unix file permission bits, including setuid, setgid, and sticky.
pub const Mode = struct {
    user: u3,
    group: u3,
    other: u3,
    setuid: bool = false,
    setgid: bool = false,
    sticky: bool = false,

    /// Convert to a 12-bit octal value (setuid=0o4000, setgid=0o2000, sticky=0o1000).
    pub fn toOctal(self: Mode) u32 {
        var result = (@as(u32, self.user) << 6) |
            (@as(u32, self.group) << 3) |
            @as(u32, self.other);
        if (self.setuid) result |= 0o4000;
        if (self.setgid) result |= 0o2000;
        if (self.sticky) result |= 0o1000;
        // Postcondition: u3 rwx fields (max 0o777) plus the three special bits
        // (0o7000) can never exceed the 12-bit permission range, even though
        // the u32 return type could hold far larger values.
        std.debug.assert(result <= 0o7777);
        return result;
    }

    /// Create from a 12-bit octal value.
    pub fn fromOctal(octal: u32) Mode {
        return Mode{
            .user = @truncate((octal >> 6) & 0x7),
            .group = @truncate((octal >> 3) & 0x7),
            .other = @truncate(octal & 0x7),
            .setuid = (octal & 0o4000) != 0,
            .setgid = (octal & 0o2000) != 0,
            .sticky = (octal & 0o1000) != 0,
        };
    }
};

/// Parse a 1–4 digit octal mode string (value 0o0000–0o7777).
///
/// Returns the raw octal value on success, or `ModeError.InvalidOctalMode` when:
/// - the string is empty or longer than 4 characters,
/// - any character is outside '0'–'7', or
/// - the parsed value exceeds 0o7777.
pub fn parseOctal(str: []const u8) ModeError!u32 {
    if (str.len == 0 or str.len > 4) return ModeError.InvalidOctalMode;
    for (str) |c| {
        if (c < '0' or c > '7') return ModeError.InvalidOctalMode;
    }
    var octal: u32 = 0;
    for (str) |c| {
        octal = octal * 8 + (c - '0');
    }
    if (octal > 0o7777) return ModeError.InvalidOctalMode;
    return octal;
}

/// Parse a symbolic mode string, applying comma-separated clauses to `base_mode`.
///
/// `base_mode` is the current file mode in 12-bit octal form (e.g. 0o755).
/// It is used both as the starting state for the result and to determine whether
/// the `X` pseudo-permission should activate (non-directory files that already
/// have at least one execute bit set).
///
/// `context.is_directory` enables `X` for directory targets unconditionally.
pub fn parseSymbolic(
    mode_str: []const u8,
    base_mode: u32,
    context: ModeContext,
) ModeError!Mode {
    var result = Mode.fromOctal(base_mode);
    var iter = std.mem.splitScalar(u8, mode_str, ',');
    while (iter.next()) |raw_clause| {
        const clause = std.mem.trim(u8, raw_clause, " ");
        try applyClause(&result, clause, base_mode, context);
    }
    return result;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Result of scanning the who-specifier prefix of a clause.
const ScanWhoResult = struct {
    /// Index of the first character after the who-specifier (the operator).
    cursor: usize, // tiger:allow:usize-arch slice index into clause
    /// Who bitmask: bit0=user, bit1=group, bit2=other. Always 1..=7.
    who: u8,
    /// True when at least one explicit u/g/o/a specifier was present.
    who_explicit: bool,
};

/// Result of scanning the permission characters of a clause.
const ScanPermsResult = union(enum) {
    /// Accumulated permission bits: 4=r 2=w 1=x 8=s 16=t.
    perms: u8,
    /// A permission-copy in perm position was applied; clause is done.
    copy_done,
};

/// Apply one symbolic mode clause (e.g. "u+rx", "go=r", "a-s", "g=u") in-place.
fn applyClause(
    mode: *Mode,
    clause: []const u8,
    base_mode: u32,
    context: ModeContext,
) ModeError!void {
    if (clause.len < 2) return ModeError.InvalidMode;

    const scan = try applyClause_scanWho(clause);
    var i = scan.cursor;
    const who = scan.who;
    const who_explicit = scan.who_explicit;
    // scanWho guarantees a valid, non-empty who bitmask (1..7); re-assert at the
    // consumer to pair the property across the producer/consumer boundary.
    std.debug.assert(who != 0);
    std.debug.assert(who <= 7);

    if (i >= clause.len) return ModeError.InvalidMode;
    const op = clause[i];
    i += 1;
    // scanWho only stops at an operator char, so clause[i] here is one of these.
    // Disjunction: cannot split into separate asserts (that would require all
    // three at once and always fire).
    std.debug.assert(op == '+' or op == '-' or op == '='); // tiger:allow:compound-assert

    // --- permission copying: "g=u", "o+g", "u-o" ---
    // Detected when the remaining text is exactly one u/g/o character.
    if (i < clause.len and clause.len == i + 1) {
        const ch = clause[i];
        if (ch == 'u' or ch == 'g' or ch == 'o') {
            applyCopy(mode, who, ch, op);
            return;
        }
    }

    const perms = switch (try applyClause_scanPerms(mode, clause, i, who, op, base_mode, context)) {
        .copy_done => return,
        .perms => |p| p,
    };

    // POSIX §4.7: when no who-specifier was given and the operator adds or
    // sets permissions ('+' or '='), apply the complement of the process
    // umask per-class. For '-' (removal), the umask does not constrain
    // which bits are cleared.
    if (!who_explicit and op != '-' and context.umask != 0) {
        applyClause_applyWithUmask(mode, op, perms, context);
    } else {
        applyPerms(mode, who, op, perms);
    }
}

/// Scan the leading who-specifier of a clause, stopping at the operator.
/// Returns the cursor at the operator, the who-bitmask (defaulting to 'a'),
/// and whether an explicit specifier was present.
fn applyClause_scanWho(clause: []const u8) ModeError!ScanWhoResult {
    std.debug.assert(clause.len >= 2);

    var i: usize = 0;
    var who: u8 = 0; // bitmask: bit0=user, bit1=group, bit2=other
    var who_explicit = false;

    while (i < clause.len) : (i += 1) {
        switch (clause[i]) {
            'u' => {
                who |= 1;
                who_explicit = true;
            },
            'g' => {
                who |= 2;
                who_explicit = true;
            },
            'o' => {
                who |= 4;
                who_explicit = true;
            },
            'a' => {
                who |= 7;
                who_explicit = true;
            },
            '+', '-', '=' => break,
            else => return ModeError.InvalidMode,
        }
    }
    if (who == 0) who = 7; // no specifier → 'a' (all)

    std.debug.assert(who != 0);
    std.debug.assert(who <= 7);
    // Postcondition: the loop guard is `i < clause.len`, so on every exit the
    // returned cursor is at most clause.len (pairs with scanPerms's precondition).
    std.debug.assert(i <= clause.len);
    return .{ .cursor = i, .who = who, .who_explicit = who_explicit };
}

/// Scan permission characters starting at `cursor`, accumulating the perm
/// bitmask. A permission-copy in perm position is applied here and reported
/// via `.copy_done`; otherwise the accumulated bits are returned via `.perms`.
fn applyClause_scanPerms(
    mode: *Mode,
    clause: []const u8,
    cursor: usize, // tiger:allow:usize-arch slice index into clause
    who: u8,
    op: u8,
    base_mode: u32,
    context: ModeContext,
) ModeError!ScanPermsResult {
    std.debug.assert(cursor <= clause.len);
    std.debug.assert(who != 0);
    std.debug.assert(who <= 7);

    var i = cursor;
    var perms: u8 = 0; // bits: 4=r 2=w 1=x 8=s 16=t
    while (i < clause.len) : (i += 1) {
        switch (clause[i]) {
            'r' => perms |= 4,
            'w' => perms |= 2,
            'x' => perms |= 1,
            's' => perms |= 8,
            't' => perms |= 16,
            'X' => {
                // POSIX: X sets execute only for directories or for files that
                // already have at least one execute bit set.
                if (context.is_directory or (base_mode & 0o111) != 0) {
                    perms |= 1;
                }
            },
            // Permission copying in perm position: "a+u", "go+g"
            'u', 'g', 'o' => {
                if (clause.len == i + 1) {
                    applyCopy(mode, who, clause[i], op);
                    return .copy_done;
                }
                return ModeError.InvalidMode;
            },
            else => return ModeError.InvalidMode,
        }
    }

    std.debug.assert((perms & ~@as(u8, 0b11111)) == 0);
    return .{ .perms = perms };
}

/// Apply `perms` for '+'/'=' with the process umask masking the rwx bits
/// per-class. Special bits (s/t) pass through unmasked. Only reached when no
/// explicit who-specifier was given and the operator is not '-'.
fn applyClause_applyWithUmask(mode: *Mode, op: u8, perms: u8, context: ModeContext) void {
    // Negative space: this helper is never reached for '-' or a zero umask,
    // matching the parent's `op != '-' and context.umask != 0` branch guard.
    std.debug.assert(op != '-');
    std.debug.assert(context.umask != 0);
    // Positive-space companion: the parent excludes '-' from a proven '+/-/='
    // op, leaving exactly '+' or '='. Disjunction: not splittable.
    std.debug.assert(op == '+' or op == '='); // tiger:allow:compound-assert

    const u_mask: u3 = @truncate((context.umask >> 6) & 7);
    const g_mask: u3 = @truncate((context.umask >> 3) & 7);
    const o_mask: u3 = @truncate(context.umask & 7);
    // Umask constrains only rwx bits; special bits (s/t) pass through.
    const basic: u3 = @truncate(perms & 7);
    const special: u8 = perms & ~@as(u8, 7);
    // Apply per-class with masked basic bits, then special bits globally.
    applyPerms(mode, 1, op, (basic & ~u_mask) | special);
    applyPerms(mode, 2, op, (basic & ~g_mask) | special);
    applyPerms(mode, 4, op, (basic & ~o_mask) | special);
}

/// Apply permission copying between who classes.
fn applyCopy(mode: *Mode, who: u8, copy_from: u8, op: u8) void {
    // who originates from scanWho (1..7); 0 would make this a silent no-op.
    std.debug.assert(who != 0);
    std.debug.assert(who <= 7);
    // op flows unchanged from applyClause's proven '+'/'-'/'=' value.
    // Disjunction: not splittable.
    std.debug.assert(op == '+' or op == '-' or op == '='); // tiger:allow:compound-assert

    const src: u3 = switch (copy_from) {
        'u' => mode.user,
        'g' => mode.group,
        'o' => mode.other,
        else => return,
    };
    if (who & 1 != 0) applyBasic(&mode.user, op, src);
    if (who & 2 != 0) applyBasic(&mode.group, op, src);
    if (who & 4 != 0) applyBasic(&mode.other, op, src);
}

/// Apply a basic rwx bit-mask to one permission field (user/group/other).
inline fn applyBasic(field: *u3, op: u8, bits: u3) void {
    // op traces back to applyClause's proven '+'/'-'/'=' value; the else->{}
    // branch below would silently no-op any other char. Disjunction: not splittable.
    std.debug.assert(op == '+' or op == '-' or op == '='); // tiger:allow:compound-assert
    switch (op) {
        '+' => field.* |= bits,
        '-' => field.* &= ~bits,
        '=' => field.* = bits,
        else => {},
    }
}

/// Apply a full permission mask (rwx + special bits) to the mode.
fn applyPerms(mode: *Mode, who: u8, op: u8, perms: u8) void {
    // who comes from scanWho (1..7) or a literal 1/2/4 from the umask helper;
    // only bits 0-2 are inspected, so any higher bit is out of contract.
    std.debug.assert(who != 0);
    std.debug.assert(who <= 7);
    // op is the proven '+'/'-'/'=' value forwarded from applyClause.
    // Disjunction: not splittable.
    std.debug.assert(op == '+' or op == '-' or op == '='); // tiger:allow:compound-assert

    const basic: u3 = @truncate(perms & 7);

    if (who & 1 != 0) applyBasic(&mode.user, op, basic);
    if (who & 2 != 0) applyBasic(&mode.group, op, basic);
    if (who & 4 != 0) applyBasic(&mode.other, op, basic);

    // setuid ('s' with user who) / setgid ('s' with group who)
    if (perms & 8 != 0) {
        if (who & 1 != 0) {
            switch (op) {
                '+', '=' => mode.setuid = true,
                '-' => mode.setuid = false,
                else => {},
            }
        }
        if (who & 2 != 0) {
            switch (op) {
                '+', '=' => mode.setgid = true,
                '-' => mode.setgid = false,
                else => {},
            }
        }
    }

    // sticky ('t') — who-bits are ignored per POSIX
    if (perms & 16 != 0) {
        switch (op) {
            '+', '=' => mode.sticky = true,
            '-' => mode.sticky = false,
            else => {},
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

// --- Mode struct ---

test "mode: fromOctal / toOctal roundtrip" {
    const cases = [_]u32{
        0o000, 0o644, 0o755, 0o777, 0o123, 0o456, 0o4755, 0o2644, 0o1777, 0o7777,
    };
    for (cases) |original| {
        const m = Mode.fromOctal(original);
        try testing.expectEqual(original, m.toOctal());
    }
}

test "mode: fromOctal parses special bits" {
    const m4 = Mode.fromOctal(0o4755);
    try testing.expect(m4.setuid);
    try testing.expect(!m4.setgid);
    try testing.expect(!m4.sticky);

    const m2 = Mode.fromOctal(0o2644);
    try testing.expect(!m2.setuid);
    try testing.expect(m2.setgid);
    try testing.expect(!m2.sticky);

    const m1 = Mode.fromOctal(0o1777);
    try testing.expect(!m1.setuid);
    try testing.expect(!m1.setgid);
    try testing.expect(m1.sticky);
}

test "mode: toOctal encodes rwx fields correctly" {
    const m = Mode{ .user = 7, .group = 5, .other = 5 };
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());

    const m2 = Mode{ .user = 6, .group = 4, .other = 4 };
    try testing.expectEqual(@as(u32, 0o644), m2.toOctal());
}

// --- parseOctal ---

test "parseOctal: valid 1-4 digit modes" {
    try testing.expectEqual(@as(u32, 0o7), try parseOctal("7"));
    try testing.expectEqual(@as(u32, 0o75), try parseOctal("75"));
    try testing.expectEqual(@as(u32, 0o755), try parseOctal("755"));
    try testing.expectEqual(@as(u32, 0o644), try parseOctal("644"));
    try testing.expectEqual(@as(u32, 0o777), try parseOctal("777"));
    try testing.expectEqual(@as(u32, 0o000), try parseOctal("000"));
    try testing.expectEqual(@as(u32, 0o0644), try parseOctal("0644"));
    try testing.expectEqual(@as(u32, 0o4755), try parseOctal("4755"));
    try testing.expectEqual(@as(u32, 0o7777), try parseOctal("7777"));
}

test "parseOctal: rejects empty string" {
    try testing.expectError(ModeError.InvalidOctalMode, parseOctal(""));
}

test "parseOctal: rejects strings longer than 4 chars" {
    try testing.expectError(ModeError.InvalidOctalMode, parseOctal("75555"));
    try testing.expectError(ModeError.InvalidOctalMode, parseOctal("12345"));
}

test "parseOctal: rejects non-octal digits" {
    try testing.expectError(ModeError.InvalidOctalMode, parseOctal("888"));
    try testing.expectError(ModeError.InvalidOctalMode, parseOctal("999"));
    try testing.expectError(ModeError.InvalidOctalMode, parseOctal("8"));
    try testing.expectError(ModeError.InvalidOctalMode, parseOctal("9"));
}

test "parseOctal: rejects alphabetic strings" {
    try testing.expectError(ModeError.InvalidOctalMode, parseOctal("abc"));
    try testing.expectError(ModeError.InvalidOctalMode, parseOctal("rwx"));
}

// --- parseSymbolic: basic operators ---

test "parseSymbolic: u+r adds read for user" {
    const m = try parseSymbolic("u+r", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o400), m.toOctal());
}

test "parseSymbolic: g+w adds write for group" {
    const m = try parseSymbolic("g+w", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o020), m.toOctal());
}

test "parseSymbolic: o+x adds execute for other" {
    const m = try parseSymbolic("o+x", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o001), m.toOctal());
}

test "parseSymbolic: a+rwx sets all permissions" {
    const m = try parseSymbolic("a+rwx", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o777), m.toOctal());
}

test "parseSymbolic: u-r removes read from user" {
    const m = try parseSymbolic("u-r", 0o777, .{});
    try testing.expectEqual(@as(u32, 0o377), m.toOctal());
}

test "parseSymbolic: go-w removes write from group and other" {
    const m = try parseSymbolic("go-w", 0o777, .{});
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: u=rwx sets user to rwx exactly" {
    const m = try parseSymbolic("u=rwx", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o700), m.toOctal());
}

test "parseSymbolic: go=rx sets group and other to rx" {
    const m = try parseSymbolic("go=rx", 0o777, .{});
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: a= clears all permissions" {
    const m = try parseSymbolic("a=", 0o777, .{});
    try testing.expectEqual(@as(u32, 0o000), m.toOctal());
}

// --- parseSymbolic: comma-separated clauses ---

test "parseSymbolic: u=rwx,go=rx produces 0o755" {
    const m = try parseSymbolic("u=rwx,go=rx", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: a+rx from base 0 produces 0o555" {
    const m = try parseSymbolic("a+rx", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o555), m.toOctal());
}

test "parseSymbolic: u+x,g+x,o+x each add execute" {
    const m = try parseSymbolic("u+x,g+x,o+x", 0o444, .{});
    try testing.expectEqual(@as(u32, 0o555), m.toOctal());
}

// --- parseSymbolic: default who (no specifier → all) ---

test "parseSymbolic: +x with no who adds execute for all" {
    const m = try parseSymbolic("+x", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o111), m.toOctal());
}

test "parseSymbolic: -r with no who removes read from all" {
    const m = try parseSymbolic("-r", 0o777, .{});
    try testing.expectEqual(@as(u32, 0o333), m.toOctal());
}

test "parseSymbolic: =rw with no who sets rw for all" {
    const m = try parseSymbolic("=rw", 0o755, .{});
    try testing.expectEqual(@as(u32, 0o666), m.toOctal());
}

// --- parseSymbolic: special bits ---

test "parseSymbolic: u+s sets setuid" {
    const m = try parseSymbolic("u+s", 0o755, .{});
    try testing.expect(m.setuid);
    try testing.expect(!m.setgid);
    try testing.expectEqual(@as(u32, 0o4755), m.toOctal());
}

test "parseSymbolic: g+s sets setgid" {
    const m = try parseSymbolic("g+s", 0o755, .{});
    try testing.expect(!m.setuid);
    try testing.expect(m.setgid);
    try testing.expectEqual(@as(u32, 0o2755), m.toOctal());
}

test "parseSymbolic: u+s,g+s sets both setuid and setgid" {
    const m = try parseSymbolic("u+s,g+s", 0o755, .{});
    try testing.expect(m.setuid);
    try testing.expect(m.setgid);
    try testing.expectEqual(@as(u32, 0o6755), m.toOctal());
}

test "parseSymbolic: a+t sets sticky bit" {
    const m = try parseSymbolic("a+t", 0o755, .{});
    try testing.expect(m.sticky);
    try testing.expectEqual(@as(u32, 0o1755), m.toOctal());
}

test "parseSymbolic: o+t sets sticky (who ignored per POSIX)" {
    const m = try parseSymbolic("o+t", 0o755, .{});
    try testing.expect(m.sticky);
}

test "parseSymbolic: u-s clears setuid" {
    const m = try parseSymbolic("u-s", 0o4755, .{});
    try testing.expect(!m.setuid);
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: g-s clears setgid" {
    const m = try parseSymbolic("g-s", 0o2755, .{});
    try testing.expect(!m.setgid);
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: a-t clears sticky" {
    const m = try parseSymbolic("a-t", 0o1755, .{});
    try testing.expect(!m.sticky);
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

// --- parseSymbolic: X (conditional execute) ---

test "parseSymbolic: a+X on non-directory with no execute bit → no-op" {
    const m = try parseSymbolic("a+X", 0o644, .{ .is_directory = false });
    try testing.expectEqual(@as(u32, 0o644), m.toOctal());
}

test "parseSymbolic: a+X on non-directory with execute bit → adds execute" {
    const m = try parseSymbolic("a+X", 0o744, .{ .is_directory = false });
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: a+X on directory → always adds execute" {
    const m = try parseSymbolic("a+X", 0o644, .{ .is_directory = true });
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: u+X on directory → adds user execute only" {
    const m = try parseSymbolic("u+X", 0o644, .{ .is_directory = true });
    try testing.expectEqual(@as(u32, 0o744), m.toOctal());
}

// --- parseSymbolic: permission copying ---

test "parseSymbolic: g=u copies user perms to group" {
    // user=rwx (7), group=r (4), other=r (4)
    const m = try parseSymbolic("g=u", 0o744, .{});
    // group should now equal user (7)
    try testing.expectEqual(@as(u32, 0o774), m.toOctal());
}

test "parseSymbolic: o+g copies group perms added to other" {
    // group=r-x (5), other=--- (0)
    const m = try parseSymbolic("o+g", 0o750, .{});
    // other should get group bits added: 0o750 | 0o005 = 0o755
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: u-o removes other bits from user" {
    // user=rwx (7), other=r (4)
    const m = try parseSymbolic("u-o", 0o744, .{});
    // user & ~other = 7 & ~4 = 7 & 3 = 3 = 011 = -wx
    try testing.expectEqual(@as(u32, 0o344), m.toOctal());
}

// --- parseSymbolic: error cases ---

test "parseSymbolic: rejects empty clause" {
    // Empty clause between commas
    try testing.expectError(ModeError.InvalidMode, parseSymbolic(",a+x", 0, .{}));
}

test "parseSymbolic: rejects invalid who character" {
    try testing.expectError(ModeError.InvalidMode, parseSymbolic("z+x", 0, .{}));
}

test "parseSymbolic: rejects missing operator" {
    try testing.expectError(ModeError.InvalidMode, parseSymbolic("urwx", 0, .{}));
}

test "parseSymbolic: rejects invalid permission character" {
    try testing.expectError(ModeError.InvalidMode, parseSymbolic("u+q", 0, .{}));
}

test "parseSymbolic: rejects purely alphabetic non-mode string" {
    try testing.expectError(ModeError.InvalidMode, parseSymbolic("abc", 0, .{}));
}

test "parseSymbolic: rejects numeric string as invalid" {
    // Numeric strings should go through parseOctal, not parseSymbolic.
    // "12a" starts with non-who chars → invalid
    try testing.expectError(ModeError.InvalidMode, parseSymbolic("12a", 0, .{}));
}

// ============================================================================
// Edge-case tests (Batch 3 Track C additions)
// ============================================================================

// --- sticky bit without explicit who-specifier ---

test "parseSymbolic: +t with no who sets sticky bit (who-bits ignored per POSIX)" {
    const m = try parseSymbolic("+t", 0o755, .{});
    try testing.expect(m.sticky);
    try testing.expectEqual(@as(u32, 0o1755), m.toOctal());
}

test "parseSymbolic: -t with no who clears sticky bit" {
    const m = try parseSymbolic("-t", 0o1755, .{});
    try testing.expect(!m.sticky);
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: u+t also sets sticky (who-bits for sticky ignored)" {
    // Per POSIX, 't' is always sticky regardless of who-bits
    const m = try parseSymbolic("u+t", 0o644, .{});
    try testing.expect(m.sticky);
}

// --- umask field is currently a no-op ---

// --- parseSymbolic: umask support ---

test "parseSymbolic: explicit 'a' who ignores umask" {
    // Explicit a+rwx: umask has no effect
    const no_umask = try parseSymbolic("a+rwx", 0o000, .{ .umask = 0 });
    const with_umask = try parseSymbolic("a+rwx", 0o000, .{ .umask = 0o022 });
    try testing.expectEqual(no_umask.toOctal(), with_umask.toOctal());
    try testing.expectEqual(@as(u32, 0o777), with_umask.toOctal());
}

test "parseSymbolic: implicit who '+x' respects umask" {
    // umask 0o022: group write (0o020) and other write (0o002) blocked
    // +x sets execute for all, but umask 0o022 only blocks w bits, not x
    const m = try parseSymbolic("+x", 0o644, .{ .umask = 0o022 });
    // umask 022 = ----w--w-; complement masks x through for all classes
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: implicit who '+w' respects umask 022" {
    // +w with umask 022: user gets w, group and other blocked
    const m = try parseSymbolic("+w", 0o000, .{ .umask = 0o022 });
    // umask 022 blocks g+w and o+w; only u+w passes
    try testing.expectEqual(@as(u32, 0o200), m.toOctal());
}

test "parseSymbolic: implicit who '=rw' respects umask 077" {
    // =rw with umask 077: user gets rw, group and other get nothing
    const m = try parseSymbolic("=rw", 0o755, .{ .umask = 0o077 });
    try testing.expectEqual(@as(u32, 0o600), m.toOctal());
}

test "parseSymbolic: implicit who '-x' ignores umask" {
    // Removal is never constrained by umask
    const m = try parseSymbolic("-x", 0o777, .{ .umask = 0o077 });
    try testing.expectEqual(@as(u32, 0o666), m.toOctal());
}

test "parseSymbolic: explicit u+w ignores umask" {
    const m = try parseSymbolic("u+w", 0o000, .{ .umask = 0o222 });
    // Explicit who: umask has no effect
    try testing.expectEqual(@as(u32, 0o200), m.toOctal());
}

test "parseSymbolic: implicit who '+rw' respects umask 022" {
    // +rw with umask 022: u gets rw, g gets r (w blocked), o gets r (w blocked)
    const m = try parseSymbolic("+rw", 0o000, .{ .umask = 0o022 });
    try testing.expectEqual(@as(u32, 0o644), m.toOctal());
}

// --- three-clause 755 construction ---

test "parseSymbolic: u=rwx,g=rx,o=r (three clauses) produces 0o754" {
    const m = try parseSymbolic("u=rwx,g=rx,o=r", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o754), m.toOctal());
}

test "parseSymbolic: u=rwx,go=rx is equivalent to three-step construction" {
    // Both forms should produce identical results
    const two_clause = try parseSymbolic("u=rwx,go=rx", 0o000, .{});
    const three_clause = try parseSymbolic("u=rwx,g=rx,o=rx", 0o000, .{});
    try testing.expectEqual(two_clause.toOctal(), three_clause.toOctal());
}

// --- special bits in combination ---

test "parseSymbolic: u=rwxs,g=rx sets user execute + setuid, group rx" {
    const m = try parseSymbolic("u=rwxs,g=rx", 0o000, .{});
    try testing.expect(m.setuid);
    try testing.expect(!m.setgid);
    try testing.expectEqual(@as(u32, 0o4750), m.toOctal());
}

test "parseSymbolic: a+st sets both setuid/setgid and sticky from base 0755" {
    // 'a+s': sets setuid (for user) and setgid (for group) since who=all
    // 'a+t': sets sticky
    const m = try parseSymbolic("a+st", 0o755, .{});
    try testing.expect(m.setuid);
    try testing.expect(m.setgid);
    try testing.expect(m.sticky);
    try testing.expectEqual(@as(u32, 0o7755), m.toOctal());
}

// --- a+X edge cases ---

test "parseSymbolic: a+X on non-directory with only user execute → adds all execute" {
    // base has user execute bit but not group or other
    const m = try parseSymbolic("a+X", 0o744, .{ .is_directory = false });
    // X triggers because (0o744 & 0o111) != 0 (user has execute)
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "parseSymbolic: a+X on non-directory with only group execute → adds all execute" {
    const m = try parseSymbolic("a+X", 0o050, .{ .is_directory = false });
    // 0o050 has group execute bit set, so X activates
    try testing.expectEqual(@as(u32, 0o151), m.toOctal());
}

test "parseSymbolic: a+X on non-directory with no execute bit is a no-op" {
    const before: u32 = 0o664;
    const m = try parseSymbolic("a+X", before, .{ .is_directory = false });
    try testing.expectEqual(before, m.toOctal());
}

test "parseSymbolic: go+X on directory → adds group and other execute, not user" {
    const m = try parseSymbolic("go+X", 0o600, .{ .is_directory = true });
    // Only group and other execute added; user stays at 6
    try testing.expectEqual(@as(u32, 0o611), m.toOctal());
}

// --- permission copying edge cases ---

test "parseSymbolic: o=g copies group to other (= operator)" {
    // group=rx (5), other=--- (0)
    const m = try parseSymbolic("o=g", 0o050, .{});
    try testing.expectEqual(@as(u32, 0o055), m.toOctal());
}

test "parseSymbolic: ug=o copies other to both user and group" {
    // other=r (4), user=rw (6), group=rw (6)
    const m = try parseSymbolic("ug=o", 0o664, .{});
    // both user and group become other (4 = r)
    try testing.expectEqual(@as(u32, 0o444), m.toOctal());
}

test "parseSymbolic: g=u then o=u in sequence" {
    const m = try parseSymbolic("g=u,o=u", 0o700, .{});
    // user=rwx (7), group becomes 7, other becomes 7
    try testing.expectEqual(@as(u32, 0o777), m.toOctal());
}

// --- Mode fromOctal/toOctal with full special-bit combinations ---

test "mode: all special bits set simultaneously" {
    const full = Mode.fromOctal(0o7777);
    try testing.expect(full.setuid);
    try testing.expect(full.setgid);
    try testing.expect(full.sticky);
    try testing.expectEqual(@as(u32, 0o7777), full.toOctal());
}

test "mode: zero mode has no permissions" {
    const empty = Mode.fromOctal(0o0000);
    try testing.expectEqual(@as(u3, 0), empty.user);
    try testing.expectEqual(@as(u3, 0), empty.group);
    try testing.expectEqual(@as(u3, 0), empty.other);
    try testing.expect(!empty.setuid);
    try testing.expect(!empty.setgid);
    try testing.expect(!empty.sticky);
}
