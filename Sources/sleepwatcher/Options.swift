// SPDX-License-Identifier: GPL-3.0-or-later
//
// sleepwatcher - Options.swift
// Command line and config file parsing, compatible with sleepwatcher 2.2.1.

import Foundation

let version = "3.0.0"

enum AllowSleep: Equatable {
    case always
    case never
    case command(String)
}

struct Options {
    var verbose = false
    var daemon = false
    var pidfile: String?
    var allowSleep = AllowSleep.always
    var cantSleep: String?
    var sleep: String?
    var wakeup: String?
    var anyWake: String?
    var displayDim: String?
    var displayUndim: String?
    var displaySleep: String?
    var displayWakeup: String?
    var idleTimeout: TimeInterval = 0
    var idle: String?
    var idleResume: String?
    var breakLength: TimeInterval = 0
    var resume: String?
    var plug: String?
    var unplug: String?
    var lock: String?
    var unlock: String?
    var lidOpen: String?
    var lidClose: String?
    var hookTimeout: TimeInterval = 0

    var hasHooks: Bool {
        allowSleep != .always || [cantSleep, sleep, wakeup, anyWake, displayDim, displayUndim, displaySleep,
            displayWakeup, idle, resume, plug, unplug, lock, unlock, lidOpen, lidClose].contains { $0 != nil }
    }
}

private enum ArgumentKind {
    case none, required, optional
}

private struct OptionSpec {
    let long: String
    let short: Character?
    let argument: ArgumentKind
}

// Short letters and long names are those of sleepwatcher 2.2.1; options
// without a short letter are new in 3.0.
private let specs: [OptionSpec] = [
    .init(long: "now", short: "n", argument: .none),
    .init(long: "version", short: "v", argument: .none),
    .init(long: "verbose", short: "V", argument: .none),
    .init(long: "daemon", short: "d", argument: .none),
    .init(long: "getidletime", short: "g", argument: .none),
    .init(long: "help", short: "h", argument: .none),
    .init(long: "config", short: "f", argument: .required),
    .init(long: "pidfile", short: "p", argument: .required),
    .init(long: "allowsleep", short: "a", argument: .optional),
    .init(long: "cantsleep", short: "c", argument: .required),
    .init(long: "sleep", short: "s", argument: .required),
    .init(long: "wakeup", short: "w", argument: .required),
    .init(long: "anywake", short: nil, argument: .required),
    .init(long: "displaydim", short: "D", argument: .required),
    .init(long: "displayundim", short: "E", argument: .required),
    .init(long: "displaysleep", short: "S", argument: .required),
    .init(long: "displaywakeup", short: "W", argument: .required),
    .init(long: "timeout", short: "t", argument: .required),
    .init(long: "idle", short: "i", argument: .required),
    .init(long: "idleresume", short: "R", argument: .required),
    .init(long: "break", short: "b", argument: .required),
    .init(long: "resume", short: "r", argument: .required),
    .init(long: "plug", short: "P", argument: .required),
    .init(long: "unplug", short: "U", argument: .required),
    .init(long: "lock", short: nil, argument: .required),
    .init(long: "unlock", short: nil, argument: .required),
    .init(long: "lidopen", short: nil, argument: .required),
    .init(long: "lidclose", short: nil, argument: .required),
    .init(long: "hooktimeout", short: nil, argument: .required),
]

@MainActor
struct OptionParser {
    private(set) var options = Options()
    private var configDepth = 0

    /// Parses argv; `-n`, `-v`, `-g` and `-h` act immediately and exit, as in 2.2.1.
    static func parse(_ arguments: [String]) -> Options {
        var parser = OptionParser()
        if arguments.count <= 1 { usage() }
        parser.parseArguments(Array(arguments.dropFirst()))
        parser.validate()
        return parser.options
    }

