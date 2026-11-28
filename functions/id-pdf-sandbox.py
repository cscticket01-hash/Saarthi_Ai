"""Fail-closed Linux Poppler sandbox for the central ID-card library.

Only fixed Poppler operations are accepted. No inherited broker environment,
network, process spawning or arbitrary filesystem writes. Requires Landlock
ABI >= 6 and libseccomp. Production activation requires hosted positive and
negative probes plus authenticated staging acceptance.
"""
import ctypes as C
import errno
import json
import os
import platform
import re
import resource
import socket
import stat
import sys

LIBC = C.CDLL(None, use_errno=True)
LIBC.syscall.restype = C.c_long
SEC = C.CDLL("libseccomp.so.2", use_errno=True)
SEC.seccomp_init.argtypes = [C.c_uint32]
SEC.seccomp_init.restype = C.c_void_p
SEC.seccomp_syscall_resolve_name.argtypes = [C.c_char_p]
SEC.seccomp_syscall_resolve_name.restype = C.c_int
SEC.seccomp_rule_add.argtypes = [C.c_void_p, C.c_uint32, C.c_int, C.c_uint]
SEC.seccomp_rule_add.restype = C.c_int
SEC.seccomp_load.argtypes = [C.c_void_p]
SEC.seccomp_load.restype = C.c_int
SEC.seccomp_release.argtypes = [C.c_void_p]

EXEC, WRITE, READ, READDIR = 1, 2, 4, 8
TRUNCATE = 1 << 14

class Ruleset(C.Structure):
    _fields_ = [("fs", C.c_uint64), ("net", C.c_uint64), ("scoped", C.c_uint64)]

class PathRule(C.Structure):
    _pack_ = 1
    _fields_ = [("access", C.c_uint64), ("fd", C.c_int32)]

def checked(result):
    if result < 0:
        raise OSError(C.get_errno() or errno.EPERM, "sandbox setup failed")
    return result

def limits():
    for key, value in [
        (resource.RLIMIT_CPU, 8),
        (resource.RLIMIT_AS, 256 * 1024 * 1024),
        (resource.RLIMIT_FSIZE, 8 * 1024 * 1024),
        (resource.RLIMIT_NOFILE, 48),
        (resource.RLIMIT_CORE, 0),
    ]:
        resource.setrlimit(key, (value, value))

def isolate(executable, directory, outputs):
    if platform.machine() not in ("x86_64", "aarch64") or os.getuid() == 0 or os.geteuid() == 0:
        raise RuntimeError("non-root Linux sandbox required")
    abi = checked(LIBC.syscall(444, 0, 0, 1))
    if abi < 6:
        raise RuntimeError("Landlock ABI 6 required")
    checked(LIBC.prctl(38, 1, 0, 0, 0))  # PR_SET_NO_NEW_PRIVS
    rules = Ruleset(0xffff, 3, 3)
    fd = checked(LIBC.syscall(444, C.byref(rules), C.sizeof(rules), 0))
    def add(path, rights):
        pfd = os.open(path, os.O_PATH | os.O_CLOEXEC)
        try:
            rule = PathRule(rights, pfd)
            checked(LIBC.syscall(445, fd, 1, C.byref(rule), 0))
        finally:
            os.close(pfd)
    try:
        # Only runtime libraries/fonts and this one job's input/output.
        # No /proc, application tree, broker credentials or other jobs.
        for p in ("/usr/lib", "/usr/lib64", "/lib", "/lib64"):
            if os.path.isdir(p):
                add(p, EXEC | READ | READDIR)
        for p in ("/etc/fonts", "/usr/share/fonts", "/usr/share/fontconfig",
                  "/usr/share/poppler", "/usr/share/locale", "/var/cache/fontconfig"):
            if os.path.isdir(p):
                add(p, READ | READDIR)
        for p in ("/etc/ld.so.cache", "/etc/localtime", "/dev/urandom"):
            if os.path.isfile(p) or p == "/dev/urandom":
                if os.path.exists(p):
                    add(p, READ)
        if os.path.exists("/dev/null"):
            add("/dev/null", READ | WRITE)
        if executable:
            add(executable, EXEC | READ)
        add(directory, READ | READDIR)
        # Preallocated exact outputs only: no creation of arbitrary files,
        # directories, hardlinks or symlinks, so total output is bounded.
        for path in outputs:
            add(path, READ | WRITE | TRUNCATE)
        checked(LIBC.syscall(446, fd, 0))
    finally:
        os.close(fd)
    # Default-deny syscall allowlist. No sockets, process creation, ptrace,
    # signalling other processes, mount, namespace creation or io_uring.
    names = """
      read write readv writev pread64 pwrite64 close close_range lseek
      open openat openat2 fstat newfstatat stat lstat statx access faccessat
      faccessat2 readlink readlinkat getdents64 getcwd chdir
      mmap mmap2 mprotect munmap mremap brk madvise mincore
      arch_prctl set_tid_address set_robust_list rseq futex futex_waitv
      rt_sigaction rt_sigprocmask rt_sigreturn sigaltstack
      getrandom clock_gettime clock_getres gettimeofday time nanosleep
      clock_nanosleep restart_syscall sched_getaffinity sched_yield
      getpid getppid gettid getuid geteuid getgid getegid getresuid getresgid
      getrlimit prlimit64 getrusage uname sysinfo
      ioctl fcntl fcntl64 dup dup2 dup3 fsync fdatasync ftruncate
      statfs fstatfs umask execve exit exit_group
    """.split()
    ctx = SEC.seccomp_init(0x00050000 | errno.EPERM)
    if not ctx:
        raise RuntimeError("seccomp init failed")
    try:
        for name in names:
            nr = SEC.seccomp_syscall_resolve_name(name.encode("ascii"))
            if nr >= 0 and SEC.seccomp_rule_add(ctx, 0x7fff0000, nr, 0) != 0:
                raise RuntimeError("seccomp rule failed")
        if SEC.seccomp_load(ctx) != 0:
            raise RuntimeError("seccomp load failed")
    finally:
        SEC.seccomp_release(ctx)

