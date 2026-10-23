// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationOCI
import Darwin
import Foundation

/// A process the agent starts in the guest for the host.
///
/// The process's standard streams are pipes, or one pseudo-terminal for a process with a terminal,
/// copied to and from vsock connections to the host; the host listens on the ports and the agent
/// connects to them when the process starts.
final class GuestProcess: @unchecked Sendable {
    struct Exit: Sendable {
        let code: Int32
        let date: Date
    }

    let id: String
    private let process: ContainerizationOCI.Process
    private let ports: (stdin: UInt32?, stdout: UInt32?, stderr: UInt32?)
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stdinWriter: Int32 = -1
    private var stdinConnection: Int32 = -1
    private var terminalController: Int32 = -1
    private var exit: Exit?
    private var waiters: [CheckedContinuation<Exit, Never>] = []
    /// The copies of the process's output; its exit is reported once they finished, never before.
    private let outputCopies = DispatchGroup()

    init(id: String, process: ContainerizationOCI.Process, stdin: UInt32?, stdout: UInt32?, stderr: UInt32?) throws {
        guard !process.args.isEmpty else {
            throw AgentError.invalidArgument("the process has no arguments")
        }
        self.id = id
        self.process = process
        self.ports = (stdin, stdout, stderr)
    }

    var currentExit: Exit? { lock.withLock { exit } }

    /// Whether the process started and has not exited yet.
    var isRunning: Bool { lock.withLock { pid > 0 && exit == nil } }

    /// Connects the streams, spawns the process and returns its PID.
    func start() throws -> pid_t {
        let launch = try Launch(process: process)
        if process.terminal {
            return try startWithTerminal(launch)
        }
        var fileDescriptors: [Int32] = []
        defer { fileDescriptors.forEach { close($0) } }

        func pipePair() throws -> (read: Int32, write: Int32) {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else {
                throw AgentError.posix("pipe", errno)
            }
            return (ends[0], ends[1])
        }

        let stdin = try pipePair()
        fileDescriptors.append(stdin.read)
        let stdout = try pipePair()
        fileDescriptors.append(stdout.write)
        let stderr = try pipePair()
        fileDescriptors.append(stderr.write)

        let stdinConnection = try ports.stdin.map(VsockConnection.toHost)
        let stdoutConnection = try ports.stdout.map(VsockConnection.toHost)
        let stderrConnection = try ports.stderr.map(VsockConnection.toHost)

        let pid = try launch.spawn(stdin: stdin.read, stdout: stdout.write, stderr: stderr.write)
        lock.withLock {
            self.pid = pid
            self.stdinWriter = stdin.write
            self.stdinConnection = stdinConnection ?? -1
        }

        if let stdinConnection {
            copy(from: stdinConnection, to: stdin.write, closeSource: true, closeDestination: true) { [weak self] in
                self?.lock.withLock {
                    self?.stdinWriter = -1
                    self?.stdinConnection = -1
                }
            }
        } else {
            closeStdin()
        }
        copy(from: stdout.read, to: stdoutConnection ?? -1, closeSource: true, closeDestination: true, group: outputCopies)
        copy(from: stderr.read, to: stderrConnection ?? -1, closeSource: true, closeDestination: true, group: outputCopies)
        watchExit(pid)
        return pid
    }

    /// Starts the process on a new pseudo-terminal: its controller carries standard input and
    /// output, and the process leads a session with the terminal as its controlling terminal.
    private func startWithTerminal(_ launch: Launch) throws -> pid_t {
        let terminal = try PseudoTerminal()
        // The controller has two descriptors so that each copy closes its own: one descriptor
        // closed under the other copy could be reused by an unrelated file and receive its data.
        let controllerWriter = dup(terminal.controller)
        guard controllerWriter >= 0 else {
            let error = errno
            close(terminal.controller)
            close(terminal.device)
            throw AgentError.posix("dup", error)
        }
        let stdinConnection: Int32?
        let stdoutConnection: Int32?
        let pid: pid_t
        do {
            defer { close(terminal.device) }
            stdinConnection = try ports.stdin.map(VsockConnection.toHost)
            stdoutConnection = try ports.stdout.map(VsockConnection.toHost)
            pid = try launch.spawn(stdin: terminal.device, stdout: terminal.device, stderr: terminal.device, controllingTerminal: true)
        } catch {
            close(terminal.controller)
            close(controllerWriter)
            throw error
        }
        lock.withLock {
            self.pid = pid
            self.stdinWriter = controllerWriter
            self.stdinConnection = stdinConnection ?? -1
            self.terminalController = terminal.controller
        }
        if let stdinConnection {
            copy(from: stdinConnection, to: controllerWriter, closeSource: true, closeDestination: true) { [weak self] in
                self?.lock.withLock {
                    self?.stdinWriter = -1
                    self?.stdinConnection = -1
                }
            }
        } else {
            closeStdin()
        }
        // The controller reads EIO once the last process holding the terminal closed it.
        copy(from: terminal.controller, to: stdoutConnection ?? -1, closeSource: true, closeDestination: true, group: outputCopies) {
            [weak self] in
            self?.lock.withLock { self?.terminalController = -1 }
        }
        watchExit(pid)
        return pid
    }

