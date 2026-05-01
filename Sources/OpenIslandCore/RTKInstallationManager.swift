import CryptoKit
import Darwin
import Foundation

// MARK: - Status

public struct RTKInstallationStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case unsupportedArchitecture
        case notInstalled
        case installedDisabled    // binary on disk, no settings.json hook
        case installedEnabled     // binary executable + settings.json hook
        case needsRepair          // hook present but binary missing
    }

    public var state: State
    public var arch: String
    public var rtkVersion: String
    public var binaryURL: URL
    public var pidFileURL: URL
    public var settingsURL: URL
    public var binaryPresent: Bool
    public var binaryExecutable: Bool
    public var hookConfigured: Bool

    public init(
        state: State,
        arch: String,
        rtkVersion: String,
        binaryURL: URL,
        pidFileURL: URL,
        settingsURL: URL,
        binaryPresent: Bool,
        binaryExecutable: Bool,
        hookConfigured: Bool
    ) {
        self.state = state
        self.arch = arch
        self.rtkVersion = rtkVersion
        self.binaryURL = binaryURL
        self.pidFileURL = pidFileURL
        self.settingsURL = settingsURL
        self.binaryPresent = binaryPresent
        self.binaryExecutable = binaryExecutable
        self.hookConfigured = hookConfigured
    }
}

// MARK: - Errors

public enum RTKInstallError: LocalizedError, Sendable {
    case unsupportedArchitecture(found: String)
    case downloadFailed(underlying: String)
    case sha256Mismatch(expected: String, actual: String)
    case extractionFailed(reason: String)
    case binaryNotFoundInArchive
    case binaryNotExecutable
    case alreadyInstalled
    case notInstalled
    /// `~/.local/bin/rtk` already exists and is not the symlink we'd
    /// create. We refuse to clobber a user's hand-installed RTK
    /// (Homebrew, cargo, vendored copy, etc.).
    case userLocalBinConflicted(path: String, kind: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedArchitecture(found):
            return "RTK requires Apple Silicon (arm64). This Mac reports \(found)."
        case let .downloadFailed(reason):
            return "Failed to download RTK tarball: \(reason)"
        case let .sha256Mismatch(expected, actual):
            return "RTK tarball SHA256 mismatch. Expected \(expected), got \(actual). Refusing to install."
        case let .extractionFailed(reason):
            return "Failed to extract RTK tarball: \(reason)"
        case .binaryNotFoundInArchive:
            return "RTK tarball did not contain an `rtk` binary."
        case .binaryNotExecutable:
            return "RTK binary was installed but is not executable."
        case .alreadyInstalled:
            return "RTK is already installed."
        case .notInstalled:
            return "RTK is not installed."
        case let .userLocalBinConflicted(path, kind):
            return "Refusing to overwrite \(path) (\(kind)). Remove it manually, or pin RTK at that location yourself."
        }
    }
}

// MARK: - Manager

/// Installs RTK (https://github.com/rtk-ai/rtk) as a Claude Code PreToolUse
/// hook. Three artifacts on disk:
///
/// - `~/.open-island/bin/rtk`   — the upstream binary, downloaded and
///                                SHA256-verified at install time
/// - `~/.local/bin/rtk`         — symlink → `~/.open-island/bin/rtk`.
///                                Required because `rtk hook claude`
///                                rewrites Bash commands to bare
///                                `rtk <subcommand>` (relative; no
///                                env override exposes a binary path),
///                                and Claude Code spawns the rewritten
///                                string via `$PATH` lookup. See the
///                                symlink step in `install()`.
/// - `~/.claude/settings.json`  — gains a PreToolUse hook entry whose
///                                command is `<bin> hook claude` (RTK's
///                                stdin/stdout PreToolUse handler).
///                                settings are mutated through
///                                `ClaudeSettingsBackupHelper` so a
///                                timestamped backup lands on disk
///                                before the rewrite.
///
/// Telemetry is read from RTK's own SQLite store via `rtk gain --format
/// json` in a separate poller; this manager is install/uninstall only.
///
/// All three are reversed on `uninstall()` (symlink only if it still
/// points at our binary — an alien target means the user repointed it
/// manually and we leave it alone). The combination of helper-guarded
/// backup + RTK watchdog (rolls back settings if the binary goes
/// missing) means a fresh `~/.claude/settings.json` after uninstall is
/// JSON-equivalent to the snapshot before install.
public final class RTKInstallationManager: @unchecked Sendable {

    // MARK: Pinned version + checksum

