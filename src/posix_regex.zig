//! POSIX regex bindings that never `@cImport` `regex.h`.
//!
//! glibc's `regex_t` is opaque to translate-c, and NetBSD headers trip
//! `@cImport` on `pragma` / `__END_DECLS`. find, grep, and nl call through
//! `regex_alloc.c` instead, and heap-allocate `regex_t` on every OS.

const std = @import("std");
const assert = std.debug.assert;

/// Heap-allocated POSIX `regex_t`. Size is unknown to Zig on every OS.
pub const Regex = opaque {};

/// Match offsets with a fixed ABI so Zig never depends on `regoff_t`.
pub const Match = extern struct {
    rm_so: i64,
    rm_eo: i64,
};

/// Current callers pass `nmatch` of 0 or 1; the C shim caps copies here.
const match_slots_max: usize = 32;

pub extern "c" const vibe_REG_NOSUB: c_int;
pub extern "c" const vibe_REG_ICASE: c_int;
pub extern "c" const vibe_REG_EXTENDED: c_int;
pub extern "c" const vibe_REG_NOTBOL: c_int;

/// POSIX `regcomp`/`regexec` bits. Loaded from C so the values match the libc.
pub const Flags = struct {
    nosub: c_int,
    icase: c_int,
    extended: c_int,
    notbol: c_int,
};

/// Read the libc flag values. They are never zero on a POSIX system.
pub fn flags() Flags {
    const f = Flags{
        .nosub = vibe_REG_NOSUB,
        .icase = vibe_REG_ICASE,
        .extended = vibe_REG_EXTENDED,
        .notbol = vibe_REG_NOTBOL,
    };
    assert(f.nosub != 0);
    assert(f.icase != 0);
    assert(f.extended != 0);
    assert(f.notbol != 0);
    return f;
}

extern "c" fn regex_heap_alloc() ?*Regex;
extern "c" fn regex_heap_free(re: *Regex) void;
extern "c" fn vibe_regcomp(preg: *Regex, pattern: [*:0]const u8, cflags: c_int) c_int;
extern "c" fn vibe_regexec(
    preg: *const Regex,
    string: [*:0]const u8,
    nmatch: usize,
    pmatch: ?[*]Match,
    eflags: c_int,
) c_int;
extern "c" fn vibe_regfree(preg: *Regex) void;
extern "c" fn vibe_regerror(
    errcode: c_int,
    preg: *const Regex,
    errbuf: [*]u8,
    errbuf_size: usize,
) usize;

/// Allocate an empty `regex_t` on the C heap.
pub fn alloc() ?*Regex {
    const re = regex_heap_alloc();
    if (re) |ptr| {
        assert(@intFromPtr(ptr) != 0);
        assert(@intFromPtr(ptr) != std.math.maxInt(usize));
        return ptr;
    }
    return null;
}

/// Release only the heap slot. Call after `freePattern`, or after `comp` fails.
pub fn heapFree(re: *Regex) void {
    assert(@intFromPtr(re) != 0);
    assert(@intFromPtr(re) != std.math.maxInt(usize));
    regex_heap_free(re);
}

/// `regfree` the compiled pattern without returning the heap slot.
pub fn freePattern(re: *Regex) void {
    assert(@intFromPtr(re) != 0);
    assert(@intFromPtr(re) != std.math.maxInt(usize));
    vibe_regfree(re);
}

/// `regfree` then free the heap slot. Pair with a successful `compile`/`comp`.
pub fn deinit(re: *Regex) void {
    assert(@intFromPtr(re) != 0);
    assert(@intFromPtr(re) != std.math.maxInt(usize));
    vibe_regfree(re);
    regex_heap_free(re);
}

/// Compile `pattern` into an already-allocated `regex_t`.
pub fn comp(re: *Regex, pattern: [*:0]const u8, cflags: c_int) c_int {
    assert(@intFromPtr(re) != 0);
    assert(cflags >= 0);
    return vibe_regcomp(re, pattern, cflags);
}

/// Allocate and compile. On `regcomp` failure the heap slot is released.
pub fn compile(pattern: [*:0]const u8, cflags: c_int) ?*Regex {
    assert(cflags >= 0);
    const re = alloc() orelse return null;
    assert(@intFromPtr(re) != 0);
    const rc = vibe_regcomp(re, pattern, cflags);
    if (rc != 0) {
        regex_heap_free(re);
        return null;
    }
    return re;
}

/// Execute a compiled pattern. `pmatch` may be null when `nmatch` is 0.
pub fn exec(
    re: *const Regex,
    string: [*:0]const u8,
    nmatch: usize,
    pmatch: ?[*]Match,
    eflags: c_int,
) c_int {
    assert(@intFromPtr(re) != 0);
    assert(nmatch <= match_slots_max);
    assert(eflags >= 0);
    if (nmatch > 0) assert(pmatch != null);
    return vibe_regexec(re, string, nmatch, pmatch, eflags);
}

/// Write a `regerror` message into `errbuf`.
pub fn errorMessage(
    errcode: c_int,
    preg: *const Regex,
    errbuf: [*]u8,
    errbuf_size: usize,
) usize {
    assert(@intFromPtr(preg) != 0);
    assert(errbuf_size > 0);
    return vibe_regerror(errcode, preg, errbuf, errbuf_size);
}
