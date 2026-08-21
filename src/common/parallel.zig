const std = @import("std");

pub const parallel_workers_max: u32 = 8;

const wait_iterations_max: u32 = 1_000_000;
const worker_wait_iterations_max: u32 = 10_000_000;

pub fn runBounded(
    io: std.Io,
    n_workers: u32,
    ctx: anytype,
    work_fn: *const fn (@TypeOf(ctx), u32) anyerror!void,
    n_jobs: u32,
) anyerror!void {
    std.debug.assert(parallel_workers_max > 0);
    std.debug.assert(n_jobs <= std.math.maxInt(u32));
    _ = io;
    _ = n_workers;
    _ = work_fn;
}

fn waitForAtLeast(
    value: *const std.atomic.Value(u32),
    target: u32,
    iterations_max: u32,
) bool {
    std.debug.assert(target > 0);
    std.debug.assert(iterations_max > 0);

    var iteration: u32 = 0;
    while (iteration < iterations_max) : (iteration += 1) {
        if (value.load(.acquire) >= target) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}

fn waitForFlag(value: *const std.atomic.Value(u8), iterations_max: u32) bool {
    std.debug.assert(iterations_max > 0);
    std.debug.assert(value.load(.monotonic) <= 1);

    var iteration: u32 = 0;
    while (iteration < iterations_max) : (iteration += 1) {
        if (value.load(.acquire) != 0) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}

test "parallel runBounded with 0 jobs is a no-op" {
    const Context = struct {
        run_count: *std.atomic.Value(u32),

        fn work(ctx: *const @This(), job_index: u32) anyerror!void {
            _ = job_index;
            _ = ctx.run_count.fetchAdd(1, .monotonic);
        }
    };

    var run_count = std.atomic.Value(u32).init(0);
    const ctx = Context{ .run_count = &run_count };

    try std.testing.expectEqual(@as(u32, 0), run_count.load(.acquire));
    try runBounded(std.testing.io, 4, &ctx, Context.work, 0);
    try std.testing.expectEqual(@as(u32, 0), run_count.load(.acquire));
}

test "parallel runBounded runs every job" {
    const Context = struct {
        run_count: *std.atomic.Value(u32),

        fn work(ctx: *const @This(), job_index: u32) anyerror!void {
            std.debug.assert(job_index < 5);
            std.debug.assert(ctx.run_count.load(.monotonic) <= 5);
            _ = ctx.run_count.fetchAdd(1, .monotonic);
        }
    };

    var run_count = std.atomic.Value(u32).init(0);
    const ctx = Context{ .run_count = &run_count };

    try std.testing.expectEqual(@as(u32, 0), run_count.load(.acquire));
    try runBounded(std.testing.io, 2, &ctx, Context.work, 5);
    try std.testing.expectEqual(@as(u32, 5), run_count.load(.acquire));
}

test "parallel runBounded treats 0 workers as 1" {
    const Context = struct {
        run_count: *std.atomic.Value(u32),
        entered: *std.atomic.Value(u32),
        in_flight: *std.atomic.Value(u32),
        peak: *std.atomic.Value(u32),
        release: *std.atomic.Value(u8),
        wait_timed_out: *std.atomic.Value(u8),

        fn work(ctx: *const @This(), job_index: u32) anyerror!void {
            std.debug.assert(job_index < 3);
            std.debug.assert(ctx.release.load(.monotonic) <= 1);

            _ = ctx.run_count.fetchAdd(1, .monotonic);
            _ = ctx.entered.fetchAdd(1, .release);
            const in_flight = ctx.in_flight.fetchAdd(1, .acq_rel) + 1;
            _ = ctx.peak.fetchMax(in_flight, .acq_rel);
            defer _ = ctx.in_flight.fetchSub(1, .release);

            if (!waitForFlag(ctx.release, worker_wait_iterations_max)) {
                ctx.wait_timed_out.store(1, .release);
                return error.GateTimedOut;
            }
        }
    };
    const Runner = struct {
        ctx: *const Context,
        had_error: *std.atomic.Value(u8),

        fn run(runner: *const @This()) void {
            std.debug.assert(runner.had_error.load(.monotonic) == 0);
            std.debug.assert(runner.ctx.run_count.load(.monotonic) == 0);

            runBounded(std.testing.io, 0, runner.ctx, Context.work, 3) catch {
                runner.had_error.store(1, .release);
            };
        }
    };

    var run_count = std.atomic.Value(u32).init(0);
    var entered = std.atomic.Value(u32).init(0);
    var in_flight = std.atomic.Value(u32).init(0);
    var peak = std.atomic.Value(u32).init(0);
    var release = std.atomic.Value(u8).init(0);
    var wait_timed_out = std.atomic.Value(u8).init(0);
    var had_error = std.atomic.Value(u8).init(0);
    const ctx = Context{
        .run_count = &run_count,
        .entered = &entered,
        .in_flight = &in_flight,
        .peak = &peak,
        .release = &release,
        .wait_timed_out = &wait_timed_out,
    };
    const runner = Runner{ .ctx = &ctx, .had_error = &had_error };

    var group: std.Io.Group = .init;
    try group.concurrent(std.testing.io, Runner.run, .{&runner});
    const gate_reached = waitForAtLeast(&entered, 1, wait_iterations_max);
    release.store(1, .release);
    try group.await(std.testing.io);

    try std.testing.expectEqual(@as(u32, 3), run_count.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), peak.load(.acquire));
    try std.testing.expect(gate_reached);
    try std.testing.expectEqual(@as(u8, 0), wait_timed_out.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), had_error.load(.acquire));
}

