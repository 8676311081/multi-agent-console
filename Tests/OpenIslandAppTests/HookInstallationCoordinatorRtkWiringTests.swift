import Foundation
import Testing
@testable import OpenIslandApp
@testable import OpenIslandCore

/// Coverage for the cold-start / refresh wiring path that
/// `HookInstallationCoordinator.ensureRtkRuntimeWired()` was
/// extracted to fix. Before this helper existed, `RTKWatchdog` and
/// `RTKTelemetryReader` were only armed inside `installRtk()`, so
/// every dev-app restart left them dormant even though disk state
/// said RTK was installed (see `rtk-polling-diagnosis.md`).
///
/// Tests are `@MainActor` because `HookInstallationCoordinator` is.
@MainActor
struct HookInstallationCoordinatorRtkWiringTests {
    private static func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtk-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build an RTKInstallationManager rooted in a temp directory.
    /// `status()` will return based on the temp directory's contents,
    /// so tests can plant a binary + hook entry to drive it to
    /// `.installedEnabled` without touching real `~/.open-island`.
    private static func makeTempRootedManager(in root: URL) -> RTKInstallationManager {
        let home = root.appendingPathComponent("HOME", isDirectory: true)
        let claude = root.appendingPathComponent("HOME/.claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        return RTKInstallationManager(
            homeDirectory: home,
            claudeDirectory: claude,
            archProvider: { "arm64" },
            downloader: { _ in URL(fileURLWithPath: "/dev/null") },
            expectedTarballSHA256: "deadbeef"
        )
    }

    /// Build a synthetic `.installedEnabled` status without exercising
    /// the install path. Used for direct tests of
    /// `ensureRtkRuntimeWired()` that don't care about disk state.
    private static func makeInstalledEnabledStatus(
        for manager: RTKInstallationManager
    ) -> RTKInstallationStatus {
        RTKInstallationStatus(
            state: .installedEnabled,
            arch: "arm64",
            rtkVersion: "test",
            binaryURL: manager.binaryURL,
            pidFileURL: manager.pidFileURL,
            settingsURL: manager.settingsURL,
            binaryPresent: true,
            binaryExecutable: true,
            hookConfigured: true
        )
    }

    // MARK: - Direct ensureRtkRuntimeWired() coverage

    @Test
    func ensureRtkRuntimeWiredStartsBothWhenEnabled() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = HookInstallationCoordinator()
        let mgr = Self.makeTempRootedManager(in: root)
        coord.rtkInstallationManager = mgr
        coord.rtkStatus = Self.makeInstalledEnabledStatus(for: mgr)
        coord.llmStatsStore = LLMStatsStore(url: root.appendingPathComponent("llm-stats.json"))

        coord.ensureRtkRuntimeWired()
        defer { coord.stopRtkWatchdog() }

