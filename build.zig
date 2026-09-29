const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .linux) @panic("swaymt requires Linux");
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    options.addOption(bool, "brightstay", b.option(bool, "brightstay", "Include hardware-specific BrightStay support") orelse false);
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    module.addOptions("options", options);
    const exe = b.addExecutable(.{ .name = "swaymt", .root_module = module });
    if (optimize != .Debug) exe.lto = .full;
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run swaymt").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    if (optimize != .Debug) tests.lto = .full;
    b.step("test", "Run isolated tests").dependOn(&b.addRunArtifact(tests).step);
}
