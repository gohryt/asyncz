const std = @import("std");
const mem = std.mem;
const Context = @import("Context.zig");
const syscall = @import("syscall.zig");
const Errno = syscall.Errno;

pub const SQE = syscall.Ring.SubmissionQueue.Entry;
pub const CQE = syscall.Ring.CompletionQueue.Entry;
pub const Params = syscall.Ring.Params;
pub const EnterFlags = syscall.Ring.EnterFlags;
pub const SubmissionQueueFlags = syscall.Ring.SubmissionQueue.Flags;

const Ring = @This();

pub const Result = struct {
    context_ptr: *Context,
    value: i32 = 0,
    flags: u32 = 0,
};

FD: i32,
flags: Params.Flags,
features: Params.Features,
SQ: struct {
    const SQ = @This();

    ring: []u8,
    SQEs: []SQE,
    k_head: *u32,
    k_tail: *u32,
    k_flags: *u32,
    k_dropped: *u32,

    head: u32,
    tail: u32,
    ring_mask: u32,

    pub fn needsWakeup(SQ_ptr: *SQ) bool {
        const flags: SubmissionQueueFlags = @bitCast(@atomicLoad(u32, SQ_ptr.k_flags, .acquire));
        return flags.need_wakeup;
    }
},
CQ: struct {
    const CQ = @This();

    ring: []u8,
    CQEs: []CQE,
    k_head: *u32,
    k_tail: *u32,
    k_overflow: *u32,
    k_flags: *u32,

    ring_mask: u32,

    pub fn readyCount(CQ_ptr: *CQ) u32 {
        return @atomicLoad(u32, CQ_ptr.k_tail, .acquire) -% @atomicLoad(u32, CQ_ptr.k_head, .acquire);
    }
},
queued: usize,

const Operation = union(enum) {
    nop: Nop,
    openat: Openat,
    statx: Statx,
    read: Read,
    write: Write,
    accept: Accept,
    recv: Recv,
    send: Send,
    close: Close,

    pub const Nop = void;

    pub const Openat = struct {
        directory_FD: i32,
        path: [*:0]u8,
        flags: syscall.File.Flags,
        mode: syscall.Mode,
    };

    pub const Statx = struct {
        directory_FD: i32,
        path: [*:0]u8,
        flags: syscall.At,
        mask: syscall.Statx.Mask,
        statx_ptr: *syscall.Statx,
    };

    pub const Read = struct {
        FD: i32,
        buffer: []u8,
        offset: u64,
    };

    pub const Write = struct {
        FD: i32,
        buffer: []u8,
        offset: u64,
    };

    pub const Accept = struct {
        FD: i32,
        socket_ptr: *syscall.Socket.Address,
        socket_len: *u32,
        flags: u32,
    };

    pub const Recv = struct {
        flags: u32,
        FD: i32,
        buffer: []u8,
    };

    pub const Send = struct {
        flags: u32,
        FD: i32,
        buffer: []u8,
    };

    pub const Close = struct {
        FD: i32,
    };
};

pub const IOPoll = void;
pub const SQPoll = struct {
    thread_idle: u32, // in milliseconds
};
pub const SQAffinity = struct {
    thread_CPU: u32,
};
pub const CQEntries = u32;
pub const AttachWQ = struct {
    WQ_FD: i32,
};

pub const Error = error{
    InnerInit,
    SQOverflow,
};

pub const max_entries: u32 = 4096;

pub fn init(ring_ptr: *Ring, entries: u32, options: anytype) !void {
    var params: Params = mem.zeroInit(Params, .{
        .flags = .{ .no_SQ_array = true },
    });

    const Options: type = @TypeOf(options);
    const options_type_info: std.builtin.Type = @typeInfo(Options);

    if (options_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(Options));
    }

    inline for (options_type_info.@"struct".fields) |field| {
        switch (field.type) {
            IOPoll => {
                params.flags.IO_poll = true;
            },
            SQPoll => {
                const SQ_poll: SQPoll = @field(options, field.name);
                params.flags.SQ_poll = true;
                params.submission_queue_thread_idle = SQ_poll.thread_idle;
            },
            SQAffinity => {
                const SQ_affinity: SQAffinity = @field(options, field.name);
                params.flags.SQ_affinity = true;
                params.SQ_thread_CPU = SQ_affinity.thread_CPU;
            },
            CQEntries => {
                const CQ_entries: u32 = @field(options, field.name);
                params.flags.CQ_entries = true;
                params.CQ_entries = CQ_entries;
            },
            AttachWQ => {
                const attach_WQ: bool = @field(options, field.name);
                params.flags.attach_WQ = true;
                params.WQ_FD = attach_WQ.WQ_FD;
            },
            else => {
                @compileError("expected tuple or struct argument, found " ++ @typeName(Options));
            },
        }
    }

    const result: usize = syscall.Ring.setup(entries, &params);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));
    errdefer _ = syscall.close(@intCast(result));

    try innerInit(ring_ptr, @intCast(result), &params);
}

