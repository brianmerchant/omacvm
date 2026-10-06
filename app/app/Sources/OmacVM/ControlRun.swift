import Darwin
import Foundation
import Security

/// `OmacVM --control-run CLI ARGS...`: OmacVM Bridge runs the control
/// centre's omacvm for this app's VMs through here
/// (src/bridge/mac/control.swift, control_policy.swift appRunnerPath).
///
/// Why: the Bridge spawns omacvm with its responsibility disclaimed (Local
/// Network privacy). A bash of its own is then refused a VMs folder on an
/// external drive, without a prompt (Removable Volumes), and the control
/// centre says "no such OmacVM.app VM". Spawned the same way, this app's
/// executable answers for itself: macOS counts the run as the app's, with
/// the access the person already gave the app. Nothing new is asked.
///
/// The app's access is not lent to anything else: only when OmacVM Bridge
/// of this identity, signed like this app, started it (its parent); only
/// this app's own omacvm; only the commands the Bridge runs; a fixed
/// environment. No window, no AppKit.
enum ControlRun {
    static let flag = "--control-run"
    /// What control.swift runs: vms, features, check, graphics and its jobs (jobArgv).
    static let commands: Set<String> = ["vms", "features", "check", "graphics", "enable", "disable", "apply", "update"]
    static let environmentKeys = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TERM", "TMPDIR",
                                  "OMACVM_JOB_STATUS", "OMACVM_PROGRESS"]

    struct Refusal: Error, Equatable { let why: String }

    static func bridgeID(test: Bool) -> String { test ? "org.omacvm.test.bridge" : "org.omacvm.bridge" }

    /// The run, or why not. `ownCLI`: this app's omacvm
    /// (Contents/Resources/omacvm/omacvm), compared as real paths.
    static func plan(args: [String], ownCLI: String, environment: [String: String], test: Bool,
                     realPath: (String) -> String? = ControlRun.realPath) -> Result<([String], [String: String]), Refusal> {
        guard args.count >= 2, let cli = realPath(args[0]), let own = realPath(ownCLI), cli == own else {
            return .failure(Refusal(why: "runs only this app's omacvm"))
        }
        guard commands.contains(args[1]) else { return .failure(Refusal(why: "not a command the control centre runs: \(args[1])")) }
        var env: [String: String] = [:]
        for k in environmentKeys { if let v = environment[k] { env[k] = v } }
        if test { env["OMACVM_TEST_IDENTITY"] = "1" }
        return .success((args, env))
    }

    static func realPath(_ p: String) -> String? {
        guard let r = Darwin.realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    struct Signer: Equatable { let id: String, team: String? }

    /// Who signed a running process (nil: this one), checked by macOS now; nil when not validly signed.
    static func signer(pid: pid_t?) -> Signer? {
        var code: SecCode?
        if let pid {
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess else { return nil }
        } else {
            guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        }
        guard let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any], let id = d[kSecCodeInfoIdentifier as String] as? String else { return nil }
        return Signer(id: id, team: d[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    /// The parent may run this: OmacVM Bridge of this identity, signed by the same team as this app.
    static func parentAllowed(parent: Signer?, me: Signer?, test: Bool) -> Bool {
        guard let parent, let me else { return false }
        return parent.id == bridgeID(test: test) && parent.team == me.team
    }

    /// Runs the command and exits with its status (126: refused, 127: did not start).
    static func main(_ args: [String], test: Bool) -> Never {
        func refuse(_ why: String) -> Never {
            FileHandle.standardError.write(Data("control-run: \(why)\n".utf8))
            exit(126)
        }
        guard parentAllowed(parent: signer(pid: getppid()), me: signer(pid: nil), test: test) else {
            refuse("only OmacVM Bridge runs this")
        }
        let ownCLI = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/omacvm/omacvm").path
        let argv: [String], env: [String: String]
        switch plan(args: args, ownCLI: ownCLI, environment: ProcessInfo.processInfo.environment, test: test) {
        case .success(let p): (argv, env) = p
        case .failure(let r): refuse(r.why)
        }
        // stdin, stdout and stderr as the Bridge set them; nothing else. Same
        // process group: the Bridge's kill(-pid) still ends the whole run.
        var fa: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawnattr_init(&attr)
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addinherit_np(&fa, fd) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let cargv = argv.map { strdup($0) } + [nil]
        let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        var pid = pid_t()
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, cargv, cenv)
        guard rc == 0 else {
            FileHandle.standardError.write(Data("control-run: \(argv[0]) did not start: \(String(cString: strerror(rc)))\n".utf8))
            exit(127)
        }
        // The Bridge's SIGTERM reaches the whole group; this one only waits.
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let sig = status & 0x7f
        exit(sig == 0 ? (status >> 8) & 0xff : 128 + sig)
    }
}
