//! https://codeberg.org/tensorush/scoop/src/branch/main/src/xnu.zig
//! XNU KPC API available with root privileges for x86_64/aarch64 macOS/iOS.
//! Source: https://gist.github.com/ibireme/173517c208c7dc333ba962c1f0d67d12

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

/// XNU KPC error set.
pub const Error = error{
    GetKpcAllCounters,
    GetKpcThreadCounters,
    SetKpcAllCounters,
    SetKpcConfig,
    GetKpcCounter,
    SetKpcCounting,
    SetKpcThreadCounting,
    SetActionCount,
    SetTimerCount,
    SetSamplers,
    SetFilterByPid,
    SetTimerPeriod,
    SetTimer,
    SetTimerPet,
    SetLightweightPet,
    SetSample,
    SetTrace,
    SetTraceBuffer,
    InitTraceBuffer,
    SetTraceFilter,
    EnableTrace,
    ReadTrace,
    DisableTrace,
    UnsetTrace,
    UnsetSample,
    UnsetLightweightPet,
    UnsetKpcCounting,
    UnsetKpcThreadCounting,
    UnsetKpcAllCounters,
    CollectThreadPmcData,
} || KpepConfigError;

/// KPEP event alias.
pub const KpepEventAlias = enum {
    Cycles,
    Instructions,
    Branches,
    BranchMisses,
    DataCacheMisses,
    InstructionCacheMisses,

    /// KPEP event names from /usr/share/kpep/<name>.plist.
    pub fn getNames(self: KpepEventAlias) []const [:0]const u8 {
        return switch (self) {
            .Cycles => &.{
                // Apple A7-A15.
                "FIXED_CYCLES".*[0..],
                // Intel Core 1th-10th.
                "CPU_CLK_UNHALTED.THREAD".*[0..],
                // Intel Yonah, Merom.
                "CPU_CLK_UNHALTED.CORE".*[0..],
            },
            .Instructions => &.{
                // Apple A7-A15.
                "FIXED_INSTRUCTIONS".*[0..],
                // Intel Core 1th-10th, Yonah, Merom.
                "INST_RETIRED.ANY".*[0..],
            },
            .Branches => &.{
                // Apple A7-A15.
                "INST_BRANCH".*[0..],
                // Intel Core 1th-10th.
                "BR_INST_RETIRED.ALL_BRANCHES".*[0..],
                // Intel Yonah, Merom.
                "INST_RETIRED.ANY".*[0..],
            },
            .BranchMisses => &.{
                // Apple A7-A15, since iOS 15, macOS 12.
                "BRANCH_MISPRED_NONSPEC".*[0..],
                // Apple A7-A14.
                "BRANCH_MISPREDICT".*[0..],
                // Intel Core 2th-10th.
                "BR_MISP_RETIRED.ALL_BRANCHES".*[0..],
                // Intel Yonah, Merom.
                "BR_INST_RETIRED.MISPRED".*[0..],
            },
            .DataCacheMisses => &.{
                // Apple A7-A15.
                "L1D_CACHE_MISS_LD_NONSPEC".*[0..],
                // Intel Core 1th-10th, Yonah, Merom.
                "MEM_LOAD_RETIRED.LLC_MISS".*[0..],
            },
            .InstructionCacheMisses => &.{
                // Apple A7-A15.
                "L1I_CACHE_MISS_DEMAND".*[0..],
                // Intel Core 1th-10th, Yonah, Merom.
                "L1I.MISSES".*[0..],
            },
        };
    }
};

// -----------------------------------------------------------------------------
// <kperf.framework> header (reverse-engineered)
// This framework wraps some sysctl calls to communicate with the KPC in kernel.
// Most functions require root privileges, or process is "blessed".
// -----------------------------------------------------------------------------

// Cross-platform class constants.
pub const KPC_CLASS_FIXED = 0;
pub const KPC_CLASS_CONFIGURABLE = 1;
pub const KPC_CLASS_POWER = 2;
pub const KPC_CLASS_RAWPMU = 3;

