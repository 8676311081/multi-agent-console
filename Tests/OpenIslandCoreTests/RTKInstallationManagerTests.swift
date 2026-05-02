import CryptoKit
import Foundation
import Testing
@testable import OpenIslandCore

struct RTKInstallationManagerTests {
    // MARK: - Test fixtures

    /// Build a tar.gz containing a single executable file named `rtk` at
    /// the archive root, mimicking the upstream RTK release layout.
    /// Returns (tarball URL, sha256 hex string).
    static func makeFakeTarball(
        in dir: URL,
        binaryContents: String = "#!/bin/sh\necho fake-rtk\n"
    ) throws -> (URL, String) {
        let stage = dir.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let bin = stage.appendingPathComponent("rtk")
        try binaryContents.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let tarball = dir.appendingPathComponent("fake-rtk-\(UUID().uuidString).tar.gz")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-czf", tarball.path, "-C", stage.path, "rtk"]
        try proc.run()
        proc.waitUntilExit()
        try? FileManager.default.removeItem(at: stage)

        let data = try Data(contentsOf: tarball)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (tarball, hex)
    }

    static func makeManager(
        in root: URL,
        arch: String = "arm64",
        downloader: @escaping @Sendable (URL) async throws -> URL,
        expectedSHA: String
    ) -> RTKInstallationManager {
        let home = root.appendingPathComponent("HOME", isDirectory: true)
        let claude = root.appendingPathComponent("HOME/.claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        return RTKInstallationManager(
            homeDirectory: home,
            claudeDirectory: claude,
            archProvider: { arch },
            downloader: downloader,
            expectedTarballSHA256: expectedSHA
        )
    }

    static func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtk-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Architecture gate

