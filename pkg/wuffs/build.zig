const std = @import("std");

// All the C macros defined so that the header matches the build.
const defines = [_][]const u8{
    "WUFFS_CONFIG__MODULES",
    "WUFFS_CONFIG__MODULE__AUX__BASE",
    "WUFFS_CONFIG__MODULE__AUX__IMAGE",
    "WUFFS_CONFIG__MODULE__BASE",
    "WUFFS_CONFIG__MODULE__ADLER32",
    "WUFFS_CONFIG__MODULE__CRC32",
    "WUFFS_CONFIG__MODULE__DEFLATE",
    "WUFFS_CONFIG__MODULE__JPEG",
    "WUFFS_CONFIG__MODULE__PNG",
    "WUFFS_CONFIG__MODULE__ZLIB",
};

// Generated C code, includes the macros above. Designed to mimic old c.zig.
// TODO: is this still needed, or are the -D flags enough?
const wuffs_c_source = wuffs_c_source: {
    const include: []const u8 = "#include <wuffs-v0.4.c>";
    const len = len: {
        var len: usize = 0;
        for (defines) |d| len += std.fmt.count("#define {s}\n", .{d});
        len += std.fmt.count("{s}\n", .{include});
        break :len len;
    };

    var buf: [len:0]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    for (defines) |d| writer.print("#define {s}\n", .{d}) catch unreachable;
    writer.print("{s}\n", .{include}) catch unreachable;
    buf[len] = 0;
    break :wuffs_c_source buf;
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("wuffs", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const unit_tests = b.addTest(.{
        .name = "test",
        .root_module = module,
    });

    translate: {
        const translate_c = b.lazyImport(@This(), "translate_c") orelse break :translate;
        const translate_c_dep = b.lazyDependency("translate_c", .{}) orelse break :translate;

        // Aro's Darwin macro generation does not yet assign a
        // __ENVIRONMENT_* macro for visionOS. Wuffs exposes a
        // platform-neutral C ABI, so translate its header as the equivalent
        // iOS Darwin ABI while compiling the C implementation for the real
        // visionOS target below.
        const translate_target = @import("apple_sdk").translateTarget(b, target);

        const wuffs_c: translate_c.Translator = .init(translate_c_dep, .{
            .c_source_file = b.addWriteFiles().add("wuffs_c.h", &wuffs_c_source),
            .target = translate_target,
            .optimize = optimize,
            .libc_file = if (translate_target.result.os.tag.isDarwin()) libc_file: {
                switch (try @import("apple_sdk").pathsForTarget(b, translate_target.result)) {
                    inline else => |paths| break :libc_file paths.libc,
                }
            } else null,
        });

        const wuffs_c_mod = if (target.result.os.tag == .visionos) module: {
            const translated = b.createModule(.{
                .root_source_file = wuffs_c.output_file,
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            translated.addImport("c_builtins", translate_c_dep.module("c_builtins"));
            translated.addImport("helpers", translate_c_dep.module("helpers"));
            break :module translated;
        } else wuffs_c.mod;

        var flags: std.ArrayList([]const u8) = .empty;
        defer flags.deinit(b.allocator);
        try flags.append(b.allocator, "-DWUFFS_IMPLEMENTATION");
        if (target.result.abi == .msvc) {
            try flags.append(b.allocator, "-fno-sanitize=undefined");
            try flags.append(b.allocator, "-fno-sanitize-trap=undefined");
        }
        inline for (defines) |key| {
            try flags.append(b.allocator, "-D" ++ key);
        }

        if (b.lazyDependency("wuffs", .{})) |wuffs_dep| {
            wuffs_c.addIncludePath(wuffs_dep.path("release/c"));
            if (wuffs_c_mod != wuffs_c.mod) {
                wuffs_c_mod.addIncludePath(wuffs_dep.path("release/c"));
            }
            wuffs_c_mod.addCSourceFile(.{
                .file = wuffs_dep.path("release/c/wuffs-v0.4.c"),
                .flags = flags.items,
            });
        }

        module.addImport("wuffs_c", wuffs_c_mod);
    }

    if (b.lazyDependency("pixels", .{})) |pixels_dep| {
        inline for (.{ "000000", "FFFFFF" }) |color| {
            inline for (.{ "gif", "jpg", "png", "ppm" }) |extension| {
                const filename = std.fmt.comptimePrint(
                    "1x1#{s}.{s}",
                    .{ color, extension },
                );
                unit_tests.root_module.addAnonymousImport(filename, .{
                    .root_source_file = pixels_dep.path(filename),
                });
            }
        }
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