    /// Pinned RTK release. When upgrading:
    ///   1. Bump `RTK_VERSION` below
    ///   2. Download the new tarball:
    ///        curl -L -o /tmp/rtk.tar.gz \
    ///          https://github.com/rtk-ai/rtk/releases/download/v<VERSION>/rtk-aarch64-apple-darwin.tar.gz
    ///   3. Compute SHA256: `shasum -a 256 /tmp/rtk.tar.gz`
    ///   4. Cross-check against `checksums.txt` in the same release
    ///   5. Update `EXPECTED_RTK_TARBALL_SHA256` below
    ///   6. Update the `Verified` line below with the UTC timestamp of
    ///      step 3-4 and the verifier's identity
    ///   7. Commit version + hash + verified-line as one atomic change
    public static let RTK_VERSION = "0.38.0"

    /// SHA256 of `rtk-aarch64-apple-darwin.tar.gz` from RTK v0.38.0
    /// Source: https://github.com/rtk-ai/rtk/releases/download/v0.38.0/checksums.txt
    /// Verified: 2026-05-01T13:21Z by qwen via local install (Open Island worktree local/integrated)
    public static let EXPECTED_RTK_TARBALL_SHA256 =
        "3896c8c43d02641ddaad88e91a9569233f35e4e938a3bf7882656dc73928f97a"

    public static func tarballURL(version: String = RTK_VERSION) -> URL {
        URL(string: "https://github.com/rtk-ai/rtk/releases/download/v\(version)/rtk-aarch64-apple-darwin.tar.gz")!
    }

    // MARK: File names

    public static let binaryFileName = "rtk"
    public static let pidFileName = "rtk-watchdog.pid"

    /// Legacy wrapper file written by pre-fix versions of the installer.
    /// Removed on uninstall when present so an upgrade-then-uninstall
    /// cycle leaves no orphans behind.
    public static let legacyWrapperFileName = "rtk-wrapper.sh"

    /// Legacy telemetry file written by pre-fix wrapper. Removed on
    /// uninstall when present (and never created by the post-fix path).
    public static let legacyStatsJSONLFileName = "rtk-stats.jsonl"

    public static let preToolUseMatcher = "Bash"
    public static let supportedArchitecture = "arm64"

    /// The RTK subcommand string we register as Claude Code's
    /// PreToolUse hook command. Claude Code shell-parses the
    /// `command` field (verified: existing hook entries in
    /// `settings.json` use space-separated args, and the Claude
    /// Code binary contains `Bun.spawnSync` against `/bin/sh`),
    /// so passing `<binary> hook claude` as a single string works
    /// without any wrapper script in between.
    public static let hookSubcommand = "hook claude"

    // MARK: Configuration

    public typealias TarballDownloader = @Sendable (URL) async throws -> URL

    public let homeDirectory: URL
    public let openIslandHomeURL: URL
    public let openIslandBinDirURL: URL
    public let claudeDirectory: URL
    public let binaryURL: URL
    public let pidFileURL: URL
    public let settingsURL: URL

    /// `~/.local/bin/` — already on the user's `$PATH` via the standard
    /// XDG-style zsh setup. We drop a symlink named `rtk` here so the
    /// rewritten command (`rtk git status`, etc.) emitted by
    /// `rtk hook claude` resolves when Claude Code spawns it. See the
    /// install path's symlink step for the conflict-handling story.
    public let userLocalBinDirURL: URL
    public let userLocalBinSymlinkURL: URL

    /// `~/.open-island/bin/rtk-wrapper.sh` — only present on machines
    /// upgrading from the pre-fix installer; removed on uninstall.
    public let legacyWrapperURL: URL

    /// `~/.open-island/rtk-stats.jsonl` — only present on machines
    /// upgrading from the pre-fix wrapper; removed on uninstall.
    public let legacyStatsJSONLURL: URL

    /// The exact string we register as Claude Code's PreToolUse hook
    /// `command`. Claude Code shell-parses this, so the result is the
    /// equivalent of `bash -c '<binaryURL.path> hook claude'`.
    public var hookCommand: String {
        "\(binaryURL.path) \(Self.hookSubcommand)"
    }

