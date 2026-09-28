const std = @import("std");
const linux = std.os.linux;
const target_product: u16 = 26542;
const vcp_color_preset_code: u8 = 0x14;
const color_preset_value: u16 = 11;
const cache_dir = "/var/cache/brightstay";
const cache_name = "monitor.cache";

/// Best-effort, like the Rust implementation: absence of a usable monitor is not
/// an error. Cache failures never undo a successful hardware operation.
/// Linux only; no libc, allocator, subprocess, or Io instance is required.
pub fn run() !void {
    var backend: Backend = .{};
    defer backend.deinit();
    reapplyColorPreset(&backend);
}

fn decimal(comptime T: type, text: []const u8) ?T {
    const digits = if (std.mem.startsWith(u8, text, "+")) text[1..] else text;
    if (digits.len == 0) return null;
    var value: T = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        value = std.math.mul(T, value, 10) catch return null;
        value = std.math.add(T, value, @intCast(c - '0')) catch return null;
    }
    return value;
}

fn parseCache(content: []const u8) ?u8 {
    const text = std.mem.trimEnd(u8, content, " \t\n\r\x0b\x0c");
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const bus = decimal(u8, text[0..colon]) orelse return null;
    if ((decimal(u16, text[colon + 1 ..]) orelse return null) != target_product) return null;
    return bus;
}

fn matchesEdid(edid: *const [128]u8) bool {
    // Deliberately match the reference, not stricter EISA/header validation.
    return (edid[8] != 0 or edid[9] != 0) and
        std.mem.readInt(u16, edid[10..12], .little) == target_product;
}

fn vcpPacket() [7]u8 {
    var packet = [_]u8{ 0x51, 0x84, 0x03, vcp_color_preset_code, 0, 0, 0 };
    std.mem.writeInt(u16, packet[4..6], color_preset_value, .big);
    // Destination address (0x37 << 1) participates but is not in the payload.
    packet[6] = 0x6e;
    for (packet[0..6]) |byte| packet[6] ^= byte;
    return packet;
}

fn applyDevice(device: anytype) !bool {
    const edid = try device.readEdid();
    if (!matchesEdid(&edid)) return false;
    try device.setVcp();
    return true;
}

// Injection is confined to orchestration; tests never call the host backend.
fn reapplyColorPreset(backend: anytype) void {
    if (backend.cached()) |bus| {
        if (backend.apply(bus) catch false) return;
    }
    while (backend.next() catch return) |bus| {
        // An EDID/open failure skips a device; a matching device's failed Set
        // terminates the scan, matching the Rust slow path.
        if (backend.apply(bus) catch |err| switch (err) {
            error.SetVcpFailed => return,
            else => continue,
        }) {
            backend.save(bus) catch backend.cacheWarning();
            return;
        }
    }
}

fn checked(result: usize) !usize {
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        .INTR => error.Interrupted,
        .NOENT => error.FileNotFound,
        .EXIST => error.PathExists,
        else => error.LinuxIoFailure,
    };
}

fn openAt(dir: i32, path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) !i32 {
    while (true) {
        const result = checked(linux.openat(dir, path, flags, mode)) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
        return @intCast(result);
    }
}

fn readSome(fd: i32, bytes: []u8) !usize {
    while (true) {
        return checked(linux.read(fd, bytes.ptr, bytes.len)) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
    }
}

fn writeAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = checked(linux.write(fd, bytes[offset..].ptr, bytes.len - offset)) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
        if (n == 0) return error.ShortWrite;
        offset += n;
    }
}

fn sync(fd: i32) !void {
    while (true) {
        _ = checked(linux.fsync(fd)) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
        return;
    }
}

