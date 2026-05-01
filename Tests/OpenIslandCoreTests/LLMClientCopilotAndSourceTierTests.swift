import Foundation
import Testing
@testable import OpenIslandCore

struct LLMClientCopilotAndSourceTierTests {
    // MARK: - LLMClient enum extension

    @Test
    func copilotIsACaseAndHasDisplayName() {
        #expect(LLMClient.copilot.rawValue == "copilot")
        #expect(LLMClient.copilot.displayName == "Copilot")
    }

    @Test
    func copilotIsInAllCases() {
        #expect(LLMClient.allCases.contains(.copilot))
    }

    // MARK: - User-Agent matching

    @Test
    func userAgentWithCopilotMapsToCopilotClient() {
        // `gh copilot` and Copilot CLI both surface this kind of UA
        // on outbound HTTP. We don't expect to ever see this in
        // practice (Copilot bypasses our proxy), but the matcher
        // exists so the unusual user who routes Copilot through
        // OPENAI_BASE_URL gets attribution.
        #expect(LLMUsageHeuristics.clientFromUserAgent("GithubCopilot/1.0") == .copilot)
        #expect(LLMUsageHeuristics.clientFromUserAgent("github-copilot/2.5") == .copilot)
        #expect(LLMUsageHeuristics.clientFromUserAgent("Copilot-CLI/0.5") == .copilot)
    }

    @Test
    func userAgentMatchersStillWorkForExistingClients() {
        #expect(LLMUsageHeuristics.clientFromUserAgent("Cursor/0.42") == .cursor)
        #expect(LLMUsageHeuristics.clientFromUserAgent("codex-cli/0.38") == .codex)
        #expect(LLMUsageHeuristics.clientFromUserAgent("claude-cli/2.1.123") == .claudeCode)
        #expect(LLMUsageHeuristics.clientFromUserAgent("anthropic-sdk-python/0.1") == .claudeCode)
        #expect(LLMUsageHeuristics.clientFromUserAgent(nil) == .unknown)
        #expect(LLMUsageHeuristics.clientFromUserAgent("") == .unknown)
        #expect(LLMUsageHeuristics.clientFromUserAgent("totally-foreign-thing/1") == .unknown)
    }

    @Test
    func cursorTakesPrecedenceOverEmbeddedAnthropicSDKUA() {
        // Pre-existing invariant — pin it so the new copilot rule
        // doesn't accidentally reorder the matcher.
        #expect(LLMUsageHeuristics.clientFromUserAgent("Cursor/0.42 anthropic/0.1") == .cursor)
    }

    // MARK: - Codable forward-compat

    @Test
    func legacyStatsJSONWithoutCopilotKeyDecodesCleanly() throws {
        // Simulate stats.json written before this commit existed —
        // outer dict has only `claudeCode` / `codex` / `cursor`
        // keys. Decoding must not throw, and missing copilot is
        // simply absent from the result.
        let legacyJSON = """
        {
          "version": 1,
          "days": {
            "2026-05-01": {
              "claude-code": {"turns": 1, "tokensIn": 100, "tokensOut": 10, "costUsd": 0.001}
            }
          }
        }
        """
        let snap = try JSONDecoder().decode(
            LLMStatsSnapshot.self,
            from: Data(legacyJSON.utf8)
        )
        let bucket = snap.days["2026-05-01"]?["claude-code"]
        #expect(bucket?.turns == 1)
        // Copilot bucket simply isn't present — nil, not error.
        #expect(snap.days["2026-05-01"]?[LLMClient.copilot.rawValue] == nil)
    }

    @Test
    func copilotBucketRoundTripsThroughCodable() throws {
        var snap = LLMStatsSnapshot()
        snap.days["2026-05-02"] = [
            LLMClient.copilot.rawValue: LLMDayBucket(turns: 5, tokensIn: 200, tokensOut: 80)
        ]
        let encoded = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(LLMStatsSnapshot.self, from: encoded)
        #expect(decoded.days["2026-05-02"]?["copilot"]?.tokensIn == 200)
    }

    // MARK: - AgentUsageSourceTier

    @Test
    func sourceTierIsUnofficialFlagMatchesEachCase() {
        #expect(AgentUsageSourceTier.authoritative.isUnofficial == false)
        #expect(AgentUsageSourceTier.localOwned.isUnofficial == false)
        #expect(AgentUsageSourceTier.unofficialReversed.isUnofficial == true)
    }

    @Test
    func sourceTierRoundTripsThroughCodable() throws {
        for tier in AgentUsageSourceTier.allCases {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(AgentUsageSourceTier.self, from: data)
            #expect(decoded == tier)
        }
    }
}
