const std = @import("std");
const Context = @import("Context.zig");
const syscall = @import("syscall.zig");
const Address = @import("Address.zig");
const Errno = syscall.Errno;
const Ring = @import("Ring.zig");

const Listener = @This();

FD: i32,
address_len: u32,
address_ptr: *Address,

pub const Protocol = syscall.Socket.Protocol;

pub fn listenTCP(listener_ptr: *Listener, address_ptr: *Address) !void {
    var result: usize = syscall.socket(address_ptr.data.family_id, .{ .type = .stream }, .TCP);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));

    const FD: i32 = @intCast(result);

    const address_len: u32 = address_ptr.getLength();

    result = syscall.bind(FD, &address_ptr.data, address_len);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));

    result = syscall.listen(FD, 512);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));

    listener_ptr.* = .{ .FD = FD, .address_len = address_len, .address_ptr = address_ptr };
}

pub fn close(listener_ptr: *Listener) !void {
    const result: usize = syscall.close(listener_ptr.FD);
    if (result > syscall.result_max) return Errno.toError(@enumFromInt(0 -% result));
}

pub fn accept(listener_ptr: *Listener) !Connection {
    const result: usize = syscall.accept(listener_ptr.FD, &listener_ptr.address_ptr.data, &listener_ptr.address_len, 0);
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