// Cross-platform class mask constants.
pub const KPC_CLASS_FIXED_MASK = 1 << KPC_CLASS_FIXED;
pub const KPC_CLASS_CONFIGURABLE_MASK = 1 << KPC_CLASS_CONFIGURABLE;
pub const KPC_CLASS_POWER_MASK = 1 << KPC_CLASS_POWER;
pub const KPC_CLASS_RAWPMU_MASK = 1 << KPC_CLASS_RAWPMU;

// PMU version constants.
pub const KPC_PMU_ERROR = 0; // Error
pub const KPC_PMU_INTEL_V3 = 1; // Intel
pub const KPC_PMU_ARM_APPLE = 2; // ARM64
pub const KPC_PMU_INTEL_V2 = 3; // Old Intel
pub const KPC_PMU_ARM_V2 = 4; // Old ARM

// The maximum number of counters we could read from every class in one go.
// ARMV7: FIXED: 1, CONFIGURABLE: 4
// ARM32: FIXED: 2, CONFIGURABLE: 6
// ARM64: FIXED: 2, CONFIGURABLE: CORE_NCTRS - FIXED (6 or 8)
// x86: 32
pub const KPC_MAX_COUNTERS = 32;

// Bits for defining what to do on an action.
// Defined in https://github.com/apple/darwin-xnu/blob/main/osfmk/kperf/action.h
pub const KPERF_SAMPLER_TH_INFO = 1 << 0;
pub const KPERF_SAMPLER_TH_SNAPSHOT = 1 << 1;
pub const KPERF_SAMPLER_KSTACK = 1 << 2;
pub const KPERF_SAMPLER_USTACK = 1 << 3;
pub const KPERF_SAMPLER_PMC_THREAD = 1 << 4;
pub const KPERF_SAMPLER_PMC_CPU = 1 << 5;
pub const KPERF_SAMPLER_PMC_CONFIG = 1 << 6;
pub const KPERF_SAMPLER_MEMINFO = 1 << 7;
pub const KPERF_SAMPLER_TH_SCHEDULING = 1 << 8;
pub const KPERF_SAMPLER_TH_DISPATCH = 1 << 9;
pub const KPERF_SAMPLER_TK_SNAPSHOT = 1 << 10;
pub const KPERF_SAMPLER_SYS_MEM = 1 << 11;
pub const KPERF_SAMPLER_TH_INSCYC = 1 << 12;
pub const KPERF_SAMPLER_TK_INFO = 1 << 13;

// Maximum number of kperf action ids.
pub const KPERF_ACTION_MAX = 32;

// Maximum number of kperf timer ids.
pub const KPERF_TIMER_MAX = 8;

// x86/Arm config registers are 64-bit.
pub const kpc_config_t = u64;

// Custom KPC thread counter data.
pub const kpc_thread_data = struct {
    tid: u32,
    timestamp_0: u64,
    timestamp_1: u64,
    counters_0: [KPC_MAX_COUNTERS]u64,
    counters_1: [KPC_MAX_COUNTERS]u64,
};

/// Print current CPU identification string to the buffer (same as snprintf),
/// such as "cpu_7_8_10b282dc_46". This string can be used to locate the PMC
/// database in /usr/share/kpep.
/// @return string's length, or negative value if error occurs.
/// @note This method does not requires root privileges.
/// @details sysctl get(hw.cputype), get(hw.cpusubtype),
///                 get(hw.cpufamily), get(machdep.cpu.model)
pub extern "kperf" fn kpc_cpu_string(buf: *c_char, buf_size: usize) c_int;

/// Get the version of KPC that's being run.
/// @return See `PMU version constants` above.
/// @details sysctl get(kpc.pmu_version)
pub extern "kperf" fn kpc_pmu_version() u32;

/// Get running PMC classes.
/// @return See `class mask constants` above,
///         0 if error occurs or no class is set.
/// @details sysctl get(kpc.counting)
pub extern "kperf" fn kpc_get_counting() u32;

/// Set PMC classes to enable counting.
/// @param classes See `class mask constants` above, set 0 to shutdown counting.
/// @return 0 for success.
/// @details sysctl set(kpc.counting)
pub extern "kperf" fn kpc_set_counting(classes: u32) c_int;