pub fn deinit(ring_ptr: *Ring) void {
    ring_ptr.innerDeinit();
    _ = syscall.close(ring_ptr.FD);
}

pub fn queue(ring_ptr: *Ring, operation: Operation, flags: u8, user_data: u64) !void {
    const SQE_ptr: *SQE = try ring_ptr.nextSQE();

    switch (operation) {
        .nop => {
            SQE_ptr.* = .{
                .opcode = .nop,
                .flags = flags,
                .FD = -1,
                .user_data = user_data,
            };
        },
        .openat => |openat| {
            SQE_ptr.* = .{
                .opcode = .openat,
                .flags = flags,
                .FD = openat.directory_FD,
                .union_2 = .{ .address = @intFromPtr(openat.path) },
                .length = @bitCast(openat.mode),
                .union_3 = .{ .file_flags = openat.flags },
                .user_data = user_data,
            };
        },
        .statx => |statx| {
            SQE_ptr.* = .{
                .opcode = .statx,
                .flags = flags,
                .FD = statx.directory_FD,
                .union_1 = .{ .offset = @intFromPtr(statx.statx_ptr) },
                .union_2 = .{ .address = @intFromPtr(statx.path) },
                .length = @bitCast(statx.mask),
                .union_3 = .{ .statx_flags = @bitCast(statx.flags) },
                .user_data = user_data,
            };
        },
        .read => |read| {
            SQE_ptr.* = .{
                .opcode = .read,
                .flags = flags,
                .FD = read.FD,
                .union_1 = .{ .offset = read.offset },
                .union_2 = .{ .address = @intFromPtr(read.buffer.ptr) },
                .length = @intCast(read.buffer.len),
                .user_data = user_data,
            };
        },
        .write => |write| {
            SQE_ptr.* = .{
                .opcode = .write,
                .flags = flags,
                .FD = write.FD,
                .union_1 = .{ .offset = write.offset },
                .union_2 = .{ .address = @intFromPtr(write.buffer.ptr) },
                .length = @intCast(write.buffer.len),
                .user_data = user_data,
            };
        },
        .accept => |accept| {
            SQE_ptr.* = .{
                .opcode = .accept,
                .flags = flags,
                .FD = accept.FD,
                .union_1 = .{ .offset = @intFromPtr(accept.socket_len) },
                .union_2 = .{ .address = @intFromPtr(accept.socket_ptr) },
                .union_3 = .{ .accept_flags = @bitCast(accept.flags) },
                .user_data = user_data,
            };
        },
        .recv => |recv| {
            SQE_ptr.* = .{
                .opcode = .recv,
                .flags = flags,
                .FD = recv.FD,
                .union_2 = .{ .address = @intFromPtr(recv.buffer.ptr) },
                .length = @intCast(recv.buffer.len),
                .union_3 = .{ .msg_flags = @bitCast(recv.flags) },
                .user_data = user_data,
            };
        },
        .send => |send| {
            SQE_ptr.* = .{
                .opcode = .send,
                .flags = flags,
                .FD = send.FD,
                .union_2 = .{ .address = @intFromPtr(send.buffer.ptr) },
                .length = @intCast(send.buffer.len),
                .union_3 = .{ .msg_flags = @bitCast(send.flags) },
                .user_data = user_data,
            };
        },
        .close => |close| {
            SQE_ptr.* = .{
                .opcode = .close,
                .flags = flags,
                .FD = close.FD,
                .user_data = user_data,
            };
        },
    }

    _ = @atomicRmw(usize, &ring_ptr.queued, .Add, 1, .release);
}

pub fn submit(ring_ptr: *Ring) !usize {
    return innerSubmitAndWait(ring_ptr, try ring_ptr.flushSQ(), 0);
}

pub fn submitAndWait(ring_ptr: *Ring, at_least: u32) !usize {
    return innerSubmitAndWait(ring_ptr, try ring_ptr.flushSQ(), at_least);
}

pub fn wait(ring_ptr: *Ring, at_least: u32) !usize {
    return innerSubmitAndWait(ring_ptr, 0, at_least);
}

