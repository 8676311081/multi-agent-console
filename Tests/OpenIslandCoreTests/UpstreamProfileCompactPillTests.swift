import Foundation
import Testing
@testable import OpenIslandCore

/// Unit tests for the abbreviation half of the compact-pill chip.
/// Tint color is in the app module (Color is SwiftUI) and is
/// covered by `IslandPanelChipTests` over there.
struct UpstreamProfileCompactPillTests {
    @Test
    func anthropicNativeAbbreviationIsAnt() {
        // Stays "ANT" rather than reflecting Claude CLI's internal
        // /model selection — proxy can't observe that reliably.
        #expect(BuiltinProfiles.anthropicNative.compactPillAbbreviation == "ANT")
    }

    @Test
    func deepseekV4ProAbbreviation() {
        #expect(BuiltinProfiles.deepseekV4Pro.compactPillAbbreviation == "DSV4P")
    }

    @Test
    func deepseekV4FlashAbbreviation() {
        #expect(BuiltinProfiles.deepseekV4Flash.compactPillAbbreviation == "DSV4F")
    }

    @Test
    func customProfileAbbreviationIsLiteralCustom() {
        // Custom profiles (any user-added entry) collapse to the
        // single literal "CUSTOM" so users see a consistent
        // affordance regardless of how they named their profile.
        let custom = UpstreamProfile(
            id: "my-azure-deployment",
            displayName: "k",
            baseURL: URL(string: "https://example.com")!,
            keychainAccount: nil,
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        #expect(custom.compactPillAbbreviation == "CUSTOM")
    }

    @Test
    func unknownNonCustomProfileFallsBackToUppercaseId() {
        // Defensive: a future built-in we haven't switch-cased yet
        // shouldn't crash or render an empty string. Uppercase id
        // is a readable fallback until the table is updated.
        let unknown = UpstreamProfile(
            id: "future-built-in",
            displayName: "k",
            baseURL: URL(string: "https://example.com")!,
            keychainAccount: nil,
            modelOverride: nil,
            isCustom: false,
            costMetadata: nil
        )
        #expect(unknown.compactPillAbbreviation == "FUTURE-BUILT-IN")
    }
}
