// SPDX-License-Identifier: GPL-3.0-or-later
//
// sleepwatcher - Log.swift
// Logging to the unified log (`log stream --predicate 'subsystem == "sleepwatcher"'`)
// and, unless daemonized, to stdout/stderr like the original sleepwatcher did.

import Foundation
import os

@MainActor
enum Log {
    static var verbose = false
    static var toStdio = true
    static let progname = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "sleepwatcher"

    private static let logger = Logger(subsystem: "sleepwatcher", category: "events")

    /// Event messages; only emitted with -V / --verbose.
    static func info(_ message: String) {
        guard verbose else { return }
        logger.notice("\(message, privacy: .public)")
        if toStdio {
            print("\(progname): \(message)")
            fflush(stdout)
        }
    }

    /// Problems; always emitted.
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        if toStdio {
            FileHandle.standardError.write(Data("\(progname): \(message)\n".utf8))
        }
    }
}