fn readCacheAt(dir: i32) !?u8 {
    const fd = openAt(dir, cache_name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer _ = linux.close(fd);
    var buffer: [128]u8 = undefined;
    var len: usize = 0;
    while (len < buffer.len) {
        const n = try readSome(fd, buffer[len..]);
        if (n == 0) return parseCache(buffer[0..len]);
        len += n;
    }
    return null;
}

fn writeCacheAt(dir: i32, bus: u8, destination: [*:0]const u8) !void {
    var random: [16]u8 = undefined;
    var offset: usize = 0;
    while (offset < random.len) {
        const n = checked(linux.getrandom(random[offset..].ptr, random.len - offset, 0)) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
        if (n == 0) return error.NoRandomness;
        offset += n;
    }
    var name_buffer: [80]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buffer, ".monitor.cache.{x}", .{std.fmt.bytesToHex(random, .lower)});
    const fd = try openAt(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
    defer _ = linux.close(fd);
    // After rename, this name no longer belongs to our temporary file.
    var renamed = false;
    defer if (!renamed) {
        _ = linux.unlinkat(dir, name, 0);
    };
    _ = try checked(linux.fchmod(fd, 0o664));
    var text: [32]u8 = undefined;
    try writeAll(fd, try std.fmt.bufPrint(&text, "{d}:{d}\n", .{ bus, target_product }));
    try sync(fd);
    _ = try checked(linux.renameat(dir, name, dir, destination));
    renamed = true;
    // A failure here leaves the replacement visible, but durability uncertain.
    try sync(dir);
}

const Message = extern struct {
    address: u16,
    flags: u16,
    len: u16,
    buffer: [*]u8,
};
const Transfer = extern struct { messages: [*]Message, count: u32 };

const Device = struct {
    fd: i32,

    fn readEdid(self: Device) ![128]u8 {
        var edid: [128]u8 = undefined;
        var offset = [_]u8{0};
        // I2C_RDWR: offset write + repeated-start read at EDID address 0x50.
        var messages = [_]Message{
            .{ .address = 0x50, .flags = 0, .len = 1, .buffer = &offset },
            .{ .address = 0x50, .flags = 1, .len = 128, .buffer = &edid },
        };
        var transfer: Transfer = .{ .messages = &messages, .count = messages.len };
        const n = try checked(linux.ioctl(self.fd, 0x0707, @intFromPtr(&transfer)));
        if (n != messages.len) return error.ShortTransfer;
        return edid;
    }

    fn setVcp(self: Device) !void {
        var packet = vcpPacket();
        var messages = [_]Message{.{ .address = 0x37, .flags = 0, .len = packet.len, .buffer = &packet }};
        var transfer: Transfer = .{ .messages = &messages, .count = 1 };
        const n = checked(linux.ioctl(self.fd, 0x0707, @intFromPtr(&transfer))) catch return error.SetVcpFailed;
        if (n != 1) return error.SetVcpFailed;
    }
};

const Backend = struct {
    scan_fd: ?i32 = null,
    buffer: [4096]u8 align(@alignOf(linux.dirent64)) = undefined,
    position: usize = 0,
    length: usize = 0,

    fn deinit(self: *Backend) void {
        if (self.scan_fd) |fd| _ = linux.close(fd);
    }

    fn cached(self: *Backend) ?u8 {
        const fd = openAt(linux.AT.FDCWD, cache_dir, .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0) catch |err| {
            if (err != error.FileNotFound) self.cacheWarning();
            return null;
        };
        defer _ = linux.close(fd);
        return readCacheAt(fd) catch {
            self.cacheWarning();
            return null;
        };
    }

    fn apply(_: *Backend, bus: u8) !bool {
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "/dev/i2c-{d}", .{bus});
        const fd = try openAt(linux.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        defer _ = linux.close(fd);
        return applyDevice(Device{ .fd = fd });
    }

    fn next(self: *Backend) !?u8 {
        if (self.scan_fd == null) self.scan_fd = try openAt(linux.AT.FDCWD, "/sys/class/i2c-dev", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
        while (true) {
            if (self.position == self.length) {
                self.length = checked(linux.getdents64(self.scan_fd.?, &self.buffer, self.buffer.len)) catch |err| {
                    if (err == error.Interrupted) continue;
                    return err;
                };
                self.position = 0;
                if (self.length == 0) return null;
            }
            const start = self.position;
            const name_offset = @offsetOf(linux.dirent64, "name");
            if (self.length - start <= name_offset) return error.InvalidDirectoryEntry;
            const entry: *align(1) const linux.dirent64 = @ptrCast(&self.buffer[start]);
            if (entry.reclen <= name_offset or entry.reclen > self.length - start) return error.InvalidDirectoryEntry;
            self.position += entry.reclen;
            const bytes = self.buffer[start + name_offset .. self.position];
            const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidDirectoryEntry;
            const name = bytes[0..end];
            if (std.mem.startsWith(u8, name, "i2c-")) {
                if (decimal(u8, name[4..])) |bus| return bus;
            }
        }
    }

    fn save(_: *Backend, bus: u8) !void {
        // Provision /var/cache/brightstay externally, as in the Rust service.
        const fd = try openAt(linux.AT.FDCWD, cache_dir, .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0);
        defer _ = linux.close(fd);
        try writeCacheAt(fd, bus, cache_name);
    }

    fn cacheWarning(_: *Backend) void {
        writeAll(2, "brightstay: cache unavailable; hardware result preserved\n") catch {};
    }
};

fn targetEdid() [128]u8 {
    var edid = [_]u8{0} ** 128;
    edid[9] = 1;
    std.mem.writeInt(u16, edid[10..12], target_product, .little);
    return edid;
}

test "cache parsing rejects malformed, overflowing and wrong-product entries" {
    for ([_][]const u8{ "", "abc", "1", "1:2:3", "1:26542x", "1:0", "256:26542", "-1:26542", " 1:26542", "1 :26542", "1: 26542", "1:26_542", "1:0x67ae", "1:26542\x00", "1:65536" }) |text| {
        try std.testing.expectEqual(@as(?u8, null), parseCache(text));
    }
    try std.testing.expectEqual(@as(?u8, 0), parseCache("0:26542"));
    try std.testing.expectEqual(@as(?u8, 255), parseCache("255:26542\n \t\r"));
    try std.testing.expectEqual(@as(?u8, 7), parseCache("+007:+26542\n"));
}

test "EDID uses precisely nonzero manufacturer and little-endian product" {
    var edid = targetEdid();
    try std.testing.expect(matchesEdid(&edid));
    edid[9] = 0;
    try std.testing.expect(!matchesEdid(&edid));
    edid[8] = 0x80;
    try std.testing.expect(matchesEdid(&edid));
    std.mem.swap(u8, &edid[10], &edid[11]);
    try std.testing.expect(!matchesEdid(&edid));
}

test "DDC CI Set VCP wire packet and destination checksum" {
    try std.testing.expectEqualSlices(u8, &.{ 0x51, 0x84, 0x03, 0x14, 0x00, 0x0b, 0xa7 }, &vcpPacket());
}

const Fake = struct {
    cache: ?u8 = 7,
    edid: [128]u8 = targetEdid(),
    read_failure: bool = false,
    set_failure: bool = false,
    save_failure: bool = false,
    scan_recovers: bool = true,
    scan_failure: bool = false,
    reads: usize = 0,
    sets: usize = 0,
    scans: usize = 0,
    saves: usize = 0,
    warnings: usize = 0,

    fn cached(self: *Fake) ?u8 {
        return self.cache;
    }
    fn readEdid(self: *Fake) ![128]u8 {
        self.reads += 1;
        if (self.read_failure) return error.ReadFailed;
        return self.edid;
    }
    fn setVcp(self: *Fake) !void {
        self.sets += 1;
        if (self.set_failure) return error.SetVcpFailed;
    }
    fn apply(self: *Fake, bus: u8) !bool {
        try std.testing.expectEqual(@as(u8, if (self.scans == 0) 7 else 3), bus);
        return applyDevice(self);
    }
    fn next(self: *Fake) !?u8 {
        self.scans += 1;
        if (self.scan_failure) return error.ScanFailed;
        if (self.scans > 1) return null;
        if (self.scan_recovers) {
            self.edid = targetEdid();
            self.read_failure = false;
            self.set_failure = false;
        }
        return 3;
    }
    fn save(self: *Fake, bus: u8) !void {
        try std.testing.expectEqual(@as(u8, 3), bus);
        self.saves += 1;
        if (self.save_failure) return error.CacheFailed;
    }
    fn cacheWarning(self: *Fake) void {
        self.warnings += 1;
    }
};

test "valid cached bus checks EDID and performs operation without scanning" {
    var fake: Fake = .{};
    reapplyColorPreset(&fake);
    try std.testing.expectEqual(@as(usize, 1), fake.reads);
    try std.testing.expectEqual(@as(usize, 1), fake.sets);
    try std.testing.expectEqual(@as(usize, 0), fake.scans);
    try std.testing.expectEqual(@as(usize, 0), fake.saves);
}

test "missing cache, stale EDID, EDID failure and VCP failure fall back" {
    for (0..4) |case| {
        var fake: Fake = .{};
        switch (case) {
            0 => fake.cache = null,
            1 => fake.edid = [_]u8{0} ** 128,
            2 => fake.read_failure = true,
            3 => fake.set_failure = true,
            else => unreachable,
        }
        reapplyColorPreset(&fake);
        try std.testing.expectEqual(@as(usize, 1), fake.scans);
        try std.testing.expectEqual(@as(usize, 1), fake.saves);
        try std.testing.expectEqual(@as(usize, if (case == 3) 2 else 1), fake.sets);
    }
}

test "cache failure warns after hardware success" {
    var fake: Fake = .{ .cache = null, .save_failure = true };
    reapplyColorPreset(&fake);
    try std.testing.expectEqual(@as(usize, 1), fake.sets);
    try std.testing.expectEqual(@as(usize, 1), fake.warnings);
}

test "unsuccessful scan never writes cache" {
    for (0..4) |case| {
        var fake: Fake = .{ .cache = null, .scan_recovers = false };
        switch (case) {
            0 => fake.scan_failure = true,
            1 => fake.read_failure = true,
            2 => fake.edid = [_]u8{0} ** 128,
            3 => fake.set_failure = true,
            else => unreachable,
        }
        reapplyColorPreset(&fake);
        try std.testing.expectEqual(@as(usize, 0), fake.saves);
        try std.testing.expectEqual(@as(usize, if (case == 1 or case == 2) 2 else 1), fake.scans);
    }
}

fn expectNoTemps(dir: std.Io.Dir) !void {
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".monitor.cache."));
    }
}

