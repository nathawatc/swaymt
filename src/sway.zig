//! Linux-only Sway IPC. No environment access, libc, subprocesses, or heap allocator.
const std = @import("std");
const linux = std.os.linux;
const endian = @import("builtin").cpu.arch.endian();

pub const Mode = enum { internal, external, extended };

const run_command: u32 = 0;
const get_outputs: u32 = 3;
const max_payload = 64 * 1024;
const max_name = 255;
const max_command = max_name * 5 + 32;
const Output = struct { name: []const u8 };
const CommandResult = struct { success: bool, @"error": ?[]const u8 = null };

/// Validate both connector names (including disabled outputs), acknowledge a reload,
/// then acknowledge enable and power on for desired outputs before disabling the
/// other. These acknowledgements do not verify physical output state. Extended mode
/// keeps the reloaded configuration's layout; it does not synthesize positions.
/// Diagnostics include missing names and Sway's command error text on stderr.
/// Replies and JSON scratch space are each limited to 64 KiB. Names: 255 bytes.
/// Unusual connector names containing backslashes are unsupported: Sway's command
/// separator and argument parsers handle escapes differently. Ordinary quotes are supported.
/// The caller supplies SWAYSOCK and handles a missing environment variable.
pub fn apply(socket_path: []const u8, internal: []const u8, external: []const u8, mode: Mode) !void {
    try validateNames(internal, external);
    const fd = try connectSocket(socket_path);
    defer _ = linux.close(fd);
    try applyConnected(fd, internal, external, mode);
}

fn connectSocket(path: []const u8) !i32 {
    var address: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSocketPath;
    if (path.len >= address.path.len) return error.SocketPathTooLong;
    @memcpy(address.path[0..path.len], path);
    const fd: i32 = @intCast(try syscall(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(fd);
    // A failed/interrupted connect is not retried on the same socket.
    _ = try syscall(linux.connect(fd, &address, @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1)));
    return fd;
}

fn syscall(result: usize) !usize {
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        .INTR => error.Interrupted,
        .ACCES, .PERM => error.PermissionDenied,
        .NOENT => error.SocketNotFound,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET, .PIPE => error.ConnectionClosed,
        .AGAIN, .TIMEDOUT => error.SocketTimedOut,
        .NOMEM, .NOBUFS => error.SystemResources,
        .MFILE, .NFILE => error.TooManyOpenFiles,
        else => error.SocketFailure,
    };
}

fn sendAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = syscall(linux.sendto(fd, bytes[offset..].ptr, bytes.len - offset, linux.MSG.NOSIGNAL, null, 0)) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        offset += n;
    }
}

fn readExact(fd: i32, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = syscall(linux.recvfrom(fd, bytes[offset..].ptr, bytes.len - offset, 0, null, null)) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
        if (n == 0) return error.TruncatedFrame;
        offset += n;
    }
}

fn frameHeader(kind: u32, len: u32) [14]u8 {
    var header: [14]u8 = undefined;
    @memcpy(header[0..6], "i3-ipc");
    // i3/Sway IPC uses native byte order, not network byte order.
    std.mem.writeInt(u32, header[6..10], len, endian);
    std.mem.writeInt(u32, header[10..14], kind, endian);
    return header;
}

fn sendFrame(fd: i32, kind: u32, payload: []const u8) !void {
    if (payload.len > max_payload) return error.PayloadTooLarge;
    const header = frameHeader(kind, @intCast(payload.len));
    if (payload.len <= max_command) {
        var frame: [14 + max_command]u8 = undefined;
        @memcpy(frame[0..14], &header);
        @memcpy(frame[14..][0..payload.len], payload);
        return sendAll(fd, frame[0 .. 14 + payload.len]);
    }
    try sendAll(fd, &header);
    try sendAll(fd, payload);
}

fn readFrame(fd: i32, kind: u32, buffer: []u8) ![]const u8 {
    var header: [14]u8 = undefined;
    try readExact(fd, &header);
    if (!std.mem.eql(u8, header[0..6], "i3-ipc")) return error.InvalidMagic;
    if (std.mem.readInt(u32, header[10..14], endian) != kind) return error.UnexpectedMessageType;
    const len = std.mem.readInt(u32, header[6..10], endian);
    if (len > max_payload or len > buffer.len) return error.PayloadTooLarge;
    try readExact(fd, buffer[0..len]);
    return buffer[0..len];
}

fn parse(comptime T: type, allocator: std.mem.Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
        .max_value_len = max_payload,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.JsonTooLarge,
        else => error.InvalidJson,
    };
}

