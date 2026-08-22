const std = @import("std");

pub const parallel_workers_max: u32 = 8;

const wait_iterations_max: u32 = 50_000_000;
const worker_wait_iterations_max: u32 = 200_000_000;
const yield_period: u32 = 4096;

/// Every participant (workers plus the caller) overshoots the steal index by
/// at most one, so this bound keeps the shared counter from wrapping.
const n_jobs_max: u32 = std.math.maxInt(u32) - parallel_workers_max - 1;

/// Sentinel for "no job has failed". Any packed (job index, error) value is
/// smaller because the error integer never fills its full 32-bit half.
const error_slot_empty: u64 = std.math.maxInt(u64);

const ErrorInt = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

/// State shared between the caller and every worker: the lock-free steal
/// index and the packed lowest-failing-job error slot.
const Shared = struct {
    next_job: std.atomic.Value(u32),
    error_slot: std.atomic.Value(u64),
};

/// Two-phase start barrier. Workers arrive and sleep on a futex; the caller
/// releases them together only after every spawned worker has arrived. A
/// worker that never slept before starting work gets no wake-up preemption
/// credit from the scheduler, so a CPU-bound job on an early worker could
/// otherwise starve the remaining workers for tens of milliseconds.
const StartBarrier = struct {
    ready_count: std.atomic.Value(u32),
    expected_count: std.atomic.Value(u32),
    all_ready: std.Io.Event,
    go_gate: std.Io.Event,

    const init: StartBarrier = .{
        .ready_count = .init(0),
        .expected_count = .init(0),
        .all_ready = .unset,
        .go_gate = .unset,
    };

    /// Called by each worker: register arrival, then sleep until released.
    /// The seq_cst pair with `release` ensures either the worker sees the
    /// expected count or the caller sees the final ready count.
    fn arrive(barrier: *StartBarrier, io: std.Io) void {
        const arrived = barrier.ready_count.fetchAdd(1, .seq_cst) + 1;
        std.debug.assert(arrived >= 1);
        std.debug.assert(arrived <= parallel_workers_max);

        const expected = barrier.expected_count.load(.seq_cst);
        if (expected != 0 and arrived == expected) barrier.all_ready.set(io);
        barrier.go_gate.waitUncancelable(io);
    }

    /// Called by the caller after spawning: wait until all `started` workers
    /// are asleep on the gate, then wake them together.
    fn release(barrier: *StartBarrier, io: std.Io, started: u32) void {
        std.debug.assert(started >= 1);
        std.debug.assert(started <= parallel_workers_max);

        barrier.expected_count.store(started, .seq_cst);
        if (barrier.ready_count.load(.seq_cst) == started) barrier.all_ready.set(io);
        barrier.all_ready.waitUncancelable(io);
        barrier.go_gate.set(io);
    }
};

pub fn runBounded(
    io: std.Io,
    n_workers: u32,
    ctx: anytype,
    work_fn: *const fn (@TypeOf(ctx), u32) anyerror!void,
    n_jobs: u32,
) anyerror!void {
    std.debug.assert(parallel_workers_max > 0);
    std.debug.assert(n_jobs <= n_jobs_max);
    if (n_jobs == 0) return;

    const Ctx = @TypeOf(ctx);
    var shared: Shared = .{
        .next_job = .init(0),
        .error_slot = .init(error_slot_empty),
    };

    var group: std.Io.Group = .init;
    var barrier: StartBarrier = .init;
    // The caller participates as one of the workers, so only the rest are
    // spawned. A worker count of one therefore spawns nothing and runs the
    // jobs sequentially on the calling thread.
    const worker_count = workerCount(n_workers, n_jobs);
    const started = spawnWorkers(
        Ctx,
        &group,
        &barrier,
        io,
        ctx,
        work_fn,
        &shared,
        n_jobs,
        worker_count - 1,
    );
    // The barrier release and the await both touch the Io vtable, so both
    // are gated on at least one worker having started — with none started
    // the group holds no resources and the barrier has no arrivals to wait
    // for. This keeps std.Io.failing (which spawns nothing) off both paths.
    if (started > 0) barrier.release(io, started);
    // The caller steals from the same index as the workers. This is also the
    // fallback that finishes every job when concurrency is unavailable.
    stealJobs(Ctx, ctx, work_fn, &shared, n_jobs);
    if (started > 0) try group.await(io);

    const packed_error = shared.error_slot.load(.acquire);
    if (packed_error == error_slot_empty) return;
    return unpackError(packed_error);
}

