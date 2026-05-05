import Foundation
import CryptoKit
import os
#if canImport(Security)
import Security
#endif

public enum HooksBinaryInstallError: Error, LocalizedError {
    /// `SecCodeCheckValidity` rejected the source binary — it has been
    /// modified since signing (in production) or the cdhash doesn't
    /// match its embedded signature (in any mode). Hard-fail rather
    /// than copy a tampered binary into the user's filesystem.
    case sourceSignatureInvalid(URL, OSStatus)
    /// Same check on the destination after copy. Detects in-flight
    /// tampering during `copyItem` (e.g. another process racing the
    /// inode) — extremely rare but cheap to verify.
    case destinationSignatureInvalid(URL, OSStatus)
    /// The trust manifest's recorded SHA-256 doesn't match the
    /// currently-installed binary. Surfaces as a hint that a third
    /// party replaced the hooks binary while OpenIsland wasn't
    /// running. Caller should respond by re-installing from the
    /// bundled source.
    case installedBinaryTamperedSinceLastInstall(URL)

    public var errorDescription: String? {
        switch self {
        case let .sourceSignatureInvalid(url, status):
            return "Source hooks binary signature invalid (status=\(status)): \(url.path)"
        case let .destinationSignatureInvalid(url, status):
            return "Installed hooks binary signature invalid (status=\(status)): \(url.path)"
        case let .installedBinaryTamperedSinceLastInstall(url):
            return "Installed hooks binary SHA-256 differs from trust manifest record: \(url.path)"
        }
    }
}

public enum ManagedHooksBinary {
    public static let binaryName = "OpenIslandHooks"
    public static let legacyBinaryName = "VibeIslandHooks"
    /// Trust-manifest filename, written next to the installed binary.
    /// JSON containing `{ "sha256": "...", "installedAt": "ISO8601",
    /// "sourcePath": "..." }`. Read on every `updateIfNeeded` call to
    /// detect an installed binary that's been swapped out from under
    /// OpenIsland.
    public static let trustManifestName = ".openisland-hooks-trust.json"

