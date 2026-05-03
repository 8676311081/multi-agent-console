import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OpenIslandApp
@testable import OpenIslandCore

/// Coverage for the AppModel-side observable surface that the
/// island-pill chip binds to: profile-id mirror, color mapping,
/// re-render on switch. SwiftUI rendering itself is exercised at
/// UI smoke time.
///
/// AppModel constructs an `LLMProxyCoordinator` which uses
/// `UserDefaults.standard` for the active profile id. Tests that
/// mutate this leak across tests — `defer` resets the key back so
/// the next AppModel sees the canonical default.
private let activeProfileDefaultsKey = "OpenIsland.LLMProxy.activeProfileId"

private func resetActiveProfileToDefault() {
    UserDefaults.standard.removeObject(forKey: activeProfileDefaultsKey)
}

@MainActor
struct IslandPanelChipTests {
    @Test
    func chipColorMapsToProvider() {
        // Each built-in maps to its branded tint. Tests the App-side
        // extension that lives next to IslandPanelView (Color is
        // SwiftUI, can't share with the OpenIslandCore extension).
        #expect(BuiltinProfiles.anthropicNative.compactPillTintColor == .orange)
        #expect(BuiltinProfiles.deepseekV4Pro.compactPillTintColor == .blue)
        // Light-blue Flash variant — exact RGB is implementation
        // detail, but it must be distinct from Pro's plain blue so
        // users can tell them apart at a glance.
        #expect(BuiltinProfiles.deepseekV4Flash.compactPillTintColor != .blue)
        // Custom collapses to gray.
        let custom = UpstreamProfile(
            id: "my-custom",
            displayName: "k",
            baseURL: URL(string: "https://example.com")!,
            keychainAccount: nil,
            modelOverride: nil,
            isCustom: true,
            costMetadata: nil
        )
        #expect(custom.compactPillTintColor == .gray)
    }

    @Test
    func chipReadsActiveProfileFromAppModel() {
        resetActiveProfileToDefault()
        _ = NSApplication.shared
        let model = AppModel()
        // Default state: anthropic-native — the chip should resolve
        // to the matching profile object.
        #expect(model.activeUpstreamProfile.id == "anthropic-native")
        #expect(model.activeUpstreamProfile.compactPillAbbreviation == "ANT")
    }

    @Test
    func chipUpdatesWhenProfileChanges() throws {
        // setActiveUpstreamProfile must update both the store (for
        // proxy hot path) AND the @Observable mirror (for UI
        // redraw). This test focuses on the mirror — the chip would
        // otherwise stay on the old profile after a switch.
        resetActiveProfileToDefault()
        defer { resetActiveProfileToDefault() }
        _ = NSApplication.shared
        let model = AppModel()
        #expect(model.activeUpstreamProfileId == "anthropic-native")

        try model.setActiveUpstreamProfile("deepseek-v4-flash")

        #expect(model.activeUpstreamProfileId == "deepseek-v4-flash")
        #expect(model.activeUpstreamProfile.id == "deepseek-v4-flash")
        #expect(model.activeUpstreamProfile.compactPillAbbreviation == "DSV4F")
    }

    @Test
    func chipTapDeepLinkRoutesToModelRoutingTab() {
        // The chip's onTap is `model.openModelRouting()`. Coverage
        // for the underlying state transition lives here so a future
        // refactor of the chip's tap handler can't accidentally
        // route to `.llmSpend` without the test failing.
        _ = NSApplication.shared
        let model = AppModel()
        #expect(model.selectedSettingsTab == nil)
        model.openModelRouting()
        #expect(model.selectedSettingsTab == .modelRouting)
    }

    @Test
    func setActiveUpstreamProfileToUnknownIdThrowsAndDoesNotMutate() {
        // Defensive: if the store rejects the id (unknown profile),
        // the AppModel mirror must NOT be updated to a dangling
        // value. The store's setActiveProfile already throws; verify
        // we propagate the error and leave the mirror intact.
        resetActiveProfileToDefault()
        _ = NSApplication.shared
        let model = AppModel()
        let originalId = model.activeUpstreamProfileId
        #expect(throws: UpstreamProfileError.self) {
            try model.setActiveUpstreamProfile("definitely-not-a-real-id")
        }
        #expect(model.activeUpstreamProfileId == originalId)
    }
}
