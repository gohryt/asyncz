const std = @import("std");
const Context = @import("Context.zig");
const syscall = @import("syscall.zig");
const Errno = syscall.Errno;
const Ring = @import("Ring.zig");

FD: i32 = 0,
address: *syscall.SocketAddress,
address_length: u32,

const Listener = @This();

pub fn listen(listener_ptr: *Listener, address: *syscall.SocketAddress, address_length: u32) !void {
    var result: usize = syscall.socket(.internet4, 1, 0);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));

    const FD: i32 = @intCast(result);

    result = syscall.bind(FD, address, address_length);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));

    result = syscall.listen(FD, 512);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));

    listener_ptr.* = .{ .FD = FD, .address = address, .address_length = address_length };
}

pub fn close(listener_ptr: *Listener) !void {
    const result: usize = syscall.close(listener_ptr.FD);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));
}

pub fn accept(listener_ptr: *Listener) !Connection {
    const result: usize = syscall.accept(listener_ptr.FD, listener_ptr.address, &listener_ptr.address_length, 0);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));

    return .{ .FD = @intCast(result) };
}

pub const Connection: type = struct {
    FD: i32,

    pub fn close(connection_ptr: *Connection) !void {
        const result: usize = syscall.close(connection_ptr.FD);
        if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));
    }

    pub fn read(connection_ptr: *Connection, buffer: []u8) !usize {
        const result: usize = syscall.recv(connection_ptr.FD, buffer, 0, null, null);
        if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));
        return result;
    }

    pub fn write(connection_ptr: *Connection, buffer: []u8) !usize {
        const result: usize = syscall.send(connection_ptr.FD, buffer, 0, null, 0);
        if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));
        return result;
    }
};
