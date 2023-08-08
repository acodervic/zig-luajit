const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) (std.zig.system.NativeTargetInfo.DetectError || std.mem.Allocator.Error || std.fmt.BufPrintError || error{ UnsupportedCpuArchitecture, Overflow })!void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = .{ .major = 2, .minor = 1, .patch = 0 };
    const target_info = try std.zig.system.NativeTargetInfo.detect(target);
    const arch = target_info.target.cpu.arch;
    const os = target_info.target.os.tag;
    const abi = target_info.target.abi;

    // Library
    const lib_step = b.step("lib", "Install library");

    const lib = b.addStaticLibrary(.{
        .name = "luajit",
        .version = version,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const flags = .{ "-fno-sanitize=undefined", "-O2", "-fomit-frame-pointer" } ++ switch (os) {
        .linux => .{ "-funwind-tables", "-DLUAJIT_UNWIND_EXTERNAL" },
        else => .{ "", "" },
    };

    lib.addCSourceFiles(&(CORE_FILES ++ LIB_FILES), &flags);

    switch (os) {
        .windows => lib.addObjectFile(.{ .path = LUAJIT_DIR ++ "lj_vm.o" }),
        else => lib.addAssemblyFile(.{ .path = LUAJIT_DIR ++ "lj_vm.S" }),
    }

    const sys_libs = .{"m"} ++ .{switch (os) {
        .linux => "unwind",
        else => "",
    }};

    inline for (sys_libs) |sys_lib| {
        lib.linkSystemLibrary(sys_lib);
    }

    const arch_name = switch (arch) {
        .aarch64, .aarch64_be => "arm64",
        .arm, .mips, .mips64, .mipsel, .mips64el, .x86 => @tagName(arch),
        .powerpc, .powerpcle => "ppc",
        .x86_64 => "x64",
        else => return error.UnsupportedCpuArchitecture,
    };

    var lj_target_buf: [64]u8 = undefined;
    var minilua_flags = try std.BoundedArray([]const u8, 512).init(0);
    const lj_target = try std.fmt.bufPrint(lj_target_buf[0..], "-DLUAJIT_TARGET=LUAJIT_ARCH_{s}", .{arch_name});
    minilua_flags.appendSliceAssumeCapacity(&.{ "-fno-sanitize=undefined", lj_target });

    switch (arch) {
        .aarch64_be => minilua_flags.appendAssumeCapacity("-D__AARCH64EB__=1"),
        .mipsel, .mips64el => minilua_flags.appendAssumeCapacity("-D__MIPSEL__=1"),
        .powerpc => minilua_flags.appendAssumeCapacity("-DLJ_ARCH_ENDIAN=LUAJIT_BE"),
        .powerpcle => minilua_flags.appendAssumeCapacity("-DLJ_ARCH_ENDIAN=LUAJIT_LE"),
        .x86 => minilua_flags.appendSliceAssumeCapacity(&.{ "-march=i686", "-msse", "-msse2", "-mfpmath=sse" }),
        else => {},
    }

    var dasm_opts_arr = try std.BoundedArray([]const u8, 512).init(0);

    dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "DUALNUM", "-D", switch (builtin.cpu.arch.endian()) {
        .Little => "ENDIAN_LE",
        .Big => "ENDIAN_BE",
    } });

    switch (arch) {
        .aarch64, .aarch64_be, .mips64, .mips64el, .x86_64 => dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "P64" }),
        else => {},
    }

    switch (os) {
        .ios => { // iOS supports neither JIT nor stack unwinding.
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "FFI", "-D", "NO_UNWIND" });
            minilua_flags.appendAssumeCapacity("-DLUAJIT_NO_UNWIND");
        },
        .lv2 => if (arch != .powerpc64) { // PS3 doesn't support JIT, FFI or stack unwinding.
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "JIT", "-D", "FFI", "-D", "NO_UNWIND" });
            minilua_flags.appendAssumeCapacity("-DLUAJIT_NO_UNWIND");
        },
        .ps4, .ps5 => { // PS4 and PS5 don't support JIT, FFI or stack unwinding.
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "NO_UNWIND" });
            minilua_flags.appendAssumeCapacity("-DLUAJIT_NO_UNWIND");
        },
        .windows => if (arch != .powerpc64 and arch != .x86_64) { // Xbox 360 and Xbox One support neither JIT nor FFI.
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "JIT", "-D", "FFI" });
        },
        else => if (arch != .aarch64 and arch != .arm) { // PS Vita and Nintendo Switch support neither JIT nor FFI.
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "JIT", "-D", "FFI" });
        },
    }

    switch (abi.floatAbi()) {
        .hard => {
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "FPU", "-D", "HFABI" });
            minilua_flags.appendSliceAssumeCapacity(&.{ "-DLJ_ARCH_HASFPU=1", "-DLJ_ABI_SOFTFP=0" });
        },
        .soft => {},
        .soft_fp => minilua_flags.appendSliceAssumeCapacity(&.{ "-DLJ_ARCH_HASFPU=0", "-DLJ_ABI_SOFTFP=1" }),
    }

    dasm_opts_arr.appendSliceAssumeCapacity(&(.{ "-D", "VER=80" })); // LJ_ARCH_VERSION

    switch (os) {
        .windows => minilua_flags.appendSliceAssumeCapacity(&.{ "-D", "WIN" }),
        else => {},
    }

    var dynasm_arch = arch_name;

    switch (arch) {
        .aarch64 => dynasm_arch = "arm64",
        .arm => if (os == .ios) {
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "IOS" });
        },
        .mips, .mipsel, .mips64, .mips64el => {
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "MIPSR6" });
        },
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => {
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "SQRT" });
            dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "ROUND" });
            if (arch == .powerpc64 or arch == .powerpc64le) {
                dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-D", "GPR64" });
            }
        },
        else => {},
    }

    var dasm_dasc_buf: [64]u8 = undefined;
    const dasm_dasc = try std.fmt.bufPrint(dasm_dasc_buf[0..], "./vm_{s}.dasc", .{dynasm_arch});
    dasm_opts_arr.appendSliceAssumeCapacity(&.{ "-o", "./host/buildvm_arch.h", dasm_dasc });

    // Minilua interpreter
    const minilua = b.addExecutable(.{
        .name = "minilua",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    minilua.addCSourceFile(.{ .file = .{ .path = LUAJIT_HOST_DIR ++ "minilua.c" }, .flags = minilua_flags.slice() });
    minilua.linkSystemLibrary("m");

    const minilua_run = b.addRunArtifact(minilua);
    minilua_run.addArg("../dynasm/dynasm.lua");
    minilua_run.addArgs(dasm_opts_arr.slice());
    minilua_run.cwd = LUAJIT_DIR;

    // Build VM executable
    const buildvm = b.addExecutable(.{
        .name = "buildvm",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    buildvm.addCSourceFiles(&VM_FILES, minilua_flags.slice());
    buildvm.addIncludePath(.{ .path = LUAJIT_DIR });
    buildvm.linkSystemLibrary("m");
    buildvm.step.dependOn(&minilua_run.step);

    inline for (.{ "bcdef", "ffdef", "libdef", "recdef" }) |def| {
        const buildvm_def_run = b.addRunArtifact(buildvm);
        buildvm_def_run.addArgs(&.{ "-m", def, "-o", "lj_" ++ def ++ ".h" });
        inline for (LIB_FILES) |LIB_FILE| {
            buildvm_def_run.addArg(std.fs.path.basename(LIB_FILE));
        }
        buildvm_def_run.cwd = LUAJIT_DIR;
        lib.step.dependOn(&buildvm_def_run.step);
    }

    const buildvm_folddef_run = b.addRunArtifact(buildvm);
    buildvm_folddef_run.addArgs(&.{ "-m", "folddef", "-o", "lj_folddef.h", "lj_opt_fold.c" });
    buildvm_folddef_run.cwd = LUAJIT_DIR;
    lib.step.dependOn(&buildvm_folddef_run.step);

    const buildvm_vmdef_run = b.addRunArtifact(buildvm);
    buildvm_vmdef_run.addArgs(&.{ "-m", "vmdef", "-o", "jit/vmdef.lua" });
    inline for (LIB_FILES) |LIB_FILE| {
        buildvm_vmdef_run.addArg(std.fs.path.basename(LIB_FILE));
    }
    buildvm_vmdef_run.cwd = LUAJIT_DIR;
    lib.step.dependOn(&buildvm_vmdef_run.step);

    const buildvm_ljvm_run = b.addRunArtifact(buildvm);
    buildvm_ljvm_run.cwd = LUAJIT_DIR;
    buildvm_ljvm_run.addArgs(&.{ "-m", switch (os) {
        .macos, .ios => "machasm",
        .windows => "peobj",
        else => "elfasm",
    }, "-o", switch (os) {
        .windows => "lj_vm.o",
        else => "lj_vm.S",
    } });
    lib.step.dependOn(&buildvm_ljvm_run.step);

    const lib_install = b.addInstallArtifact(lib, .{});
    lib_step.dependOn(&lib_install.step);
    b.default_step.dependOn(lib_step);
}

const LUAJIT_DIR = "LuaJIT/src/";

const CORE_FILES = .{
    LUAJIT_DIR ++ "lib_aux.c",
    LUAJIT_DIR ++ "lib_init.c",
    LUAJIT_DIR ++ "lj_alloc.c",
    LUAJIT_DIR ++ "lj_api.c",
    LUAJIT_DIR ++ "lj_asm.c",
    LUAJIT_DIR ++ "lj_assert.c",
    LUAJIT_DIR ++ "lj_bc.c",
    LUAJIT_DIR ++ "lj_bcread.c",
    LUAJIT_DIR ++ "lj_bcwrite.c",
    LUAJIT_DIR ++ "lj_buf.c",
    LUAJIT_DIR ++ "lj_carith.c",
    LUAJIT_DIR ++ "lj_ccall.c",
    LUAJIT_DIR ++ "lj_ccallback.c",
    LUAJIT_DIR ++ "lj_cconv.c",
    LUAJIT_DIR ++ "lj_cdata.c",
    LUAJIT_DIR ++ "lj_char.c",
    LUAJIT_DIR ++ "lj_clib.c",
    LUAJIT_DIR ++ "lj_cparse.c",
    LUAJIT_DIR ++ "lj_crecord.c",
    LUAJIT_DIR ++ "lj_ctype.c",
    LUAJIT_DIR ++ "lj_debug.c",
    LUAJIT_DIR ++ "lj_dispatch.c",
    LUAJIT_DIR ++ "lj_err.c",
    LUAJIT_DIR ++ "lj_ffrecord.c",
    LUAJIT_DIR ++ "lj_func.c",
    LUAJIT_DIR ++ "lj_gc.c",
    LUAJIT_DIR ++ "lj_gdbjit.c",
    LUAJIT_DIR ++ "lj_ir.c",
    LUAJIT_DIR ++ "lj_lex.c",
    LUAJIT_DIR ++ "lj_lib.c",
    LUAJIT_DIR ++ "lj_load.c",
    LUAJIT_DIR ++ "lj_mcode.c",
    LUAJIT_DIR ++ "lj_meta.c",
    LUAJIT_DIR ++ "lj_obj.c",
    LUAJIT_DIR ++ "lj_opt_dce.c",
    LUAJIT_DIR ++ "lj_opt_fold.c",
    LUAJIT_DIR ++ "lj_opt_loop.c",
    LUAJIT_DIR ++ "lj_opt_mem.c",
    LUAJIT_DIR ++ "lj_opt_narrow.c",
    LUAJIT_DIR ++ "lj_opt_sink.c",
    LUAJIT_DIR ++ "lj_opt_split.c",
    LUAJIT_DIR ++ "lj_parse.c",
    LUAJIT_DIR ++ "lj_prng.c",
    LUAJIT_DIR ++ "lj_profile.c",
    LUAJIT_DIR ++ "lj_record.c",
    LUAJIT_DIR ++ "lj_serialize.c",
    LUAJIT_DIR ++ "lj_snap.c",
    LUAJIT_DIR ++ "lj_state.c",
    LUAJIT_DIR ++ "lj_str.c",
    LUAJIT_DIR ++ "lj_strfmt_num.c",
    LUAJIT_DIR ++ "lj_strfmt.c",
    LUAJIT_DIR ++ "lj_strscan.c",
    LUAJIT_DIR ++ "lj_tab.c",
    LUAJIT_DIR ++ "lj_trace.c",
    LUAJIT_DIR ++ "lj_udata.c",
    LUAJIT_DIR ++ "lj_vmevent.c",
    LUAJIT_DIR ++ "lj_vmmath.c",
};

const LIB_FILES = .{
    LUAJIT_DIR ++ "lib_base.c",
    LUAJIT_DIR ++ "lib_bit.c",
    LUAJIT_DIR ++ "lib_buffer.c",
    LUAJIT_DIR ++ "lib_debug.c",
    LUAJIT_DIR ++ "lib_ffi.c",
    LUAJIT_DIR ++ "lib_io.c",
    LUAJIT_DIR ++ "lib_jit.c",
    LUAJIT_DIR ++ "lib_math.c",
    LUAJIT_DIR ++ "lib_os.c",
    LUAJIT_DIR ++ "lib_package.c",
    LUAJIT_DIR ++ "lib_string.c",
    LUAJIT_DIR ++ "lib_table.c",
};

const LUAJIT_HOST_DIR = LUAJIT_DIR ++ "host/";

const VM_FILES = .{
    LUAJIT_HOST_DIR ++ "buildvm_asm.c",
    LUAJIT_HOST_DIR ++ "buildvm_fold.c",
    LUAJIT_HOST_DIR ++ "buildvm_lib.c",
    LUAJIT_HOST_DIR ++ "buildvm_peobj.c",
    LUAJIT_HOST_DIR ++ "buildvm.c",
};