    private mutating func parseArguments(_ arguments: [String]) {
        var index = 0
        func next() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }

        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--" {
                index += 1
                break
            } else if arg.hasPrefix("--") {
                let body = arg.dropFirst(2)
                let name = String(body.prefix { $0 != "=" })
                let inline = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
                guard let spec = specs.first(where: { $0.long == name }) else {
                    Log.error("unrecognized option '\(arg)'")
                    exit(2)
                }
                switch spec.argument {
                case .none:
                    if inline != nil {
                        Log.error("option '--\(name)' doesn't allow an argument")
                        exit(2)
                    }
                    apply(spec, nil)
                case .optional:
                    apply(spec, inline)
                case .required:
                    guard let value = inline ?? next() else {
                        Log.error("option '--\(name)' requires an argument")
                        exit(2)
                    }
                    apply(spec, value)
                }
            } else if arg.hasPrefix("-") && arg.count > 1 {
                var letters = Substring(arg.dropFirst())
                while let letter = letters.first {
                    letters = letters.dropFirst()
                    guard let spec = specs.first(where: { $0.short == letter }) else {
                        Log.error("invalid option -- \(letter)")
                        exit(2)
                    }
                    switch spec.argument {
                    case .none:
                        apply(spec, nil)
                        continue
                    case .optional:
                        // Like getopt: -a takes an argument only when attached (-a/path/to/cmd).
                        apply(spec, letters.isEmpty ? nil : String(letters))
                    case .required:
                        guard let value = letters.isEmpty ? next() : String(letters) else {
                            Log.error("option requires an argument -- \(letter)")
                            exit(2)
                        }
                        apply(spec, value)
                    }
                    break
                }
            } else {
                break
            }
            index += 1
        }
        if index < arguments.count {
            Log.error("superfluous arguments ignored: \"\(arguments[index]) ...\"")
        }
    }

    private mutating func apply(_ spec: OptionSpec, _ value: String?) {
        switch spec.long {
        case "now": exit(SystemSleep.now())
        case "version": printVersion()
        case "help": usage()
        case "getidletime":
            // Tenths of a second, as in 2.2.1.
            print(IdleTime.seconds().map { Int($0 * 10) } ?? -1)
            exit(0)
        case "verbose": options.verbose = true
        case "daemon": options.daemon = true
        case "config": readConfig(value!)
        case "pidfile": options.pidfile = value
        case "allowsleep": options.allowSleep = value.map { .command($0) } ?? .never
        case "cantsleep": options.cantSleep = value
        case "sleep": options.sleep = value
        case "wakeup": options.wakeup = value
        case "anywake": options.anyWake = value
        case "displaydim": options.displayDim = value
        case "displayundim": options.displayUndim = value
        case "displaysleep": options.displaySleep = value
        case "displaywakeup": options.displayWakeup = value
        case "timeout": options.idleTimeout = parseDuration(value!, option: "timeout")
        case "idle": options.idle = value
        case "idleresume": options.idleResume = value
        case "break": options.breakLength = parseDuration(value!, option: "break")
        case "resume": options.resume = value
        case "plug": options.plug = value
        case "unplug": options.unplug = value
        case "lock": options.lock = value
        case "unlock": options.unlock = value
        case "lidopen": options.lidOpen = value
        case "lidclose": options.lidClose = value
        case "hooktimeout": options.hookTimeout = parseDuration(value!, option: "hooktimeout", bareUnit: 1)
        default: fatalError("unhandled option \(spec.long)")
        }
    }

    /// Config file lines are `name=value` or `name` using the long option
    /// names; `#` and `;` start comment lines. Same format as 2.2.1.
    private mutating func readConfig(_ path: String) {
        guard configDepth < 8 else {
            Log.error("config files nested too deeply at \(path)")
            return
        }
        guard let contents = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else {
            Log.error("can't read config file \(path)")
            return
        }
        configDepth += 1
        defer { configDepth -= 1 }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.drop { $0 == " " || $0 == "\t" }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            let name = line.prefix { $0 != "=" }.filter { $0 != " " && $0 != "\t" }
            let hasValue = line.contains("=")
            let value = hasValue ? String(line.drop { $0 != "=" }.dropFirst().drop { $0 == " " || $0 == "\t" }) : nil

            guard let spec = specs.first(where: { $0.long == name }) else {
                Log.error("unknown parameter '\(line)' in config file \(path)")
                continue
            }
            if (spec.argument == .none && hasValue) || (spec.argument == .required && !hasValue) {
                Log.error("malformed parameter '\(line)' in config file \(path)")
                continue
            }
            apply(spec, value)
        }
    }

    /// A bare number is in tenths of a second for -t and -b (2.2.1 compatible)
    /// and in seconds for --hooktimeout. Suffixes s, m and h are also accepted.
    private func parseDuration(_ text: String, option: String, bareUnit: TimeInterval = 0.1) -> TimeInterval {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600]
        var digits = Substring(text)
        var unit = bareUnit
        if let last = digits.last, let suffixUnit = units[last] {
            unit = suffixUnit
            digits = digits.dropLast()
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let value = UInt(digits) else {
            Log.error("invalid digit(s) in \(option) argument '\(text)'")
            return -1
        }
        return TimeInterval(value) * unit
    }

    private mutating func validate() {
        func pair(_ timeout: inout TimeInterval, _ command: inout String?, _ timeoutName: String, _ commandName: String) {
            if timeout < 0 {
                timeout = 0
                command = nil
            }
            if timeout == 0 && command != nil {
                Log.error("\(commandName) without \(timeoutName) ignored")
                command = nil
            }
            if timeout > 0 && command == nil {
                Log.error("\(timeoutName) without \(commandName) ignored")
                timeout = 0
            }
        }
        pair(&options.idleTimeout, &options.idle, "timeout", "idlecommand")
        pair(&options.breakLength, &options.resume, "break", "resumecommand")
        if options.idle == nil && options.idleResume != nil {
            Log.error("idleresumecommand without idlecommand ignored")
            options.idleResume = nil
        }
        if options.hookTimeout < 0 { options.hookTimeout = 0 }
        if !options.hasHooks {
            Log.error("no useful options set")
        }
    }
}

