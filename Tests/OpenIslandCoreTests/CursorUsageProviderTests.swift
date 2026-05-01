import Foundation
import Testing
@_implementationOnly import SQLite3
@testable import OpenIslandCore

struct CursorUsageProviderTests {
    private static func makeFixtureDB(
        membershipType: String?
    ) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-fixture-\(UUID().uuidString).vscdb")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw NSError(domain: "test", code: -1)
        }
        defer { sqlite3_close(db) }

        let create = "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);"
        sqlite3_exec(db, create, nil, nil, nil)
        if let membership = membershipType {
            let escaped = membership.replacingOccurrences(of: "'", with: "''")
            let insert = "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/stripeMembershipType', '\(escaped)');"
            sqlite3_exec(db, insert, nil, nil, nil)
        }
        return url
    }

    // MARK: - Snapshot shape

    @Test
    func providerReturnsNilWhenDatabaseAbsent() async throws {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-cursor-\(UUID().uuidString).vscdb")
        let provider = CursorUsageProvider(dbURL: missing)
        let snap = await provider.load()
        #expect(snap == nil)
    }

    @Test
    func providerReturnsNilWhenMembershipKeyAbsent() async throws {
        let url = try Self.makeFixtureDB(membershipType: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let provider = CursorUsageProvider(dbURL: url)
        let snap = await provider.load()
        #expect(snap == nil)
    }

    @Test
    func providerReadsFreeMembershipAndMarksUnofficial() async throws {
        let url = try Self.makeFixtureDB(membershipType: "free")
        defer { try? FileManager.default.removeItem(at: url) }

        let provider = CursorUsageProvider(dbURL: url)
        let snap = try #require(await provider.load())
        #expect(snap.client == .cursor)
        #expect(snap.source == .unofficialReversed)
        #expect(snap.source.isUnofficial)
        #expect(snap.planLabel == "Free")
        #expect(snap.windows.isEmpty)  // local DB has no quota data
        #expect(!snap.isEmpty)          // planLabel populated → renderable
    }

    @Test
    func providerReadsProMembership() async throws {
        let url = try Self.makeFixtureDB(membershipType: "pro")
        defer { try? FileManager.default.removeItem(at: url) }

        let snap = try #require(await CursorUsageProvider(dbURL: url).load())
        #expect(snap.planLabel == "Pro")
    }

    @Test
    func providerReadsTeamMemberMembership() async throws {
        // Underscore-separated raw value should display as "Team Member"
        // — the normalizer replaces `_` with space and title-cases each
        // word.
        let url = try Self.makeFixtureDB(membershipType: "team_member")
        defer { try? FileManager.default.removeItem(at: url) }

        let snap = try #require(await CursorUsageProvider(dbURL: url).load())
        #expect(snap.planLabel == "Team Member")
    }

    // MARK: - Plan-label normalization

    @Test
    func normalizePlanLabelKeepsRawForUnknownShapes() {
        // Empty / whitespace passthrough — never invent a plan name.
        #expect(CursorUsageProvider.normalizePlanLabel("") == "")
        #expect(CursorUsageProvider.normalizePlanLabel("  ") == "  ")
    }

    @Test
    func normalizePlanLabelTitleCasesAndStripsUnderscores() {
        #expect(CursorUsageProvider.normalizePlanLabel("free") == "Free")
        #expect(CursorUsageProvider.normalizePlanLabel("pro") == "Pro")
        #expect(CursorUsageProvider.normalizePlanLabel("business") == "Business")
        #expect(CursorUsageProvider.normalizePlanLabel("team_member") == "Team Member")
        #expect(CursorUsageProvider.normalizePlanLabel("pro_plus") == "Pro Plus")
    }

    // MARK: - Read-only invariant: opening a fixture DB doesn't
    // mutate it. Equivalent of "we'd never log a Cursor user out".

    @Test
    func providerOpensReadOnlyDoesNotMutateDB() async throws {
        let url = try Self.makeFixtureDB(membershipType: "pro")
        defer { try? FileManager.default.removeItem(at: url) }

        let mtimeBefore = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        // Sleep briefly so any write would shift mtime visibly.
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await CursorUsageProvider(dbURL: url).load()

        let mtimeAfter = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        #expect(mtimeBefore == mtimeAfter)
    }

    // MARK: - Concurrent loads don't deadlock

    @Test
    func concurrentLoadsResolveCorrectly() async throws {
        let url = try Self.makeFixtureDB(membershipType: "pro")
        defer { try? FileManager.default.removeItem(at: url) }

        let provider = CursorUsageProvider(dbURL: url)
        async let s1 = provider.load()
        async let s2 = provider.load()
        async let s3 = provider.load()
        let snaps = await [s1, s2, s3]
        #expect(snaps.compactMap(\.self).count == 3)
        #expect(snaps.compactMap(\.self).allSatisfy { $0.planLabel == "Pro" })
    }
}