/// Get running PMC classes for current thread.
/// @return See `class mask constants` above,
///         0 if error occurs or no class is set.
/// @details sysctl get(kpc.thread_counting)
pub extern "kperf" fn kpc_get_thread_counting() u32;

/// Set PMC classes to enable counting for current thread.
/// @param classes See `class mask constants` above, set 0 to shutdown counting.
/// @return 0 for success.
/// @details sysctl set(kpc.thread_counting)
pub extern "kperf" fn kpc_set_thread_counting(classes: u32) c_int;

/// Get how many config registers there are for a given mask.
/// For example: Intel may returns 1 for `KPC_CLASS_FIXED_MASK`,
///                        returns 4 for `KPC_CLASS_CONFIGURABLE_MASK`.
/// @param classes See `class mask constants` above.
/// @return 0 if error occurs or no class is set.
/// @note This method does not requires root privileges.
/// @details sysctl get(kpc.config_count)
pub extern "kperf" fn kpc_get_config_count(classes: u32) u32;

/// Get config registers.
/// @param classes see `class mask constants` above.
/// @param config Config buffer to receive values, should not smaller than
///               kpc_get_config_count(classes) * @sizeOf(kpc_config_t).
/// @return 0 for success.
/// @details sysctl get(kpc.config_count), get(kpc.config)
pub extern "kperf" fn kpc_get_config(classes: u32, config: *kpc_config_t) c_int;

/// Set config registers.
/// @param classes see `class mask constants` above.
/// @param config Config buffer, should not smaller than
///               kpc_get_config_count(classes) * @sizeOf(kpc_config_t).
/// @return 0 for success.
/// @details sysctl get(kpc.config_count), set(kpc.config)
pub extern "kperf" fn kpc_set_config(classes: u32, config: *kpc_config_t) c_int;

/// Get how many counters there are for a given mask.
/// For example: Intel may returns 3 for `KPC_CLASS_FIXED_MASK`,
///                        returns 4 for `KPC_CLASS_CONFIGURABLE_MASK`.
/// @param classes See `class mask constants` above.
/// @note This method does not requires root privileges.
/// @details sysctl get(kpc.counter_count)
pub extern "kperf" fn kpc_get_counter_count(classes: u32) u32;

/// Get counter accumulations.
/// If `all_cpus` is true, the buffer count should not smaller than
/// (cpu_count * counter_count). Otherwise, the buffer count should not smaller
/// than (counter_count).
/// @see kpc_get_counter_count(), kpc_cpu_count().
/// @param all_cpus true for all CPUs, false for current cpu.
/// @param classes See `class mask constants` above.
/// @param curcpu A pointer to receive current cpu id, can be NULL.
/// @param buf Buffer to receive counter's value.
/// @return 0 for success.
/// @details sysctl get(hw.ncpu), get(kpc.counter_count), get(kpc.counters)
pub extern "kperf" fn kpc_get_cpu_counters(all_cpus: bool, classes: u32, curcpu: *c_int, buf: *u64) c_int;

/// Get counter accumulations for current thread.
/// @param tid Thread id, should be 0.
/// @param buf_count The number of buf's elements (not bytes),
///                  should not smaller than kpc_get_counter_count().
/// @param buf Buffer to receive counter's value.
/// @return 0 for success.
/// @details sysctl get(kpc.thread_counters)
pub extern "kperf" fn kpc_get_thread_counters(tid: u32, buf_count: u32, buf: *u64) c_int;

/// Acquire/release the counters used by the Power Manager.
/// @param val 1:acquire, 0:release
/// @return 0 for success.
/// @details sysctl set(kpc.force_all_ctrs)
pub extern "kperf" fn kpc_force_all_ctrs_set(val: c_int) c_int;

/// Get the state of all_ctrs.
/// @return 0 for success.
/// @details sysctl get(kpc.force_all_ctrs)
pub extern "kperf" fn kpc_force_all_ctrs_get(val_out: *c_int) c_int;

