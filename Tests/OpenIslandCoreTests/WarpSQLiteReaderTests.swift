import Foundation
import Testing
import SQLite3
@testable import OpenIslandCore

struct WarpSQLiteReaderTests {
    @Test
    func defaultDatabasePathPointsToWarpGroupContainer() {
        let path = WarpSQLiteReader.defaultDatabasePath()
        #expect(path.hasSuffix("/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"))
        // Path should be absolute and start with the user's home dir.
        #expect(path.hasPrefix(NSHomeDirectory()))
    }

    @Test
    func readerAcceptsExplicitPathOverride() {
        let custom = "/tmp/warp-fixture.sqlite"
        let reader = WarpSQLiteReader(databasePath: custom)
        #expect(reader.databasePath == custom)
    }

    @Test
    func lookupPaneUUIDReturnsUppercaseHexForClaudeInKnownCwd() throws {
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .threeTabsTwoClaudes)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        let uuid = reader.lookupPaneUUID(forCwd: "/Users/u/open-vibe-island")
        #expect(uuid == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
    }

    @Test
    func lookupPaneUUIDReturnsNilForCwdWithoutClaudeCommand() throws {
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .threeTabsTwoClaudes)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        #expect(reader.lookupPaneUUID(forCwd: "/nonexistent") == nil)
    }

    @Test
    func lookupPaneUUIDReturnsNilForMissingDatabaseFile() {
        let reader = WarpSQLiteReader(databasePath: "/nonexistent/path/warp.sqlite")
        #expect(reader.lookupPaneUUID(forCwd: "/any") == nil)
    }

    @Test
    func currentFocusedPaneUUIDReturnsActiveTabsUUID() throws {
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .threeTabsTwoClaudes)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Scenario has active_tab_index = 1 which is tab id 2 (open-vibe-island).
        let reader = WarpSQLiteReader(databasePath: tmp)
        #expect(reader.currentFocusedPaneUUID() == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
    }

    @Test
    func currentFocusedPaneUUIDReturnsNilForMissingDatabase() {
        let reader = WarpSQLiteReader(databasePath: "/nonexistent.sqlite")
        #expect(reader.currentFocusedPaneUUID() == nil)
    }

    @Test
    func tabCountInActiveWindowReturnsCount() throws {
        let tmp = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
        try WarpSQLiteFixture.write(to: tmp, scenario: .threeTabsTwoClaudes)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let reader = WarpSQLiteReader(databasePath: tmp)
        #expect(reader.tabCountInActiveWindow() == 3)
    }

    @Test
    func tabCountInActiveWindowReturnsZeroForMissingDatabase() {
        let reader = WarpSQLiteReader(databasePath: "/nonexistent.sqlite")
        #expect(reader.tabCountInActiveWindow() == 0)
    }
}

// MARK: - Fixture

/// Builds a minimal synthetic warp.sqlite with the exact schema columns the
/// reader queries. Only the queried subset is present; other tables and
/// constraints are omitted intentionally to keep the fixture short.
enum WarpSQLiteFixture {
    static func write(to path: String, scenario: Scenario) throws {
        // Open (create) the file
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "WarpSQLiteFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE app (id INTEGER PRIMARY KEY, active_window_id INTEGER);
        CREATE TABLE windows (id INTEGER PRIMARY KEY, active_tab_index INTEGER NOT NULL);
        CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER NOT NULL);
        CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER NOT NULL, is_leaf BOOLEAN NOT NULL);
        CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY, uuid BLOB NOT NULL, cwd TEXT);
        CREATE TABLE commands (id INTEGER PRIMARY KEY, session_id INTEGER, command TEXT, pwd TEXT);
        CREATE TABLE blocks (id INTEGER PRIMARY KEY, pane_leaf_uuid BLOB, block_id TEXT);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "WarpSQLiteFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "schema failed: \(String(cString: sqlite3_errmsg(db)))"])
        }

        for row in scenario.rows {
            guard sqlite3_exec(db, row, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "WarpSQLiteFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "insert failed: \(String(cString: sqlite3_errmsg(db)))"])
            }
        }
    }

    struct Scenario {
        var rows: [String]

        /// Three tabs in one window. Tab 1 cwd=giftcard (pane uuid AAAA...),
        /// tab 2 cwd=open-vibe-island (pane uuid BBBB...), tab 3 cwd=/tmp (pane uuid CCCC...).
        /// Claude was launched in giftcard from Warp shell session 1001 and in open-vibe-island from 1002.
        static let threeTabsTwoClaudes = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, 1);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 1);", // tab index 1 = second tab (0-based)
            "INSERT INTO tabs (id, window_id) VALUES (1, 1), (2, 1), (3, 1);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES (1, 1, 1), (2, 2, 1), (3, 3, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(1, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', '/Users/u/giftcard')," +
                "(2, x'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', '/Users/u/open-vibe-island')," +
                "(3, x'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC', '/tmp');",
            "INSERT INTO commands (id, session_id, command, pwd) VALUES " +
                "(100, 1001, 'cd giftcard', '/Users/u')," +
                "(101, 1001, 'claude --dangerously-skip-permissions', '/Users/u/giftcard')," +
                "(200, 1002, 'claude --dangerously-skip-permissions', '/Users/u/open-vibe-island');",
            "INSERT INTO blocks (id, pane_leaf_uuid, block_id) VALUES " +
                "(1, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'precmd-1001-1')," +
                "(2, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'precmd-1001-2')," +
                "(3, x'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', 'precmd-1002-1');",
        ])
    }
}