def job_directory(source):
    directory = os.path.dirname(source)
    if (not re.fullmatch(r"/tmp/saarthi-id-(analysis|review|sandbox)-[A-Za-z0-9]{6,32}", directory)
            or source != directory + "/source.pdf"
            or os.path.realpath(source) != source):
        raise ValueError("invalid job path")
    d = os.stat(directory, follow_symlinks=False)
    f = os.stat(source, follow_symlinks=False)
    if (not stat.S_ISDIR(d.st_mode) or d.st_uid != os.getuid() or d.st_mode & 0o077
            or not stat.S_ISREG(f.st_mode) or f.st_uid != os.getuid() or f.st_mode & 0o077):
        raise ValueError("job must be private and owned by service user")
    return directory

def allocate(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(fd)

def denied(call):
    try:
        call()
    except OSError as exc:
        return exc.errno in (errno.EACCES, errno.EPERM)
    return False

def main():
    mode, *args = sys.argv[1:]
    if mode == "--self-test":
        source, = args
        directory = job_directory(source)
        output = directory + "/probe.out"
        allocate(output)
        os.chdir(directory)
        limits()
        isolate(None, directory, [output])
        def test_read(path):
            fd = os.open(path, os.O_RDONLY)
            os.close(fd)
        def test_write(path):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(fd)
        def test_socket():
            s = socket.socket()
            s.close()
        checks = {
            "privateInput": not denied(lambda: test_read(source)),
            "outsideReadDenied": denied(lambda: test_read("/etc/passwd")),
            "procReadDenied": denied(lambda: test_read("/proc/self/environ")),
            "extraOutputDenied": denied(lambda: test_write(directory + "/extra")),
            "networkDenied": denied(test_socket),
            "cpuLimited": resource.getrlimit(resource.RLIMIT_CPU) == (8, 8),
            "memoryLimited": resource.getrlimit(resource.RLIMIT_AS) == (256*1024*1024,)*2,
            "fileLimited": resource.getrlimit(resource.RLIMIT_FSIZE) == (8*1024*1024,)*2,
        }
        fd = os.open(output, os.O_WRONLY | os.O_TRUNC)
        os.write(fd, b"ok")
        os.close(fd)
        checks["approvedOutput"] = True
        print(json.dumps(checks), flush=True)
        return 0 if all(checks.values()) else 1

    if mode == "/usr/bin/pdftotext" and len(args) == 9:
        source = args[-2]
        if args != ["-f","1","-l","3","-bbox-layout","-enc","UTF-8",source,"-"]:
            raise ValueError("invalid text arguments")
        outputs = []
    elif mode == "/usr/bin/pdftohtml" and len(args) == 10:
        source = args[-2]
        output = os.path.dirname(source) + "/geometry.xml"
        if args != ["-f","1","-l","3","-xml","-zoom","1","-noroundcoord",source,output]:
            raise ValueError("invalid geometry arguments")
        # Inline image references prevent a variable number of disk files.
        args.insert(-2, "-dataurls")
        outputs = [output]
    elif mode == "/usr/bin/pdftoppm" and len(args) == 9:
        source = args[-2]
        prefix = os.path.dirname(source) + "/review"
        pages = args[3]
        if pages not in ("1", "2") or args != ["-f","1","-l",pages,"-r","600","-png",source,prefix]:
            raise ValueError("invalid raster arguments")
        outputs = [prefix + "-" + str(i) + ".png" for i in range(1, int(pages)+1)]
    else:
        raise ValueError("unsupported Poppler operation")
    directory = job_directory(source)
    for output in outputs:
        allocate(output)
    os.chdir(directory)
    limits()
    isolate(mode, directory, outputs)
    os.execve(mode, [mode] + args, {"PATH":"/usr/bin:/bin", "LANG":"C", "LC_ALL":"C",
        "HOME":directory, "TMPDIR":directory, "XDG_CACHE_HOME":directory})
    return 1

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Never log the uploaded PDF, host paths, stderr or credentials.
        print("PDF sandbox rejected operation", file=sys.stderr, flush=True)
        sys.exit(1)