/// Set number of actions, should be `KPERF_ACTION_MAX`.
/// @details sysctl set(kperf.action.count)
pub extern "kperf" fn kperf_action_count_set(count: u32) c_int;

/// Get number of actions.
/// @details sysctl get(kperf.action.count)
pub extern "kperf" fn kperf_action_count_get(count: *u32) c_int;

/// Set what to sample when a trigger fires an action, e.g. `KPERF_SAMPLER_PMC_CPU`.
/// @details sysctl set(kperf.action.samplers)
pub extern "kperf" fn kperf_action_samplers_set(action_id: u32, sample: u32) c_int;

/// Get what to sample when a trigger fires an action.
/// @details sysctl get(kperf.action.samplers)
pub extern "kperf" fn kperf_action_samplers_get(action_id: u32, sample: u32) c_int;

/// Apply a task filter to the action, -1 to disable filter.
/// @details sysctl set(kperf.action.filter_by_task)
pub extern "kperf" fn kperf_action_filter_set_by_task(action_id: u32, port: i32) c_int;

/// Apply a pid filter to the action, -1 to disable filter.
/// @details sysctl set(kperf.action.filter_by_pid)
pub extern "kperf" fn kperf_action_filter_set_by_pid(action_id: u32, pid: i32) c_int;

/// Set number of time triggers, should be `KPERF_TIMER_MAX`.
/// @details sysctl set(kperf.timer.count)
pub extern "kperf" fn kperf_timer_count_set(count: u32) c_int;

/// Get number of time triggers.
/// @details sysctl get(kperf.timer.count)
pub extern "kperf" fn kperf_timer_count_get(count: *u32) c_int;

/// Set timer number and period.
/// @details sysctl set(kperf.timer.period)
pub extern "kperf" fn kperf_timer_period_set(action_id: u32, tick: u64) c_int;

/// Get timer number and period.
/// @details sysctl get(kperf.timer.period)
pub extern "kperf" fn kperf_timer_period_get(action_id: u32, tick: *u64) c_int;

/// Set timer ID and action ID.
/// @details sysctl set(kperf.timer.action)
pub extern "kperf" fn kperf_timer_action_set(action_id: u32, timer_id: u32) c_int;

/// Get timer ID and action ID.
/// @details sysctl get(kperf.timer.action)
pub extern "kperf" fn kperf_timer_action_get(action_id: u32, timer_id: *u32) c_int;

/// Set which timer ID does PET (Profile Every Thread).
/// @details sysctl set(kperf.timer.pet_timer)
pub extern "kperf" fn kperf_timer_pet_set(timer_id: u32) c_int;

/// Get which timer ID does PET (Profile Every Thread).
/// @details sysctl get(kperf.timer.pet_timer)
pub extern "kperf" fn kperf_timer_pet_get(timer_id: *u32) c_int;

/// Enable or disable sampling.
/// @details sysctl set(kperf.sampling)
pub extern "kperf" fn kperf_sample_set(enabled: u32) c_int;

/// Get is currently sampling.
/// @details sysctl get(kperf.sampling)
pub extern "kperf" fn kperf_sample_get(enabled: *u32) c_int;

/// Reset kperf: stop sampling, kdebug, timers and actions.
/// @return 0 for success.
pub extern "kperf" fn kperf_reset() c_int;

/// Nanoseconds to CPU ticks.
pub extern "kperf" fn kperf_ns_to_ticks(ns: u64) u64;

/// CPU ticks to nanoseconds.
pub extern "kperf" fn kperf_ticks_to_ns(ticks: u64) u64;

/// CPU ticks frequency (mach_absolute_time).
pub extern "kperf" fn kperf_tick_frequency() u64;

/// Get lightweight PET mode (not in kperf.framework).
pub fn kperf_lightweight_pet_get(enabled: *u32) c_int {
    if (!enabled) return -1;
    var size: usize = 4;
    return std.c.sysctlbyname("kperf.lightweight_pet", enabled, &size, null, 0);
}