/// Effective worker count: `n_workers == 0` means one worker, capped by the
/// global maximum and by the number of jobs so no worker spawns idle.
fn workerCount(n_workers: u32, n_jobs: u32) u32 {
    std.debug.assert(n_jobs > 0);

    const requested = @max(n_workers, 1);
    const count = @min(@min(requested, parallel_workers_max), n_jobs);

    std.debug.assert(count >= 1);
    std.debug.assert(count <= parallel_workers_max);
    return count;
}

/// Spawn up to `spawn_count` concurrent workers into `group`. Stops at the
/// first `ConcurrencyUnavailable` and returns how many actually started.
fn spawnWorkers(
    comptime Ctx: type,
    group: *std.Io.Group,
    barrier: *StartBarrier,
    io: std.Io,
    ctx: Ctx,
    work_fn: *const fn (Ctx, u32) anyerror!void,
    shared: *Shared,
    n_jobs: u32,
    spawn_count: u32,
) u32 {
    // The caller occupies one worker slot, so at most max - 1 are spawned.
    std.debug.assert(spawn_count < parallel_workers_max);
    std.debug.assert(n_jobs > 0);

    // Returning void coerces to Cancelable!void, which Group requires; job
    // errors are recorded in the shared slot because Group discards them.
    const Worker = struct {
        fn run(
            worker_io: std.Io,
            worker_barrier: *StartBarrier,
            worker_ctx: Ctx,
            worker_fn: *const fn (Ctx, u32) anyerror!void,
            worker_shared: *Shared,
            jobs_total: u32,
        ) void {
            std.debug.assert(jobs_total > 0);
            std.debug.assert(jobs_total <= n_jobs_max);
            worker_barrier.arrive(worker_io);
            stealJobs(Ctx, worker_ctx, worker_fn, worker_shared, jobs_total);
        }
    };

    var started: u32 = 0;
    while (started < spawn_count) : (started += 1) {
        group.concurrent(
            io,
            Worker.run,
            .{ io, barrier, ctx, work_fn, shared, n_jobs },
        ) catch break;
    }
    return started;
}

/// Steal job indices from the shared counter until none remain, running each
/// job and recording any failure. Runs on workers and on the caller.
fn stealJobs(
    comptime Ctx: type,
    ctx: Ctx,
    work_fn: *const fn (Ctx, u32) anyerror!void,
    shared: *Shared,
    n_jobs: u32,
) void {
    std.debug.assert(n_jobs > 0);
    std.debug.assert(n_jobs <= n_jobs_max);

    // One participant steals at most every job plus one overshoot, so the
    // loop bound is explicit even though the counter test exits earlier.
    var stolen: u32 = 0;
    while (stolen <= n_jobs) : (stolen += 1) {
        const job_index = shared.next_job.fetchAdd(1, .acq_rel);
        if (job_index >= n_jobs) return;
        work_fn(ctx, job_index) catch |err| recordError(shared, job_index, err);
    }
}

/// Record a job failure so that the lowest failing job index wins, no matter
/// which failure happened first in wall-clock order.
fn recordError(shared: *Shared, job_index: u32, err: anyerror) void {
    comptime std.debug.assert(@bitSizeOf(anyerror) <= 32);

    const error_int: ErrorInt = @intFromError(err);
    // Error integer 0 is reserved for "no error", so a real error packs to a
    // nonzero low half and can never collide with the empty sentinel.
    std.debug.assert(error_int != 0);
    const packed_value = (@as(u64, job_index) << 32) | @as(u64, error_int);
    std.debug.assert(packed_value != error_slot_empty);

    _ = shared.error_slot.fetchMin(packed_value, .acq_rel);
}

/// Recover the error from a packed (job index, error integer) slot value.
fn unpackError(packed_value: u64) anyerror {
    std.debug.assert(packed_value != error_slot_empty);

    const error_int: ErrorInt = @intCast(packed_value & std.math.maxInt(u32));
    std.debug.assert(error_int != 0);
    return @errorFromInt(error_int);
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
        spinAndMaybeYield(iteration);
    }
    return false;
}

fn waitForFlag(value: *const std.atomic.Value(u8), iterations_max: u32) bool {
    std.debug.assert(iterations_max > 0);
    std.debug.assert(value.load(.monotonic) <= 1);

    var iteration: u32 = 0;
    while (iteration < iterations_max) : (iteration += 1) {
        if (value.load(.acquire) != 0) return true;
        spinAndMaybeYield(iteration);
    }
    return false;
}

/// Tight spins starve sibling workers on oversubscribed BSD QEMU guests.
fn spinAndMaybeYield(iteration: u32) void {
    std.debug.assert(yield_period > 1);
    std.debug.assert(yield_period & (yield_period - 1) == 0);
    std.atomic.spinLoopHint();
    if (iteration & (yield_period - 1) == 0) std.Thread.yield() catch {};
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
