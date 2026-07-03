// Cross-platform synchronization primitives for the httpz thread pool.
//
// On Windows, uses SRWLOCK + CONDITION_VARIABLE instead of Io.Mutex/Io.Condition.
// Io.Condition on Windows uses NtWaitForAlertByThreadId (via parking_futex), which
// can be spuriously woken by any code in the process that calls NtAlertThreadByThreadId
// with our thread's ID. The DeltaV/Hawk runtime does this for its own IPC, causing
// all httpz worker threads to spin at ~12% CPU after the first DeltaV call.
//
// SRWLOCK + CONDITION_VARIABLE use RtlWaitOnAddress-based notifications internally
// and are not affected by NtAlertThreadByThreadId, making them the correct primitive
// for blocking worker threads in this environment.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const native_os = builtin.os.tag;

pub const Mutex = if (native_os == .windows) WinMutex else IoMutex;
pub const Condition = if (native_os == .windows) WinCondition else IoCondition;

// ── Windows implementation ────────────────────────────────────────────────────

const windows = std.os.windows;

// RtlSleepConditionVariableSRW is available in ntdll but not yet in Zig's stdlib bindings.
// NOTE: kernel32's SleepConditionVariableSRW is used here (not the ntdll Rtl variant)
// because the ntdll version takes a LARGE_INTEGER* timeout whereas the kernel32 version
// takes a plain DWORD, matching the documented Win32 API.
extern "kernel32" fn SleepConditionVariableSRW(
    ConditionVariable: *windows.CONDITION_VARIABLE,
    SRWLock: *windows.SRWLOCK,
    dwMilliseconds: windows.DWORD,
    Flags: windows.ULONG,
) callconv(.winapi) windows.BOOL;

const WinMutex = struct {
    srwlock: windows.SRWLOCK = windows.SRWLOCK_INIT,

    pub const init: WinMutex = .{};

    pub inline fn lockUncancelable(self: *WinMutex, io: Io) void {
        _ = io;
        windows.ntdll.RtlAcquireSRWLockExclusive(&self.srwlock);
    }

    pub inline fn unlock(self: *WinMutex, io: Io) void {
        _ = io;
        windows.ntdll.RtlReleaseSRWLockExclusive(&self.srwlock);
    }
};

const WinCondition = struct {
    cv: windows.CONDITION_VARIABLE = windows.CONDITION_VARIABLE_INIT,

    pub const init: WinCondition = .{};

    pub inline fn waitUncancelable(self: *WinCondition, io: Io, mutex: *WinMutex) void {
        _ = io;
        // INFINITE = 0xFFFFFFFF; Flags = 0 means exclusive (non-shared) lock
        _ = SleepConditionVariableSRW(&self.cv, &mutex.srwlock, 0xFFFFFFFF, 0);
    }

    pub inline fn signal(self: *WinCondition, io: Io) void {
        _ = io;
        windows.ntdll.RtlWakeConditionVariable(&self.cv);
    }

    pub inline fn broadcast(self: *WinCondition, io: Io) void {
        _ = io;
        windows.ntdll.RtlWakeAllConditionVariable(&self.cv);
    }
};

// ── Non-Windows fallback (thin wrappers over Io.Mutex / Io.Condition) ─────────

const IoMutex = struct {
    inner: Io.Mutex = .init,

    pub const init: IoMutex = .{};

    pub inline fn lockUncancelable(self: *IoMutex, io: Io) void {
        self.inner.lockUncancelable(io);
    }

    pub inline fn unlock(self: *IoMutex, io: Io) void {
        self.inner.unlock(io);
    }
};

const IoCondition = struct {
    inner: Io.Condition = .init,

    pub const init: IoCondition = .{};

    pub inline fn waitUncancelable(self: *IoCondition, io: Io, mutex: *IoMutex) void {
        self.inner.waitUncancelable(io, &mutex.inner);
    }

    pub inline fn signal(self: *IoCondition, io: Io) void {
        self.inner.signal(io);
    }

    pub inline fn broadcast(self: *IoCondition, io: Io) void {
        self.inner.broadcast(io);
    }
};