/// Set lightweight PET mode (not in kperf.framework).
pub fn kperf_lightweight_pet_set(enabled: u32) c_int {
    var new_enabled = enabled;
    return std.c.sysctlbyname("kperf.lightweight_pet", null, null, @ptrCast(&new_enabled), 4);
}

// -----------------------------------------------------------------------------
// <kperfdata.framework> header (reverse-engineered)
// This framework provides some functions to access the local CPU database.
// These functions do not require root privileges.
// -----------------------------------------------------------------------------

// KPEP CPU architecture constants.
pub const KPEP_ARCH_I386 = 0;
pub const KPEP_ARCH_X86_64 = 1;
pub const KPEP_ARCH_ARM = 2;
pub const KPEP_ARCH_ARM64 = 3;

/// KPEP event (size: 48/28 bytes on 64/32 bit OS).
pub const kpep_event = struct {
    /// Unique name of a event, such as "INST_RETIRED.ANY".
    name: *c_char,
    /// Description for this event.
    description: *c_char,
    /// Errata, currently NULL.
    errata: *c_char,
    /// Alias name, such as "Instructions", "Cycles".
    alias: *c_char,
    /// Fallback event name for fixed counter.
    fallback: *c_char,
    mask: u32,
    number: u8,
    umask: u8,
    reserved: u8,
    is_fixed: u8,
};

/// KPEP database (size: 144/80 bytes on 64/32 bit OS).
pub const kpep_db = struct {
    /// Database name, such as "haswell".
    name: *c_char,
    /// Plist name, such as "cpu_7_8_10b282dc".
    cpu_id: *c_char,
    /// Marketing name, such as "Intel Haswell".
    marketing_name: *c_char,
    /// Plist data (CFDataRef), currently NULL.
    plist_data: *anyopaque,
    /// All events (CFDict<CFSTR(event_name), kpep_event *>).
    event_map: *anyopaque,
    /// Event struct buffer (@sizeOf(kpep_event) * events_count).
    event_arr: *kpep_event,
    /// Fixed counter events (@sizeOf(kpep_event *) * fixed_counter_count).
    fixed_event_arr: **kpep_event,
    /// All aliases (CFDict<CFSTR(event_name), kpep_event *>).
    alias_map: *anyopaque,
    reserved_1: usize,
    reserved_2: usize,
    reserved_3: usize,
    /// All events count.
    event_count: usize,
    alias_count: usize,
    fixed_counter_count: usize,
    config_counter_count: usize,
    power_counter_count: usize,
    /// See `KPEP CPU architecture constants` above.
    architecture: u32,
    fixed_counter_bits: u32,
    config_counter_bits: u32,
    power_counter_bits: u32,
};

/// KPEP config (size: 80/44 bytes on 64/32 bit OS).
pub const kpep_config = struct {
    db: *kpep_db,
    /// (@sizeOf(kpep_event *) * counter_count), init NULL.
    ev_arr: *kpep_event,
    /// (@sizeOf(usize *) * counter_count), init 0.
    ev_map: *usize,
    /// (@sizeOf(usize *) * counter_count), init -1.
    ev_idx: *usize,
    /// (@sizeOf(u32 *) * counter_count), init 0.
    flags: *u32,
    /// (@sizeOf(u64 *) * counter_count), init 0.
    kpc_periods: *u64,
    /// kpep_config_events_count().
    event_count: usize,
    counter_count: usize,
    /// See `class mask constants` above.
    classes: u32,
    config_counter: u32,
    power_counter: u32,
    reserved: u32,
};