fn checkOutputs(json: []const u8, internal: []const u8, external: []const u8) !void {
    var scratch: [max_payload]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);
    const outputs = try parse([]const Output, allocator.allocator(), json);
    var found_internal = false;
    var found_external = false;
    for (outputs) |output| {
        found_internal = found_internal or std.mem.eql(u8, output.name, internal);
        found_external = found_external or std.mem.eql(u8, output.name, external);
    }
    if (!found_internal) std.debug.print("swaymt: output \"{s}\" not found (including disabled outputs)\n", .{internal});
    if (!found_external) std.debug.print("swaymt: output \"{s}\" not found (including disabled outputs)\n", .{external});
    if (!found_internal or !found_external) return error.OutputNotFound;
}

fn checkCommand(json: []const u8, text: []const u8) !void {
    var scratch: [max_payload]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);
    const results = try parse([]const CommandResult, allocator.allocator(), json);
    for (results) |result| {
        if (!result.success) {
            std.debug.print("swaymt: command `{s}` failed: {s}\n", .{ text, result.@"error" orelse "Sway supplied no error text" });
            return error.CommandFailed;
        }
    }
    // Each request contains exactly one command. Empty success arrays are invalid.
    if (results.len != 1) return error.InvalidCommandReply;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidOutputName;
    if (name.len > max_name) return error.OutputNameTooLong;
    if (std.mem.eql(u8, name, "-") or std.mem.eql(u8, name, "--")) return error.InvalidOutputName;
    for (name) |c| {
        // Backslashes are unsupported because argsep and split_args disagree on escapes.
        // Also reject selectors, variable expansion, NUL and terminal/control characters.
        if (c < 0x20 or c == 0x7f or c == '*' or c == '?' or c == '$' or c == '\\') return error.InvalidOutputName;
    }
}

fn validateNames(internal: []const u8, external: []const u8) !void {
    try validateName(internal);
    try validateName(external);
    if (std.ascii.eqlIgnoreCase(internal, external)) return error.SameOutput;
}