    /// Sets the window size of the process's terminal; a process without a terminal ignores it.
    func resize(columns: UInt32, rows: UInt32) throws {
        try lock.withLock {
            guard terminalController >= 0 else {
                return
            }
            var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
            guard ioctl(terminalController, PseudoTerminal.setWindowSize, &size) == 0 else {
                throw AgentError.posix("ioctl(TIOCSWINSZ)", errno)
            }
        }
    }

    /// Waits until the process has exited and its output has reached the host.
    func wait() async -> Exit {
        await withCheckedContinuation { cc in
            let exit = lock.withLock {
                if self.exit == nil {
                    waiters.append(cc)
                }
                return self.exit
            }
            if let exit {
                cc.resume(returning: exit)
            }
        }
    }

    /// Sends `signal` to the process group of the process.
    func signal(_ signal: Int32) throws {
        let pid = lock.withLock { self.pid }
        guard pid > 0, currentExit == nil else {
            throw AgentError.failedPrecondition("process \(id) is not running")
        }
        guard kill(-pid, signal) == 0 else {
            throw AgentError.posix("kill", errno)
        }
    }

    /// Closes the process's standard input.
    func closeStdin() {
        let (writer, connection) = lock.withLock {
            defer {
                stdinWriter = -1
                stdinConnection = -1
            }
            return (stdinWriter, stdinConnection)
        }
        if connection >= 0 {
            // Unblocks the copy, which then closes both ends.
            shutdown(connection, SHUT_RD)
        } else if writer >= 0 {
            close(writer)
        }
    }

    /// Copies `source` to `destination` on its own thread until `source` ends; `destination` -1
    /// discards the data. A copy in `group` keeps the group entered until it ends.
    private func copy(
        from source: Int32, to destination: Int32, closeSource: Bool, closeDestination: Bool, group: DispatchGroup? = nil,
        done: (@Sendable () -> Void)? = nil
    ) {
        group?.enter()
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            reading: while true {
                let count = read(source, &buffer, buffer.count)
                if count < 0 && errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    break
                }
                guard destination >= 0 else {
                    continue
                }
                var offset = 0
                while offset < count {
                    let written = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + offset, count - offset) }
                    if written < 0 && errno == EINTR {
                        continue
                    }
                    guard written > 0 else {
                        break reading
                    }
                    offset += written
                }
            }
            if closeSource {
                close(source)
            }
            if closeDestination && destination >= 0 {
                close(destination)
            }
            done?()
            group?.leave()
        }
        thread.start()
    }

    private func watchExit(_ pid: pid_t) {
        let thread = Thread { [weak self] in
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, 0)
            } while result < 0 && errno == EINTR
            if result < 0 {
                FileHandle.standardError.write(Data("parbake-agent: waitpid(\(pid)) failed: \(String(cString: strerror(errno)))\n".utf8))
            }
            let code: Int32
            if status & 0x7f == 0 {
                code = (status >> 8) & 0xff
            } else {
                code = 128 + (status & 0x7f)
            }
            guard let self else {
                return
            }
            // Output written before the exit reaches the host before the exit is reported. Standard
            // input is not waited for: the host may keep it open after the process ended.
            self.outputCopies.wait()
            self.closeStdin()
            let exit = Exit(code: code, date: Date())
            let waiters = self.lock.withLock {
                self.exit = exit
                defer { self.waiters = [] }
                return self.waiters
            }
            waiters.forEach { $0.resume(returning: exit) }
        }
        thread.start()
    }
}

/// How the agent turns an OCI process into a `posix_spawn` call.
struct Launch {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let workingDirectory: String

    init(process: ContainerizationOCI.Process) throws {
        let account = try Account(user: process.user)
        var environment = [
            "HOME": account.home,
            "USER": account.name,
            "LOGNAME": account.name,
            "SHELL": account.shell,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
        ]
        if let temporary = TemporaryDirectories.shared.directory(for: account) {
            // Tools on macOS expect the account's own temporary directory; launchd sets it only
            // for a session, not for the agent's children.
            environment["TMPDIR"] = temporary
        }
        if process.terminal {
            // The same default containerization gives a Linux process with a terminal.
            environment["TERM"] = "xterm"
        }
        for entry in process.env {
            let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            environment[String(pair[0])] = pair.count == 2 ? String(pair[1]) : ""
        }
        let environmentList = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let resolved = try Self.resolve(process.args[0], path: environment["PATH"] ?? "")
        self.workingDirectory = process.cwd.isEmpty || process.cwd == "/" && account.uid != 0 ? account.home : process.cwd

        let current = getuid()
        if account.uid == current {
            self.executable = resolved
            self.arguments = [resolved] + process.args.dropFirst()
            self.environment = environmentList
        } else if current == 0 {
            try GUISession.require(uid: account.uid, name: account.name)
            // The account's session bootstrap gives the process the login keychain and the window server.
            self.executable = "/bin/launchctl"
            self.arguments =
                ["/bin/launchctl", "asuser", String(account.uid), "/usr/bin/sudo", "-u", account.name, "--", "/usr/bin/env", "-i"]
                + environmentList + [resolved] + process.args.dropFirst()
            self.environment = environmentList
        } else {
            throw AgentError.failedPrecondition(
                "the agent runs as uid \(current) and cannot start a process as uid \(account.uid)")
        }
    }

