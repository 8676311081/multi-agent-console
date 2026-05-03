import SwiftUI
import OpenIslandCore

/// `Color` lives in SwiftUI, so the tint extension can't sit beside
/// `compactPillAbbreviation` in `OpenIslandCore`. Same convention as
/// the SettingsTab.iconColor pattern in SettingsView — provider
/// identity → tint mapping kept next to the pill's render code.
extension UpstreamProfile {
    /// Color for the chip background on the compact pill. Provider-
    /// branded so users don't need to read the abbreviation to know
    /// which backend is active at a glance: orange = Anthropic,
    /// blue = DeepSeek (Pro), light blue = DeepSeek (Flash variant),
    /// gray = custom.
    var compactPillTintColor: Color {
        switch id {
        case "anthropic-native":
            return .orange
        case "deepseek-v4-pro":
            return .blue
        case "deepseek-v4-flash":
            // Lighter blue distinguishes Flash from Pro at a glance.
            return Color(red: 0.40, green: 0.70, blue: 1.00)
        default:
            return .gray
        }
    }
}
