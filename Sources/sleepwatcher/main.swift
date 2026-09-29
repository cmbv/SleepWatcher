// SPDX-License-Identifier: GPL-3.0-or-later
//
// sleepwatcher 3 - monitor sleep, wakeup and idleness of the Mac
//
// A Swift port of sleepwatcher 2.2.1 by Bernhard Baehr (2002-2019),
// updated for current macOS. Command line and config file compatible.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

var options = OptionParser.parse(CommandLine.arguments)
Log.verbose = options.verbose

// daemon(3) is unavailable to Swift, so -d relaunches the same command line
// detached from the terminal; the marker variable stops the copy from
// relaunching again.
if options.daemon {
    let marker = "SLEEPWATCHER_DAEMONIZED"
    if ProcessInfo.processInfo.environment[marker] == nil {
        exit(Daemon.relaunchDetached(marker: marker))
    }
    Log.toStdio = false
}

@MainActor func writePidFile(_ path: String?) {
    guard let path else { return }
    if FileManager.default.createFile(atPath: path, contents: Data("\(getpid())".utf8)) == false {
        Log.error("can't write pidfile \(path)")
    }
}

@MainActor func removePidFile(_ path: String?) {
    if let path { unlink(path) }
}

writePidFile(options.pidfile)

let guiSession = Session.hasGraphicAccess()
Log.info("sleepwatcher \(version) started (\(guiSession ? "login session" : "no login session"))")

let watcher = Watcher(options: options, guiSession: guiSession)
watcher.start()

var signalSources: [DispatchSourceSignal] = []
for sig in HookRunner.managedSignals {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            if sig == SIGHUP {
                Log.info("got SIGHUP - reconfiguring")
                let old = options
                options = OptionParser.parse(CommandLine.arguments)
                Log.verbose = options.verbose
                if old.pidfile != options.pidfile {
                    removePidFile(old.pidfile)
                    writePidFile(options.pidfile)
                }
                watcher.reconfigure(options)
            } else {
                Log.info("got \(sig == SIGTERM ? "SIGTERM" : "SIGINT") - exiting")
                removePidFile(options.pidfile)
                exit(0)
            }
        }
    }
    source.resume()
    signalSources.append(source)
}

CFRunLoopRun()