/// Error code for kpep_config_xxx() and kpep_db_xxx() functions.
pub const kpep_config_error_code = enum {
    None,
    InvalidArgument,
    OutOfMemory,
    Io,
    BufferTooSmall,
    CurrentSystemUnknown,
    DatabasePathInvalid,
    DatabaseNotFound,
    DatabaseArchitectureUnsupported,
    DatabaseVersionUnsupported,
    DatabaseCorrupt,
    EventNotFound,
    ConflictingEvents,
    CountersNotForced,
    EventUnavailable,
    CheckErrno,

    pub fn toError(self: kpep_config_error_code) KpepConfigError {
        return switch (self) {
            .None => KpepConfigError.None,
            .InvalidArgument => KpepConfigError.InvalidArgument,
            .OutOfMemory => KpepConfigError.OutOfMemory,
            .Io => KpepConfigError.Io,
            .BufferTooSmall => KpepConfigError.BufferTooSmall,
            .CurrentSystemUnknown => KpepConfigError.CurrentSystemUnknown,
            .DatabasePathInvalid => KpepConfigError.DatabasePathInvalid,
            .DatabaseNotFound => KpepConfigError.DatabaseNotFound,
            .DatabaseArchitectureUnsupported => KpepConfigError.DatabaseArchitectureUnsupported,
            .DatabaseVersionUnsupported => KpepConfigError.DatabaseVersionUnsupported,
            .DatabaseCorrupt => KpepConfigError.DatabaseCorrupt,
            .EventNotFound => KpepConfigError.EventNotFound,
            .ConflictingEvents => KpepConfigError.ConflictingEvents,
            .CountersNotForced => KpepConfigError.CountersNotForced,
            .EventUnavailable => KpepConfigError.EventUnavailable,
            .CheckErrno => KpepConfigError.CheckErrno,
        };
    }
};

pub const KpepConfigError = error{
    None,
    InvalidArgument,
    OutOfMemory,
    Io,
    BufferTooSmall,
    CurrentSystemUnknown,
    DatabasePathInvalid,
    DatabaseNotFound,
    DatabaseArchitectureUnsupported,
    DatabaseVersionUnsupported,
    DatabaseCorrupt,
    EventNotFound,
    ConflictingEvents,
    CountersNotForced,
    EventUnavailable,
    CheckErrno,
};

/// Create a config.
/// @param db A kpep db, see kpep_db_create()
/// @param cfg_ptr A pointer to receive the new config.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_create(db: ?*kpep_db, cfg_ptr: *?*kpep_config) c_int;

/// Free the config.
pub extern "kperfdata" fn kpep_config_free(cfg: ?*kpep_config) void;

/// Add an event to config.
/// @param cfg The config.
/// @param ev_ptr A event pointer.
/// @param flag 0: all, 1: user space only
/// @param err Error bitmap pointer, can be NULL.
///            If return value is `CONFLICTING_EVENTS`, this bitmap contains
///            the conflicted event indices, e.g. "1 << 2" means index 2.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_add_event(cfg: ?*kpep_config, ev_ptr: **kpep_event, flag: u32, err: ?*u32) c_int;

/// Remove event at index.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_remove_event(cfg: ?*kpep_config, idx: usize) c_int;

/// Force all counters.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_force_counters(cfg: ?*kpep_config) c_int;

/// Get events count.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_events_count(cfg: ?*kpep_config, count_ptr: *usize) c_int;

/// Get all event pointers.
/// @param buf A buffer to receive event pointers.
/// @param buf_size The buffer's size in bytes, should not smaller than
///                 kpep_config_events_count() * @sizeOf(*anyopaque).
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_events(cfg: ?*kpep_config, buf: **kpep_event, buf_size: usize) c_int;

/// Get kpc register configs.
/// @param buf A buffer to receive kpc register configs.
/// @param buf_size The buffer's size in bytes, should not smaller than
///                 kpep_config_kpc_count() * @sizeOf(kpc_config_t).
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_kpc(cfg: ?*kpep_config, buf: *kpc_config_t, buf_size: usize) c_int;

/// Get kpc register config count.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_kpc_count(cfg: ?*kpep_config, count_ptr: *usize) c_int;

/// Get kpc classes.
/// @param classes See `class mask constants` above.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_kpc_classes(cfg: ?*kpep_config, classes_ptr: *u32) c_int;

/// Get the index mapping from event to counter.
/// @param buf A buffer to receive indexes.
/// @param buf_size The buffer's size in bytes, should not smaller than
///                 kpep_config_events_count() * @sizeOf(kpc_config_t).
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_config_kpc_map(cfg: ?*kpep_config, buf: *usize, buf_size: usize) c_int;

