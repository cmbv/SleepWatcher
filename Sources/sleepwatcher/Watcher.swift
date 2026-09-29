// SPDX-License-Identifier: GPL-3.0-or-later
//
// sleepwatcher - Watcher.swift
// Subscribes to system events and runs the configured commands.

import AppKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

@MainActor
final class Watcher {
    private(set) var options: Options
    private var hooks: HookRunner
    /// Whether we run in a user's window-server session, where AppKit
    /// notifications (full wake, screen sleep, lock) are available.
    private let guiSession: Bool

    private var rootPort: io_connect_t = 0
    private var notificationPorts: [IONotificationPortRef] = []
    private var notifiers: [io_object_t] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private enum DisplayState { case on, dimmed, off }
    private var displayState = DisplayState.on
    private var hasDisplayWrangler = false
    private var hasLid = false
    private var lidClosed: Bool?
    private var powerSource: PowerSource?

    private var idleTimer: DispatchSourceTimer?
    private var idleFired = false
    private var inBreak = false
    private var lastIdleSample: TimeInterval = 0
    private var lastWake = ProcessInfo.processInfo.systemUptime
    private let activityPollInterval: TimeInterval = 1

    init(options: Options, guiSession: Bool) {
        self.options = options
        self.hooks = HookRunner(timeout: options.hookTimeout)
        self.guiSession = guiSession
    }

    func start() {
        registerSystemPower()
        registerDisplayWrangler()
        registerPowerSource()
        registerLid()
        if guiSession {
            registerWorkspace()
        }
        warnAboutUnsupportedOptions()
        scheduleIdleCheck(after: 0)
    }

    func reconfigure(_ newOptions: Options) {
        options = newOptions
        hooks.timeout = newOptions.hookTimeout
        resetActivityState()
        warnAboutUnsupportedOptions()
        scheduleIdleCheck(after: 0)
    }

    // MARK: - Commands

    @discardableResult
    private func run(_ command: String?, event: String) -> HookResult? {
        guard let command else { return nil }
        let result = hooks.run(command, event: event)
        if !result.succeeded && (result.timedOut || result.spawnError != nil) {
            Log.error("\(event): \(command): \(result)")
        } else {
            Log.info("\(event): \(command): \(result)")
        }
        return result
    }

    // MARK: - System sleep / wake

