// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// A new pseudo-terminal: the controller the agent copies to and from, and the terminal device
/// the process gets as its standard streams.
struct PseudoTerminal {
    /// `TIOCSWINSZ`, `_IOW('t', 103, struct winsize)`; the macro does not import into Swift.
    static let setWindowSize: UInt = 0x8008_7467

    let controller: Int32
    let device: Int32

    init() throws {
        let controller = posix_openpt(O_RDWR | O_NOCTTY)
        guard controller >= 0 else {
            throw AgentError.posix("posix_openpt", errno)
        }
        guard grantpt(controller) == 0, unlockpt(controller) == 0, let name = ptsname(controller) else {
            let error = errno
            close(controller)
            throw AgentError.posix("grantpt", error)
        }
        let device = open(name, O_RDWR | O_NOCTTY)
        guard device >= 0 else {
            let error = errno
            close(controller)
            throw AgentError.posix("open \(String(cString: name))", error)
        }
        self.controller = controller
        self.device = device
    }

    /// Sets the window size of the terminal whose controller is `controller`.
    static func resize(controller: Int32, columns: UInt32, rows: UInt32) throws {
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(controller, setWindowSize, &size) == 0 else {
            throw AgentError.posix("ioctl(TIOCSWINSZ)", errno)
        }
    }
}

/// The agent's `--controlling-terminal` mode: started as the leader of a new session, it makes its
/// standard input the session's controlling terminal and executes the rest of its arguments.
/// Without a controlling terminal, a shell gets no job control and Ctrl-C sends no SIGINT.
enum ControllingTerminal {
    static let flag = "--controlling-terminal"
    /// `TIOCSCTTY`, `_IO('t', 97)`; the macro does not import into Swift.
    static let setControllingTerminal: UInt = 0x2000_7461

    /// Runs the mode when the agent was started with `flag`; returns only when it was not.
    static func runIfRequested(_ arguments: [String]) {
        guard arguments.count > 2, arguments[1] == flag else {
            return
        }
        let command = Array(arguments.dropFirst(2))
        guard ioctl(0, setControllingTerminal, 0) == 0 else {
            fail("ioctl(TIOCSCTTY)")
        }
        var pointers = command.map { strdup($0) }
        pointers.append(nil)
        execv(command[0], &pointers)
        fail("execv \(command[0])")
    }

    private static func fail(_ what: String) -> Never {
        FileHandle.standardError.write(Data("parbake-agent: \(what): \(String(cString: strerror(errno)))\n".utf8))
        Darwin.exit(127)
    }
}