/// Open a kpep database file in "/usr/share/kpep/" or "/usr/local/share/kpep/".
/// @param name File name, for example "haswell", "cpu_100000c_1_92fb37c8".
///             Pass NULL for current CPU.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_db_create(name: ?*const c_char, db_ptr: *?*kpep_db) c_int;

/// Free the kpep database.
pub extern "kperfdata" fn kpep_db_free(db: ?*kpep_db) void;

/// Get the database's name.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_db_name(db: ?*kpep_db, name: *const *const c_char) c_int;

/// Get the event alias count.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_db_aliases_count(db: ?*kpep_db, count: *usize) c_int;

/// Get all alias.
/// @param buf A buffer to receive all alias strings.
/// @param buf_size The buffer's size in bytes,
///        should not smaller than kpep_db_aliases_count() * @sizeOf(*anyopaque).
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_db_aliases(db: ?*kpep_db, buf: *const *const c_char, buf_size: usize) c_int;

/// Get counters count for given classes.
/// @param classes 1: Fixed, 2: Configurable.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_db_counters_count(db: ?*kpep_db, classes: u8, count: *usize) c_int;

/// Get all event count.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_db_events_count(db: ?*kpep_db, count: *usize) c_int;

/// Get all events.
/// @param buf A buffer to receive all event pointers.
/// @param buf_size The buffer's size in bytes,
///        should not smaller than kpep_db_events_count() * @sizeOf(*anyopaque).
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_db_events(db: ?*kpep_db, buf: **kpep_event, buf_size: usize) c_int;

/// Get one event by name.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_db_event(db: ?*kpep_db, name: *const c_char, ev_ptr: *?*kpep_event) c_int;

/// Get event's name.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_event_name(ev: *kpep_event, name_ptr: *const *const c_char) c_int;

/// Get event's alias.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_event_alias(ev: *kpep_event, alias_ptr: *const *const c_char) c_int;

/// Get event's description.
/// @return kpep_config_error_code, 0 for success.
pub extern "kperfdata" fn kpep_event_description(ev: *kpep_event, str_ptr: *const *const c_char) c_int;

// ------------------------------------------------------------------------------
// kdebug private structs
// https://github.com/apple/darwin-xnu/blob/main/bsd/sys_private/kdebug_private.h
// ------------------------------------------------------------------------------

// Ensure that both ILP32 and LP64 variants of aarch64 use the same kd_buf structure.
pub const kd_buf_argtype = if (builtin.cpu.arch.isAARCH64()) u64 else usize;

pub const kd_buf = extern struct {
    timestamp: u64,
    arg1: kd_buf_argtype,
    arg2: kd_buf_argtype,
    arg3: kd_buf_argtype,
    arg4: kd_buf_argtype,
    arg5: kd_buf_argtype, // thread ID
    debug_id: u32, // see <sys/kdebug.h>
    // Ensure that both ILP32 and LP64 variants of aarch64 use the same kd_buf structure.
    cpuid: if (@sizeOf(usize) == 64 or builtin.cpu.arch.isAARCH64()) u32 else void, // CPU index
    unused: if (@sizeOf(usize) == 64 or builtin.cpu.arch.isAARCH64()) kd_buf_argtype else void,
};

// Bits for the type field of kd_regtype.
pub const KDBG_CLASSTYPE = 0x10000;
pub const KDBG_SUBCLSTYPE = 0x20000;
pub const KDBG_RANGETYPE = 0x40000;
pub const KDBG_TYPENONE = 0x80000;
pub const KDBG_CKTYPES = 0xF0000;

// Only trace at most 4 types of events, at the code granularity.
pub const KDBG_VALCHECK = 0x00200000;

// Debugid sub-classes and code from XNU source.
pub const PERF_KPC = 6;
pub const PERF_KPC_DATA_THREAD = 8;

pub const kd_regtype = extern struct {
    type: c_uint,
    value1: c_uint,
    value2: c_uint,
    value3: c_uint,
    value4: c_uint,
};

