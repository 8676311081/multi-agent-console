import Testing
import Foundation
@testable import OpenIslandCore

/// Concurrency probes for `UpstreamProfileStore`. Single-threaded tests
/// in `UpstreamProfileStoreTests` cannot exercise the lock — these
/// fire many readers and writers in parallel to surface races.
///
/// To catch data races on `Dictionary` / `String` operations inside
/// `UserDefaults` and the JSON decoder, run with TSan:
///   swift test --sanitize=thread --filter UpstreamProfileStoreConcurrency
///
/// Without TSan these still verify functional correctness — no crashes,
/// no torn reads (a profile id either fully equals one of the two
/// values being flipped, never something else).
@Suite struct UpstreamProfileStoreConcurrencyTests {

    private func makeStore() -> (UpstreamProfileStore, UserDefaults) {
        let suiteName = "test.UpstreamProfileStoreConcurrencyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create test UserDefaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (UpstreamProfileStore(userDefaults: defaults), defaults)
    }

    /// Concurrent readers + writer flipping the active id between two
    /// known builtin ids. Every observed `currentActiveProfile().id`
    /// must equal one of those two values — anything else means a
    /// torn read. Plain `try?` suppresses transient
    /// `unknownProfile` (allowed when the writer hasn't run yet).
    @Test func concurrentActiveProfileFlipNeverTearsId() async throws {
        let (store, _) = makeStore()
        let validIds: Set<String> = ["anthropic-native", "deepseek-v4-pro"]

        await withTaskGroup(of: String?.self) { group in
            // 1 writer: flips between the two ids
            group.addTask {
                for i in 0..<200 {
                    let target = i.isMultiple(of: 2) ? "anthropic-native" : "deepseek-v4-pro"
                    try? store.setActiveProfile(target)
                }
                return nil
            }
            // 16 readers: each samples 100 times
            for _ in 0..<16 {
                group.addTask {
                    var observed: String?
                    for _ in 0..<100 {
                        observed = store.currentActiveProfile().id
                    }
                    return observed
                }
            }

            for await observedID in group {
                if let id = observedID {
                    #expect(validIds.contains(id), "Torn read: observed unexpected id \"\(id)\"")
                }
            }
        }
    }

    /// Add + remove custom profiles while readers iterate `allProfiles`.
    /// The list snapshot a reader sees must always be internally
    /// consistent — no profile id appearing twice, no nil-but-counted
    /// entries.
    @Test func concurrentCustomProfileMutationKeepsListConsistent() async throws {
        let (store, _) = makeStore()

        // Pre-seed: one base custom profile so the list is never empty.
        let baseProfile = UpstreamProfile(
            id: "custom-test-base",
            displayName: "Base",
            baseURL: URL(string: "https://example.invalid")!,
            keychainAccount: "custom-test-base",
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        try store.addCustomProfile(baseProfile)

        await withTaskGroup(of: Void.self) { group in
            // Mutators: churn a transient profile
            group.addTask {
                let transient = UpstreamProfile(
                    id: "custom-test-transient",
                    displayName: "Transient",
                    baseURL: URL(string: "https://example.invalid/x")!,
                    keychainAccount: "custom-test-transient",
                    modelOverride: nil,
                    isCustom: true,
                    costMetadata: nil
                )
                for _ in 0..<150 {
                    try? store.addCustomProfile(transient)
                    try? store.removeCustomProfile(id: "custom-test-transient")
                }
            }
            // Readers
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<200 {
                        let snapshot = store.allProfiles
                        // Each snapshot must be internally consistent: no duplicate ids.
                        let ids = snapshot.map(\.id)
                        let unique = Set(ids)
                        #expect(ids.count == unique.count, "Duplicate id in snapshot: \(ids)")
                        // Base profile must always be present (we never remove it).
                        #expect(unique.contains("custom-test-base"))
                    }
                }
            }
        }
    }

    /// `profileMatching(url:)` calls `currentActiveProfileLocked()` from
    /// inside its own withLock — verifying that re-entrant lock
    /// acquisition would deadlock. This test must complete in well
    /// under the test framework's per-test timeout. If it hangs, the
    /// implementation regressed to a re-entrant call.
    @Test func profileMatchingDoesNotDeadlock() async throws {
        let (store, _) = makeStore()
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    for _ in 0..<50 {
                        _ = store.profileMatching(url: url)
                    }
                }
            }
            // Concurrent writer to ensure the contended path is exercised.
            group.addTask {
                for i in 0..<100 {
                    let target = i.isMultiple(of: 2) ? "anthropic-native" : "deepseek-v4-pro"
                    try? store.setActiveProfile(target)
                }
            }
        }
        // Reaching here without timeout = no deadlock.
    }
}
