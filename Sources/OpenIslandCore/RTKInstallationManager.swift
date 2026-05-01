import CryptoKit
import Darwin
import Foundation

// MARK: - Status

public struct RTKInstallationStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case unsupportedArchitecture
        case notInstalled
        case installedDisabled    // binary on disk, no settings.json hook
        case installedEnabled     // binary + wrapper + settings.json hook
        case needsRepair          // hook present but binary or wrapper missing
    }

    public var state: State
    public var arch: String
    public var rtkVersion: String
    public var binaryURL: URL
    public var wrapperURL: URL
    public var statsJSONLURL: URL
    public var pidFileURL: URL
    public var settingsURL: URL
    public var binaryPresent: Bool
    public var binaryExecutable: Bool
    public var wrapperPresent: Bool
    public var hookConfigured: Bool

    public init(
        state: State,
        arch: String,
        rtkVersion: String,
        binaryURL: URL,
        wrapperURL: URL,
        statsJSONLURL: URL,
        pidFileURL: URL,
        settingsURL: URL,
        binaryPresent: Bool,
        binaryExecutable: Bool,
        wrapperPresent: Bool,
        hookConfigured: Bool
    ) {
        self.state = state
        self.arch = arch
        self.rtkVersion = rtkVersion
        self.binaryURL = binaryURL
        self.wrapperURL = wrapperURL
        self.statsJSONLURL = statsJSONLURL
        self.pidFileURL = pidFileURL
        self.settingsURL = settingsURL
        self.binaryPresent = binaryPresent
        self.binaryExecutable = binaryExecutable
        self.wrapperPresent = wrapperPresent
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
        }
    }
}

// MARK: - Manager