fn quoteName(buffer: []u8, name: []const u8) ![]const u8 {
    try validateName(name);
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte('"');
    for (name) |c| {
        if (c == '"') {
            // Close double quotes, put a literal double quote in single quotes,
            // reopen double quotes. Unlike \" this survives Sway's strip_quotes.
            try writer.writeAll("\"'\"'\"");
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('"');
    return writer.buffered();
}

fn outputCommand(buffer: []u8, name: []const u8, action: []const u8) ![]const u8 {
    var quoted_buffer: [max_name * 5 + 2]u8 = undefined;
    const quoted = try quoteName(&quoted_buffer, name);
    return std.fmt.bufPrint(buffer, "output {s} {s}", .{ quoted, action });
}

fn command(fd: i32, text: []const u8, reply: []u8) !void {
    try sendFrame(fd, run_command, text);
    try checkCommand(try readFrame(fd, run_command, reply), text);
}

fn applyConnected(fd: i32, internal: []const u8, external: []const u8, mode: Mode) !void {
    try validateNames(internal, external);
    var reply: [max_payload]u8 = undefined;
    try sendFrame(fd, get_outputs, "");
    try checkOutputs(try readFrame(fd, get_outputs, &reply), internal, external);
    try command(fd, "reload", &reply);

    var buffer: [max_command]u8 = undefined;
    const first = if (mode == .external) external else internal;
    const second = if (mode == .external) internal else external;
    // Enable alone does not override configured power off. Acknowledge each
    // command separately; do not infer physical output state from acceptance.
    try command(fd, try outputCommand(&buffer, first, "enable"), &reply);
    try command(fd, try outputCommand(&buffer, first, "power on"), &reply);
    if (mode == .extended) {
        try command(fd, try outputCommand(&buffer, second, "enable"), &reply);
        try command(fd, try outputCommand(&buffer, second, "power on"), &reply);
    } else {
        try command(fd, try outputCommand(&buffer, second, "disable"), &reply);
    }
}

// Tests use only local socket pairs. Neither SWAYSOCK nor a compositor is needed.
fn socketPair() ![2]i32 {
    var pair: [2]i32 = undefined;
    _ = try syscall(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    return pair;
}

fn closePair(pair: [2]i32) void {
    for (pair) |fd| _ = linux.close(fd);
}

test "header is native endian and payload excludes terminator" {
    const header = frameHeader(get_outputs, 0x1020304);
    try std.testing.expectEqualStrings("i3-ipc", header[0..6]);
    try std.testing.expectEqual(@as(u32, 0x1020304), std.mem.readInt(u32, header[6..10], endian));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, header[10..14], endian));
    const pair = try socketPair();
    defer closePair(pair);
    try sendFrame(pair[0], run_command, "reload");
    var wire: [20]u8 = undefined;
    try readExact(pair[1], &wire);
    try std.testing.expectEqualSlices(u8, &frameHeader(0, 6), wire[0..14]);
    try std.testing.expectEqualStrings("reload", wire[14..]);
}

test "send frame preserves wire bytes across coalescing boundary" {
    var payload: [max_command + 1]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    for ([_]usize{ 0, max_command - 1, max_command, max_command + 1 }) |len| {
        const pair = try socketPair();
        defer closePair(pair);
        try sendFrame(pair[0], run_command, payload[0..len]);
        _ = try syscall(linux.shutdown(pair[0], linux.SHUT.WR));
        var wire: [14 + payload.len]u8 = undefined;
        try readExact(pair[1], wire[0 .. 14 + len]);
        try std.testing.expectEqualSlices(u8, &frameHeader(run_command, @intCast(len)), wire[0..14]);
        try std.testing.expectEqualSlices(u8, payload[0..len], wire[14..][0..len]);
        var extra: [1]u8 = undefined;
        try std.testing.expectError(error.TruncatedFrame, readExact(pair[1], &extra));
    }
    try std.testing.expectError(error.PayloadTooLarge, sendFrame(-1, run_command, &(@as([max_payload + 1]u8, @splat(0)))));
}

test "truncated headers and payloads fail at every boundary" {
    const header = frameHeader(get_outputs, 3);
    var wire: [17]u8 = undefined;
    @memcpy(wire[0..14], &header);
    @memcpy(wire[14..], "abc");
    for (0..wire.len) |len| {
        const pair = try socketPair();
        defer closePair(pair);
        try sendAll(pair[0], wire[0..len]);
        _ = try syscall(linux.shutdown(pair[0], linux.SHUT.WR));
        var buffer: [32]u8 = undefined;
        try std.testing.expectError(error.TruncatedFrame, readFrame(pair[1], get_outputs, &buffer));
    }
}

test "malformed magic, type, and oversized frame" {
    for (0..4) |case| {
        const pair = try socketPair();
        defer closePair(pair);
        var header = frameHeader(get_outputs, 0);
        const expected = switch (case) {
            0 => blk: {
                header[0] = 'x';
                break :blk error.InvalidMagic;
            },
            1 => blk: {
                header = frameHeader(0x80000003, 0);
                break :blk error.UnexpectedMessageType;
            },
            2 => blk: {
                header = frameHeader(get_outputs, max_payload + 1);
                break :blk error.PayloadTooLarge;
            },
            else => blk: {
                header = frameHeader(get_outputs, 33);
                break :blk error.PayloadTooLarge;
            },
        };
        try sendAll(pair[0], &header);
        var buffer: [32]u8 = undefined;
        try std.testing.expectError(expected, readFrame(pair[1], get_outputs, &buffer));
    }
}

test "closed peer returns error without SIGPIPE" {
    const pair = try socketPair();
    defer _ = linux.close(pair[0]);
    _ = linux.close(pair[1]);
    try std.testing.expectError(error.ConnectionClosed, sendFrame(pair[0], run_command, "reload"));
}

const test_outputs =
    \\[{"name":"eDP-1","active":false,"rect":{"x":0,"y":0},"modes":[{"width":1920}]},
    \\ {"name":"DP-1","active":true,"unknown":[null,{"a":[1,2,3]}]}]
;

test "output lookup includes disabled names and ignores unrelated state" {
    try checkOutputs(test_outputs, "eDP-1", "DP-1");
    try checkOutputs("[{\"name\":\"eDP-\\u0031\"},{\"name\":\"DP-1\"}]", "eDP-1", "DP-1");
    try std.testing.expectError(error.OutputNotFound, checkOutputs(test_outputs, "missing-internal", "missing-external"));
    try std.testing.expectError(error.OutputNotFound, checkOutputs(test_outputs, "eDP-1", "missing"));
    try std.testing.expectError(error.OutputNotFound, checkOutputs("[]", "eDP-1", "DP-1"));
    for ([_][]const u8{ "{}", "[{}]", "[{\"name\":null}]", "[{\"name\":1}]", "[", "[] true", "[{\"name\":\"a\",\"name\":\"b\"}]" }) |json| {
        try std.testing.expectError(error.InvalidJson, checkOutputs(json, "eDP-1", "DP-1"));
    }
}

test "command replies require one success and preserve failures" {
    try checkCommand("[{\"success\":true,\"unknown\":{\"x\":1}}]", "reload");
    try std.testing.expectError(error.CommandFailed, checkCommand("[{\"success\":false,\"error\":\"bad \\\"mode\\\"\"}]", "reload"));
    try std.testing.expectError(error.CommandFailed, checkCommand("[{\"success\":false}]", "reload"));
    for ([_][]const u8{ "[]", "[{\"success\":true},{\"success\":true}]" }) |json| {
        try std.testing.expectError(error.InvalidCommandReply, checkCommand(json, "reload"));
    }
    for ([_][]const u8{ "{}", "[{}]", "[{\"success\":1}]", "[{\"success\":true}]x" }) |json| {
        try std.testing.expectError(error.InvalidJson, checkCommand(json, "reload"));
    }
}

test "JSON allocation is bounded" {
    var tiny: [1]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&tiny);
    try std.testing.expectError(error.JsonTooLarge, parse([]const Output, allocator.allocator(), test_outputs));
    var json: [max_payload]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&json);
    try writer.writeByte('[');
    for (0..4096) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":\"x\"}");
    }
    try writer.writeByte(']');
    try std.testing.expectError(error.JsonTooLarge, checkOutputs(writer.buffered(), "eDP-1", "DP-1"));
}