        #expect(coord.rtkWatchdog?.isRunning == true)
        #expect(coord.rtkTelemetryReader?.isRunning == true)
    }

    @Test
    func ensureRtkRuntimeWiredNoOpWhenStatusNil() throws {
        let coord = HookInstallationCoordinator()
        // No rtkStatus, no llmStatsStore — empty cold start.
        coord.ensureRtkRuntimeWired()

        #expect(coord.rtkWatchdog == nil)
        #expect(coord.rtkTelemetryReader == nil)
    }

    @Test
    func ensureRtkRuntimeWiredNoOpWhenStateNotInstalled() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = HookInstallationCoordinator()
        let mgr = Self.makeTempRootedManager(in: root)
        coord.rtkInstallationManager = mgr
        coord.rtkStatus = RTKInstallationStatus(
            state: .notInstalled,
            arch: "arm64",
            rtkVersion: "test",
            binaryURL: mgr.binaryURL,
            pidFileURL: mgr.pidFileURL,
            settingsURL: mgr.settingsURL,
            binaryPresent: false,
            binaryExecutable: false,
            hookConfigured: false
        )
        coord.llmStatsStore = LLMStatsStore(url: root.appendingPathComponent("llm-stats.json"))

        coord.ensureRtkRuntimeWired()

        #expect(coord.rtkWatchdog == nil, "watchdog should not start when state != installedEnabled")
        #expect(coord.rtkTelemetryReader == nil, "reader should not start when state != installedEnabled")
    }

    @Test
    func ensureRtkRuntimeWiredIsIdempotent() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = HookInstallationCoordinator()
        let mgr = Self.makeTempRootedManager(in: root)
        coord.rtkInstallationManager = mgr
        coord.rtkStatus = Self.makeInstalledEnabledStatus(for: mgr)
        coord.llmStatsStore = LLMStatsStore(url: root.appendingPathComponent("llm-stats.json"))

        coord.ensureRtkRuntimeWired()
        let watchdog1 = coord.rtkWatchdog
        let reader1 = coord.rtkTelemetryReader
        coord.ensureRtkRuntimeWired()
        coord.ensureRtkRuntimeWired()
        defer { coord.stopRtkWatchdog() }

        // Helper must reuse the already-running instances. Reference
        // identity asserts no second watchdog / reader was constructed
        // by the second / third call.
        #expect(coord.rtkWatchdog === watchdog1, "watchdog must not be recreated on subsequent calls")
        #expect(coord.rtkTelemetryReader === reader1, "reader must not be recreated on subsequent calls")
        #expect(coord.rtkWatchdog?.isRunning == true)
        #expect(coord.rtkTelemetryReader?.isRunning == true)
    }

    @Test
    func ensureRtkRuntimeWiredSkipsReaderWhenStoreMissing() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Missing llmStatsStore (e.g. early in init before LLMProxy is
        // wired). Watchdog still starts, reader is deferred.
        let coord = HookInstallationCoordinator()
        let mgr = Self.makeTempRootedManager(in: root)
        coord.rtkInstallationManager = mgr
        coord.rtkStatus = Self.makeInstalledEnabledStatus(for: mgr)
        coord.llmStatsStore = nil

        coord.ensureRtkRuntimeWired()
        defer { coord.stopRtkWatchdog() }

        #expect(coord.rtkWatchdog?.isRunning == true)
        #expect(coord.rtkTelemetryReader == nil)
    }

    // MARK: - refreshRtkStatus() routes through the helper

    /// `refreshRtkStatus()` reads disk state then calls
    /// `ensureRtkRuntimeWired()`. To exercise the full chain, plant a
    /// disk state that drives `manager.status()` to `.installedEnabled`
    /// (binary executable + managed PreToolUse hook), then call
    /// `refreshRtkStatus()` and assert wiring lands.
    @Test
    func refreshRtkStatusWiresRuntimeWhenDiskStateIsEnabled() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeTempRootedManager(in: root)
        // Plant a fake executable binary at mgr.binaryURL.
        try FileManager.default.createDirectory(
            at: mgr.openIslandBinDirURL,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/bash\n".utf8).write(to: mgr.binaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: mgr.binaryURL.path
        )
        // Plant a managed PreToolUse hook in settings.json.
        let hookCmd = mgr.hookCommand
        try ClaudeSettingsBackupHelper.mutateClaudeSettings(
            directory: mgr.claudeDirectory
        ) { settings in
            RTKInstallationManager.installPreToolUseEntry(in: &settings, hookCommand: hookCmd)
        }
        // Sanity: the manager should now report .installedEnabled.
        let probedState = try mgr.status().state
        #expect(probedState == .installedEnabled, "fixture must expose .installedEnabled, got \(probedState)")

        let coord = HookInstallationCoordinator()
        coord.rtkInstallationManager = mgr
        coord.llmStatsStore = LLMStatsStore(url: root.appendingPathComponent("llm-stats.json"))

        coord.refreshRtkStatus()
        defer { coord.stopRtkWatchdog() }

        #expect(coord.rtkStatus?.state == .installedEnabled)
        #expect(coord.rtkWatchdog?.isRunning == true,
                "refreshRtkStatus must route through ensureRtkRuntimeWired and arm the watchdog")
        #expect(coord.rtkTelemetryReader?.isRunning == true,
                "refreshRtkStatus must route through ensureRtkRuntimeWired and arm the reader")
    }

    @Test
    func refreshRtkStatusDoesNotWireRuntimeWhenDiskStateIsNotInstalled() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeTempRootedManager(in: root)
        // No binary planted, no hook → status() returns .notInstalled.
        let coord = HookInstallationCoordinator()
        coord.rtkInstallationManager = mgr
        coord.llmStatsStore = LLMStatsStore(url: root.appendingPathComponent("llm-stats.json"))

        coord.refreshRtkStatus()

        #expect(coord.rtkStatus?.state == .notInstalled)
        #expect(coord.rtkWatchdog == nil, "refresh must NOT wire runtime when disk state is notInstalled")
        #expect(coord.rtkTelemetryReader == nil)
    }
}
