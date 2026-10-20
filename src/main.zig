const std = @import("std");
const options = @import("options");
const sway = @import("sway.zig");
const dmenu = @import("dmenu.zig");
const brightstay = if (options.brightstay) @import("brightstay.zig") else struct {};

const Mode = enum { internal, external, extended, dmenu, brightstay };
const Cli = struct {
    internal: ?[]const u8 = null,
    external: ?[]const u8 = null,
    mode: Mode = .extended,
    help: bool = false,
};
const request = "Display: \nInternal\nExternal\nExtended\n" ++ if (options.brightstay) "BrightStay\n" else "";
const usage =
    \\Usage: swaymt -i INTERNAL -e EXTERNAL [internal|external|extended|dmenu]
    \\  -i, --internal NAME   Internal output connector
    \\  -e, --external NAME   External output connector
    \\  -h, --help            Show help
    \\Default: extended. The dmenu picker uses Noctalia's Unix socket.
    \\
++ if (options.brightstay) "  swaymt brightstay     Reapply the hardware-specific color preset\n" else "";

pub fn main(init: std.process.Init.Minimal) void {
    run(init) catch |err| {
        std.debug.print("swaymt: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn parse(args: []const [*:0]const u8) !Cli {
    var cli: Cli = .{};
    var mode_seen = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cli.help = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--internal") or
            std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--external"))
        {
            const internal = std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--internal");
            const slot = if (internal) &cli.internal else &cli.external;
            if (slot.* != null) return error.DuplicateOutputOption;
            index += 1;
            if (index == args.len) return error.MissingOutputName;
            const name = std.mem.span(args[index]);
            if (name.len == 0 or name[0] == '-') return error.InvalidOutputName;
            slot.* = name;
        } else {
            if (mode_seen) return error.UnexpectedArgument;
            cli.mode = std.meta.stringToEnum(Mode, arg) orelse return error.UnknownModeOrOption;
            if (cli.mode == .brightstay and !options.brightstay) return error.BrightStayNotCompiled;
            mode_seen = true;
        }
    }
    if (!cli.help and cli.mode != .brightstay) {
        if (cli.internal == null or cli.external == null) return error.MissingOutputOptions;
        if (std.ascii.eqlIgnoreCase(cli.internal.?, cli.external.?)) return error.SameOutput;
    }
    return cli;
}

fn selection(text: []const u8) !?Mode {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return null;
    inline for (.{ .{ "Internal", Mode.internal }, .{ "External", Mode.external }, .{ "Extended", Mode.extended } }) |item| {
        if (std.mem.eql(u8, value, item[0])) return item[1];
    }
    if (options.brightstay and std.mem.eql(u8, value, "BrightStay")) return .brightstay;
    return error.InvalidDmenuSelection;
}

fn menuPath(buffer: []u8, runtime: []const u8, display: []const u8) ![]const u8 {
    if (runtime.len == 0 or display.len == 0) return error.EmptyDmenuEnvironment;
    return std.mem.print(buffer, "{s}/noctalia-dmenu-{s}.sock", .{ runtime, display }) catch return error.SocketPathTooLong;
}

fn run(init: std.process.Init.Minimal) !void {
    const cli = parse(init.args.vector) catch |err| {
        std.debug.print("{s}", .{usage});
        return err;
    };
    if (cli.help) {
        printHelp();
        return;
    }
    var mode = cli.mode;
    if (mode == .dmenu) {
        const runtime = init.environ.getPosix("XDG_RUNTIME_DIR") orelse return error.MissingXdgRuntimeDir;
        const display = init.environ.getPosix("WAYLAND_DISPLAY") orelse return error.MissingWaylandDisplay;
        var path: [108]u8 = undefined;
        var response: [64]u8 = undefined;
        const socket = try menuPath(&path, runtime, display);
        const chosen = dmenu.choose(socket, request, &response) catch |err| {
            std.debug.print("swaymt: Noctalia dmenu socket {s}: {s}\n", .{ socket, @errorName(err) });
            return err;
        } orelse return;
        mode = (try selection(chosen)) orelse return;
    }
    if (options.brightstay and mode == .brightstay) {
        brightstay.run();
        return;
    }
    const socket = init.environ.getPosix("SWAYSOCK") orelse return error.MissingSwaySock;
    if (socket.len == 0) return error.MissingSwaySock;
    const sway_mode: sway.Mode = switch (mode) {
        .internal => .internal,
        .external => .external,
        .extended => .extended,
        else => unreachable,
    };
    sway.apply(socket, cli.internal.?, cli.external.?, sway_mode) catch |err| {
        std.debug.print("swaymt: Sway socket {s}: {s}\n", .{ socket, @errorName(err) });
        return err;
    };
}

fn printHelp() void {
    var written: usize = 0;
    while (written < usage.len) {
        const n = std.os.linux.write(1, usage[written..].ptr, usage.len - written);
        switch (std.os.linux.errno(n)) {
            .SUCCESS => if (n == 0) return else {
                written += n;
            },
            .INTR => continue,
            else => return,
        }
    }
}

test "CLI defaults, modes, long options and validation" {
    const names = [_][*:0]const u8{ "swaymt", "-i", "eDP-1", "-e", "HDMI-A-1" };
    try std.testing.expectEqual(Mode.extended, (try parse(&names)).mode);
    inline for (.{ "internal", "external", "extended", "dmenu" }) |mode| {
        const cli = try parse(&(names ++ .{mode}));
        try std.testing.expectEqualStrings(mode, @tagName(cli.mode));
        try std.testing.expectError(error.MissingOutputOptions, parse(&.{ "swaymt", mode }));
    }
    const long = try parse(&.{ "swaymt", "--external", "HDMI-A-1", "--internal", "eDP-1" });
    try std.testing.expectEqualStrings("eDP-1", long.internal.?);
    try std.testing.expect((try parse(&.{ "swaymt", "--help" })).help);
    try std.testing.expectError(error.MissingOutputOptions, parse(&.{"swaymt"}));
    try std.testing.expectError(error.MissingOutputName, parse(&.{ "swaymt", "-i" }));
    try std.testing.expectError(error.InvalidOutputName, parse(&.{ "swaymt", "-i", "-e" }));
    try std.testing.expectError(error.DuplicateOutputOption, parse(&.{ "swaymt", "-i", "one", "-i", "two" }));
    try std.testing.expectError(error.SameOutput, parse(&.{ "swaymt", "-i", "one", "-e", "ONE" }));
    try std.testing.expectError(error.UnknownModeOrOption, parse(&.{ "swaymt", "mirror" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&(names ++ .{ "internal", "external" })));
    if (options.brightstay) {
        try std.testing.expectEqual(Mode.brightstay, (try parse(&.{ "swaymt", "brightstay" })).mode);
    } else {
        try std.testing.expectError(error.BrightStayNotCompiled, parse(&.{ "swaymt", "brightstay" }));
    }
}

test "Noctalia request, path and selection mapping" {
    const expected = "Display: \nInternal\nExternal\nExtended\n" ++ if (options.brightstay) "BrightStay\n" else "";
    try std.testing.expectEqualStrings(expected, request);
    var path: [108]u8 = undefined;
    try std.testing.expectEqualStrings("/example/noctalia-dmenu-wayland-1.sock", try menuPath(&path, "/example", "wayland-1"));
    try std.testing.expectEqual(@as(?Mode, .internal), try selection("Internal"));
    try std.testing.expectEqual(@as(?Mode, .external), try selection(" External\n"));
    try std.testing.expectEqual(@as(?Mode, .extended), try selection("Extended"));
    try std.testing.expectEqual(@as(?Mode, null), try selection(" \r\n"));
    try std.testing.expectError(error.InvalidDmenuSelection, selection("Mirror"));
    if (options.brightstay) {
        try std.testing.expectEqual(@as(?Mode, .brightstay), try selection("BrightStay"));
    } else {
        try std.testing.expectError(error.InvalidDmenuSelection, selection("BrightStay"));
    }
}

test {
    _ = sway;
    _ = dmenu;
    if (options.brightstay) _ = brightstay;
}