test "Sway quoting protects separators and preserves ordinary quotes" {
    var buffer: [max_command]u8 = undefined;
    try std.testing.expectEqualStrings("output \"DP-1\" enable", try outputCommand(&buffer, "DP-1", "enable"));
    try std.testing.expectEqualStrings("output \"a; exec bad, [x] 'b'\" disable", try outputCommand(&buffer, "a; exec bad, [x] 'b'", "disable"));
    try std.testing.expectEqualStrings("\"a\"'\"'\"b\"", try quoteName(&buffer, "a\"b"));
    for ([_][]const u8{ "a\\b", "a\\\";b", "a\\\\" }) |name| {
        try std.testing.expectError(error.InvalidOutputName, quoteName(&buffer, name));
    }
    for ([_][]const u8{ "", "*", "DP-*", "?", "-", "--", "$output", "a\n", "a\r", "a\x00b", "a\x1b", "a\\" }) |name| {
        try std.testing.expectError(error.InvalidOutputName, quoteName(&buffer, name));
    }
    try std.testing.expectError(error.OutputNameTooLong, quoteName(&buffer, &(@as([max_name + 1]u8, @splat('a')))));
    try std.testing.expectError(error.SameOutput, validateNames("DP-1", "dp-1"));
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, quoteName(&tiny, "DP-1"));
}

test "backslash-free quote concatenation keeps each byte inside quotes" {
    // This checks only the supported backslash-free subset, not a model of
    // Sway's differing escape handling in argsep and split_args.
    const alphabet = "a\"';, []";
    for (0..4096) |value| {
        var number = value;
        var name: [4]u8 = undefined;
        for (&name) |*byte| {
            byte.* = alphabet[number % alphabet.len];
            number /= alphabet.len;
        }
        var encoded: [32]u8 = undefined;
        const quoted = try quoteName(&encoded, &name);
        var decoded: [4]u8 = undefined;
        var length: usize = 0;
        var in_double = false;
        var in_single = false;
        for (quoted) |byte| {
            if (byte == '"' and !in_single) {
                in_double = !in_double;
            } else if (byte == '\'' and !in_double) {
                in_single = !in_single;
            } else {
                // No unquoted separator/whitespace/criteria can escape this token.
                try std.testing.expect(in_double or in_single);
                try std.testing.expect(length < decoded.len);
                decoded[length] = byte;
                length += 1;
            }
        }
        try std.testing.expect(!in_double and !in_single);
        try std.testing.expectEqualStrings(&name, decoded[0..length]);
    }
}

test "coalesced frames including empty payload are read independently" {
    const pair = try socketPair();
    defer closePair(pair);
    try sendFrame(pair[0], get_outputs, "");
    try sendFrame(pair[0], run_command, "[]");
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("", try readFrame(pair[1], get_outputs, &buffer));
    try std.testing.expectEqualStrings("[]", try readFrame(pair[1], run_command, &buffer));
}

