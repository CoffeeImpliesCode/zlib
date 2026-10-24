// SPDX-License-Identifier: zlib
// See ../FORK-LICENSE.md for what that identifier covers.
//
//! Wires the runtime loader, zlib checks, generated dispatch, and patched translation.
//! Runtime consumers use this route instead of linking the C archive.
//! All externs route except the reasoned libc superset; omissions may cause `MissingSymbol`.

const std = @import("std");

/// Prefix used by `runtime/sync.c` and `library.zig`; keep both in sync.
/// Use a distinct prefix for each independent runtime instance in one binary.
const sync_prefix = "zlib_rt";

/// Reasoned system-header superset, not a `translate-c` inventory; over-listing is harmless.
/// Omitting emitted names may cause `MissingSymbol`; commas and ASCII whitespace separate names.
const libc_noise =
    \\DllMain _Exit _Fork _OSSwapInt16 _OSSwapInt32 _OSSwapInt64,
    \\__FreeBSD_libc_enter_restricted_mode __bswap16 __bswap32 __bswap64 __bswap_16 __bswap_32,
    \\__bswap_64 __debugbreak __fastfail __fdelt_chk __fdelt_warn __getcwd_chk,
    \\__getdomainname_chk __getgroups_chk __gethostname_chk __getlogin_r_chk __getpgid,
    \\__getwd_chk __getwd_warn __lock_fhandle __makedev __mingw_access __mingw_call__open,
    \\__mingw_call__open_warn_missing __mingw_call__open_warn_toomany __mingw_call__read,
    \\__mingw_call__sopen __mingw_call__sopen_warn_missing __mingw_call__sopen_warn_toomany,
    \\__mingw_call__wopen __mingw_call__wopen_warn_missing __mingw_call__wopen_warn_toomany,
    \\__mingw_call__wsopen __mingw_call__wsopen_warn_missing __mingw_call__wsopen_warn_toomany,
    \\__mingw_call_memcpy_s __mingw_call_wcscat __mingw_call_wcscpy __mingw_chk_fail_warn,
    \\__mingw_get_crt_info __name __p__acmdln __p__wcmdln __posix_getopt __pread64_chk,
    \\__pread_chk __prefetch __read_chk __readlink_chk __readlinkat_chk __ret_policy,
    \\__section__ __ssp_check_iovec __ssp_gid_bos __ssp_overlap __stack_chk_fail __swap16md,
    \\__swap32md __swap64md __syscall __sysconf __tfork_thread __threadhandle __threadid,
    \\__ttyname_r_chk __typeof __uint16_identity __uint32_identity __uint64_identity,
    \\__volatile__ __wasi_args_get __wasi_args_sizes_get __wasi_clock_res_get,
    \\__wasi_clock_time_get __wasi_environ_get __wasi_environ_sizes_get __wasi_fd_advise,
    \\__wasi_fd_allocate __wasi_fd_close __wasi_fd_datasync __wasi_fd_fdstat_get,
    \\__wasi_fd_fdstat_set_flags __wasi_fd_fdstat_set_rights __wasi_fd_filestat_get,
    \\__wasi_fd_filestat_set_size __wasi_fd_filestat_set_times __wasi_fd_pread,
    \\__wasi_fd_prestat_dir_name __wasi_fd_prestat_get __wasi_fd_pwrite __wasi_fd_read,
    \\__wasi_fd_readdir __wasi_fd_renumber __wasi_fd_seek __wasi_fd_sync __wasi_fd_tell,
    \\__wasi_fd_write __wasi_path_create_directory __wasi_path_filestat_get,
    \\__wasi_path_filestat_set_times __wasi_path_link __wasi_path_open __wasi_path_readlink,
    \\__wasi_path_remove_directory __wasi_path_rename __wasi_path_symlink,
    \\__wasi_path_unlink_file __wasi_poll_oneoff __wasi_proc_exit __wasi_random_get,
    \\__wasi_sched_yield __wasi_sock_accept __wasi_sock_recv __wasi_sock_send,
    \\__wasi_sock_shutdown __wasi_thread_spawn __wasilibc_tell __wcserror __wcserror_s _access,
    \\_access_s _beginthread _beginthreadex _c_exit _cexit _chmod _chsize _chsize_s _close,
    \\_commit _configure_narrow_argv _configure_wide_argv _creat _crt_at_quick_exit,
    \\_crt_atexit _cwait _dup _dup2 _endthread _endthreadex _eof _errno _execl _execle _execlp,
    \\_execlpe _execute_onexit_table _execv _execve _execvp _execvpe _exit _filelength,
    \\_filelengthi64 _findclose _findfirst32 _findfirst32i64 _findfirst64 _findfirst64i32,
    \\_findnext32 _findnext32i64 _findnext64 _findnext64i32 _get_errno _get_osfhandle _getpid,
    \\_initialize_narrow_environment _initialize_onexit_table _initialize_wide_environment,
    \\_initterm _initterm_e _isatty _loaddll _locking _lseek _lseeki64 _memccpy _memicmp,
    \\_memicmp_l _mktemp _mktemp_s _open _open_osfhandle _pipe _query_app_type _read,
    \\_register_onexit_function _register_thread_local_exe_atexit_callback _set_app_type,
    \\_set_errno _setmode _sopen _sopen_s _spawnl _spawnle _spawnlp _spawnlpe _spawnv _spawnve,
    \\_spawnvp _spawnvpe _strcmpi _strcoll_l _strdup _strerror _strerror_s _stricmp _stricmp_l,
    \\_stricoll _stricoll_l _strlwr _strlwr_s _strlwr_s_l _strncat_s_l _strncoll _strncoll_l,
    \\_strncpy_s_l _strnicmp _strnicmp_l _strnicoll _strnicoll_l _strnset _strnset_l,
    \\_strnset_s _strrev _strset _strset_l _strset_s _strtok_s_l _strupr _strupr_l _strupr_s,
    \\_strupr_s_l _strxfrm_l _tell _telli64 _umask _umask_s _unlink _unloaddll _unlock_fhandle,
    \\_wCRT_INIT _waccess _waccess_s _wchmod _wcreat _wcscoll _wcsdup _wcserror _wcserror_s,
    \\_wcsicmp _wcsicmp_l _wcsicoll _wcsicoll_l _wcslwr _wcslwr_l _wcslwr_s _wcslwr_s_l,
    \\_wcsncat_s_l _wcsncoll _wcsncoll_l _wcsncpy_l _wcsncpy_s_l _wcsnicmp _wcsnicmp_l,
    \\_wcsnicoll _wcsnicoll_l _wcsnset _wcsnset_s _wcsnset_s_l _wcsrev _wcsset _wcsset_s,
    \\_wcsset_s_l _wcstok _wcstok_s_l _wcsupr _wcsupr_l _wcsupr_s _wcsupr_s_l _wcsxfrm_l,
    \\_wexecl _wexecle _wexeclp _wexeclpe _wexecv _wexecve _wexecvp _wexecvpe _wfindfirst32,
    \\_wfindfirst64 _wfindfirst64i32 _wfindnext32 _wfindnext64 _wfindnext64i32 _wmktemp,
    \\_wmktemp_s _wopen _wrename _write _wsopen _wsopen_s _wspawnl _wspawnle _wspawnlp,
    \\_wspawnlpe _wspawnv _wspawnve _wspawnvp _wspawnvpe _wsystem _wunlink abort access,
    \\accessx_np acct add_profil alarm async_daemon be16dec be16enc be32dec be32enc be64dec,
    \\be64enc brk chdir check_utility_compat chmod chown chroot chsize close close_range,
    \\closefrom confstr copy_file_range creat crypt crypt_checkpass crypt_get_format,
    \\crypt_newhash crypt_r crypt_set_format ctermid cuserid cwait daemon des_cipher,
    \\des_setkey dup dup2 dup3 eaccess encrypt endusershell eof euidaccess exchangedata execl,
    \\execle execlp execlpe exect execv execvP execve execveat execvp execvpe exit faccessat,
    \\fchdir fchown fchownat fchroot fdatasync fdiscard feature_present fexecve fflagstostr,
    \\ffsctl fgetattrlist filelength fork fpathconf freadlink fsctl fsetattrlist fstatat fsync,
    \\fsync_range fsync_volume_np ftruncate ftruncate64 funlinkat get_current_dir_name,
    \\getattrlist getattrlistat getattrlistbulk getcwd getdirentriesattr getdomainname,
    \\getdtablecount getdtablesize getegid getentropy geteuid getgid getgrouplist,
    \\getgroupmembership getgroups gethostid gethostname gethostuuid getlogin getlogin_r,
    \\getloginclass getmode getopt getopt_long getopt_long_only getosreldate getpagesize,
    \\getpass getpass_r getpassfd getpeereid getpgid getpgrp getpid getppid getresgid,
    \\getresuid getsgroups_np getsid getsubopt getthrid getthrname gettid getuid getusershell,
    \\getwd getwgroups_np group_member initgroups int iruserok iruserok_sa isatty issetugid,
    \\kcmp lchown le16dec le16enc le32dec le32enc le64dec le64enc link linkat lockf lockf64,
    \\locking lpathconf lseek lseek64 memccpy memchr memcmp memcpy memcpy_s memicmp memmove,
    \\memmove_s mempcpy memset mkdir mkdtemp mkdtempat_np mknod mkostemp mkostemps,
    \\mkostempsat_np mkpath_np mkpathat_np mkstemp mkstemp_dprotected_np mkstemps,
    \\mkstempsat_np mktemp mmap name nfssvc nice nlm_syscall open openat pathconf pathconfat,
    \\pause pipe pipe2 pledge posix_close pread pread64 profil pselect psignal pthread_atfork,
    \\pthread_getugid_np pthread_setugid_np pwrite pwrite64 quick_exit quotactl rcmd rcmd_af,
    \\rcmdsh re_comp re_exec read readlink readlinkat reboot remove rename renameat revoke,
    \\rfork rfork_thread rmdir rresvport rresvport_af rresvport_af_addr ruserok sbrk searchfs,
    \\select setattrlist setattrlistat setdomainname setegid seteuid setgid setgroups,
    \\sethostid sethostname setkey setlogin setloginclass setmode setpgid setpgrp setproctitle,
    \\setproctitle_fast setregid setresgid setresuid setreuid setrgid setruid setsgroups_np,
    \\setsid setthrname setuid setusershell setwgroups_np sleep sopen spawnl spawnle spawnlp,
    \\spawnlpe spawnv spawnve spawnvp spawnvpe strcat strcat_s strchr strcmp strcmpi strcoll,
    \\strcpy strcpy_s strcspn strdup strerror strerror_s stricmp strlen strlwr strlwr_l,
    \\strmode strncat strncat_s strncmp strncpy strncpy_s strnicmp strnlen strnlen_s strnset,
    \\strpbrk strrchr strrev strset strsignal strspn strstr strtofflags strtok strtok_r,
    \\strtok_s strupr strxfrm swab swapctl swapoff swapon symlink symlinkat sync,
    \\sync_volume_np syncfs syscall sysconf system tcgetpgrp tcsetpgrp tell truncate,
    \\truncate64 ttyname ttyname_r ttyslot ualarm umask undelete unlink unlinkat unsigned,
    \\unveil unwhiteout usleep valloc vfork vhangup void wcscat wcscat_s wcschr wcscmp wcscoll,
    \\wcscpy wcscpy_s wcscspn wcsdup wcsicmp wcsicoll wcslen wcslwr wcsncat wcsncat_s wcsncmp,
    \\wcsncpy wcsncpy_s wcsnicmp wcsnlen wcsnlen_s wcsnset wcspbrk wcsrchr wcsrev wcsset,
    \\wcsspn wcsstr wcstok_s wcsupr wcsxfrm write,
