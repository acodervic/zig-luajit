const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) (std.zig.system.NativeTargetInfo.DetectError || std.mem.Allocator.Error || std.fmt.BufPrintError || error{ UnsupportedCpuArchitecture, Overflow })!void {
    const target = b.standardTargetOptions(.{});
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
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });

    const flags = .{ "-fno-sanitize=undefined", "-O2", "-fomit-frame-pointer" } ++ switch (os) {
        .linux => .{ "-funwind-tables", "-DLUAJIT_UNWIND_EXTERNAL" },
        else => .{ "", "" },
    };

    lib.addCSourceFiles(&(CORE_FILES ++ LIB_FILES), &flags);

    switch (os) {
        .windows => lib.addObjectFile(.{ .path = "LuaJIT/src/lj_vm.o" }),
        else => lib.addAssemblyFile(.{ .path = "LuaJIT/src/lj_vm.S" }),
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
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    minilua.addCSourceFile(.{ .file = .{ .path = "LuaJIT/src/host/minilua.c" }, .flags = minilua_flags.slice() });
    minilua.linkSystemLibrary("m");

    const minilua_run = b.addRunArtifact(minilua);
    minilua_run.addArg("../dynasm/dynasm.lua");
    minilua_run.addArgs(dasm_opts_arr.slice());
    minilua_run.cwd = "LuaJIT/src";

    // Build VM executable
    const buildvm = b.addExecutable(.{
        .name = "buildvm",
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    buildvm.addCSourceFiles(&VM_FILES, minilua_flags.slice());
    buildvm.addIncludePath(.{ .path = "LuaJIT/src" });
    buildvm.linkSystemLibrary("m");
    buildvm.step.dependOn(&minilua_run.step);

    inline for (.{ "bcdef", "ffdef", "libdef", "recdef" }) |def| {
        const buildvm_def_run = b.addRunArtifact(buildvm);
        buildvm_def_run.addArgs(&.{ "-m", def, "-o", "lj_" ++ def ++ ".h" });
        inline for (LIB_FILES) |LIB_FILE| {
            buildvm_def_run.addArg(std.fs.path.basename(LIB_FILE));
        }
        buildvm_def_run.cwd = "LuaJIT/src";
        lib.step.dependOn(&buildvm_def_run.step);
    }

    const buildvm_folddef_run = b.addRunArtifact(buildvm);
    buildvm_folddef_run.addArgs(&.{ "-m", "folddef", "-o", "lj_folddef.h", "lj_opt_fold.c" });
    buildvm_folddef_run.cwd = "LuaJIT/src";
    lib.step.dependOn(&buildvm_folddef_run.step);

    const buildvm_vmdef_run = b.addRunArtifact(buildvm);
    buildvm_vmdef_run.addArgs(&.{ "-m", "vmdef", "-o", "jit/vmdef.lua" });
    inline for (LIB_FILES) |LIB_FILE| {
        buildvm_vmdef_run.addArg(std.fs.path.basename(LIB_FILE));
    }
    buildvm_vmdef_run.cwd = "LuaJIT/src";
    lib.step.dependOn(&buildvm_vmdef_run.step);

    const buildvm_ljvm_run = b.addRunArtifact(buildvm);
    buildvm_ljvm_run.cwd = "LuaJIT/src";
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

const CORE_FILES = .{
    "LuaJIT/src/lib_aux.c",
    "LuaJIT/src/lib_init.c",
    "LuaJIT/src/lj_alloc.c",
    "LuaJIT/src/lj_api.c",
    "LuaJIT/src/lj_asm.c",
    "LuaJIT/src/lj_assert.c",
    "LuaJIT/src/lj_bc.c",
    "LuaJIT/src/lj_bcread.c",
    "LuaJIT/src/lj_bcwrite.c",
    "LuaJIT/src/lj_buf.c",
    "LuaJIT/src/lj_carith.c",
    "LuaJIT/src/lj_ccall.c",
    "LuaJIT/src/lj_ccallback.c",
    "LuaJIT/src/lj_cconv.c",
    "LuaJIT/src/lj_cdata.c",
    "LuaJIT/src/lj_char.c",
    "LuaJIT/src/lj_clib.c",
    "LuaJIT/src/lj_cparse.c",
    "LuaJIT/src/lj_crecord.c",
    "LuaJIT/src/lj_ctype.c",
    "LuaJIT/src/lj_debug.c",
    "LuaJIT/src/lj_dispatch.c",
    "LuaJIT/src/lj_err.c",
    "LuaJIT/src/lj_ffrecord.c",
    "LuaJIT/src/lj_func.c",
    "LuaJIT/src/lj_gc.c",
    "LuaJIT/src/lj_gdbjit.c",
    "LuaJIT/src/lj_ir.c",
    "LuaJIT/src/lj_lex.c",
    "LuaJIT/src/lj_lib.c",
    "LuaJIT/src/lj_load.c",
    "LuaJIT/src/lj_mcode.c",
    "LuaJIT/src/lj_meta.c",
    "LuaJIT/src/lj_obj.c",
    "LuaJIT/src/lj_opt_dce.c",
    "LuaJIT/src/lj_opt_fold.c",
    "LuaJIT/src/lj_opt_loop.c",
    "LuaJIT/src/lj_opt_mem.c",
    "LuaJIT/src/lj_opt_narrow.c",
    "LuaJIT/src/lj_opt_sink.c",
    "LuaJIT/src/lj_opt_split.c",
    "LuaJIT/src/lj_parse.c",
    "LuaJIT/src/lj_prng.c",
    "LuaJIT/src/lj_profile.c",
    "LuaJIT/src/lj_record.c",
    "LuaJIT/src/lj_serialize.c",
    "LuaJIT/src/lj_snap.c",
    "LuaJIT/src/lj_state.c",
    "LuaJIT/src/lj_str.c",
    "LuaJIT/src/lj_strfmt_num.c",
    "LuaJIT/src/lj_strfmt.c",
    "LuaJIT/src/lj_strscan.c",
    "LuaJIT/src/lj_tab.c",
    "LuaJIT/src/lj_trace.c",
    "LuaJIT/src/lj_udata.c",
    "LuaJIT/src/lj_vmevent.c",
    "LuaJIT/src/lj_vmmath.c",
};

const LIB_FILES = .{
    "LuaJIT/src/lib_base.c",
    "LuaJIT/src/lib_bit.c",
    "LuaJIT/src/lib_buffer.c",
    "LuaJIT/src/lib_debug.c",
    "LuaJIT/src/lib_ffi.c",
    "LuaJIT/src/lib_io.c",
    "LuaJIT/src/lib_jit.c",
    "LuaJIT/src/lib_math.c",
    "LuaJIT/src/lib_os.c",
    "LuaJIT/src/lib_package.c",
    "LuaJIT/src/lib_string.c",
    "LuaJIT/src/lib_table.c",
};

const VM_FILES = .{
    "LuaJIT/src/host/buildvm_asm.c",
    "LuaJIT/src/host/buildvm_fold.c",
    "LuaJIT/src/host/buildvm_lib.c",
    "LuaJIT/src/host/buildvm_peobj.c",
    "LuaJIT/src/host/buildvm.c",
};