pub fn peekCQEs(ring: *Ring, max: u32) ![]CQE {
    const ready_count: u32 = ring.CQ.readyCount();
    const count: u32 = min(u32, ready_count, max);

    if (ready_count > 0) {
        const head: u32 = @atomicLoad(u32, ring.CQ.k_head, .acquire) & ring.CQ.ring_mask;
        const last: u32 = head + count;

        return ring.CQ.CQEs[head..last];
    }

    return &.{};
}

fn innerSubmitAndWait(ring_ptr: *Ring, flushed: u32, at_least: u32) !usize {
    var flags: EnterFlags = .{};

    if (at_least > 0 or ring_ptr.CQNeedsEnter()) {
        flags.getevents = true;
    }

    if (ring_ptr.flags.SQ_poll) {
        if (ring_ptr.SQ.needsWakeup()) {
            flags.SQ_wakeup = true;
        } else if (at_least == 0) {
            return @intCast(flushed);
        }
    }

    const result: usize = syscall.Ring.enter(ring_ptr.FD, flushed, at_least, flags, @ptrFromInt(0), 0);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));

    return result;
}

pub fn seenSQE(ring_ptr: *Ring) void {
    ring_ptr.advanceCQ(1);
}

pub fn advanceCQ(ring_ptr: *Ring, n: u32) void {
    _ = @atomicRmw(u32, ring_ptr.CQ.k_head, .Add, n, .release);
    _ = @atomicRmw(usize, &ring_ptr.queued, .Sub, n, .release);
}

fn innerInit(ring_ptr: *Ring, FD: i32, params_ptr: *Params) !void {
    const has_single_mmap: bool = params_ptr.features.single_mmap;

    if (params_ptr.flags.no_mmap) {
        return Error.InnerInit;
    }

    var SQE_size: usize = @sizeOf(SQE);
    if (params_ptr.flags.SQE128) SQE_size <<= 1;
    var CQE_size: usize = @sizeOf(CQE);
    if (params_ptr.flags.CQE32) CQE_size <<= 1;

    var SQ_ring_len: usize = params_ptr.submission_queue_ring_offsets.array + (params_ptr.submission_queue_entries * @sizeOf(u32));
    var CQ_ring_len: usize = params_ptr.completion_queue_ring_offsets.cqes + (params_ptr.completion_queue_entries * CQE_size);

    if (has_single_mmap) {
        if (CQ_ring_len > SQ_ring_len) {
            SQ_ring_len = CQ_ring_len;
        } else {
            CQ_ring_len = SQ_ring_len;
        }
    }

    const SQ_SQEs_len: usize = params_ptr.submission_queue_entries * SQE_size;

    const SQ_ring_ptr: usize = syscall.mmap(
        null,
        SQ_ring_len,
        .{ .read = true, .write = true },
        .{ .type = .shared, .populate = true },
        FD,
        syscall.Ring.SQ_ring_offset,
    );
    if (SQ_ring_ptr > syscall.result_max) return Errno.toError(@enumFromInt(0 -% SQ_ring_ptr));
    errdefer _ = syscall.munmap(@ptrFromInt(SQ_ring_ptr), SQ_ring_len);

    const SQ_ring: []u8 = @as([*]u8, @ptrFromInt(SQ_ring_ptr))[0..SQ_ring_len];

    var CQ_ring_ptr: usize = SQ_ring_ptr;
    var CQ_ring: []u8 = SQ_ring;

    if (!has_single_mmap) {
        CQ_ring_ptr = syscall.mmap(
            null,
            CQ_ring_len,
            .{ .read = true, .write = true },
            .{ .type = .shared, .populate = true },
            FD,
            syscall.Ring.CQ_ring_offset,
        );
        if (CQ_ring_ptr > syscall.result_max) return Errno.toError(@enumFromInt(0 -% CQ_ring_ptr));
        errdefer _ = syscall.munmap(@ptrFromInt(CQ_ring_ptr), CQ_ring_len);

        CQ_ring = @as([*]u8, @ptrFromInt(CQ_ring_ptr))[0..CQ_ring_len];
    }

    const SQ_SQEs_ptr: usize = syscall.mmap(
        null,
        SQ_SQEs_len,
        .{ .read = true, .write = true },
        .{ .type = .shared, .populate = true },
        FD,
        syscall.Ring.SQ_SQEs_offset,
    );
    if (SQ_SQEs_ptr > syscall.result_max) return Errno.toError(@enumFromInt(0 -% SQ_SQEs_ptr));
    errdefer _ = syscall.munmap(@ptrFromInt(SQ_SQEs_ptr), SQ_SQEs_len);

    const SQ_SQEs: []SQE = @as([*]SQE, @ptrFromInt(SQ_SQEs_ptr))[0..params_ptr.submission_queue_entries];

    ring_ptr.* = .{
        .FD = FD,
        .flags = params_ptr.flags,
        .features = params_ptr.features,
        .SQ = .{
            .ring = SQ_ring,
            .SQEs = SQ_SQEs,

            .k_head = @as(*u32, @ptrFromInt(SQ_ring_ptr + params_ptr.submission_queue_ring_offsets.head)),
            .k_tail = @as(*u32, @ptrFromInt(SQ_ring_ptr + params_ptr.submission_queue_ring_offsets.tail)),
            .k_flags = @as(*u32, @ptrFromInt(SQ_ring_ptr + params_ptr.submission_queue_ring_offsets.flags)),
            .k_dropped = @as(*u32, @ptrFromInt(SQ_ring_ptr + params_ptr.submission_queue_ring_offsets.dropped)),

            .head = 0,
            .tail = 0,
            .ring_mask = @as(*u32, @ptrFromInt(SQ_ring_ptr + params_ptr.submission_queue_ring_offsets.ring_mask)).*,
        },
        .CQ = .{
            .ring = CQ_ring,
            .CQEs = @as([*]CQE, @ptrFromInt(CQ_ring_ptr + params_ptr.completion_queue_ring_offsets.cqes))[0..params_ptr.completion_queue_entries],

            .k_head = @as(*u32, @ptrFromInt(CQ_ring_ptr + params_ptr.completion_queue_ring_offsets.head)),
            .k_tail = @as(*u32, @ptrFromInt(CQ_ring_ptr + params_ptr.completion_queue_ring_offsets.tail)),
            .k_overflow = @as(*u32, @ptrFromInt(CQ_ring_ptr + params_ptr.completion_queue_ring_offsets.overflow)),
            .k_flags = @as(*u32, @ptrFromInt(CQ_ring_ptr + params_ptr.completion_queue_ring_offsets.flags)),

            .ring_mask = @as(*u32, @ptrFromInt(CQ_ring_ptr + params_ptr.completion_queue_ring_offsets.ring_mask)).*,
        },
        .queued = 0,
    };
}

