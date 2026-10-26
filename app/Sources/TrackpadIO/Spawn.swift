// How the trackpad helper starts a process (the engine's status and hittest). The helper holds the Accessibility
// permission; macOS would count what it starts as its "responsible" children and let them use it. Each child here
// disclaims that (responsibility_spawnattrs_setdisclaim, the spawn attribute Terminal and browsers use): it becomes its
// own responsible process with no permission, so even a helper copied next to someone else's engine script gives that
// script nothing. Also: a new process group if asked, no descriptor of ours but stdin/stdout, signals at their defaults.
import Darwin
import Foundation

public enum Spawn {
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim: Disclaim? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: Disclaim.self) }   // RTLD_DEFAULT; in libquarantine

    /// argv[0] is the program's path. stdin/stdout: a descriptor to give it, or -1 for /dev/null; stderr is /dev/null.
    /// nil when it could not start, or when the disclaim is not available (then nothing starts at all).
    public static func run(_ argv: [String], environment: [String: String], stdin: Int32, stdout: Int32, newGroup: Bool) -> pid_t? {
        guard let disclaim else { return nil }
        var attr: posix_spawnattr_t? = nil, fa: posix_spawn_file_actions_t? = nil
        posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
        posix_spawn_file_actions_init(&fa); defer { posix_spawn_file_actions_destroy(&fa) }
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if newGroup { flags |= POSIX_SPAWN_SETPGROUP; posix_spawnattr_setpgroup(&attr, 0) }
        posix_spawnattr_setflags(&attr, Int16(flags))
        var def = sigset_t(); sigemptyset(&def)
        for s in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&def, s) }
        posix_spawnattr_setsigdefault(&attr, &def)
        var mask = sigset_t(); sigemptyset(&mask); posix_spawnattr_setsigmask(&attr, &mask)
        guard disclaim(&attr, 1) == 0 else { return nil }
        if stdin >= 0 { posix_spawn_file_actions_adddup2(&fa, stdin, 0) } else { posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0) }
        if stdout >= 0 { posix_spawn_file_actions_adddup2(&fa, stdout, 1) } else { posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0) }
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnvp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cArgv { free(p) }; for p in cEnvp { free(p) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, argv[0], &fa, &attr, &cArgv, &cEnvp) == 0 ? pid : nil
    }
}
