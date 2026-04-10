import Foundation
import SQLite3

/// Read-only access to Warp's live SQLite state for precision jump targeting.
///
/// This depends on Warp's internal schema and is not a supported Warp API.
/// All query failures degrade silently: callers receive nil/0 and should
/// fall back to whatever non-Warp behavior they had.
public struct WarpSQLiteReader: Sendable {
    public let databasePath: String

    public init(databasePath: String = WarpSQLiteReader.defaultDatabasePath()) {
        self.databasePath = databasePath
    }

    /// Returns the standard on-disk location of Warp's SQLite database for the
    /// stable release channel. Warp stores state inside its Group Container,
    /// not the per-app Application Support, because Warp is sandboxed.
    public static func defaultDatabasePath() -> String {
        NSHomeDirectory()
            + "/Library/Group Containers/2BBY89MBSN.dev.warp"
            + "/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
    }

    /// Resolves the Warp pane UUID hosting a Claude/Codex agent running in `cwd`.
    ///
    /// The query joins `commands` → `blocks` via the `precmd-<session_id>-<n>`
    /// block_id format (Warp records one block per shell prompt), filters to
    /// commands starting with "claude" or "codex" in the given pwd, and takes
    /// the most recent match.
    ///
    /// Returns uppercase hex string (32 chars, no separators) suitable for
    /// comparison against the result of `currentFocusedPaneUUID`. Returns nil
    /// on any error.
    public func lookupPaneUUID(forCwd cwd: String) -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT hex(b.pane_leaf_uuid)
        FROM commands c
        JOIN blocks b ON b.block_id LIKE 'precmd-' || c.session_id || '-%'
        WHERE (c.command LIKE 'claude%' OR c.command LIKE 'codex%')
          AND c.pwd = ?
        ORDER BY c.id DESC
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let cwdCString = cwd.withCString { strdup($0) }
        defer { free(cwdCString) }
        sqlite3_bind_text(stmt, 1, cwdCString, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    /// Resolves the pane UUID of the currently focused pane in the currently
    /// active Warp window. This is what drives the polling loop during a
    /// precision jump.
    ///
    /// Returns uppercase hex string suitable for direct comparison to the
    /// output of `lookupPaneUUID`. Returns nil on any error or if there is
    /// no active window.
    public func currentFocusedPaneUUID() -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT hex(tp.uuid)
        FROM tabs t
        JOIN pane_nodes pn ON pn.tab_id = t.id AND pn.is_leaf = 1
        JOIN terminal_panes tp ON tp.id = pn.id
        WHERE t.window_id = (SELECT active_window_id FROM app LIMIT 1)
        ORDER BY t.id
        LIMIT 1 OFFSET (
            SELECT active_tab_index FROM windows
            WHERE id = (SELECT active_window_id FROM app LIMIT 1)
        );
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    /// Returns the number of tabs in the currently active Warp window.
    /// Used as the upper bound for the keystroke cycle retry loop during
    /// precision jump. Returns 0 on any error.
    public func tabCountInActiveWindow() -> Int {
        guard let db = openReadOnly() else { return 0 }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT COUNT(*) FROM tabs
        WHERE window_id = (SELECT active_window_id FROM app LIMIT 1);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Internal

    private func openReadOnly() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        // Set a short busy timeout so we don't hang if Warp is mid-transaction.
        sqlite3_busy_timeout(db, 60) // ms
        return db
    }
}
