// SPDX-License-Identifier: GPL-3.0-or-later
//
// sleepwatcher - SystemInfo.swift
// IOKit message constants (C macros that Swift cannot import) and small
// queries: idle time, power source, GUI session, sleep now.

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Security

/// iokit_common_msg(x) / iokit_family_msg(sub_iokit_powermanagement, x) values from IOMessage.h and IOPM.h.
enum IOMessage {
    static let canSystemSleep: UInt32         = 0xE000_0270
    static let systemWillSleep: UInt32        = 0xE000_0280
    static let systemWillNotSleep: UInt32     = 0xE000_0290
    static let systemHasPoweredOn: UInt32     = 0xE000_0300
    static let deviceWillPowerOff: UInt32     = 0xE000_0210
    static let deviceHasPoweredOn: UInt32     = 0xE000_0230
    static let clamshellStateChange: UInt32   = 0xE003_4100
    static let clamshellStateBit: UInt        = 1 << 0
}

enum IdleTime {
    /// Seconds since the last keyboard, mouse or trackpad event.
    /// Read from IOHIDSystem's HIDIdleTime, which needs no Input Monitoring permission.
    static func seconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        if let number = value as? NSNumber {
            return number.doubleValue / 1_000_000_000
        }
        if let data = value as? Data, data.count >= MemoryLayout<UInt64>.size {
            return Double(data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 1_000_000_000
        }
        return nil
    }
}

enum PowerSource: String {
    case ac = "AC"
    case battery = "battery"

    /// The source currently powering the Mac. Anything other than AC (internal
    /// battery or a UPS reporting over USB) counts as unplugged.
    static func current() -> PowerSource? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return nil }
        return type == kIOPMACPowerKey ? .ac : .battery
    }
}

enum Session {
    /// True when running inside a logged-in user's window-server session (a
    /// LaunchAgent in the Aqua session, or a Terminal). Screen lock, full-wake
    /// and screen sleep notifications are only delivered there.
    static func hasGraphicAccess() -> Bool {
        let callerSecuritySession: SecuritySessionId = 0xFFFF_FFFF
        var attributes = SessionAttributeBits(rawValue: 0)
        guard SessionGetInfo(callerSecuritySession, nil, &attributes) == errSessionSuccess else { return false }
        return attributes.contains(.sessionHasGraphicAccess)
    }
}

enum SystemSleep {
    /// Implements -n / --now. Returns the process exit code.
    static func now() -> Int32 {
        guard IOPMSleepEnabled() != 0 else {
            FileHandle.standardError.write(Data("sleepwatcher: sleep mode is disabled\n".utf8))
            return 1
        }
        let rootPort = IOPMFindPowerManagement(kIOMainPortDefault)
        guard rootPort != IO_OBJECT_NULL else {
            FileHandle.standardError.write(Data("sleepwatcher: IOPMFindPowerManagement failed\n".utf8))
            return 1
        }
        defer { IOServiceClose(rootPort) }
        let err = IOPMSleepSystem(rootPort)
        guard err == kIOReturnSuccess else {
            FileHandle.standardError.write(Data("sleepwatcher: IOPMSleepSystem failed: \(err)\n".utf8))
            return 1
        }
        return 0
    }
}

enum Daemon {
    /// Starts this executable again with the same arguments in a new session
    /// with stdio on /dev/null. Returns the exit code for the parent.
    @MainActor
    static func relaunchDetached(marker: String) -> Int32 {
        guard let executable = Bundle.main.executablePath else {
            Log.error("daemonizing failed: can't locate executable")
            return 1
        }
        var environment = ProcessInfo.processInfo.environment
        environment[marker] = "1"

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let argv = CommandLine.arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let err = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        if err != 0 {
            Log.error("daemonizing failed: \(String(cString: strerror(err)))")
            return 1
        }
        return 0
    }
}