    private func registerSystemPower() {
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &port, { context, _, messageType, argument in
            let watcher = Unmanaged<Watcher>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated {
                watcher.systemPowerEvent(messageType, notificationID: Int(bitPattern: argument))
            }
        }, &notifier)
        guard rootPort != 0, let port else {
            Log.error("IORegisterForSystemPower failed")
            exit(1)
        }
        add(port, notifier)
    }

    private func systemPowerEvent(_ messageType: UInt32, notificationID: Int) {
        switch messageType {
        case IOMessage.canSystemSleep:
            let allow: Bool
            switch options.allowSleep {
            case .always:
                allow = true
                Log.info("allow sleep")
            case .never:
                allow = false
                Log.info("deny sleep")
            case .command(let command):
                let result = hooks.run(command, event: "allowsleep")
                allow = result.succeeded
                Log.info("\(allow ? "allow" : "deny") sleep: \(command): \(result)")
            }
            if allow {
                IOAllowPowerChange(rootPort, notificationID)
            } else {
                IOCancelPowerChange(rootPort, notificationID)
            }

        case IOMessage.systemWillSleep:
            run(options.sleep, event: "sleep")
            IOAllowPowerChange(rootPort, notificationID)

        case IOMessage.systemWillNotSleep:
            if options.cantSleep != nil {
                run(options.cantSleep, event: "cantsleep")
            } else {
                Log.info("can't sleep")
            }

        case IOMessage.systemHasPoweredOn:
            lastWake = ProcessInfo.processInfo.systemUptime
            resetActivityState()
            scheduleIdleCheck(after: 0)
            run(options.anyWake, event: "anywake")
            // Outside a login session there is no way to tell a dark wake
            // from a full wake, so behave like 2.2.1.
            if !guiSession {
                run(options.wakeup, event: "wakeup")
            }

        default:
            break
        }
    }

    // MARK: - Display

    private func registerDisplayWrangler() {
        let wrangler = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IODisplayWrangler"))
        guard wrangler != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(wrangler) }
        hasDisplayWrangler = addInterest(wrangler) { watcher, messageType, _ in
            watcher.displayWranglerEvent(messageType)
        }
    }

    private func displayWranglerEvent(_ messageType: UInt32) {
        switch messageType {
        case IOMessage.deviceWillPowerOff:
            displayState = displayState == .on ? .dimmed : .off
            if displayState == .dimmed {
                run(options.displayDim, event: "displaydim")
            } else if !guiSession {
                run(options.displaySleep, event: "displaysleep")
            }
        case IOMessage.deviceHasPoweredOn:
            if displayState == .dimmed {
                run(options.displayUndim, event: "displayundim")
            } else if !guiSession {
                run(options.displayWakeup, event: "displaywakeup")
            }
            displayState = .on
        default:
            break
        }
    }

    // MARK: - Power source

    private func registerPowerSource() {
        powerSource = PowerSource.current()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            let watcher = Unmanaged<Watcher>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.powerSourceChanged() }
        }, context)?.takeRetainedValue() else {
            Log.error("IOPSNotificationCreateRunLoopSource failed")
            exit(1)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func powerSourceChanged() {
        // Fires on every battery percentage change too; only act on a switch.
        guard let current = PowerSource.current(), current != powerSource else { return }
        powerSource = current
        switch current {
        case .ac: run(options.plug, event: "plug")
        case .battery: run(options.unplug, event: "unplug")
        }
    }

    // MARK: - Lid

    private func registerLid() {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(rootDomain) }
        guard let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return }
        lidClosed = state
        hasLid = addInterest(rootDomain) { watcher, messageType, argument in
            guard messageType == IOMessage.clamshellStateChange else { return }
            watcher.lidChanged(closed: UInt(bitPattern: argument) & IOMessage.clamshellStateBit != 0)
        }
    }

    private func lidChanged(closed: Bool) {
        guard closed != lidClosed else { return }
        lidClosed = closed
        run(closed ? options.lidClose : options.lidOpen, event: closed ? "lidclose" : "lidopen")
    }

    // MARK: - Login session notifications

    private func registerWorkspace() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification) { $0.run($0.options.wakeup, event: "wakeup") }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.run($0.options.displaySleep, event: "displaysleep") }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.run($0.options.displayWakeup, event: "displaywakeup") }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.run($0.options.lock, event: "lock") }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.run($0.options.unlock, event: "unlock") }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (Watcher) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    // MARK: - Idle / resume

    /// Idle time is polled from HIDIdleTime rather than watched with
    /// IOHIDManager as in 2.2.1, which on current macOS needs the Input
    /// Monitoring permission and otherwise silently never reports input.
    /// Checks are scheduled for exactly when a threshold can be crossed; only
    /// while waiting for the user to come back is it polled every second.
    private func scheduleIdleCheck(after delay: TimeInterval) {
        guard options.idle != nil || options.resume != nil else {
            idleTimer?.cancel()
            idleTimer = nil
            return
        }
        if idleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.checkIdle() }
            }
            timer.resume()
            idleTimer = timer
        }
        let delay = max(delay, 0.1)
        idleTimer?.schedule(deadline: .now() + delay, leeway: .milliseconds(Int(min(delay * 100, 500))))
    }

    private func checkIdle() {
        guard let hidIdle = IdleTime.seconds() else {
            Log.error("can't read HIDIdleTime")
            scheduleIdleCheck(after: 10)
            return
        }
        // Count idleness from the last wake at most, as 2.2.1 did by
        // restarting its idle timer on wakeup.
        let idle = min(hidIdle, ProcessInfo.processInfo.systemUptime - lastWake)
        let activity = idle < lastIdleSample
        lastIdleSample = idle

        var nextCheck: [TimeInterval] = []

        if options.idle != nil {
            if idleFired && activity {
                idleFired = false
                run(options.idleResume, event: "idleresume")
            }
            if !idleFired && idle >= options.idleTimeout {
                idleFired = true
                run(options.idle, event: "idle")
            }
            nextCheck.append(idleFired ? activityPollInterval : options.idleTimeout - idle)
        }

        if options.resume != nil {
            if inBreak && activity {
                inBreak = false
                run(options.resume, event: "resume")
            }
            if !inBreak && idle >= options.breakLength {
                inBreak = true
            }
            nextCheck.append(inBreak ? activityPollInterval : options.breakLength - idle)
        }

        // Commands may have taken a while; re-read before scheduling.
        if let hidIdleNow = IdleTime.seconds() {
            lastIdleSample = min(hidIdleNow, ProcessInfo.processInfo.systemUptime - lastWake)
        }
        scheduleIdleCheck(after: nextCheck.min() ?? activityPollInterval)
    }

    private func resetActivityState() {
        idleFired = false
        inBreak = false
        lastIdleSample = 0
    }

    // MARK: - Helpers

    private func warnAboutUnsupportedOptions() {
        if !guiSession {
            for (name, command) in [("lock", options.lock), ("unlock", options.unlock)] where command != nil {
                Log.error("--\(name) needs a login session (run as a LaunchAgent); ignored")
            }
            if !hasDisplayWrangler && (options.displaySleep != nil || options.displayWakeup != nil) {
                Log.error("display sleep/wake notifications unavailable outside a login session")
            }
        }
        if !hasDisplayWrangler && (options.displayDim != nil || options.displayUndim != nil) {
            Log.error("IODisplayWrangler not found; displaydim/displayundim unavailable")
        }
        if !hasLid && (options.lidOpen != nil || options.lidClose != nil) {
            Log.error("this Mac has no lid; lidopen/lidclose ignored")
        }
    }

    private func add(_ port: IONotificationPortRef, _ notifier: io_object_t) {
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        notificationPorts.append(port)
        notifiers.append(notifier)
    }

    private typealias InterestHandler = @MainActor (Watcher, UInt32, UnsafeMutableRawPointer?) -> Void

    private final class InterestHandlerBox {
        unowned let watcher: Watcher
        let handler: InterestHandler
        init(_ watcher: Watcher, _ handler: @escaping InterestHandler) {
            self.watcher = watcher
            self.handler = handler
        }
    }
    private var interestHandlers: [InterestHandlerBox] = []

    /// General-interest notifications for an IOService, delivered on the main run loop.
    private func addInterest(_ service: io_service_t, _ handler: @escaping InterestHandler) -> Bool {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        let box = InterestHandlerBox(self, handler)
        var notifier: io_object_t = 0
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, messageType, argument in
            let box = Unmanaged<InterestHandlerBox>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated {
                box.handler(box.watcher, messageType, argument)
            }
        }, Unmanaged.passUnretained(box).toOpaque(), &notifier)
        guard result == kIOReturnSuccess else {
            IONotificationPortDestroy(port)
            return false
        }
        interestHandlers.append(box)
        add(port, notifier)
        return true
    }
}
