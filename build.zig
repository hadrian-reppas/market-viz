const std = @import("std");

pub fn build(b: *std.Build) void {
    const font_options = b.option([]const []const u8, "font", "") orelse
        &[_][]const u8{
            "fonts/roboto_light.ttf:20,30,40",
            "fonts/roboto_regular.ttf:20,30",
            "fonts/roboto_medium.ttf:20,30",
        };

    const fontgen = b.addExecutable(.{
        .name = "fontgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fontgen.zig"),
            .optimize = .Debug, // .ReleaseSafe
            .target = b.graph.host,
            .link_libc = true,
        }),
    });
    fontgen.root_module.linkSystemLibrary("harfbuzz", .{});
    fontgen.root_module.linkSystemLibrary("freetype2", .{});

    const fontgen_step = b.addRunArtifact(fontgen);
    const fonts = fontgen_step.addOutputFileArg("fonts.zig");
    fontgen_step.addArgs(font_options);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    });
    const exe = b.addExecutable(.{
        .name = "market-viz",
        .root_module = module,
    });
    exe.root_module.linkSystemLibrary("crypto", .{});
    exe.root_module.linkSystemLibrary("SDL3", .{});
    exe.root_module.addAnonymousImport("fonts", .{
        .root_source_file = fonts,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
