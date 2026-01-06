const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("build.zig.zon");
const log = std.log.scoped(.build);

const host_os = builtin.os.tag;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = getVersion(b) catch |err| {
        std.debug.panic("Failed to get version: error: {t}", .{err});
    };

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = @tagName(manifest.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = b.option(bool, "strip", "strip the binary"),
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

    if (target.result.os.tag == .macos)
        linkMacosFrameWorks(b, exe.root_module, target, optimize);

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
        rel_exe.root_module.addOptions("build_options", build_options);

        if (resolved_target.result.os.tag == .macos and host_os == .macos)
            linkMacosFrameWorks(b, rel_exe.root_module, resolved_target, .ReleaseSafe);

        const prefix = b.fmt("{s}-{t}-{t}-{s}", .{
            rel_exe.name, t.cpu.arch, t.os.tag, version,
        });
        const install = b.addInstallArtifact(rel_exe, .{});
        install.dest_dir = .{ .custom = b.fmt("release/{s}/bin", .{prefix}) };
        install.dest_sub_path = rel_exe.name;

        const wf = b.addWriteFiles();
        const rel_exe_name = b.fmt("{s}/bin/{s}", .{ prefix, rel_exe.out_filename });
        _ = wf.addCopyFile(rel_exe.getEmittedBin(), rel_exe_name);

        const tar = b.addSystemCommand(&.{ "tar", "czf" });
        // https://unix.stackexchange.com/questions/282055/a-lot-of-files-inside-a-tar
        if (builtin.os.tag == .macos) tar.setEnvironmentVariable("COPYFILE_DISABLE", "1");
        tar.setCwd(wf.getDirectory());
        const out_file = tar.addOutputFileArg(b.fmt("{s}.tar.gz", .{prefix}));
        tar.addArg(prefix);

        const install_tar = b.addInstallFileWithDir(out_file, .prefix, b.fmt("release-archives/{s}.tar.gz", .{prefix}));
        release.dependOn(&install_tar.step);
        release.dependOn(&install.step);
    }
}

fn linkMacosFrameWorks(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    if (host_os != .macos) @panic("Building for macos is only supported on macos due to dependency on xcode-sdk");
    const trans_c = b.addTranslateC(.{
        .optimize = optimize,
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

// https://codeberg.org/ziglang/zig/src/branch/master/build.zig
fn getVersion(b: *std.Build) ![]const u8 {
    const version = manifest.version;
    var code: u8 = undefined;
    const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
        "git", "-C", b.build_root.path orelse ".",
        "--git-dir", ".git", // affected by the -C argument
        "describe", "--match",    "*.*.*", //
        "--tags",   "--abbrev=8",
    }, &code, .Ignore) catch {
        return version;
    };
    var git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");
    if (!std.mem.startsWith(u8, git_describe, "v"))
        @panic("crap tag must start with v to differentiate from poop tag");
    git_describe = git_describe[1..];

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.10.0).
            if (!std.mem.eql(u8, git_describe, version)) {
                std.debug.panic(
                    "Crap version '{s}' does not match Git tag '{s}'\n",
                    .{ version, git_describe },
                );
            }
            return version;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
            var sem_ver = try std.SemanticVersion.parse(version);
            if (sem_ver.order(ancestor_ver) == .lt) {
                std.debug.panic(
                    "version '{f}' must be greater or equal to tagged ancestor '{f}'\n",
                    .{ sem_ver, ancestor_ver },
                );
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                log.err("Unexpected `git describe` output: {s}\n", .{git_describe});
                return version;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version, commit_height, commit_id[1..] });
        },
        else => {
            log.err("Unexpected `git describe` output: {s}\n", .{git_describe});
            return version;
        },
    }
}