const FakePeer = struct {
    fd: i32,
    mode: Mode,
    fail_at: ?usize = null,
    missing: bool = false,
    result: ?anyerror = null,

    fn run(self: *FakePeer) void {
        defer _ = linux.shutdown(self.fd, linux.SHUT.RDWR);
        self.serve() catch |err| {
            self.result = err;
        };
    }

    fn fragmented(self: *FakePeer, kind: u32, text: []const u8) !void {
        const header = frameHeader(kind, @intCast(text.len));
        for (&header) |byte| try sendAll(self.fd, &.{byte});
        for (text) |byte| try sendAll(self.fd, &.{byte});
    }

    fn serve(self: *FakePeer) !void {
        var buffer: [max_command]u8 = undefined;
        try std.testing.expectEqualStrings("", try readFrame(self.fd, get_outputs, &buffer));
        try self.fragmented(get_outputs, if (self.missing) "[]" else test_outputs);
        if (self.missing) return self.expectClosed();
        const commands: []const []const u8 = switch (self.mode) {
            .internal => &.{ "reload", "output \"eDP-1\" enable", "output \"eDP-1\" power on", "output \"DP-1\" disable" },
            .external => &.{ "reload", "output \"DP-1\" enable", "output \"DP-1\" power on", "output \"eDP-1\" disable" },
            .extended => &.{ "reload", "output \"eDP-1\" enable", "output \"eDP-1\" power on", "output \"DP-1\" enable", "output \"DP-1\" power on" },
        };
        for (commands, 0..) |expected, index| {
            try std.testing.expectEqualStrings(expected, try readFrame(self.fd, run_command, &buffer));
            // No subsequent request may precede this command's acknowledgement.
            var byte: [1]u8 = undefined;
            try std.testing.expectEqual(linux.E.AGAIN, linux.errno(linux.recvfrom(self.fd, &byte, 1, linux.MSG.DONTWAIT | linux.MSG.PEEK, null, null)));
            const failed = self.fail_at == index;
            try self.fragmented(run_command, if (failed) "[{\"success\":false,\"error\":\"fake failure\"}]" else "[{\"success\":true}]");
            if (failed) return self.expectClosed();
        }
        try self.expectClosed();
    }

    fn expectClosed(self: *FakePeer) !void {
        var byte: [1]u8 = undefined;
        try std.testing.expectError(error.TruncatedFrame, readExact(self.fd, &byte));
    }
};

fn testApply(mode: Mode, fail_at: ?usize, missing: bool) !void {
    const pair = try socketPair();
    defer closePair(pair);
    var peer: FakePeer = .{ .fd = pair[1], .mode = mode, .fail_at = fail_at, .missing = missing };
    const thread = try std.Thread.spawn(.{}, FakePeer.run, .{&peer});
    const result = applyConnected(pair[0], "eDP-1", "DP-1", mode);
    _ = linux.shutdown(pair[0], linux.SHUT.RDWR);
    thread.join();
    if (peer.result) |err| return err;
    if (missing) {
        try std.testing.expectError(error.OutputNotFound, result);
    } else if (fail_at != null) {
        try std.testing.expectError(error.CommandFailed, result);
    } else {
        try result;
    }
}

test "full fragmented IPC: all modes, one lookup, reload acknowledged first" {
    inline for (std.meta.tags(Mode)) |mode| try testApply(mode, null, false);
}

test "full IPC stops on missing output, failed reload, enable, power on, or disable" {
    try testApply(.internal, null, true);
    inline for (std.meta.tags(Mode)) |mode| {
        for (0..@as(usize, if (mode == .extended) 5 else 4)) |index| try testApply(mode, index, false);
    }
}

test "backslash quote injection is rejected before any IPC" {
    const malicious = "\x5c\x22\x5c\x22'; nop injected; nop '";
    const pair = try socketPair();
    defer closePair(pair);
    inline for (std.meta.tags(Mode)) |mode| {
        for ([_][2][]const u8{ .{ malicious, "DP-1" }, .{ "eDP-1", malicious } }) |names| {
            // Invalid path would fail next if name validation did not run first.
            try std.testing.expectError(error.InvalidOutputName, apply("", names[0], names[1], mode));
            try std.testing.expectError(error.InvalidOutputName, applyConnected(pair[0], names[0], names[1], mode));
            var byte: [1]u8 = undefined;
            try std.testing.expectEqual(linux.E.AGAIN, linux.errno(linux.recvfrom(pair[1], &byte, 1, linux.MSG.DONTWAIT, null, null)));
        }
    }
}

test "public API validates names and socket paths before connecting" {
    try std.testing.expectError(error.SameOutput, apply("unused", "DP-1", "DP-1", .extended));
    try std.testing.expectError(error.InvalidSocketPath, apply("", "eDP-1", "DP-1", .extended));
    try std.testing.expectError(error.InvalidSocketPath, apply("a\x00b", "eDP-1", "DP-1", .extended));
    try std.testing.expectError(error.SocketPathTooLong, apply(&(@as([108]u8, @splat('x'))), "eDP-1", "DP-1", .extended));
}