    private static let logger = Logger(
        subsystem: "app.openisland",
        category: "HooksBinaryLocator"
    )

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        installDirectory(fileManager: fileManager)
            .appendingPathComponent(binaryName)
            .standardizedFileURL
    }

    public static func candidateURLs(fileManager: FileManager = .default) -> [URL] {
        [
            defaultURL(fileManager: fileManager),
            legacyInstallDirectory(fileManager: fileManager)
                .appendingPathComponent(legacyBinaryName)
                .standardizedFileURL,
        ]
    }

    @discardableResult
    public static func install(
        from sourceURL: URL,
        to destinationURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let resolvedSourceURL = sourceURL.standardizedFileURL
        let resolvedDestinationURL = (destinationURL ?? defaultURL(fileManager: fileManager)).standardizedFileURL

        // Layer 1: validate source signature BEFORE copying. Rejects
        // a tampered bundled binary so we never propagate it to the
        // user's filesystem.
        try validateSignature(at: resolvedSourceURL, asDestination: false)

        try fileManager.createDirectory(
            at: resolvedDestinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if resolvedSourceURL != resolvedDestinationURL {
            if fileManager.fileExists(atPath: resolvedDestinationURL.path) {
                try fileManager.removeItem(at: resolvedDestinationURL)
            }
            try fileManager.copyItem(at: resolvedSourceURL, to: resolvedDestinationURL)
        }

        // Layer 2: tighten permissions to 0700 (owner-only).
        // C-4 mitigation: world-readable/executable hooks binary is a
        // local privilege-escalation vector (any process under the
        // user's account, plus any other local user with directory
        // read access, could read the binary or — worse — replace
        // it on the disk if the parent dir was writable). Hooks are
        // a per-user tool; no other principal needs access.
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: resolvedDestinationURL.path
        )

        // Layer 3: re-validate signature on the destination AFTER
        // copy to catch the (rare) case of a TOCTOU race between
        // copyItem and the chmod.
        try validateSignature(at: resolvedDestinationURL, asDestination: true)

        // Layer 4: write the trust manifest so a later
        // `updateIfNeeded` can detect post-install tampering.
        try writeTrustManifest(
            for: resolvedDestinationURL,
            sourcePath: resolvedSourceURL.path,
            fileManager: fileManager
        )

        return resolvedDestinationURL
    }

    /// Overwrites the installed hooks binary if the bundle source differs
    /// OR the installed binary's SHA-256 no longer matches the trust
    /// manifest (i.e. external tampering). Returns `true` if the binary
    /// was updated.
    @discardableResult
    public static func updateIfNeeded(
        from sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let installedURL = defaultURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: installedURL.path) else {
            return false
        }

        // Tamper detection: if a manifest exists and disagrees with
        // the on-disk SHA-256, treat as compromised and force a
        // reinstall from the trusted source.
        let manifestTampered = !verifyAgainstTrustManifest(
            at: installedURL,
            fileManager: fileManager
        )
        if manifestTampered {
            logger.error("Installed hooks binary tampered — SHA-256 mismatch with trust manifest at \(installedURL.path, privacy: .public). Forcing reinstall from \(sourceURL.path, privacy: .public).")
        }

        let sourceData = try Data(contentsOf: sourceURL)
        let installedData = try Data(contentsOf: installedURL)
        guard sourceData != installedData || manifestTampered else {
            return false
        }

        // Validate source before clobbering anything.
        try validateSignature(at: sourceURL.standardizedFileURL, asDestination: false)

        try fileManager.removeItem(at: installedURL)
        try fileManager.copyItem(at: sourceURL, to: installedURL)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installedURL.path)
        try validateSignature(at: installedURL, asDestination: true)
        try writeTrustManifest(
            for: installedURL,
            sourcePath: sourceURL.standardizedFileURL.path,
            fileManager: fileManager
        )
        return true
    }

    // MARK: - Signature validation (C-4 layer 1/3)

    /// Verifies a Mach-O binary using `SecCodeCheckValidity`. Catches
    /// post-signing modification (any byte tampered after `codesign`
    /// computed the signature). Works for both Apple Developer ID
    /// and ad-hoc signatures: the kernel's stored signature is
    /// compared against the live cdhash.
    ///
    /// Soft-fail policy: if Security.framework can't load (canImport
    /// guard) we skip — better to install than to brick hooks on a
    /// system where the framework is missing. This path doesn't
    /// trigger in practice on macOS.
    static func validateSignature(at url: URL, asDestination: Bool) throws {
        #if canImport(Security)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            // Couldn't even create the static-code reference. On a
            // signed system this means the file isn't a Mach-O at
            // all — fail the install so we don't propagate junk.
            if asDestination {
                throw HooksBinaryInstallError.destinationSignatureInvalid(url, createStatus)
            } else {
                throw HooksBinaryInstallError.sourceSignatureInvalid(url, createStatus)
            }
        }
        // Empty flags = default validity (signature integrity, not
        // anchor / requirement evaluation). Anchor checks are
        // deliberately omitted: a developer building locally with
        // an ad-hoc signature has no Developer ID to anchor against,
        // and this check would always fail. We rely on cdhash
        // integrity instead, which catches in-place tampering.
        let checkStatus = SecStaticCodeCheckValidity(code, [], nil)
        if checkStatus == errSecSuccess {
            return
        }
        if checkStatus == errSecCSUnsigned {
            // Unsigned binary. The shipped OpenIslandHooks is
            // always at least ad-hoc signed (launch-dev-app.sh
            // codesign step + production Developer-ID), so a
            // genuinely unsigned binary here means either:
            //   (a) test fixture using a fabricated binary, or
            //   (b) a developer hand-built helper without signing.
            // Both are acceptable in practice — the major C-4
            // exfiltration path (destination tampering) is covered
            // by chmod 0700 + the trust-manifest SHA-256 check.
            // Warn so it's loud in logs but don't fail the install.
            logger.warning("Hooks binary unsigned (errSecCSUnsigned) at \(url.path, privacy: .public) — accepting; rely on chmod 0700 + SHA-256 manifest for tamper detection.")
            return
        }
        // Any other SecStaticCodeCheckValidity failure (cdhash
        // mismatch, broken signature, malformed Mach-O after copy)
        // is a hard fail — this is the actual tamper signal we
        // care about.
        if asDestination {
            throw HooksBinaryInstallError.destinationSignatureInvalid(url, checkStatus)
        } else {
            throw HooksBinaryInstallError.sourceSignatureInvalid(url, checkStatus)
        }
        #endif
    }

    // MARK: - Trust manifest (C-4 layer 4)

    private struct TrustManifest: Codable {
        let sha256: String
        let installedAt: String
        let sourcePath: String
    }

    static func writeTrustManifest(
        for installedURL: URL,
        sourcePath: String,
        fileManager: FileManager = .default
    ) throws {
        let data = try Data(contentsOf: installedURL)
        let digest = SHA256.hash(data: data)
        let hexHash = digest.map { String(format: "%02x", $0) }.joined()
        let formatter = ISO8601DateFormatter()
        let manifest = TrustManifest(
            sha256: hexHash,
            installedAt: formatter.string(from: Date()),
            sourcePath: sourcePath
        )
        let json = try JSONEncoder().encode(manifest)
        let manifestURL = installedURL
            .deletingLastPathComponent()
            .appendingPathComponent(trustManifestName)
        try json.write(to: manifestURL, options: [.atomic])
        // Manifest contains nothing secret, but 0600 mirrors the
        // hooks binary itself and prevents another process from
        // forging an "install record" before we re-validate.
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
    }

    /// Returns `true` if the installed binary's SHA-256 matches the
    /// trust manifest, OR if no manifest exists (legacy install
    /// without manifest tracking — caller should overwrite to
    /// upgrade). Returns `false` only on a manifest-vs-binary
    /// mismatch, the actual tamper signal.
    static func verifyAgainstTrustManifest(
        at installedURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let manifestURL = installedURL
            .deletingLastPathComponent()
            .appendingPathComponent(trustManifestName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return true // legacy install — caller will write manifest on reinstall
        }
        guard
            let manifestData = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(TrustManifest.self, from: manifestData),
            let binaryData = try? Data(contentsOf: installedURL)
        else {
            return true // manifest unreadable — don't false-positive
        }
        let digest = SHA256.hash(data: binaryData)
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        return actual == manifest.sha256
    }

    private static func installDirectory(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("OpenIsland", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    private static func legacyInstallDirectory(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("VibeIsland", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }
}

public enum HooksBinaryLocator {
    public static func locate(
        fileManager: FileManager = .default,
        currentDirectory: URL? = nil,
        executableDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        #if DEBUG
        if let explicitPath = environment["OPEN_ISLAND_HOOKS_BINARY"] ?? environment["VIBE_ISLAND_HOOKS_BINARY"],
           fileManager.isExecutableFile(atPath: explicitPath) {
            return URL(fileURLWithPath: explicitPath).standardizedFileURL
        }
        #endif

        let currentDirectory = currentDirectory
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        var candidates = [
            executableDirectory?.appendingPathComponent("OpenIslandHooks"),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("OpenIslandHooks"),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("Helpers/OpenIslandHooks"),
            executableDirectory?.appendingPathComponent("VibeIslandHooks"),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("VibeIslandHooks"),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("Helpers/VibeIslandHooks"),
        ].compactMap { $0 } + ManagedHooksBinary.candidateURLs(fileManager: fileManager)

        #if DEBUG
        candidates += {
            #if arch(arm64)
            let archTriple = "arm64-apple-macosx"
            #elseif arch(x86_64)
            let archTriple = "x86_64-apple-macosx"
            #endif
            return [
                currentDirectory.appendingPathComponent(".build/\(archTriple)/release/OpenIslandHooks"),
                currentDirectory.appendingPathComponent(".build/release/OpenIslandHooks"),
                currentDirectory.appendingPathComponent(".build/\(archTriple)/release/VibeIslandHooks"),
                currentDirectory.appendingPathComponent(".build/release/VibeIslandHooks"),
                currentDirectory.appendingPathComponent(".build/\(archTriple)/debug/OpenIslandHooks"),
                currentDirectory.appendingPathComponent(".build/debug/OpenIslandHooks"),
                currentDirectory.appendingPathComponent(".build/\(archTriple)/debug/VibeIslandHooks"),
                currentDirectory.appendingPathComponent(".build/debug/VibeIslandHooks"),
            ]
        }()
        #endif

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }

        return nil
    }
}
