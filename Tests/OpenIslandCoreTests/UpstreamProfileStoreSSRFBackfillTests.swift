import Testing
import Foundation
@testable import OpenIslandCore

/// C-1 backfill tests. Verifies that already-persisted custom
/// profiles can be scanned against today's SSRF host policy and
/// that the active profile is reset when it points at a now-
/// disallowed host.
@Suite struct UpstreamProfileStoreSSRFBackfillTests {

    private func makeStore() -> UpstreamProfileStore {
        let suiteName = "test.UpstreamProfileStoreSSRFBackfill.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create test UserDefaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return UpstreamProfileStore(userDefaults: defaults)
    }

    private func makeProfile(id: String, host: String) -> UpstreamProfile {
        UpstreamProfile(
            id: id,
            displayName: id,
            baseURL: URL(string: "https://\(host)/v1")!,
            keychainAccount: id,
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
    }

    /// Public-only host policy used for tests.
    private let isHostAllowed: @Sendable (String) -> Bool = { host in
        let privateHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        if privateHosts.contains(host) { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            if octets[0] == 10 { return false }
            if octets[0] == 192, octets[1] == 168 { return false }
            if octets[0] == 169, octets[1] == 254 { return false }
            if octets[0] == 172, (16...31).contains(octets[1]) { return false }
        }
        return true
    }

    @Test
    func scanPartitionsCustomProfilesByHostPolicy() throws {
        let store = makeStore()
        try store.addCustomProfile(makeProfile(id: "good-1", host: "api.buerai.top"))
        try store.addCustomProfile(makeProfile(id: "bad-loopback", host: "127.0.0.1"))
        try store.addCustomProfile(makeProfile(id: "bad-link-local", host: "169.254.169.254"))
        try store.addCustomProfile(makeProfile(id: "good-2", host: "api.example.com"))
        try store.addCustomProfile(makeProfile(id: "bad-private", host: "192.168.1.1"))

        let scan = store.scanCustomProfiles(isHostAllowed: isHostAllowed)

        #expect(Set(scan.allowed) == ["good-1", "good-2"])
        #expect(Set(scan.disallowed) == ["bad-loopback", "bad-link-local", "bad-private"])
    }

    @Test
    func resetActiveDowngradesWhenActiveIsDisallowed() throws {
        let store = makeStore()
        let evil = makeProfile(id: "evil-aws-metadata", host: "169.254.169.254")
        try store.addCustomProfile(evil)
        try store.setActiveProfile("evil-aws-metadata")
        #expect(store.currentActiveProfile().id == "evil-aws-metadata")

        let previouslyActive = store.resetActiveIfInDisallowedList(["evil-aws-metadata"])

        #expect(previouslyActive == "evil-aws-metadata")
        #expect(store.currentActiveProfile().id == UpstreamProfileStore.defaultActiveProfileId)
    }

    @Test
    func resetActiveNoOpWhenActiveIsSafe() throws {
        let store = makeStore()
        try store.addCustomProfile(makeProfile(id: "safe-public", host: "api.example.com"))
        try store.setActiveProfile("safe-public")

        let previouslyActive = store.resetActiveIfInDisallowedList(["some-other-evil-id"])

        #expect(previouslyActive == nil)
        #expect(store.currentActiveProfile().id == "safe-public")
    }

    @Test
    func resetActiveNoOpWhenDisallowedListIsEmpty() throws {
        let store = makeStore()
        try store.addCustomProfile(makeProfile(id: "x", host: "api.example.com"))
        try store.setActiveProfile("x")

        let previouslyActive = store.resetActiveIfInDisallowedList([])

        #expect(previouslyActive == nil)
        #expect(store.currentActiveProfile().id == "x")
    }

    @Test
    func disallowedProfilesArePreservedNotDeleted() throws {
        // The backfill must NOT silently delete user data — it
        // only downgrades active. Disallowed profiles stay in the
        // store so the user can edit them via the routing pane.
        let store = makeStore()
        let evil = makeProfile(id: "evil", host: "10.0.0.1")
        try store.addCustomProfile(evil)
        try store.setActiveProfile("evil")

        _ = store.resetActiveIfInDisallowedList(["evil"])

        // Profile is still there.
        #expect(store.profile(id: "evil") != nil)
        // But not active.
        #expect(store.currentActiveProfile().id != "evil")
    }
}
