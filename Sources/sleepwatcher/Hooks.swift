// SPDX-License-Identifier: GPL-3.0-or-later
//
// sleepwatcher - Hooks.swift
// Runs user commands through /bin/sh, blocking like system(3) did in the
// original, but with a clean signal state, an event variable and an optional
// timeout.

import Foundation

struct HookResult: CustomStringConvertible {
    let status: Int32
    let timedOut: Bool
    let spawnError: Int32?

    var exited: Bool { status & 0x7f == 0 }
    var exitCode: Int32 { (status >> 8) & 0xff }
    var succeeded: Bool { spawnError == nil && !timedOut && exited && exitCode == 0 }

    var description: String {
        if let spawnError { return "failed to start: \(String(cString: strerror(spawnError)))" }
        if timedOut { return "timed out" }
        return exited ? "exit=\(exitCode)" : "signal=\(status & 0x7f)"
    }
}

struct HookRunner {
    /// Seconds before a hook is terminated; 0 waits forever.
    var timeout: TimeInterval = 0

    /// Signals sleepwatcher itself ignores (so DispatchSource can handle them);
    /// hooks must get default dispositions back.
    static let managedSignals: [Int32] = [SIGHUP, SIGINT, SIGTERM]

    func run(_ command: String, event: String) -> HookResult {
        var environment = ProcessInfo.processInfo.environment
        environment["SLEEPWATCHER_EVENT"] = event

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // Own process group so a timeout can stop the hook and everything it started.
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        Self.managedSignals.forEach { sigaddset(&defaults, $0) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let err = posix_spawn(&pid, "/bin/sh", nil, &attr, argv, envp)
        if err != 0 {
            return HookResult(status: -1, timedOut: false, spawnError: err)
        }
        return wait(for: pid)
    }

    private func wait(for pid: pid_t) -> HookResult {
        var status: Int32 = 0
        guard timeout > 0 else {
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            return HookResult(status: status, timedOut: false, spawnError: nil)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r == -1 && errno != EINTR) {
                return HookResult(status: status, timedOut: false, spawnError: nil)
            }
            if Date() >= deadline { break }
            usleep(20_000)
        }

        kill(-pid, SIGTERM)
        let killDeadline = Date().addingTimeInterval(2)
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() >= killDeadline {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                break
            }
            usleep(20_000)
        }
        return HookResult(status: status, timedOut: true, spawnError: nil)
    }
}
