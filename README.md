# sleepwatcher 3

A Swift port of [SleepWatcher 2.2.1](https://www.bernhard-baehr.de/) (Bernhard Baehr, 2002–2019), updated for current macOS (built and tested on macOS 27.0.1 on Apple silicon).

It runs your shell commands when the Mac sleeps, wakes, dims or sleeps its display, goes idle, changes power source, and (new in 3.0) when the screen locks or unlocks or the lid opens or closes.

It accepts the same command-line options and config-file format as 2.2.1, so existing `~/.sleep` / `~/.wakeup` setups work unchanged.

## Build and install

Requires the Xcode Command Line Tools (Swift 6).

```sh
make                 # build/sleepwatcher (arm64)
make test            # smoke tests; doesn't sleep the Mac
make install         # ~/.local/bin/sleepwatcher   (PREFIX=/usr/local for system-wide)
make install-agent   # LaunchAgent local.sleepwatcher running ~/.sleep and ~/.wakeup
make uninstall-agent
```

`make ARCHS="arm64 x86_64"` builds a universal binary if you also need it on an Intel Mac running macOS 13–26.

### Migrating from the Homebrew formula

```sh
brew services stop sleepwatcher 2>/dev/null
launchctl bootout gui/$(id -u)/sh.brew.sleepwatcher 2>/dev/null
rm -f ~/Library/LaunchAgents/sh.brew.sleepwatcher.plist
make install-agent
```

## What changed from 2.2.1

| Area | 2.2.1 on current macOS | 3.0 |
|---|---|---|
| Idle / resume (`-t -i -R -b -r`) | Watches keyboard and mouse with IOHIDManager, which needs the **Input Monitoring** permission. Without it, input isn't reported, so the idle timer is never reset and `-R`/`-r` can't fire. | Reads `HIDIdleTime`, which needs no permission. Checks are timed to the threshold; it only polls once a second while waiting for you to come back. |
| Wake (`-w`) | Runs on every wake, including the Power Nap / maintenance **dark wakes** that happen repeatedly overnight. | In a login session, runs only on wakes you see (`NSWorkspace.didWakeNotification`). The new `--anywake` runs on every wake. Outside a login session it behaves like 2.2.1. |
| Display sleep/wake (`-S -W`) | IODisplayWrangler, a compatibility shim on Apple silicon. | `NSWorkspace` screen sleep/wake in a login session; the wrangler is still used for dim/undim (`-D -E`) and as a fallback. A missing wrangler is a warning, not `exit(1)`. |
| Plug/unplug (`-P -U`) | Fires spuriously the first time the battery percentage changes after launch. Desktops never report a source. | Records the starting power source and fires only on real switches. Uses the providing power source type, so a desktop on a USB UPS also reports unplug/plug. |
| Hooks | `system()` with sleepwatcher's signal handlers in effect; no limit on how long a hook can run. | `posix_spawn` of `/bin/sh -c`, default signal dispositions, own process group, `SLEEPWATCHER_EVENT` in the environment, optional `--hooktimeout`. |
| Signals | `SIGHUP` handler re-parses everything inside the signal handler (not async-signal-safe). | Dispatch signal sources on the main run loop. |
| Logging | `syslog` with `-d`, stdout otherwise. | Unified log (subsystem `sleepwatcher`), plus stdout/stderr unless `-d`. |
| Build | Makefile for i386/x86_64/ppc with `-prebind`, deprecated `IOMasterPort`. | Swift 6 with strict concurrency, `kIOMainPortDefault`, arm64 by default, ad-hoc signed. |
| `-d` | `daemon(3)` | Relaunches itself detached with `posix_spawn` (`daemon(3)` is unavailable to Swift). Prefer launchd anyway. |

New options: `--anywake`, `--lock`, `--unlock`, `--lidopen`, `--lidclose`, `--hooktimeout`.

`-t`, `-b` and `--hooktimeout` also accept `s`/`m`/`h` suffixes (`-t 10m`). A bare number still means tenths of a second for `-t`/`-b`, as in 2.2.1.

Run `sleepwatcher -h` for the full option list.

## Recommended setup on macOS 27

1. **Run it as a LaunchAgent in your login session** (`make install-agent`), not as a root LaunchDaemon. The login session is where lock/unlock, full wake and screen sleep events are delivered. The agent sets `LimitLoadToSessionType=Aqua` and `ProcessType=Interactive`, adds Homebrew to `PATH`, and logs to `~/Library/Logs/sleepwatcher.log`.
2. **Keep `~/.sleep` short.** macOS gives sleep clients about 30 s at most, and less is safer. Use `--hooktimeout 20` (or `hooktimeout = 20` in a config file) so a hung network unmount can't hold up sleep.
3. **Use `-w` for "I'm back" actions** (reconnect VPN, remount shares, restart a sync tool). Use `--anywake` only for work that should also run during Power Nap.
4. **Use `--lock`/`--unlock` instead of display sleep** when you mean "the user left". The screen can sleep without locking, and it can lock without sleeping.
5. **`-a` (allowsleep) only vetoes *idle* sleep.** Closing the lid, choosing Apple menu > Sleep, or low battery can't be refused. For "keep awake while X runs", `caffeinate -i -w <pid>` is usually simpler.
6. **Branch on `$SLEEPWATCHER_EVENT`** if you point several events at one script.
7. **Watch it live:** `log stream --predicate 'subsystem == "sleepwatcher"'`.

## Testing notes

`make test` covers option and config parsing, hooks and their environment, signal state, `--hooktimeout`, SIGHUP reload, pidfile handling and `-d`. The idle and resume cycle was also checked by hand.

Events that require actually sleeping the Mac, locking the screen, sleeping the display or pulling power weren't exercised by the automated tests. Two of them depend on macOS behavior that should be confirmed on real hardware: whether `-w` is skipped for Power Nap wakes, and whether the wrangler still reports dim/undim on Apple silicon.

## License

GPL-3.0-or-later, as the original (see `COPYING`). The unmodified 2.2.1 source and man page are kept in `original/` for reference.
