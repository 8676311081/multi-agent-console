import Foundation
import os

/// Periodic check that the RTK binary is still on disk. If it disappears
/// (user `rm`'d it manually, FS corruption, anti-virus quarantine, etc.)
/// the watchdog removes Open Island's PreToolUse hook from
/// `~/.claude/settings.json` so Claude Code doesn't keep firing a hook
/// that points at a missing wrapper / binary.
///
/// Lifecycle:
///   - `start()` is idempotent. Writes our PID into `rtk-watchdog.pid`
///     so the Rust-style "is the watchdog alive?" check (e.g. on app
///     restart) has a stable signal.
///   - `stop()` cancels the tick task and removes the pid file. The
///     app calls this from `applicationWillTerminate` so a clean Cmd+Q
///     leaves no ghost process.
///   - `tick()` is the unit-testable single-cycle check. Tests don't
///     need to wait 30 seconds; they instantiate the watchdog (without
///     `start()`) and call `tick()` directly.
public final class RTKWatchdog: @unchecked Sendable {
    public static let defaultTickInterval: TimeInterval = 30

    private let manager: RTKInstallationManager
    private let tickInterval: TimeInterval
    private let fileManager: FileManager
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(
        manager: RTKInstallationManager,
        tickInterval: TimeInterval = defaultTickInterval,
        fileManager: FileManager = .default
    ) {
        self.manager = manager
        self.tickInterval = tickInterval
        self.fileManager = fileManager
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return task != nil
    }

    /// Idempotent. Spawns the periodic tick task and writes a pid file.
    ///
    /// **Lifecycle gate:** App-side callers MUST go through
    /// `HookInstallationCoordinator.ensureRtkRuntimeWired()` rather
    /// than calling `start()` directly, so cold-start / status-refresh
    /// / install-success share a single wiring point. Calling `start()`
    /// directly bypasses that gate; `public` here is a cross-module
    /// access necessity, not an invitation.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        // Best-effort pid file. If the directory doesn't exist (manager
        // not installed yet) we just silently skip — start() called from
        // an install path will have created it already.
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        try? pid.data(using: .utf8)?.write(to: manager.pidFileURL, options: .atomic)

        let captured = ManagerProxy(manager: manager, fileManager: fileManager)
        let interval = tickInterval
        task = Task.detached(priority: .background) {
            while !Task.isCancelled {
                let nanos = UInt64(max(interval, 0.001) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                captured.tick()
            }
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
        try? fileManager.removeItem(at: manager.pidFileURL)
    }

    /// Single tick: if the rtk binary is gone, ask the manager to clean
    /// up settings.json + wrapper. Synchronous, testable.
    public func tick() {
        let proxy = ManagerProxy(manager: manager, fileManager: fileManager)
        proxy.tick()
    }

    /// `@unchecked Sendable` shim so `Task.detached` can capture both
    /// the manager and a FileManager without the compiler whining about
    /// Sendable. All access is read-only after init.
    private struct ManagerProxy: @unchecked Sendable {
        let manager: RTKInstallationManager
        let fileManager: FileManager

        func tick() {
            let bin = manager.binaryURL
            if fileManager.isExecutableFile(atPath: bin.path) { return }
            // Binary missing — clean up the orphaned hook + wrapper.
            if (try? manager.handleBinaryLoss()) == nil {
                os_log(.error, "Failed to clean up orphaned hooks after RTK binary loss")
            }
        }
    }
}