;

/// Provider exports required by this configuration; none are optional.
const provider_optional = "";

/// Declarations excluded from provider lookup; empty for this configuration.
const provider_excluded = "";

/// Creates the loader core for linked builds, which need its public types.
/// Runtime builds import the core through the dispatch to preserve type identity.
pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    header: *std.Build.Module,
) *std.Build.Module {
    const core = b.createModule(.{
        .root_source_file = b.path("runtime/loader.zig"),
        .target = target,
        .optimize = optimize,
        // The Unix backend uses libc's `dlopen`; linked builds do not use this module.
        .link_libc = true,
    });
    core.addImport("zlib_header", header);
    return core;
}

/// Creates the header module shared by the facade, loader, and provider checks.
pub fn createHeaderModule(b: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    const root = files.add("zlib_header.zig",
        \\pub const bytes = @embedFile("zlib.h");
        \\
    );
    _ = files.addCopyFile(b.path("src/zlib.h"), "zlib.h");
    return b.createModule(.{
        .root_source_file = root,
    });
}

/// Creates runtime-loaded C declarations from the translation for `target`.
pub fn createModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    header: *std.Build.Module,
) *std.Build.Module {
    const core = createCoreModule(b, target, optimize, header);

    const library = b.createModule(.{
        .root_source_file = b.path("runtime/library.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("rt", core);
    library.addImport("zlib_header", header);

    return createDispatchModule(b, translate, target, optimize, core, library);
}

const GeneratedSources = struct {
    native: std.Build.LazyPath,
    dispatch: std.Build.LazyPath,
};

fn createDispatchModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    core: *std.Build.Module,
    library: *std.Build.Module,
) *std.Build.Module {
    const sources = generateDispatch(b, translate, target);

    const dispatch = b.createModule(.{
        .root_source_file = sources.dispatch,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatch.addImport("rt", core);
    dispatch.addImport("library", library);
    // Re-export declarations from the patched translation; do not duplicate types.
    // Its `c_routed` import sends nested translated references back to wrappers.
    const native = b.createModule(.{
        .root_source_file = sources.native,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.addImport("c_routed", dispatch);
    dispatch.addImport("c_native", native);
    dispatch.addCSourceFiles(.{
        .files = &.{"runtime/sync.c"},
        .flags = &.{b.fmt("-DRT_SYNC_PREFIX={s}", .{sync_prefix})},
        .language = .c,
    });
    return dispatch;
}

/// Runs the generator over this target's translation output.
/// Each target and configuration gets its own dispatch.
fn generateDispatch(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) GeneratedSources {
    const generator = b.addExecutable(.{
        .name = b.fmt("zlib-runtime-generate-{s}", .{
            target.result.zigTriple(b.allocator) catch @panic("unspellable target"),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/generate.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });

    const run = b.addRunArtifact(generator);
    run.addArg("--library");
    run.addArg("zlib");
    run.addArg("--translate");
    run.addFileArg(translate.getOutput());
    if (libc_noise.len != 0) {
        run.addArg("--noise");
        run.addArg(libc_noise);
    }
    if (provider_optional.len != 0) {
        run.addArg("--optional");
        run.addArg(provider_optional);
    }
    if (provider_excluded.len != 0) {
        run.addArg("--exclude");
        run.addArg(provider_excluded);
    }
    run.addArg("--native-output");
    const native_source = run.addOutputFileArg2("native.zig", .{});
    run.addArg("--output");
    const dispatch_source = run.addOutputFileArg2("dispatch.zig", .{});
    return .{ .native = native_source, .dispatch = dispatch_source };
}