test "cache atomic replacement, exact permissions, malformed and missing cache" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fd = tmp.dir.handle;
    try std.testing.expectEqual(@as(?u8, null), try readCacheAt(fd));
    const old = try openAt(fd, cache_name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    defer _ = linux.close(old);
    try writeAll(old, "not-a-cache");
    try std.testing.expectEqual(@as(?u8, null), try readCacheAt(fd));
    const old_reader = try openAt(fd, cache_name, .{}, 0);
    defer _ = linux.close(old_reader);
    try writeCacheAt(fd, 9, cache_name);
    var old_content: [32]u8 = undefined;
    const old_len = try readSome(old_reader, &old_content);
    try std.testing.expectEqualStrings("not-a-cache", old_content[0..old_len]);
    try std.testing.expectEqual(@as(?u8, 9), try readCacheAt(fd));
    const file = try tmp.dir.openFile(std.testing.io, cache_name, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0o664), stat.permissions.toMode() & 0o777);
    try expectNoTemps(tmp.dir);
    try writeCacheAt(fd, 3, cache_name);
    try std.testing.expectEqual(@as(?u8, 3), try readCacheAt(fd));
    try expectNoTemps(tmp.dir);
}

test "failed rename cleans temporary file and preserves existing cache" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fd = tmp.dir.handle;
    try writeCacheAt(fd, 7, cache_name);
    _ = try checked(linux.mkdirat(fd, "blocked", 0o700));
    try std.testing.expectError(error.LinuxIoFailure, writeCacheAt(fd, 9, "blocked"));
    try std.testing.expectEqual(@as(?u8, 7), try readCacheAt(fd));
    try expectNoTemps(tmp.dir);
}

test "production declarations compile without executing hardware paths" {
    std.mem.doNotOptimizeAway(&run);
}