/// Installs RTK (https://github.com/rtk-ai/rtk) as a Claude Code PreToolUse
/// hook. Three artifacts on disk:
///
/// - `~/.open-island/bin/rtk`             — the upstream binary, downloaded
///                                          and SHA256-verified at install
/// - `~/.open-island/bin/rtk-wrapper.sh`  — Open Island wrapper, references
///                                          the binary and tees `[rtk]`
///                                          stderr lines into `rtk-stats.jsonl`
/// - `~/.claude/settings.json`            — gains a PreToolUse hook entry
///                                          pointing at `rtk-wrapper.sh`
///                                          (settings are mutated through
///                                          `ClaudeSettingsBackupHelper`,
///                                          so a timestamped backup lands
///                                          on disk before the rewrite)
///
/// All three are removed on `uninstall()`. The combination of helper-
/// guarded backup + RTK watchdog (rolls back settings if the binary goes
/// missing) means a fresh `~/.claude/settings.json` after uninstall is
/// byte-identical to the snapshot before install.
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
    public static let wrapperFileName = "rtk-wrapper.sh"
    public static let statsFileName = "rtk-stats.jsonl"
    public static let pidFileName = "rtk-watchdog.pid"

    public static let preToolUseMatcher = "Bash"
    public static let supportedArchitecture = "arm64"

    // MARK: Configuration

    public typealias TarballDownloader = @Sendable (URL) async throws -> URL

    public let homeDirectory: URL
    public let openIslandHomeURL: URL
    public let openIslandBinDirURL: URL
    public let claudeDirectory: URL
    public let binaryURL: URL
    public let wrapperURL: URL
    public let statsJSONLURL: URL
    public let pidFileURL: URL
    public let settingsURL: URL

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
        self.wrapperURL = openIslandBinDirURL.appendingPathComponent(Self.wrapperFileName)
        self.statsJSONLURL = openIslandHomeURL.appendingPathComponent(Self.statsFileName)
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
                wrapperURL: wrapperURL,
                statsJSONLURL: statsJSONLURL,
                pidFileURL: pidFileURL,
                settingsURL: settingsURL,
                binaryPresent: false,
                binaryExecutable: false,
                wrapperPresent: false,
                hookConfigured: false
            )
        }

        let binaryPresent = fileManager.fileExists(atPath: binaryURL.path)
        let binaryExecutable = binaryPresent && fileManager.isExecutableFile(atPath: binaryURL.path)
        let wrapperPresent = fileManager.fileExists(atPath: wrapperURL.path)

        let settings = try ClaudeSettingsBackupHelper.currentSettings(
            directory: claudeDirectory,
            fileManager: fileManager
        )
        let hookConfigured = Self.findManagedPreToolUseEntry(in: settings, wrapperPath: wrapperURL.path) != nil

        let state: RTKInstallationStatus.State
        switch (hookConfigured, binaryExecutable, wrapperPresent) {
        case (false, false, false): state = .notInstalled
        case (false, _, _): state = .installedDisabled
        case (true, true, true): state = .installedEnabled
        default: state = .needsRepair
        }

        return RTKInstallationStatus(
            state: state,
            arch: arch,
            rtkVersion: Self.RTK_VERSION,
            binaryURL: binaryURL,
            wrapperURL: wrapperURL,
            statsJSONLURL: statsJSONLURL,
            pidFileURL: pidFileURL,
            settingsURL: settingsURL,
            binaryPresent: binaryPresent,
            binaryExecutable: binaryExecutable,
            wrapperPresent: wrapperPresent,
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

            // 6. Write wrapper script + chmod +x.
            try Self.wrapperScript().write(to: wrapperURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
            rollback.append { [fileManager, wrapperURL] in
                try? fileManager.removeItem(at: wrapperURL)
            }

            // 7. Mutate settings.json (helper guarantees backup before write).
            try ClaudeSettingsBackupHelper.mutateClaudeSettings(
                directory: claudeDirectory,
                fileManager: fileManager
            ) { [wrapperURL] settings in
                Self.installPreToolUseEntry(in: &settings, wrapperPath: wrapperURL.path)
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

    /// Reverse install. Returns the manager to `notInstalled` state and
    /// leaves `~/.claude/settings.json` byte-identical to the pre-install
    /// snapshot (assuming no other tool wrote to it between).
    @discardableResult
    public func uninstall() throws -> RTKInstallationStatus {
        // Remove our PreToolUse hook entry; settings.json is mutated
        // through the helper so a backup of the about-to-be-removed
        // state is always retained.
        let current = try status()
        if current.hookConfigured {
            try ClaudeSettingsBackupHelper.mutateClaudeSettings(
                directory: claudeDirectory,
                fileManager: fileManager
            ) { [wrapperURL] settings in
                Self.uninstallPreToolUseEntry(in: &settings, wrapperPath: wrapperURL.path)
            }
        }

        for url in [wrapperURL, binaryURL, pidFileURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        return try status()
    }

    /// Called by the watchdog when it observes the binary has gone
    /// missing. Removes the orphaned settings.json hook + wrapper but
    /// does *not* try to re-download. Idempotent.
    @discardableResult
    public func handleBinaryLoss() throws -> RTKInstallationStatus {
        let current = try status()
        if current.hookConfigured {
            try ClaudeSettingsBackupHelper.mutateClaudeSettings(
                directory: claudeDirectory,
                fileManager: fileManager
            ) { [wrapperURL] settings in
                Self.uninstallPreToolUseEntry(in: &settings, wrapperPath: wrapperURL.path)
            }
        }
        for url in [wrapperURL, pidFileURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        return try status()
    }

    // MARK: settings.json shape

    /// PreToolUse entry that points at `wrapperPath`. Format mirrors what
    /// Claude Code already accepts elsewhere in the codebase
    /// (matcher + hooks array of {type:"command", command:...}).
    static func managedPreToolUseEntry(wrapperPath: String) -> [String: Any] {
        [
            "matcher": preToolUseMatcher,
            "hooks": [
                [
                    "type": "command",
                    "command": wrapperPath,
                ] as [String: Any]
            ],
        ]
    }

    /// Find an entry in `settings["hooks"]["PreToolUse"]` whose hooks
    /// array contains a command matching `wrapperPath`. Returns its
    /// index in that PreToolUse array, or nil.
    static func findManagedPreToolUseEntry(in settings: [String: Any], wrapperPath: String) -> Int? {
        guard let hooks = settings["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]] else { return nil }
        for (idx, entry) in pre.enumerated() {
            guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
            for h in inner {
                if let cmd = h["command"] as? String, cmd == wrapperPath {
                    return idx
                }
            }
        }
        return nil
    }

    /// Append our PreToolUse entry; idempotent.
    static func installPreToolUseEntry(in settings: inout [String: Any], wrapperPath: String) {
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var pre = (hooks["PreToolUse"] as? [[String: Any]]) ?? []
        if findManagedPreToolUseEntry(in: settings, wrapperPath: wrapperPath) != nil {
            return
        }
        pre.append(managedPreToolUseEntry(wrapperPath: wrapperPath))
        hooks["PreToolUse"] = pre
        settings["hooks"] = hooks
    }

    /// Remove our PreToolUse entry; clean up empty containers so
    /// uninstall produces a settings.json byte-identical to the
    /// pre-install snapshot (when nothing else changed in between).
    static func uninstallPreToolUseEntry(in settings: inout [String: Any], wrapperPath: String) {
        guard var hooks = settings["hooks"] as? [String: Any],
              var pre = hooks["PreToolUse"] as? [[String: Any]] else { return }
        pre.removeAll { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String) == wrapperPath }
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

    // MARK: Wrapper script

    /// Bash wrapper installed alongside the rtk binary. Open Island's
    /// settings.json hook points at *this* — never the binary directly —
    /// so the wrapper can tee `[rtk] origTok→compTok tokens (N% saved)`
    /// stderr lines into `rtk-stats.jsonl` for telemetry pickup, while
    /// keeping rtk's stdout (the actual hook protocol JSON) 100%
    /// transparent. Failure mode is silent: if the binary is gone the
    /// wrapper exits 0 (= "no rewrite, pass through"), so Claude Code
    /// keeps working unchanged.
    public static func wrapperScript() -> String {
        // Bash quirk: the obvious `case "$line" in \[rtk\]*) ... ;; esac`
        // form mis-parses inside `2> >(...)` process substitution
        // (`bash -n` flags `;;` as an unexpected token). Use `[[ ==
        // glob ]]` instead — semantically equivalent and parses cleanly.
        // Sed delimiters are `:` (not the usual `/`) so we don't fight
        // bash escaping of backslash-quote sequences.
        #"""
        #!/bin/bash
        # Open Island RTK wrapper — managed file, do not edit by hand.
        # Stdout (RTK hook protocol JSON) is 100% transparent.
        # Stderr lines starting with "[rtk]" are mirrored to
        # ~/.open-island/rtk-stats.jsonl for telemetry, then forwarded.
        # If the rtk binary is missing, this script exits 0 silently —
        # Claude Code reads that as "PreToolUse approved, no rewrite",
        # so the user's workflow keeps working.
        set -u
        RTK_BIN="${HOME}/.open-island/bin/rtk"
        RTK_STATS="${HOME}/.open-island/rtk-stats.jsonl"
        if [ ! -x "$RTK_BIN" ]; then
            exit 0
        fi
        "$RTK_BIN" "$@" 2> >(
            while IFS= read -r _line; do
                printf '%s\n' "$_line" >&2
                if [[ "$_line" == \[rtk\]* ]]; then
                    _esc=$(printf '%s' "$_line" | /usr/bin/sed -e 's:\\:\\\\:g' -e 's:":\\":g')
                    printf '{"ts":%d,"raw":"%s"}\n' "$(date +%s)" "$_esc" >> "$RTK_STATS" 2>/dev/null
                fi
            done
        )
        """#
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
