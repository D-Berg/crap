//! https://codeberg.org/tensorush/scoop/src/branch/main/src/kperf.zig
const std = @import("std");
const c = @import("c");
const xnu = @import("xnu.zig");

// Log non-fatal errors
const log = std.log.scoped(.scoop);

/// Counter alias enum.
pub const CounterAlias = xnu.KpepEventAlias;

/// Process trace for observing changes in sampled counter values.
pub fn Trace(comptime E: type) type {
    return struct {
        const Self = @This();

        /// Whether counter sampling is in progress.
        var IS_SAMPLING: bool = false;

        sample_thread: std.Thread,
        opts: Options,

        /// Process-tracing error set.
        pub const Error = xnu.Error || std.Thread.SpawnError;

        /// Process-tracing options.
        pub const Options = struct {
            /// Target process pid, -1 for all threads.
            target_pid: std.posix.pid_t = -1,

            /// Number of counter sampling buffers.
            num_bufs: usize = 1_000_000,

            /// Sampling period in nanoseconds.
            /// Default value corresponds to perf's default sampling rate of 4000 Hz.
            sample_period: u64 = 250 * std.time.ns_per_us,

            /// Whether to deallocate counter sampling buffers and thread data.
            is_gpa: bool = true,
        };

        /// Start sampling counters.
        pub fn startSampling(allocator: std.mem.Allocator, counters: *std.EnumArray(E, u64), opts: Options) Error!Self {
            // Indicate sampling is in progress
            IS_SAMPLING = true;

            // Define constant action ID and timer ID
            const action_id: u32 = 1;
            const timer_id: u32 = 1;

            // Define counter mapping
            var counter_count: u32 = undefined;
            const counter_map = try start(E, &counter_count);

            // Allocate action IDs and timer IDs
            if (xnu.kperf_action_count_set(xnu.KPERF_ACTION_MAX) != 0) {
                log.err("{t}", .{Error.SetActionCount});
            }
            if (xnu.kperf_timer_count_set(xnu.KPERF_TIMER_MAX) != 0) {
                log.err("{t}", .{Error.SetTimerCount});
            }

            // Set PMC per thread sampler
            if (xnu.kperf_action_samplers_set(action_id, xnu.KPERF_SAMPLER_PMC_THREAD) != 0) {
                log.err("{t} with Action ID = {d}", .{ Error.SetSamplers, action_id });
            }

            // Set filter process
            if (xnu.kperf_action_filter_set_by_pid(action_id, opts.target_pid) != 0) {
                log.err("{t} with Action ID = {d} and PID = {d}", .{ Error.SetFilterByPid, action_id, opts.target_pid });
            }

            // Set up PET (Profile Every Thread) and start sampler
            const tick = xnu.kperf_ns_to_ticks(opts.sample_period);
            if (xnu.kperf_timer_period_set(action_id, tick) != 0) {
                log.err("{t} with Action ID = {d}", .{ Error.SetTimerPeriod, action_id });
            }
            if (xnu.kperf_timer_action_set(action_id, timer_id) != 0) {
                log.err("{t} with Action ID = {d} and Timer ID = {d}", .{ Error.SetTimer, action_id, timer_id });
            }
            if (xnu.kperf_timer_pet_set(timer_id) != 0) {
                log.err("{t} with Timer ID = {d}", .{ Error.SetTimerPet, timer_id });
            }
            if (xnu.kperf_lightweight_pet_set(1) != 0) {
                log.err("{t}", .{Error.SetLightweightPet});
            }
            if (xnu.kperf_sample_set(1) != 0) {
                log.err("{t}", .{Error.SetSample});
            }

            // Reset kdebug/ktrace
            if (xnu.kdebug_reset() != 0) {
                log.err("{t}", .{Error.SetTrace});
            }

            if (xnu.kdebug_trace_setbuf(@intCast(opts.num_bufs)) != 0) {
                log.err("{t}", .{Error.SetTraceBuffer});
            }
            if (xnu.kdebug_reinit() != 0) {
                log.err("{t}", .{Error.InitTraceBuffer});
            }

            // Set trace filter: only log PERF_KPC_DATA_THREAD
            var kdr = std.mem.zeroes(xnu.kd_regtype);
            kdr.type = xnu.KDBG_VALCHECK;
            kdr.value1 = c.KDBG_EVENTID(c.DBG_PERF, xnu.PERF_KPC, xnu.PERF_KPC_DATA_THREAD);
            if (xnu.kdebug_setreg(&kdr) != 0) {
                log.err("{t}", .{Error.SetTraceFilter});
            }

            // Start tracing
            if (xnu.kdebug_trace_enable(1) != 0) {
                log.err("{t}", .{Error.EnableTrace});
            }

            return .{
                // Spawn counter sampling thread
                .sample_thread = try .spawn(.{}, sample, .{
                    allocator,
                    counters,
                    counter_map,
                    counter_count,
                    opts,
                }),
                .opts = opts,
            };
        }

        /// Stop sampling counters.
        pub fn stopSampling(self: *Self) xnu.Error!void {
            // Signal counter sampling thread to stop sampling
            @atomicStore(bool, &IS_SAMPLING, false, .monotonic);

            // Join counter sampling thread
            self.sample_thread.join();

            // Disable process tracing
            if (xnu.kdebug_trace_enable(0) != 0) {
                return Error.DisableTrace;
            }
            if (xnu.kdebug_reset() != 0) {
                return Error.UnsetTrace;
            }
            if (xnu.kperf_sample_set(0) != 0) {
                return Error.UnsetSample;
            }
            if (xnu.kperf_lightweight_pet_set(0) != 0) {
                return Error.UnsetLightweightPet;
            }
        }

        fn sample(
            allocator: std.mem.Allocator,
            counters: *std.EnumArray(E, u64),
            counter_map: [xnu.KPC_MAX_COUNTERS]usize,
            counter_count: u32,
            opts: Options,
        ) void {
            var bufs_cur_idx: usize = 0;
            var bufs = allocator.alloc(xnu.kd_buf, opts.num_bufs * 2) catch |err| @panic(@errorName(err));
            defer if (opts.is_gpa) allocator.free(bufs);
            while (true) {
                // Wait for more buffers
                std.Thread.sleep(2 * opts.sample_period);

                // Expand buffers for next read
                if (bufs.len - bufs_cur_idx < opts.num_bufs) {
                    bufs = allocator.realloc(bufs, bufs.len * 2) catch |err| @panic(@errorName(err));
                }

                // Check whether to stop sampling
                if (!@atomicLoad(bool, &IS_SAMPLING, .monotonic)) {
                    break;
                }

                // Read trace buffer from kernel
                var count: usize = 0;
                if (xnu.kdebug_trace_read(bufs[bufs_cur_idx .. bufs_cur_idx + opts.num_bufs].ptr, @sizeOf(xnu.kd_buf) * opts.num_bufs, &count) != 0) {
                    @panic(@errorName(Error.ReadTrace));
                }
                for (bufs[bufs_cur_idx .. bufs_cur_idx + count]) |buf| {
                    const debug_id = buf.debug_id;
                    const class = c.KDBG_EXTRACT_CLASS(debug_id);
                    const subclass = c.KDBG_EXTRACT_SUBCLASS(debug_id);
                    const code = c.KDBG_EXTRACT_CODE(debug_id);

                    // Keep only thread PMC data
                    if (class != c.DBG_PERF) continue;
                    if (subclass != xnu.PERF_KPC) continue;
                    if (code != xnu.PERF_KPC_DATA_THREAD) continue;
                    bufs[bufs_cur_idx] = buf;
                    bufs_cur_idx += 1;
                }
            }
            if (bufs_cur_idx == 0) {
                @panic(@errorName(Error.CollectThreadPmcData));
            }

            stop() catch |err| @panic(@errorName(err));

            // Aggregate thread PMC data
            var thread_count: usize = 0;
            var thread_data = allocator.alloc(xnu.kpc_thread_data, 16) catch |err| @panic(@errorName(err));
            defer if (opts.is_gpa) allocator.free(thread_data);
            for (bufs[0..bufs_cur_idx], 0..) |buf, buf_idx| {
                if (buf.debug_id & c.KDBG_FUNC_MASK != c.DBG_FUNC_START) continue;
                const tid = buf.arg5;
                if (tid == 0) continue;

                // Read one counter log
                var counter_idx: u8 = 0;
                var thread_counters: [xnu.KPC_MAX_COUNTERS]u64 = undefined;
                thread_counters[counter_idx] = buf.arg1;
                counter_idx += 1;
                thread_counters[counter_idx] = buf.arg2;
                counter_idx += 1;
                thread_counters[counter_idx] = buf.arg3;
                counter_idx += 1;
                thread_counters[counter_idx] = buf.arg4;
                counter_idx += 1;

                // Counter count larger than 4,
                // values are split into multiple buffer entities
                if (counter_idx < counter_count) {
                    for (bufs[buf_idx + 1 .. bufs_cur_idx]) |buf2| {
                        if (buf2.arg5 != tid) break;
                        if (buf2.debug_id & c.KDBG_FUNC_MASK == c.DBG_FUNC_START) break;
                        if (counter_idx < counter_count) {
                            thread_counters[counter_idx] = buf2.arg1;
                            counter_idx += 1;
                        }
                        if (counter_idx < counter_count) {
                            thread_counters[counter_idx] = buf2.arg2;
                            counter_idx += 1;
                        }
                        if (counter_idx < counter_count) {
                            thread_counters[counter_idx] = buf2.arg3;
                            counter_idx += 1;
                        }
                        if (counter_idx < counter_count) {
                            thread_counters[counter_idx] = buf2.arg4;
                            counter_idx += 1;
                        }
                        if (counter_idx == counter_count) break;
                    }
                }

                // Not enough thread_counters, maybe truncated
                if (counter_idx != counter_count) continue;

                // Add to thread data
                var t_data_opt: ?*xnu.kpc_thread_data = null;
                for (thread_data[0..thread_count]) |*t_data| {
                    if (t_data.tid == tid) {
                        t_data_opt = t_data;
                        break;
                    }
                }
                if (t_data_opt) |t_data| {
                    if (t_data.timestamp_0 == 0) {
                        t_data.timestamp_0 = buf.timestamp;
                        @memcpy(t_data.counters_0[0..counter_count], thread_counters[0..counter_count]);
                    } else {
                        t_data.timestamp_1 = buf.timestamp;
                        @memcpy(t_data.counters_1[0..counter_count], thread_counters[0..counter_count]);
                    }
                } else {
                    if (thread_data.len == thread_count) {
                        thread_data = allocator.realloc(thread_data, thread_data.len * 2) catch |err| @panic(@errorName(err));
                    }
                    t_data_opt = &thread_data[thread_count];
                    thread_count += 1;
                    t_data_opt.?.* = std.mem.zeroes(xnu.kpc_thread_data);
                    t_data_opt.?.tid = @intCast(tid);
                }
            }

            // Sum counter value changes across traced threads
            var counter_diffs: [xnu.KPC_MAX_COUNTERS]u64 = @splat(0);
            for (thread_data[0..thread_count]) |t_data| {
                if (t_data.timestamp_0 == 0 or t_data.timestamp_1 == 0) continue;

                for (0..counter_count) |counter_idx| {
                    counter_diffs[counter_idx] += t_data.counters_1[counter_idx] - t_data.counters_0[counter_idx];
                }
            }

            // Fill counter value changes for traced process
            for (counter_map[0..counters.values.len], 0..) |mapped_counter_idx, i| {
                counters.set(@enumFromInt(i), counter_diffs[mapped_counter_idx]);
            }
        }
    };
}