    /// Spawns the process. With `controllingTerminal`, it starts through the agent's own
    /// `--controlling-terminal` mode, which makes `stdin`, a terminal, the controlling terminal of
    /// a new session before it executes the process; `posix_spawn` cannot do that itself.
    func spawn(stdin: Int32, stdout: Int32, stderr: Int32, controllingTerminal: Bool = false) throws -> pid_t {
        var executable = self.executable
        var arguments = self.arguments
        if controllingTerminal {
            guard let agent = Bundle.main.executablePath else {
                throw AgentError.failedPrecondition("the agent cannot find its own executable")
            }
            arguments = [agent, ControllingTerminal.flag] + arguments
            executable = agent
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A process group of its own, so a signal reaches every process it starts; no descriptor but 0 to 2 leaks.
        // Default dispositions and an empty mask: an ignored signal survives exec, and a process
        // that inherits an ignored SIGTERM never stops on `container exec` kill or stop.
        // A process with a terminal leads a new session instead, whose process group has its PID too;
        // a group leader could not call setsid, and the terminal would never become controlling.
        let group = controllingTerminal ? POSIX_SPAWN_SETSID : POSIX_SPAWN_SETPGROUP
        posix_spawnattr_setflags(
            &attributes, Int16(group | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var pid: pid_t = 0
        let result = withCStrings(arguments) { argv in
            withCStrings(environment) { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            }
        }
        guard result == 0 else {
            throw AgentError.posix("posix_spawn \(executable)", result)
        }
        return pid
    }

    static func resolve(_ command: String, path: String) throws -> String {
        if command.contains("/") {
            return command
        }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        throw AgentError.notFound("\(command) is not in PATH \(path)")
    }
}

/// The guest account a process runs as.
/// The temporary directory of each account, `/var/folders/…/T/`, looked up once per account.
final class TemporaryDirectories: @unchecked Sendable {
    static let shared = TemporaryDirectories()

    private let lock = NSLock()
    private var directories: [uid_t: String] = [:]

    /// The account's directory: the agent's own from `confstr`, another account's from `getconf`
    /// run as that account, which only a root agent can do. Nil when the lookup fails.
    func directory(for account: Account) -> String? {
        if let known = lock.withLock({ directories[account.uid] }) {
            return known
        }
        let found: String?
        if account.uid == getuid() {
            found = Self.ownDirectory()
        } else if getuid() == 0 {
            found = Self.directory(ofOther: account)
        } else {
            found = nil
        }
        if let found {
            lock.withLock { directories[account.uid] = found }
        }
        return found
    }

    private static func ownDirectory() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func directory(ofOther account: Account) -> String? {
        let getconf = Process()
        getconf.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        getconf.arguments = ["-u", account.name, "--", "/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"]
        let output = Pipe()
        getconf.standardOutput = output
        getconf.standardError = FileHandle.nullDevice
        guard (try? getconf.run()) != nil else {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        getconf.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard getconf.terminationStatus == 0, path.hasPrefix("/") else {
            return nil
        }
        return path
    }
}

struct Account {
    let uid: uid_t
    let name: String
    let home: String
    let shell: String

    init(user: ContainerizationOCI.User) throws {
        let entry = user.username.isEmpty ? getpwuid(user.uid) : getpwnam(user.username)
        guard let entry else {
            throw AgentError.notFound("no guest account \(user.username.isEmpty ? "with uid \(user.uid)" : user.username)")
        }
        uid = entry.pointee.pw_uid
        name = String(cString: entry.pointee.pw_name)
        home = String(cString: entry.pointee.pw_dir)
        shell = String(cString: entry.pointee.pw_shell)
    }
}

/// Connections from the guest to the host over vsock.
enum VsockConnection {
    /// Connects to `port` on the host and returns the socket.
    static func toHost(_ port: UInt32) throws -> Int32 {
        let socket = Darwin.socket(AF_VSOCK, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw AgentError.posix("socket(AF_VSOCK)", errno)
        }
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_cid = UInt32(VMADDR_CID_HOST)
        address.svm_port = port
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(socket)
            throw AgentError.posix("connect to host port \(port)", error)
        }
        return socket
    }
}

private func withCStrings<Result>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
