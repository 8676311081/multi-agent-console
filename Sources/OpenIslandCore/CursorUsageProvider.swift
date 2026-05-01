// CursorUsageProvider — UNOFFICIAL data source.
//
// Cursor doesn't expose a local usage / quota file. The vendor's
// own UI fetches that from `cursor.com` over an authenticated HTTP
// session we can't reuse. The closest the local SQLite gets is
// stripe membership state, which is enough to show the user "you're
// on the Free / Pro / Business tier" but NOT how many fast/slow
// premium requests they've burned this month.
//
// READ-ONLY contract:
//   We open `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
//   with `SQLITE_OPEN_READONLY`. Never write — Cursor relies on
//   exclusive write semantics for its own auth flow, and even a
//   benign UPDATE here could log the user out.

import Foundation
@_implementationOnly import SQLite3

/// Reads Cursor's stripe membership tier out of the local state DB.
/// `source = .unofficialReversed` — the schema isn't a vendor
/// contract; an upgrade can break us silently. UI surfaces this
/// with the small "ⓘ unofficial" badge.
public struct CursorUsageProvider: AgentUsageProvider {
    public let client: LLMClient = .cursor

    private let dbURL: URL

    public init(dbURL: URL = CursorUsageProvider.defaultDBURL) {
        self.dbURL = dbURL
    }

    /// FileManager.default is documented as thread-safe; we use it
    /// directly rather than storing one (FileManager isn't Sendable).
    private var fileManager: FileManager { .default }

    public static let defaultDBURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("Cursor", isDirectory: true)
        .appendingPathComponent("User", isDirectory: true)
        .appendingPathComponent("globalStorage", isDirectory: true)
        .appendingPathComponent("state.vscdb")

    public func load() async -> AgentUsageSnapshot? {
        guard fileManager.fileExists(atPath: dbURL.path) else { return nil }

        let plan = readStripeMembershipType()
        // Even if we eventually parse `bubbleId%` rows for a
        // turn-count proxy, that lives in `cursorDiskKV` (3000+
        // rows on heavy users) and risks reading stale data — we
        // don't ship that today. Plan label only.
        guard let plan, !plan.isEmpty else { return nil }

        let attrs = try? fileManager.attributesOfItem(atPath: dbURL.path)
        let modified = attrs?[.modificationDate] as? Date

        return AgentUsageSnapshot(
            client: .cursor,
            source: .unofficialReversed,
            windows: [],
            planLabel: Self.normalizePlanLabel(plan),
            capturedAt: modified
        )
    }

    /// SELECT value FROM ItemTable WHERE key='cursorAuth/stripeMembershipType'
    /// Open as read-only. Returns nil for any sqlite error or empty
    /// value — the provider contract treats absence as "no data".
    private func readStripeMembershipType() -> String? {
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, openFlags, nil) == SQLITE_OK,
              let db
        else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key='cursorAuth/stripeMembershipType' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt
        else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        // Cursor stores membership as TEXT but the column type is
        // BLOB; read both ways defensively.
        if let cString = sqlite3_column_text(stmt, 0) {
            return String(cString: cString)
        }
        return nil
    }

    /// Cursor stores raw enum-ish strings ("free", "pro", "business",
    /// "team_member" etc). Capitalize for the UI without inventing
    /// values we haven't seen.
    static func normalizePlanLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return raw }
        // Replace `_` with space and title-case each word.
        let parts = trimmed.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + word.dropFirst()
            }
        return parts.joined(separator: " ")
    }
}