    private let fileManager: FileManager
    private let archProvider: @Sendable () -> String
    private let downloader: TarballDownloader
    private let expectedTarballSHA256: String

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        claudeDirectory: URL = ClaudeConfigDirectory.resolved(),
        fileManager: FileManager = .default,
        archProvider: @escaping @Sendable () -> String = RTKInstallationManager.currentArch,
        downloader: TarballDownloader? = nil,
        expectedTarballSHA256: String = RTKInstallationManager.EXPECTED_RTK_TARBALL_SHA256
    ) {
        self.homeDirectory = homeDirectory
        self.openIslandHomeURL = homeDirectory.appendingPathComponent(".open-island", isDirectory: true)
        self.openIslandBinDirURL = openIslandHomeURL.appendingPathComponent("bin", isDirectory: true)
        self.claudeDirectory = claudeDirectory
        self.binaryURL = openIslandBinDirURL.appendingPathComponent(Self.binaryFileName)
        self.userLocalBinDirURL = homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        self.userLocalBinSymlinkURL = userLocalBinDirURL.appendingPathComponent(Self.binaryFileName)
        self.legacyWrapperURL = openIslandBinDirURL.appendingPathComponent(Self.legacyWrapperFileName)
        self.legacyStatsJSONLURL = openIslandHomeURL.appendingPathComponent(Self.legacyStatsJSONLFileName)
        self.pidFileURL = openIslandHomeURL.appendingPathComponent(Self.pidFileName)
        self.settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        self.fileManager = fileManager
        self.archProvider = archProvider
        self.downloader = downloader ?? Self.urlSessionDownloader
        self.expectedTarballSHA256 = expectedTarballSHA256
    }

    // MARK: Status

    public func status() throws -> RTKInstallationStatus {
        let arch = archProvider()
        if arch != Self.supportedArchitecture {
            return RTKInstallationStatus(
                state: .unsupportedArchitecture,
                arch: arch,
                rtkVersion: Self.RTK_VERSION,
                binaryURL: binaryURL,
                pidFileURL: pidFileURL,
                settingsURL: settingsURL,
                binaryPresent: false,
                binaryExecutable: false,
                hookConfigured: false
            )
        }

        let binaryPresent = fileManager.fileExists(atPath: binaryURL.path)
        let binaryExecutable = binaryPresent && fileManager.isExecutableFile(atPath: binaryURL.path)

        let settings = try ClaudeSettingsBackupHelper.currentSettings(
            directory: claudeDirectory,
            fileManager: fileManager
        )
        let hookConfigured = Self.findManagedPreToolUseEntry(in: settings, hookCommand: hookCommand) != nil

        let state: RTKInstallationStatus.State
        switch (hookConfigured, binaryExecutable) {
        case (false, false): state = .notInstalled
        case (false, true): state = .installedDisabled
        case (true, true): state = .installedEnabled
        case (true, false): state = .needsRepair
        }

        return RTKInstallationStatus(
            state: state,
            arch: arch,
            rtkVersion: Self.RTK_VERSION,
            binaryURL: binaryURL,
            pidFileURL: pidFileURL,
            settingsURL: settingsURL,
            binaryPresent: binaryPresent,
            binaryExecutable: binaryExecutable,
            hookConfigured: hookConfigured
        )
    }

    // MARK: Install / uninstall

    /// Download + verify + install + register hook. Any step's failure
    /// rolls back filesystem changes performed in earlier steps.
    @discardableResult
    public func install() async throws -> RTKInstallationStatus {
        let arch = archProvider()
        guard arch == Self.supportedArchitecture else {
            throw RTKInstallError.unsupportedArchitecture(found: arch)
        }

        let current = try status()
        if current.state == .installedEnabled {
            throw RTKInstallError.alreadyInstalled
        }

        try fileManager.createDirectory(at: openIslandHomeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: openIslandBinDirURL, withIntermediateDirectories: true)

        // Track everything we put on disk so we can roll back atomically.
        var rollback: [() -> Void] = []
        func rollbackAll() { rollback.reversed().forEach { $0() } }

        do {
            // 1. Download tarball to a temp location.
            let tarball: URL
            do {
                tarball = try await downloader(Self.tarballURL())
            } catch {
                throw RTKInstallError.downloadFailed(underlying: "\(error)")
            }
            rollback.append { [fileManager] in try? fileManager.removeItem(at: tarball) }

            // 2. SHA256 verify.
            let actualHash = try Self.sha256(of: tarball)
            guard actualHash == expectedTarballSHA256 else {
                throw RTKInstallError.sha256Mismatch(
                    expected: expectedTarballSHA256,
                    actual: actualHash
                )
            }

            // 3. Extract to a temp dir.
            let extractDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rtk-extract-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
            rollback.append { [fileManager] in try? fileManager.removeItem(at: extractDir) }
            try Self.runTar(tarball: tarball, extractDir: extractDir)

            // 4. Find the rtk binary in the extracted tree.
            let extractedBinary = extractDir.appendingPathComponent(Self.binaryFileName)
            guard fileManager.fileExists(atPath: extractedBinary.path) else {
                throw RTKInstallError.binaryNotFoundInArchive
            }

            // 5. Move binary to ~/.open-island/bin/rtk + chmod +x.
            if fileManager.fileExists(atPath: binaryURL.path) {
                try fileManager.removeItem(at: binaryURL)
            }
            try fileManager.moveItem(at: extractedBinary, to: binaryURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
            rollback.append { [fileManager, binaryURL] in
                try? fileManager.removeItem(at: binaryURL)
            }

            guard fileManager.isExecutableFile(atPath: binaryURL.path) else {
                throw RTKInstallError.binaryNotExecutable
            }

            // 6. Symlink ~/.local/bin/rtk → binaryURL.
            //
            // WHY this is needed at all (the part future maintainers
            // are going to wonder about):
            //
            // `rtk hook claude` accepts the Claude Code PreToolUse
            // payload on stdin and emits a hook-protocol JSON whose
            // `updatedInput.command` is a *relative* `rtk <sub>` string
            // (e.g. `rtk git status`). Claude Code then spawns that
            // rewritten command via `$PATH` lookup. RTK 0.38.0 exposes
            // no env var (`RTK_BIN`/`RTK_PATH`/etc.) to override this
            // — verified by stringifying the binary — so simply pinning
            // the hook entry at our absolute path doesn't help: the
            // *rewritten* command still needs `rtk` discoverable on
            // PATH. Our install dir `~/.open-island/bin/` isn't on the
            // default PATH, but `~/.local/bin/` is (zsh standard via
            // `.zshrc` / `.zprofile`), so a symlink there closes the
            // loop without us touching PATH or shell rc files.
            try fileManager.createDirectory(at: userLocalBinDirURL, withIntermediateDirectories: true)
            try installUserLocalBinSymlink()
            rollback.append { [self] in
                try? self.removeUserLocalBinSymlinkIfOurs()
            }

            // 7. Mutate settings.json (helper guarantees backup before
            // write). The hook command is `<bin> hook claude` — Claude
            // Code shell-parses the field, so no wrapper script is
            // needed.
            let cmd = hookCommand
            try ClaudeSettingsBackupHelper.mutateClaudeSettings(
                directory: claudeDirectory,
                fileManager: fileManager
            ) { settings in
                Self.installPreToolUseEntry(in: &settings, hookCommand: cmd)
            }
            // settings.json rollback uses the most recent backup file.
            rollback.append { [claudeDirectory, fileManager] in
                try? ClaudeSettingsBackupHelper.restoreLatestBackup(
                    directory: claudeDirectory,
                    fileManager: fileManager
                )
            }
        } catch {
            rollbackAll()
            throw error
        }

        return try status()
    }

    /// Three-state symlink reconciliation:
    /// - Path doesn't exist                          → create symlink
    /// - Path is a symlink to our binary             → no-op (idempotent)
    /// - Anything else (regular file, alien symlink) → throw
    ///   `userLocalBinConflicted` so the UI can surface the conflict
    ///   verbatim instead of silently overwriting a user-installed
    ///   `rtk` (Homebrew, cargo, vendored copy).
    private func installUserLocalBinSymlink() throws {
        let path = userLocalBinSymlinkURL.path
        let target = binaryURL.path

        if let existing = inspectUserLocalBinSymlink() {
            switch existing {
            case .ours:
                return  // already correct
            case let .alienSymlink(dest):
                throw RTKInstallError.userLocalBinConflicted(
                    path: path,
                    kind: "symlink → \(dest)"
                )
            case .brokenSymlink:
                throw RTKInstallError.userLocalBinConflicted(
                    path: path,
                    kind: "broken symlink"
                )
            case .regularFile:
                throw RTKInstallError.userLocalBinConflicted(
                    path: path,
                    kind: "regular file"
                )
            case .other:
                throw RTKInstallError.userLocalBinConflicted(
                    path: path,
                    kind: "non-symlink path"
                )
            }
        }

        try fileManager.createSymbolicLink(
            atPath: path,
            withDestinationPath: target
        )
    }

    /// Remove the symlink only if it still points at our binary. A
    /// user who hand-edited it (`ln -sf /elsewhere/rtk ~/.local/bin/rtk`)
    /// wins — we leave their override intact.
    private func removeUserLocalBinSymlinkIfOurs() throws {
        if case .ours = inspectUserLocalBinSymlink() {
            try fileManager.removeItem(at: userLocalBinSymlinkURL)
        }
    }

    private enum UserLocalBinSymlinkState {
        case ours              // symlink → our binaryURL.path
        case alienSymlink(destination: String)
        case brokenSymlink
        case regularFile
        case other
    }

    private func inspectUserLocalBinSymlink() -> UserLocalBinSymlinkState? {
        let path = userLocalBinSymlinkURL.path
        // Use lstat-style attribute lookup so we see the symlink itself,
        // not whatever it points to.
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else {
            return nil  // doesn't exist
        }
        let type = attrs[.type] as? FileAttributeType
        switch type {
        case .typeSymbolicLink:
            guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
                return .brokenSymlink
            }
            return dest == binaryURL.path ? .ours : .alienSymlink(destination: dest)
        case .typeRegular:
            return .regularFile
        default:
            return .other
        }
    }

    /// Reverse install. Returns the manager to `notInstalled` state and
    /// leaves `~/.claude/settings.json` JSON-equivalent to the
    /// pre-install snapshot (assuming no other tool wrote to it
    /// between). Also removes any leftover artifacts from the pre-fix
    /// installer (legacy wrapper script + jsonl).
    @discardableResult
    public func uninstall() throws -> RTKInstallationStatus {
        // Remove our PreToolUse hook entry; settings.json is mutated
        // through the helper so a backup of the about-to-be-removed
        // state is always retained. We also try to clean any
        // old-style hook entries that pointed at the legacy wrapper,
        // so an upgrade-then-uninstall cycle is fully clean.
        let current = try status()
        let cmd = hookCommand
        let legacyCmd = legacyWrapperURL.path
        let snapshot = try ClaudeSettingsBackupHelper.currentSettings(
            directory: claudeDirectory,
            fileManager: fileManager
        )
        let hasLegacyHook = Self.findManagedPreToolUseEntry(
            in: snapshot,
            hookCommand: legacyCmd
        ) != nil
        if current.hookConfigured || hasLegacyHook {
            try ClaudeSettingsBackupHelper.mutateClaudeSettings(
                directory: claudeDirectory,
                fileManager: fileManager
            ) { settings in
                Self.uninstallPreToolUseEntry(in: &settings, hookCommand: cmd)
                Self.uninstallPreToolUseEntry(in: &settings, hookCommand: legacyCmd)
            }
        }

        // Symlink first (only if still ours), then artifacts. Order
        // matters: removing the binary first would make the symlink
        // dangling, which `inspectUserLocalBinSymlink` reads as
        // `brokenSymlink` — and `removeUserLocalBinSymlinkIfOurs`
        // matches against `.ours` only. Keeping the binary on disk
        // until after we've validated the symlink keeps the check
        // unambiguous.
        try removeUserLocalBinSymlinkIfOurs()
        for url in [
            binaryURL,
            pidFileURL,
            legacyWrapperURL,
            legacyStatsJSONLURL,
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        return try status()
    }

    /// Called by the watchdog when it observes the binary has gone
    /// missing. Removes the orphaned settings.json hook entry + any
    /// leftover legacy artifacts but does *not* try to re-download.
    /// Idempotent.
    @discardableResult
    public func handleBinaryLoss() throws -> RTKInstallationStatus {
        let current = try status()
        let cmd = hookCommand
        let legacyCmd = legacyWrapperURL.path
        let snapshot = try ClaudeSettingsBackupHelper.currentSettings(
            directory: claudeDirectory,
            fileManager: fileManager
        )
        let hasLegacyHook = Self.findManagedPreToolUseEntry(
            in: snapshot,
            hookCommand: legacyCmd
        ) != nil
        if current.hookConfigured || hasLegacyHook {
            try ClaudeSettingsBackupHelper.mutateClaudeSettings(
                directory: claudeDirectory,
                fileManager: fileManager
            ) { settings in
                Self.uninstallPreToolUseEntry(in: &settings, hookCommand: cmd)
                Self.uninstallPreToolUseEntry(in: &settings, hookCommand: legacyCmd)
            }
        }
        // Binary is already gone, so a still-existing `~/.local/bin/rtk`
        // symlink pointing at it is dangling — strip it if it's still
        // ours (an alien override wins, same as in uninstall).
        try? removeDanglingUserLocalBinSymlinkIfOurs()
        for url in [pidFileURL, legacyWrapperURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        return try status()
    }

    /// Variant of `removeUserLocalBinSymlinkIfOurs` for the
    /// binary-loss path: the binary is already gone, so the symlink
    /// is necessarily dangling. We still match on `destinationOfSymbolicLink`
    /// pointing at our `binaryURL.path` (the *target* string survives
    /// the binary's deletion) before we touch it.
    private func removeDanglingUserLocalBinSymlinkIfOurs() throws {
        let path = userLocalBinSymlinkURL.path
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
              let dest = try? fileManager.destinationOfSymbolicLink(atPath: path),
              dest == binaryURL.path
        else { return }
        try fileManager.removeItem(at: userLocalBinSymlinkURL)
    }

    // MARK: settings.json shape

    /// PreToolUse entry whose `command` is the literal string passed
    /// in `hookCommand` (e.g. `<bin>/rtk hook claude`). Format mirrors
    /// what Claude Code already accepts elsewhere in the codebase
    /// (matcher + hooks array of {type:"command", command:...}).
    static func managedPreToolUseEntry(hookCommand: String) -> [String: Any] {
        [
            "matcher": preToolUseMatcher,
            "hooks": [
                [
                    "type": "command",
                    "command": hookCommand,
                ] as [String: Any]
            ],
        ]
    }

    /// Find an entry in `settings["hooks"]["PreToolUse"]` whose hooks
    /// array contains a command exactly matching `hookCommand`.
    /// Returns its index in that PreToolUse array, or nil.
    static func findManagedPreToolUseEntry(in settings: [String: Any], hookCommand: String) -> Int? {
        guard let hooks = settings["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]] else { return nil }
        for (idx, entry) in pre.enumerated() {
            guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
            for h in inner {
                if let cmd = h["command"] as? String, cmd == hookCommand {
                    return idx
                }
            }
        }
        return nil
    }

    /// Append our PreToolUse entry; idempotent.
    static func installPreToolUseEntry(in settings: inout [String: Any], hookCommand: String) {
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var pre = (hooks["PreToolUse"] as? [[String: Any]]) ?? []
        if findManagedPreToolUseEntry(in: settings, hookCommand: hookCommand) != nil {
            return
        }
        pre.append(managedPreToolUseEntry(hookCommand: hookCommand))
        hooks["PreToolUse"] = pre
        settings["hooks"] = hooks
    }

    /// Remove our PreToolUse entry; clean up empty containers so
    /// uninstall produces a settings.json that is JSON-equivalent to
    /// the pre-install snapshot (when nothing else changed in between).
    static func uninstallPreToolUseEntry(in settings: inout [String: Any], hookCommand: String) {
        guard var hooks = settings["hooks"] as? [String: Any],
              var pre = hooks["PreToolUse"] as? [[String: Any]] else { return }
        pre.removeAll { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String) == hookCommand }
        }
        if pre.isEmpty {
            hooks.removeValue(forKey: "PreToolUse")
        } else {
            hooks["PreToolUse"] = pre
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
    }

    // MARK: Architecture detection

    /// Runtime CPU architecture as reported by `sysctlbyname("hw.machine")`.
    /// "arm64" on Apple Silicon, "x86_64" on Intel, "arm64e" on ARM64e
    /// kernels (treated as unsupported here — RTK ships arm64 not arm64e
    /// asset).
    public static func currentArch() -> String {
        var size: size_t = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        // Drop the trailing NUL before decoding.
        if let zero = buf.firstIndex(of: 0) { buf = Array(buf[..<zero]) }
        return String(decoding: buf, as: UTF8.self)
    }

    // MARK: SHA256

    /// Streamed SHA256 over `url` so we don't hold a 4 MB tarball in RAM
    /// just for hashing. Returns lowercase hex string.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.availableData
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Tar extraction

    private static func runTar(tarball: URL, extractDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarball.path, "-C", extractDir.path]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw RTKInstallError.extractionFailed(reason: "spawn /usr/bin/tar: \(error)")
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw RTKInstallError.extractionFailed(reason: "tar exit \(process.terminationStatus): \(errOutput)")
        }
    }

    // MARK: Default downloader

    @Sendable
    private static func urlSessionDownloader(_ url: URL) async throws -> URL {
        // URLSession.download honors GitHub's release-asset 302 redirect.
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw RTKInstallError.downloadFailed(underlying: "HTTP \(http.statusCode)")
        }
        return tmp
    }
}