fn innerDeinit(ring_ptr: *Ring) void {
    const SQ_ring: []u8 = ring_ptr.SQ.ring;
    const CQ_ring: []u8 = ring_ptr.CQ.ring;
    const SQ_SQEs: []SQE = ring_ptr.SQ.SQEs;

    _ = syscall.munmap(SQ_ring.ptr, SQ_ring.len);
    if (CQ_ring.ptr != SQ_ring.ptr) _ = syscall.munmap(CQ_ring.ptr, CQ_ring.len);
    _ = syscall.munmap(@ptrCast(SQ_SQEs.ptr), SQ_SQEs.len * @sizeOf(SQE));
}

fn nextSQE(ring_ptr: *Ring) !*SQE {
    const head: u32 = if (ring_ptr.flags.SQ_poll)
        @atomicLoad(u32, ring_ptr.SQ.k_head, .seq_cst)
    else
        ring_ptr.SQ.k_head.*;

    const next: u32 = ring_ptr.SQ.tail +% 1;

    if (next -% head <= ring_ptr.SQ.SQEs.len) {
        var i: u32 = (ring_ptr.SQ.tail & ring_ptr.SQ.ring_mask);
        if (ring_ptr.flags.SQE128) i <<= 1;

        ring_ptr.SQ.tail = next;

        return &ring_ptr.SQ.SQEs[i];
    } else {
        return Error.SQOverflow;
    }
}

fn flushSQ(ring_ptr: *Ring) !u32 {
    const SQ_ptr: *@TypeOf(ring_ptr.SQ) = &ring_ptr.SQ;

    const tail: u32 = SQ_ptr.tail;

    if (SQ_ptr.head != tail) {
        SQ_ptr.head = tail;

        if (ring_ptr.flags.SQ_poll) {
            @atomicStore(u32, SQ_ptr.k_tail, tail, .release);
        } else {
            SQ_ptr.k_tail.* = tail;
        }
    }

    return tail -% @atomicLoad(u32, ring_ptr.SQ.k_head, .acquire);
}

fn CQNeedsEnter(ring_ptr: *Ring) bool {
    const flags: SubmissionQueueFlags = @bitCast(@atomicLoad(u32, ring_ptr.SQ.k_flags, .acquire));
    return ring_ptr.flags.IO_poll or flags.overflow or flags.taskrun;
}

fn min(comptime Type: type, a: Type, b: Type) Type {
    return if (a < b) a else b;
}
