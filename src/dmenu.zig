const std = @import("std");
const linux = std.os.linux;

/// Sends a complete dmenu request, then half-closes the socket to signal EOF.
/// Returns the first LF-delimited line (without LF), or the final line at EOF.
/// An empty line/response means cancellation. The result borrows `response`.
/// A line longer than `response` returns error.ResponseTooLong; no allocation occurs.
pub fn choose(socket_path: []const u8, request: []const u8, response: []u8) !?[]const u8 {
    var address: linux.sockaddr.un = .{ .path = @splat(0) };
    if (socket_path.len == 0 or std.mem.indexOfScalar(u8, socket_path, 0) != null)
        return error.InvalidSocketPath;
    if (socket_path.len >= address.path.len) return error.SocketPathTooLong;
    @memcpy(address.path[0..socket_path.len], socket_path);

    const fd: linux.fd_t = @intCast(try checked(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer _ = linux.close(fd);
    while (true) {
        const result = linux.connect(fd, &address, @intCast(@offsetOf(linux.sockaddr.un, "path") + socket_path.len + 1));
        switch (linux.errno(result)) {
            .INTR => continue,
            .ISCONN => break,
            else => _ = try checked(result),
        }
        break;
    }
    return exchange(fd, request, response);
}

fn checked(result: usize) !usize {
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.SocketNotFound,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionReset,
        .PIPE => error.BrokenPipe,
        .NOMEM, .NOBUFS => error.SystemResources,
        .MFILE, .NFILE => error.TooManyOpenFiles,
        else => error.SocketFailure,
    };
}

fn sendAll(fd: linux.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const result = linux.sendto(fd, bytes[sent..].ptr, bytes.len - sent, linux.MSG.NOSIGNAL, null, 0);
        if (linux.errno(result) == .INTR) continue;
        const count = try checked(result);
        if (count == 0) return error.BrokenPipe;
        sent += count;
    }
}

fn receive(fd: linux.fd_t, bytes: []u8) !usize {
    while (true) {
        const result = linux.recvfrom(fd, bytes.ptr, bytes.len, 0, null, null);
        if (linux.errno(result) == .INTR) continue;
        return checked(result);
    }
}

fn shutdownWrite(fd: linux.fd_t) !void {
    while (true) {
        const result = linux.shutdown(fd, linux.SHUT.WR);
        if (linux.errno(result) == .INTR) continue;
        _ = try checked(result);
        return;
    }
}

fn exchange(fd: linux.fd_t, request: []const u8, response: []u8) !?[]const u8 {
    try sendAll(fd, request);
    try shutdownWrite(fd);
    var used: usize = 0;
    while (true) {
        // Probe beyond a full buffer so an exact-fit line still accepts LF or EOF.
        var extra: [1]u8 = undefined;
        const target = if (used == response.len) &extra else response[used..];
        const count = try receive(fd, target);
        if (count == 0) return if (used == 0) null else response[0..used];
        if (std.mem.indexOfScalar(u8, target[0..count], '\n')) |end| {
            used += end;
            return if (used == 0) null else response[0..used];
        }
        if (used == response.len) return error.ResponseTooLong;
        used += count;
    }
}

fn pair() ![2]linux.fd_t {
    var fds: [2]linux.fd_t = undefined;
    _ = try checked(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds));
    return fds;
}

test "request bytes and write EOF, selected first line" {
    const fds = try pair();
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    const request = "Display: \nInternal\nExternal\nExtended\nBrightStay\n";
    try sendAll(fds[1], "External\nignored\n");
    var response: [64]u8 = undefined;
    try std.testing.expectEqualStrings("External", (try exchange(fds[0], request, &response)).?);
    var received: [128]u8 = undefined;
    var used: usize = 0;
    while (true) {
        const count = try receive(fds[1], received[used..]);
        if (count == 0) break;
        used += count;
    }
    try std.testing.expectEqualStrings(request, received[0..used]);
}

test "EOF selection, cancellation, exact fit, overflow, zero capacity" {
    const cases = .{
        .{ "Internal", 8, "Internal" },
        .{ "External\n", 8, "External" },
        .{ "", 8, null },
        .{ "\n", 8, null },
        .{ "", 0, null },
        .{ "\n", 0, null },
    };
    inline for (cases) |case| {
        const fds = try pair();
        defer _ = linux.close(fds[0]);
        defer _ = linux.close(fds[1]);
        try sendAll(fds[1], case[0]);
        try shutdownWrite(fds[1]);
        var response: [case[1]]u8 = undefined;
        const selected = try exchange(fds[0], "", &response);
        if (@as(?[]const u8, case[2])) |expected| {
            try std.testing.expectEqualStrings(expected, selected.?);
        } else {
            try std.testing.expect(selected == null);
        }
    }
    inline for (.{ 0, 3 }) |capacity| {
        const fds = try pair();
        defer _ = linux.close(fds[0]);
        defer _ = linux.close(fds[1]);
        try sendAll(fds[1], "long\n");
        var response: [capacity]u8 = undefined;
        try std.testing.expectError(error.ResponseTooLong, exchange(fds[0], "", &response));
    }
}

test "closed peer returns BrokenPipe without SIGPIPE" {
    const fds = try pair();
    defer _ = linux.close(fds[0]);
    _ = linux.close(fds[1]);
    var response: [8]u8 = undefined;
    try std.testing.expectError(error.BrokenPipe, exchange(fds[0], "request", &response));
}

test "reject invalid socket paths" {
    var response: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidSocketPath, choose("", "", &response));
    try std.testing.expectError(error.InvalidSocketPath, choose("a\x00b", "", &response));
    try std.testing.expectError(error.SocketPathTooLong, choose(&@as([108]u8, @splat('a')), "", &response));
}
