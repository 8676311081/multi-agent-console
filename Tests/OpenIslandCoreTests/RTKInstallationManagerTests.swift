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
    func installPlacesBinaryAndWrapperAndConfiguresHook() async throws {
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
        #expect(FileManager.default.isExecutableFile(atPath: mgr.wrapperURL.path))
        #expect(status.hookConfigured)

        // settings.json contains our PreToolUse entry pointing at the wrapper.
        let settings = try ClaudeSettingsBackupHelper.currentSettings(
            directory: mgr.claudeDirectory
        )
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.contains { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String) == mgr.wrapperURL.path }
        })
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
        #expect(!FileManager.default.fileExists(atPath: mgr.wrapperURL.path))
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
        // RTK's wrapper-pointing entry is gone.
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
        #expect(!FileManager.default.fileExists(atPath: mgr.wrapperURL.path))
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
        #expect(!FileManager.default.fileExists(atPath: mgr.wrapperURL.path))
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

    // MARK: - Wrapper script invariants

    @Test
    func wrapperScriptContainsRequiredElements() {
        let s = RTKInstallationManager.wrapperScript()
        #expect(s.hasPrefix("#!/bin/bash"))
        #expect(s.contains("RTK_BIN=\"${HOME}/.open-island/bin/rtk\""))
        #expect(s.contains("RTK_STATS=\"${HOME}/.open-island/rtk-stats.jsonl\""))
        // Fail-open behavior: missing binary → exit 0.
        #expect(s.contains("if [ ! -x \"$RTK_BIN\" ]; then"))
        #expect(s.contains("exit 0"))
        // [rtk] line capture.
        #expect(s.contains("[rtk]"))
        #expect(s.contains("rtk-stats.jsonl") || s.contains("$RTK_STATS"))
    }

    /// The wrapper must actually run — no syntax errors. Spawn `bash -n`
    /// (parse-only) on the script to catch typos before they ship.
    @Test
    func wrapperScriptParsesCleanlyInBash() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("rtk-wrapper.sh")
        try RTKInstallationManager.wrapperScript().write(to: scriptURL, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-n", scriptURL.path]
        let stderr = Pipe()
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "bash -n failed: \(err)")
    }

    // MARK: - settings.json shape helpers

    @Test
    func installPreToolUseEntryIsIdempotent() {
        var settings: [String: Any] = [:]
        RTKInstallationManager.installPreToolUseEntry(in: &settings, wrapperPath: "/path/to/rtk-wrapper.sh")
        RTKInstallationManager.installPreToolUseEntry(in: &settings, wrapperPath: "/path/to/rtk-wrapper.sh")

        let hooks = settings["hooks"] as? [String: Any]
        let pre = hooks?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.count == 1)
    }

    @Test
    func uninstallPreToolUseEntryRemovesEmptyContainers() {
        var settings: [String: Any] = [:]
        RTKInstallationManager.installPreToolUseEntry(in: &settings, wrapperPath: "/path/to/rtk-wrapper.sh")
        RTKInstallationManager.uninstallPreToolUseEntry(in: &settings, wrapperPath: "/path/to/rtk-wrapper.sh")
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
        RTKInstallationManager.installPreToolUseEntry(in: &settings, wrapperPath: "/path/to/rtk-wrapper.sh")
        RTKInstallationManager.uninstallPreToolUseEntry(in: &settings, wrapperPath: "/path/to/rtk-wrapper.sh")

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