    @Test
    func intelMachineReportsUnsupportedArchitecture() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeManager(
            in: root,
            arch: "x86_64",
            downloader: { _ in URL(fileURLWithPath: "/dev/null") },
            expectedSHA: "deadbeef"
        )
        let status = try mgr.status()
        #expect(status.state == .unsupportedArchitecture)
        #expect(status.arch == "x86_64")
    }

    @Test
    func intelMachineRefusesInstall() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeManager(
            in: root,
            arch: "x86_64",
            downloader: { _ in URL(fileURLWithPath: "/dev/null") },
            expectedSHA: "deadbeef"
        )
        await #expect(throws: RTKInstallError.self) {
            _ = try await mgr.install()
        }
    }

    // MARK: - Install / uninstall round-trip

    @Test
    func installPlacesBinaryAndConfiguresHookCommand() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        let status = try await mgr.install()

        #expect(status.state == .installedEnabled)
        #expect(FileManager.default.isExecutableFile(atPath: mgr.binaryURL.path))
        #expect(status.hookConfigured)
        // No wrapper script: post-fix installer points hook directly
        // at the binary.
        #expect(!FileManager.default.fileExists(atPath: mgr.legacyWrapperURL.path))
        // No legacy jsonl either.
        #expect(!FileManager.default.fileExists(atPath: mgr.legacyStatsJSONLURL.path))

        // ~/.local/bin/rtk symlink is in place and points at our binary.
        let symAttrs = try FileManager.default.attributesOfItem(atPath: mgr.userLocalBinSymlinkURL.path)
        #expect((symAttrs[.type] as? FileAttributeType) == .typeSymbolicLink)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: mgr.userLocalBinSymlinkURL.path)
        #expect(dest == mgr.binaryURL.path)

        // settings.json contains our PreToolUse entry whose command is
        // exactly `<binary> hook claude`.
        let settings = try ClaudeSettingsBackupHelper.currentSettings(
            directory: mgr.claudeDirectory
        )
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.contains { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String) == mgr.hookCommand }
        })
        #expect(mgr.hookCommand.hasSuffix(" hook claude"))
        #expect(mgr.hookCommand.hasPrefix(mgr.binaryURL.path))
    }

    /// install → uninstall round trip preserves semantics + no RTK
    /// trace remains. Byte-equality is *not* asserted here — Foundation
    /// Dictionary serialization is not insertion-order stable across
    /// parse-then-reserialize, which the helper documents as a known
    /// limitation. The companion `roundTripFromClaudeCodeNativeFixture…`
    /// test pins the user-facing semantic invariants on a real-world
    /// ECMAScript-style fixture; this one focuses on dict-shape edges.
    @Test
    func uninstallRestoresSettingsSemanticsExactlyToPreInstall() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        let preInstall: [String: Any] = [
            "theme": "light",
            "env": ["FOO": "bar"],
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Read",
                        "hooks": [["type": "command", "command": "/some/other/hook"]],
                    ]
                ]
            ],
        ]
        let preInstallData = try ClaudeSettingsBackupHelper.serializeSettings(preInstall)
        try preInstallData.write(to: mgr.settingsURL)

        _ = try await mgr.install()
        _ = try mgr.uninstall()

        let postObj = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: mgr.settingsURL)
        ) as? NSDictionary
        let preObj = preInstall as NSDictionary
        #expect(postObj == preObj)
        #expect(!FileManager.default.fileExists(atPath: mgr.binaryURL.path))
    }

    /// Real-world fixture: a settings.json written by Claude Code itself
    /// (ECMAScript-style: no slash escaping, no leading space before
    /// colons, insertion-order keys). Round-trip must preserve JSON
    /// semantics and not leave RTK artifacts behind. Byte-level
    /// equality is *not* asserted — Foundation does not preserve dict
    /// insertion order on serialization, so the post-install file may
    /// have keys in a different order. This is a documented limitation
    /// (see `ClaudeSettingsBackupHelper.serializeSettings`).
    @Test
    func roundTripFromClaudeCodeNativeFixturePreservesSemantics() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        // Verbatim ECMAScript-style fixture — exactly the shape Claude
        // Code's own settings writer produces.
        let fixture = """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:7860",
            "HTTP_PROXY": "http://127.0.0.1:1082"
          },
          "theme": "light",
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Read",
                "hooks": [
                  { "type": "command", "command": "/some/other/hook" }
                ]
              }
            ]
          }
        }
        """
        try fixture.data(using: .utf8)!.write(to: mgr.settingsURL)
        let baseline = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]

        _ = try await mgr.install()
        _ = try mgr.uninstall()

        let after = try ClaudeSettingsBackupHelper.currentSettings(directory: mgr.claudeDirectory)

        // Top-level keys preserved.
        #expect(Set(after.keys) == Set(baseline.keys))

        // env preserved verbatim.
        let baselineEnv = baseline["env"] as? [String: String]
        let afterEnv = after["env"] as? [String: String]
        #expect(afterEnv == baselineEnv)

        // theme preserved.
        #expect((after["theme"] as? String) == "light")

        // hooks.PreToolUse: the unrelated /some/other/hook entry survives,
        // RTK's `<bin> hook claude`-pointing entry is gone.
        let pre = (after["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.count == 1)
        let preserved = pre?.first
        #expect((preserved?["matcher"] as? String) == "Read")
        let preservedInner = preserved?["hooks"] as? [[String: Any]]
        #expect((preservedInner?.first?["command"] as? String) == "/some/other/hook")
    }


    @Test
    func sha256MismatchPreventsInstallAndLeavesNoArtifacts() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, _) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: String(repeating: "0", count: 64)
        )

        await #expect(throws: RTKInstallError.self) {
            _ = try await mgr.install()
        }

        // No artifacts left behind.
        #expect(!FileManager.default.fileExists(atPath: mgr.binaryURL.path))
        let status = try mgr.status()
        #expect(status.state == .notInstalled)
    }

    // MARK: - Watchdog binary-loss recovery

    @Test
    func watchdogTickAfterBinaryLossRollsBackSettings() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        // Seed empty settings.json so we can compare diff easily.
        let baseline = Data("{}".utf8)
        try baseline.write(to: mgr.settingsURL)

        _ = try await mgr.install()
        #expect(try mgr.status().state == .installedEnabled)

        // Simulate user rm-ing the binary.
        try FileManager.default.removeItem(at: mgr.binaryURL)

        let watchdog = RTKWatchdog(manager: mgr)
        watchdog.tick()  // synchronous single-cycle check

        let post = try mgr.status()
        #expect(!post.hookConfigured)
        #expect(post.state == .notInstalled)
    }

    @Test
    func handleBinaryLossIsIdempotent() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in URL(fileURLWithPath: "/dev/null") },
            expectedSHA: "deadbeef"
        )
        // Calling on an empty system shouldn't throw.
        _ = try mgr.handleBinaryLoss()
        _ = try mgr.handleBinaryLoss()
    }

    @Test
    func watchdogStartIsIdempotent() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in URL(fileURLWithPath: "/dev/null") },
            expectedSHA: "deadbeef"
        )
        // Long tick interval so the loop doesn't actually fire mid-test —
        // we only care that start() doesn't spawn a second background Task.
        let watchdog = RTKWatchdog(manager: mgr, tickInterval: 3600)
        watchdog.start()
        watchdog.start()  // second call must be a no-op (guard task == nil)
        #expect(watchdog.isRunning)
        watchdog.stop()
        #expect(!watchdog.isRunning)
    }

    // MARK: - Hook command schema (post-fix: no wrapper script)

    @Test
    func hookCommandSchema() {
        let mgr = RTKInstallationManager(
            homeDirectory: URL(fileURLWithPath: "/tmp/fakehome"),
            archProvider: { "arm64" }
        )
        // Exact shape contract: `<binaryURL.path> hook claude`.
        #expect(mgr.hookCommand == "/tmp/fakehome/.open-island/bin/rtk hook claude")
    }

    // MARK: - Legacy artifact cleanup (upgrade from pre-fix installer)

    @Test
    func uninstallRemovesLegacyJSONLIfPresent() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        // Simulate a leftover from the pre-fix wrapper.
        try FileManager.default.createDirectory(
            at: mgr.openIslandHomeURL,
            withIntermediateDirectories: true
        )
        try Data("{\"ts\":1,\"raw\":\"[rtk] legacy line\"}\n".utf8)
            .write(to: mgr.legacyStatsJSONLURL)

        _ = try await mgr.install()
        _ = try mgr.uninstall()

        #expect(!FileManager.default.fileExists(atPath: mgr.legacyStatsJSONLURL.path))
    }

    @Test
    func uninstallRemovesLegacyWrapperAndItsHookEntryIfPresent() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        // Simulate machine that previously had wrapper installed:
        //   1. A leftover wrapper script on disk
        //   2. settings.json contains a PreToolUse entry pointing at it
        try FileManager.default.createDirectory(
            at: mgr.openIslandBinDirURL,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: mgr.legacyWrapperURL)
        var seedSettings: [String: Any] = [:]
        RTKInstallationManager.installPreToolUseEntry(
            in: &seedSettings,
            hookCommand: mgr.legacyWrapperURL.path
        )
        try ClaudeSettingsBackupHelper.serializeSettings(seedSettings)
            .write(to: mgr.settingsURL)

        // Uninstall on its own (no fresh install) should clean both.
        _ = try mgr.uninstall()

        #expect(!FileManager.default.fileExists(atPath: mgr.legacyWrapperURL.path))
        let after = try ClaudeSettingsBackupHelper.currentSettings(directory: mgr.claudeDirectory)
        let pre = (after["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        // The PreToolUse list (if any) must not contain the legacy wrapper anymore.
        #expect(pre?.allSatisfy { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return true }
            return inner.allSatisfy { ($0["command"] as? String) != mgr.legacyWrapperURL.path }
        } ?? true)
    }

    @Test
    func installDoesNotCreateLegacyJSONL() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        _ = try await mgr.install()

        // Post-fix install path must never write rtk-stats.jsonl —
        // telemetry now flows through `rtk gain --format json`, not
        // wrapper-tee'd stderr.
        #expect(!FileManager.default.fileExists(atPath: mgr.legacyStatsJSONLURL.path))
    }

    // MARK: - ~/.local/bin/rtk symlink (PATH-bridging)

    /// Re-running install on a system that already has our exact
    /// symlink should not throw and should not double-create. (The
    /// outer install gate would normally reject `alreadyInstalled`,
    /// so we drive the symlink helper directly to keep this test
    /// scoped to its three-state contract.)
    @Test
    func userLocalBinSymlinkIsIdempotentWhenAlreadyOurs() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        _ = try await mgr.install()
        let firstDest = try FileManager.default.destinationOfSymbolicLink(
            atPath: mgr.userLocalBinSymlinkURL.path
        )

        // Uninstall + reinstall — symlink should be restored to the
        // same target without triggering a clobber.
        _ = try mgr.uninstall()
        _ = try await mgr.install()

        let secondDest = try FileManager.default.destinationOfSymbolicLink(
            atPath: mgr.userLocalBinSymlinkURL.path
        )
        #expect(firstDest == secondDest)
        #expect(secondDest == mgr.binaryURL.path)
    }

    @Test
    func installRefusesToClobberRegularFileAtUserLocalBinPath() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        // Plant a user-installed regular file (e.g. brew/cargo result).
        try FileManager.default.createDirectory(
            at: mgr.userLocalBinDirURL,
            withIntermediateDirectories: true
        )
        try Data("not a symlink".utf8).write(to: mgr.userLocalBinSymlinkURL)
        let beforeBytes = try Data(contentsOf: mgr.userLocalBinSymlinkURL)

        await #expect(throws: RTKInstallError.self) {
            _ = try await mgr.install()
        }

        // Refuse-clobber: the file at ~/.local/bin/rtk is unchanged,
        // and earlier-step artifacts (binary, settings.json hook
        // entry) must have been rolled back.
        #expect(try Data(contentsOf: mgr.userLocalBinSymlinkURL) == beforeBytes)
        #expect(!FileManager.default.fileExists(atPath: mgr.binaryURL.path))
        let status = try mgr.status()
        #expect(status.state == .notInstalled)
        #expect(!status.hookConfigured)
    }

    @Test
    func installRefusesToClobberAlienSymlinkAtUserLocalBinPath() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        // Plant an alien symlink (user has rtk pinned to a different path).
        try FileManager.default.createDirectory(
            at: mgr.userLocalBinDirURL,
            withIntermediateDirectories: true
        )
        let alienTarget = "/usr/local/bin/rtk"
        try FileManager.default.createSymbolicLink(
            atPath: mgr.userLocalBinSymlinkURL.path,
            withDestinationPath: alienTarget
        )

        await #expect(throws: RTKInstallError.self) {
            _ = try await mgr.install()
        }

        // Alien symlink survives unchanged.
        let dest = try FileManager.default.destinationOfSymbolicLink(
            atPath: mgr.userLocalBinSymlinkURL.path
        )
        #expect(dest == alienTarget)
    }

    @Test
    func uninstallLeavesAlienSymlinkAlone() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        _ = try await mgr.install()

        // Simulate user repointing the symlink mid-life.
        try FileManager.default.removeItem(at: mgr.userLocalBinSymlinkURL)
        let alienTarget = "/opt/homebrew/bin/rtk"
        try FileManager.default.createSymbolicLink(
            atPath: mgr.userLocalBinSymlinkURL.path,
            withDestinationPath: alienTarget
        )

        _ = try mgr.uninstall()

        // We don't touch user's override.
        #expect(FileManager.default.fileExists(atPath: mgr.userLocalBinSymlinkURL.path)
                || (try? FileManager.default.attributesOfItem(atPath: mgr.userLocalBinSymlinkURL.path)) != nil)
        let dest = try FileManager.default.destinationOfSymbolicLink(
            atPath: mgr.userLocalBinSymlinkURL.path
        )
        #expect(dest == alienTarget)

        // But our binary IS gone.
        #expect(!FileManager.default.fileExists(atPath: mgr.binaryURL.path))
    }

    @Test
    func uninstallRemovesOurOwnSymlink() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        _ = try await mgr.install()
        #expect((try? FileManager.default.attributesOfItem(
            atPath: mgr.userLocalBinSymlinkURL.path
        )) != nil)

        _ = try mgr.uninstall()

        // attributesOfItem on a missing path throws — that's the signal.
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: mgr.userLocalBinSymlinkURL.path
        )
        #expect(attrs == nil)
    }

    @Test
    func handleBinaryLossRemovesDanglingOurSymlink() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (tarball, hex) = try Self.makeFakeTarball(in: root)
        let mgr = Self.makeManager(
            in: root,
            downloader: { _ in tarball },
            expectedSHA: hex
        )

        _ = try await mgr.install()
        // User rm's the binary out from under us.
        try FileManager.default.removeItem(at: mgr.binaryURL)
        // Symlink is still on disk but now dangling.

        _ = try mgr.handleBinaryLoss()

        // Our dangling symlink is reaped (target string still matched
        // binaryURL.path), but we'd leave alien/repointed symlinks
        // alone (covered separately in uninstallLeavesAlienSymlinkAlone).
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: mgr.userLocalBinSymlinkURL.path
        )
        #expect(attrs == nil)
    }

    // MARK: - settings.json shape helpers

    @Test
    func installPreToolUseEntryIsIdempotent() {
        var settings: [String: Any] = [:]
        RTKInstallationManager.installPreToolUseEntry(
            in: &settings,
            hookCommand: "/path/to/rtk hook claude"
        )
        RTKInstallationManager.installPreToolUseEntry(
            in: &settings,
            hookCommand: "/path/to/rtk hook claude"
        )

        let hooks = settings["hooks"] as? [String: Any]
        let pre = hooks?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.count == 1)
    }

    @Test
    func uninstallPreToolUseEntryRemovesEmptyContainers() {
        var settings: [String: Any] = [:]
        RTKInstallationManager.installPreToolUseEntry(
            in: &settings,
            hookCommand: "/path/to/rtk hook claude"
        )
        RTKInstallationManager.uninstallPreToolUseEntry(
            in: &settings,
            hookCommand: "/path/to/rtk hook claude"
        )
        #expect(settings["hooks"] == nil)
    }

    @Test
    func uninstallPreToolUseEntryPreservesUnrelatedHooks() {
        var settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Read", "hooks": [["type": "command", "command": "/other"]]] as [String: Any]
                ]
            ]
        ]
        RTKInstallationManager.installPreToolUseEntry(
            in: &settings,
            hookCommand: "/path/to/rtk hook claude"
        )
        RTKInstallationManager.uninstallPreToolUseEntry(
            in: &settings,
            hookCommand: "/path/to/rtk hook claude"
        )

        let pre = (settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.count == 1)
        #expect((pre?.first?["matcher"] as? String) == "Read")
    }

    // MARK: - Architecture detection sanity

    @Test
    func currentArchOnApplePlatformReturnsKnownValue() {
        let arch = RTKInstallationManager.currentArch()
        // Whatever the host is, it should be a non-empty token.
        #expect(!arch.isEmpty)
        #expect(!arch.contains("\0"))
    }
}
