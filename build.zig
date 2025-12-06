const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("build.zig.zon");

const host_os = builtin.os.tag;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = @tagName(manifest.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = b.option(bool, "strip", "strip the binary"),
        }),
    });

    if (target.result.os.tag == .macos)
        linkMacosFrameWorks(b, exe.root_module, target);

    b.installArtifact(exe);

    const release = b.step("release", "make an upstream binary release");
    const release_targets = [_]std.Target.Query{
        .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .x86,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .riscv64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
        },

        .{
            .cpu_arch = .x86_64,
            .os_tag = .macos,
        },
    };
    for (release_targets) |target_query| {
        const resolved_target = b.resolveTargetQuery(target_query);
        const t = resolved_target.result;
        if (t.os.tag == .macos and host_os != .macos) continue;
        const rel_exe = b.addExecutable(.{
            .name = @tagName(manifest.name),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved_target,
                .optimize = .ReleaseSafe,
                .strip = true,
            }),
        });

        if (resolved_target.result.os.tag == .macos and host_os == .macos)
            linkMacosFrameWorks(b, rel_exe.root_module, resolved_target);

        const install = b.addInstallArtifact(rel_exe, .{});
        install.dest_dir = .prefix;
        install.dest_sub_path = b.fmt("{s}-{s}-{s}", .{
            @tagName(t.cpu.arch), @tagName(t.os.tag), rel_exe.name,
        });

        release.dependOn(&install.step);
    }
}

fn linkMacosFrameWorks(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (host_os != .macos) @panic("Building for macos is only supported on macos due to dependency on xcode-sdk");
    const trans_c = b.addTranslateC(.{
        .optimize = .ReleaseSafe,
        .target = target,
        .root_source_file = b.path("include/macos.h"),
    });

    const sdk_path = std.zig.system.darwin.getSdk(b.allocator, &target.result) orelse
        @panic("Failed to find SDK!");

    trans_c.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{
        sdk_path,
        "usr/include",
    }) });

    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{
        sdk_path,
        "System/Library/PrivateFrameworks",
    }) });
    module.linkFramework("kperf", .{});
    module.linkFramework("kperfdata", .{});
    module.addImport("c", trans_c.createModule());
}
