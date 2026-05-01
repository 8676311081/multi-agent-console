import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeSettingsBackupHelperTests {
    private static func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-settings-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeSettings(_ json: [String: Any], to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
        return url
    }

    @Test
    func currentSettingsReturnsEmptyDictWhenFileMissing() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        #expect(result.isEmpty)
    }

    @Test
    func currentSettingsThrowsWhenRootIsNotObject() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("settings.json")
        try Data("[1, 2, 3]".utf8).write(to: url)

        #expect(throws: ClaudeSettingsBackupError.self) {
            _ = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        }
    }

    @Test
    func mutateCreatesFileWithoutBackupWhenAbsent() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let backup = try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { settings in
            settings["theme"] = "light"
        }

        #expect(backup == nil)
        let written = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        #expect(written["theme"] as? String == "light")
        #expect(ClaudeSettingsBackupHelper.listBackups(directory: dir).isEmpty)
    }

    @Test
    func mutateBacksUpExistingFileBeforeRewriting() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = try Self.writeSettings(["theme": "dark"], to: dir)
        let originalBytes = try Data(contentsOf: original)

        let backup = try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { settings in
            settings["theme"] = "light"
        }

        let backupURL = try #require(backup)
        let backupBytes = try Data(contentsOf: backupURL)
        #expect(backupBytes == originalBytes)
        #expect(backupURL.lastPathComponent.hasPrefix("settings.json.backup."))

        let updated = try ClaudeSettingsBackupHelper.currentSettings(directory: dir)
        #expect(updated["theme"] as? String == "light")
    }

    @Test
    func mutateBlockThrowingLeavesOriginalFileButProducesBackup() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try Self.writeSettings(["x": 1], to: dir)
        let originalBytes = try Data(contentsOf: url)

        struct BlockError: Error {}
        do {
            _ = try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { _ in
                throw BlockError()
            }
            Issue.record("expected throw")
        } catch is BlockError {
            // expected
        }

        // settings.json untouched
        #expect(try Data(contentsOf: url) == originalBytes)
        // backup did land (mutate guarantees backup BEFORE block runs)
        #expect(!ClaudeSettingsBackupHelper.listBackups(directory: dir).isEmpty)
    }

    @Test
    func writeOutcomeNoChangeSkipsBackupAndWrite() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try Self.writeSettings(["a": 1], to: dir)
        let originalBytes = try Data(contentsOf: url)

        let backup = try ClaudeSettingsBackupHelper.writeClaudeSettings(directory: dir) { _ in
            .noChange
        }

        #expect(backup == nil)
        #expect(try Data(contentsOf: url) == originalBytes)
        #expect(ClaudeSettingsBackupHelper.listBackups(directory: dir).isEmpty)
    }

    @Test
    func writeOutcomeWriteBackupsAndPersists() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try Self.writeSettings(["a": 1], to: dir)
        let originalBytes = try Data(contentsOf: url)
        let newBytes = Data(#"{"a":2}"#.utf8)

        let backup = try ClaudeSettingsBackupHelper.writeClaudeSettings(directory: dir) { _ in
            .write(newBytes)
        }

        let backupURL = try #require(backup)
        #expect(try Data(contentsOf: backupURL) == originalBytes)
        #expect(try Data(contentsOf: url) == newBytes)
    }

    @Test
    func writeOutcomeDeleteBackupsAndRemoves() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try Self.writeSettings(["a": 1], to: dir)
        let originalBytes = try Data(contentsOf: url)

        let backup = try ClaudeSettingsBackupHelper.writeClaudeSettings(directory: dir) { _ in
            .delete
        }

        let backupURL = try #require(backup)
        #expect(try Data(contentsOf: backupURL) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func listBackupsReturnsNewestFirst() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Three timestamped backup files; lexical descending == chronological newest-first
        let names = [
            "settings.json.backup.2026-01-01T00-00-00Z",
            "settings.json.backup.2026-05-01T20-53-50Z",
            "settings.json.backup.2026-03-15T12-00-00Z",
        ]
        for n in names {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(n))
        }

        let listed = ClaudeSettingsBackupHelper.listBackups(directory: dir)
        #expect(listed.map(\.lastPathComponent) == [
            "settings.json.backup.2026-05-01T20-53-50Z",
            "settings.json.backup.2026-03-15T12-00-00Z",
            "settings.json.backup.2026-01-01T00-00-00Z",
        ])
    }

    @Test
    func restoreLatestBackupCopiesNewestOverSettings() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let originalBytes = Data(#"{"theme":"dark"}"#.utf8)
        let url = dir.appendingPathComponent("settings.json")
        try originalBytes.write(to: url)

        // mutate creates backup, then restore should bring original back byte-identical
        try ClaudeSettingsBackupHelper.mutateClaudeSettings(directory: dir) { settings in
            settings["theme"] = "light"
        }
        try ClaudeSettingsBackupHelper.restoreLatestBackup(directory: dir)

        #expect(try Data(contentsOf: url) == originalBytes)
    }

    @Test
    func restoreLatestBackupThrowsWhenNoBackupExists() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: ClaudeSettingsBackupError.self) {
            try ClaudeSettingsBackupHelper.restoreLatestBackup(directory: dir)
        }
    }
}