private func printVersion() -> Never {
    print("""
        sleepwatcher \(version)
        Based on sleepwatcher 2.2.1, Copyright (c) 2002-2019 Bernhard Baehr.
        This is free software that comes with ABSOLUTELY NO WARRANTY.
        See the GNU General Public License for details.
        """)
    exit(0)
}

@MainActor
private func usage() -> Never {
    print("""
        Usage: \(Log.progname) [-n] [-v] [-V] [-d] [-g] [-f configfile] [-p pidfile]
                [-a[allowsleepcommand]] [-c cantsleepcommand]
                [-s sleepcommand] [-w wakeupcommand] [--anywake command]
                [-D displaydimcommand] [-E displayundimcommand]
                [-S displaysleepcommand] [-W displaywakeupcommand]
                [-t timeout -i idlecommand [-R idleresumecommand]]
                [-b break -r resumecommand]
                [-P plugcommand] [-U unplugcommand]
                [--lock command] [--unlock command]
                [--lidopen command] [--lidclose command]
                [--hooktimeout seconds]
        Daemon to monitor sleep, wakeup and idleness of the Mac

        General
          -n, --now            sleep now and exit
          -v, --version        show version and exit
          -V, --verbose        log every action (see: log stream --predicate 'subsystem == "sleepwatcher"')
          -d, --daemon         fork into the background (don't use with launchd)
          -g, --getidletime    print keyboard/mouse idle time in 1/10 seconds and exit
          -f, --config FILE    read options from FILE (re-read on SIGHUP)
          -p, --pidfile FILE   write the process id to FILE
          --hooktimeout SECS   kill a command still running after SECS (default: never)

        System sleep
          -a, --allowsleep[=CMD]  allow idle sleep only if CMD exits 0; -a alone denies idle sleep
          -c, --cantsleep CMD  sleep allowed by -a was vetoed by another process
          -s, --sleep CMD      the Mac is going to sleep (finish within ~20 s)
          -w, --wakeup CMD     the Mac woke up for the user (not for Power Nap dark wakes
                               when running in a login session)
          --anywake CMD        any wake, including Power Nap / maintenance dark wakes

        Display
          -D, --displaydim CMD       display dimmed
          -E, --displayundim CMD     display undimmed without having slept
          -S, --displaysleep CMD     display went to sleep
          -W, --displaywakeup CMD    display woke up

        User activity (no Input Monitoring permission needed)
          -t, --timeout TIME   idle time for -i; bare number = 1/10 s, or 30s, 5m, 1h
          -i, --idle CMD       no keyboard/mouse input for the -t time
          -R, --idleresume CMD input resumed after -i ran
          -b, --break TIME     break length for -r; same units as -t
          -r, --resume CMD     input resumed after a break of at least -b

        Power and session
          -P, --plug CMD       switched to AC power
          -U, --unplug CMD     switched to battery or UPS power
          --lock CMD           screen locked (login session only)
          --unlock CMD         screen unlocked (login session only)
          --lidopen CMD        MacBook lid opened
          --lidclose CMD       MacBook lid closed

        Commands run via /bin/sh -c with SLEEPWATCHER_EVENT set to the event name.
        """)
    exit(2)
}