pub const kbufinfo_t = extern struct {
    /// number of events that can fit in the buffers.
    nkdbufs: c_int,
    /// set if trace is disabled.
    nolog: c_int,
    /// kd_ctrl_page.flags.
    flags: c_uint,
    /// number of threads in thread map.
    nkdthreads: c_int,
    /// the owning pid.
    bufid: c_int,
};

/// Clean up trace buffers and reset ktrace/kdebug/kperf.
/// @return 0 on success.
pub fn kdebug_reset() c_int {
    const mib: [3]c_int = .{ c.CTL_KERN, c.KERN_KDEBUG, c.KERN_KDREMOVE };
    return std.c.sysctl(&mib, 3, null, null, null, 0);
}

/// Disable and reinitialize the trace buffers.
/// @return 0 on success.
pub fn kdebug_reinit() c_int {
    const mib: [3]c_int = .{ c.CTL_KERN, c.KERN_KDEBUG, c.KERN_KDSETUP };
    return std.c.sysctl(&mib, 3, null, null, null, 0);
}

/// Set debug filter.
pub fn kdebug_setreg(kdr: *kd_regtype) c_int {
    const mib: [3]c_int = .{ c.CTL_KERN, c.KERN_KDEBUG, c.KERN_KDSETREG };
    var size: usize = @sizeOf(kd_regtype);
    return std.c.sysctl(&mib, 3, kdr, &size, null, 0);
}

/// Set maximum number of trace entries (kd_buf).
/// Only allow allocation up to half the available memory (sane_size).
/// @return 0 on success.
pub fn kdebug_trace_setbuf(num_bufs: c_int) c_int {
    const mib: [4]c_int = .{ c.CTL_KERN, c.KERN_KDEBUG, c.KERN_KDSETBUF, num_bufs };
    return std.c.sysctl(&mib, 4, null, null, null, 0);
}

/// Enable or disable kdebug trace.
/// Trace buffer must already be initialized.
/// @return 0 on success.
pub fn kdebug_trace_enable(enable: c_int) c_int {
    const mib: [4]c_int = .{ c.CTL_KERN, c.KERN_KDEBUG, c.KERN_KDENABLE, enable };
    return std.c.sysctl(&mib, 4, null, null, null, 0);
}

/// Retrieve trace buffer information from kernel.
/// @return 0 on success.
pub fn kdebug_get_bufinfo(info: *kbufinfo_t) c_int {
    const mib: [3]c_int = .{ c.CTL.KERN, c.KERN_KDEBUG, c.KERN_KDGETBUF };
    var needed: usize = @sizeOf(kbufinfo_t);
    return std.c.sysctl(&mib, 3, info, &needed, null, 0);
}

/// Retrieve trace buffers from kernel.
/// @param buf Memory to receive buffer data, array of `kd_buf`.
/// @param len Length of `buf` in bytes.
/// @param count Number of trace entries (kd_buf) obtained.
/// @return 0 on success.
pub fn kdebug_trace_read(buf: *anyopaque, byte_size: usize, count: *usize) c_int {
    if (byte_size == 0) return -1;
    // Note: the input and output units are not the same.
    // input: bytes
    // output: number of kd_buf
    const mib: [3]c_int = .{ c.CTL_KERN, c.KERN_KDEBUG, c.KERN_KDREADTR };
    var len = byte_size;
    const ret = std.c.sysctl(&mib, 3, buf, &len, null, 0);
    count.* = len;
    return ret;
}

/// Block until there are new buffers filled or `timeout_ms` have passed.
/// @param timeout_ms timeout milliseconds, 0 means wait forever.
/// @param suc set true if new buffers filled.
/// @return 0 on success.
pub fn kdebug_wait(timeout_ms: usize, suc: *bool) c_int {
    if (timeout_ms == 0) return -1;
    const mib: [3]c_int = .{ c.CTL_KERN, c.KERN_KDEBUG, c.KERN_KDBUFWAIT };
    var val = timeout_ms;
    const ret = std.c.sysctl(&mib, 3, null, &val, null, 0);
    suc.* = val != 0;
    return ret;
}