test "parallel runBounded caps workers at parallel_workers_max" {
    const Context = struct {
        run_count: *std.atomic.Value(u32),
        entered: *std.atomic.Value(u32),
        in_flight: *std.atomic.Value(u32),
        peak: *std.atomic.Value(u32),
        release: *std.atomic.Value(u8),
        wait_timed_out: *std.atomic.Value(u8),

        fn work(ctx: *const @This(), job_index: u32) anyerror!void {
            std.debug.assert(job_index < 16);
            std.debug.assert(ctx.release.load(.monotonic) <= 1);

            _ = ctx.run_count.fetchAdd(1, .monotonic);
            _ = ctx.entered.fetchAdd(1, .release);
            const in_flight = ctx.in_flight.fetchAdd(1, .acq_rel) + 1;
            _ = ctx.peak.fetchMax(in_flight, .acq_rel);
            defer _ = ctx.in_flight.fetchSub(1, .release);

            if (!waitForFlag(ctx.release, worker_wait_iterations_max)) {
                ctx.wait_timed_out.store(1, .release);
                return error.GateTimedOut;
            }
        }
    };
    const Runner = struct {
        ctx: *const Context,
        had_error: *std.atomic.Value(u8),

        fn run(runner: *const @This()) void {
            std.debug.assert(runner.had_error.load(.monotonic) == 0);
            std.debug.assert(runner.ctx.run_count.load(.monotonic) == 0);

            runBounded(std.testing.io, 64, runner.ctx, Context.work, 16) catch {
                runner.had_error.store(1, .release);
            };
        }
    };

    var run_count = std.atomic.Value(u32).init(0);
    var entered = std.atomic.Value(u32).init(0);
    var in_flight = std.atomic.Value(u32).init(0);
    var peak = std.atomic.Value(u32).init(0);
    var release = std.atomic.Value(u8).init(0);
    var wait_timed_out = std.atomic.Value(u8).init(0);
    var had_error = std.atomic.Value(u8).init(0);
    const ctx = Context{
        .run_count = &run_count,
        .entered = &entered,
        .in_flight = &in_flight,
        .peak = &peak,
        .release = &release,
        .wait_timed_out = &wait_timed_out,
    };
    const runner = Runner{ .ctx = &ctx, .had_error = &had_error };

    var group: std.Io.Group = .init;
    try group.concurrent(std.testing.io, Runner.run, .{&runner});
    const cap_reached = waitForAtLeast(
        &entered,
        parallel_workers_max,
        wait_iterations_max,
    );
    const ninth_entered = if (cap_reached)
        waitForAtLeast(&entered, parallel_workers_max + 1, wait_iterations_max)
    else
        false;
    release.store(1, .release);
    try group.await(std.testing.io);

    try std.testing.expectEqual(@as(u32, 16), run_count.load(.acquire));
    try std.testing.expectEqual(parallel_workers_max, peak.load(.acquire));
    try std.testing.expect(cap_reached);
    try std.testing.expect(!ninth_entered);
    try std.testing.expectEqual(@as(u8, 0), wait_timed_out.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), had_error.load(.acquire));
}

test "parallel runBounded returns the lowest job index error" {
    const Context = struct {
        io: std.Io,
        run_count: *std.atomic.Value(u32),
        entered: *std.atomic.Value(u32),
        job_three_released: *std.atomic.Value(u8),
        wait_timed_out: *std.atomic.Value(u8),

        fn work(ctx: *const @This(), job_index: u32) anyerror!void {
            std.debug.assert(job_index < 4);
            std.debug.assert(ctx.job_three_released.load(.monotonic) <= 1);

            _ = ctx.run_count.fetchAdd(1, .monotonic);
            _ = ctx.entered.fetchAdd(1, .release);
            if (!waitForAtLeast(ctx.entered, 4, worker_wait_iterations_max)) {
                ctx.wait_timed_out.store(1, .release);
                return error.GateTimedOut;
            }

            if (job_index == 3) {
                ctx.job_three_released.store(1, .release);
                return error.JobThreeFailed;
            }
            if (job_index == 1) {
                if (!waitForFlag(ctx.job_three_released, worker_wait_iterations_max)) {
                    ctx.wait_timed_out.store(1, .release);
                    return error.GateTimedOut;
                }
                try ctx.io.sleep(
                    std.Io.Duration.fromNanoseconds(std.time.ns_per_ms),
                    .awake,
                );
                return error.JobOneFailed;
            }
        }
    };

    var run_count = std.atomic.Value(u32).init(0);
    var entered = std.atomic.Value(u32).init(0);
    var job_three_released = std.atomic.Value(u8).init(0);
    var wait_timed_out = std.atomic.Value(u8).init(0);
    const ctx = Context{
        .io = std.testing.io,
        .run_count = &run_count,
        .entered = &entered,
        .job_three_released = &job_three_released,
        .wait_timed_out = &wait_timed_out,
    };

    try std.testing.expectError(
        error.JobOneFailed,
        runBounded(std.testing.io, 4, &ctx, Context.work, 4),
    );
    try std.testing.expectEqual(@as(u32, 4), run_count.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), wait_timed_out.load(.acquire));
}

test "parallel runBounded finishes jobs when concurrency is unavailable" {
    const Context = struct {
        run_count: *std.atomic.Value(u32),

        fn work(ctx: *const @This(), job_index: u32) anyerror!void {
            std.debug.assert(job_index < 5);
            std.debug.assert(ctx.run_count.load(.monotonic) <= 5);
            _ = ctx.run_count.fetchAdd(1, .monotonic);
        }
    };

    var run_count = std.atomic.Value(u32).init(0);
    const ctx = Context{ .run_count = &run_count };

    try std.testing.expectEqual(@as(u32, 0), run_count.load(.acquire));
    try runBounded(std.Io.failing, 8, &ctx, Context.work, 5);
    try std.testing.expectEqual(@as(u32, 5), run_count.load(.acquire));
}