/// Call target function with given arguments and observe changes in counter values.
pub fn call(comptime E: type, counters: *std.EnumArray(E, u64), function: anytype, args: anytype) xnu.Error!void {
    const counter_map = try start(E, null);

    // Get thread counters before
    var counters_0: [xnu.KPC_MAX_COUNTERS]u64 = undefined;
    if (xnu.kpc_get_thread_counters(0, xnu.KPC_MAX_COUNTERS, @ptrCast(&counters_0)) != 0) {
        return xnu.Error.GetKpcThreadCounters;
    }

    // Run target function
    _ = @call(.auto, function, args);

    // Get thread counters after
    var counters_1: [xnu.KPC_MAX_COUNTERS]u64 = undefined;
    if (xnu.kpc_get_thread_counters(0, xnu.KPC_MAX_COUNTERS, @ptrCast(&counters_1)) != 0) {
        return xnu.Error.GetKpcThreadCounters;
    }

    try stop();

    // Fill counter value changes for called function
    for (counter_map[0..counters.values.len], 0..) |mapped_counter_idx, i| {
        counters.set(@enumFromInt(i), counters_1[mapped_counter_idx] - counters_0[mapped_counter_idx]);
    }
}

fn start(comptime E: type, counter_count_opt: ?*u32) xnu.Error![xnu.KPC_MAX_COUNTERS]usize {
    // Check KPC permission
    var force_ctrs: c_int = 0;
    if (xnu.kpc_force_all_ctrs_get(&force_ctrs) != 0) {
        return xnu.Error.GetKpcAllCounters;
    }

    // Load PMC database
    var db_opt: ?*xnu.kpep_db = null;
    var cfg_err_code: xnu.kpep_config_error_code = @enumFromInt(xnu.kpep_db_create(null, &db_opt));
    if (cfg_err_code != .None) {
        return cfg_err_code.toError();
    }

    // Create KPEP config
    var cfg: ?*xnu.kpep_config = null;
    cfg_err_code = @enumFromInt(xnu.kpep_config_create(db_opt, &cfg));
    if (cfg_err_code != .None) {
        return cfg_err_code.toError();
    }
    cfg_err_code = @enumFromInt(xnu.kpep_config_force_counters(cfg));
    if (cfg_err_code != .None) {
        return cfg_err_code.toError();
    }

    // Get KPEP event
    const counter_aliases = comptime std.meta.tags(E);
    var events: [counter_aliases.len]*xnu.kpep_event = undefined;
    inline for (counter_aliases, 0..) |counter_alias, i| {
        events[i] = blk: {
            for (std.enums.nameCast(xnu.KpepEventAlias, counter_alias).getNames()) |name| {
                var event: ?*xnu.kpep_event = null;
                cfg_err_code = @enumFromInt(xnu.kpep_db_event(db_opt, @ptrCast(name), &event));
                if (cfg_err_code == .None) {
                    break :blk event.?;
                }
            }
            return xnu.Error.EventNotFound;
        };
    }

    // Add KPEP event to config
    for (&events) |*event| {
        cfg_err_code = @enumFromInt(xnu.kpep_config_add_event(cfg, event, 0, null));
        if (cfg_err_code != .None) {
            return cfg_err_code.toError();
        }
    }

    // Prepare counter map and register configs
    var classes: u32 = 0;
    var reg_count: usize = 0;
    var counter_map: [xnu.KPC_MAX_COUNTERS]usize = undefined;
    var regs: [xnu.KPC_MAX_COUNTERS]xnu.kpc_config_t = undefined;
    cfg_err_code = @enumFromInt(xnu.kpep_config_kpc_classes(cfg, &classes));
    if (cfg_err_code != .None) {
        return cfg_err_code.toError();
    }
    cfg_err_code = @enumFromInt(xnu.kpep_config_kpc_count(cfg, &reg_count));
    if (cfg_err_code != .None) {
        return cfg_err_code.toError();
    }
    cfg_err_code = @enumFromInt(xnu.kpep_config_kpc_map(cfg, &counter_map[0], @sizeOf(@TypeOf(counter_map))));
    if (cfg_err_code != .None) {
        return cfg_err_code.toError();
    }
    cfg_err_code = @enumFromInt(xnu.kpep_config_kpc(cfg, &regs[0], @sizeOf(@TypeOf(regs))));
    if (cfg_err_code != .None) {
        return cfg_err_code.toError();
    }

    // Set config to kernel
    if (xnu.kpc_force_all_ctrs_set(1) != 0) {
        return xnu.Error.SetKpcAllCounters;
    }
    if ((classes & xnu.KPC_CLASS_CONFIGURABLE_MASK) > 0 and reg_count > 0) {
        if (xnu.kpc_set_config(classes, &regs[0]) != 0) {
            return xnu.Error.SetKpcConfig;
        }
    }

    // Get counter count
    if (counter_count_opt) |counter_count| {
        counter_count.* = xnu.kpc_get_counter_count(classes);
        if (counter_count.* == 0) {
            return xnu.Error.GetKpcCounter;
        }
    }

    // Start counting
    if (xnu.kpc_set_counting(classes) != 0) {
        return xnu.Error.SetKpcCounting;
    }
    if (xnu.kpc_set_thread_counting(classes) != 0) {
        return xnu.Error.SetKpcThreadCounting;
    }

    return counter_map;
}

fn stop() xnu.Error!void {
    // Stop counting
    if (xnu.kpc_set_counting(0) != 0) {
        return xnu.Error.UnsetKpcCounting;
    }
    if (xnu.kpc_set_thread_counting(0) != 0) {
        return xnu.Error.UnsetKpcThreadCounting;
    }
    if (xnu.kpc_force_all_ctrs_set(0) != 0) {
        return xnu.Error.UnsetKpcAllCounters;
    }
}
