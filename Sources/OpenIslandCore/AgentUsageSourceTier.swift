import Foundation

/// Trust level of an `AgentUsageSnapshot`'s data source. Used by the
/// UI to decide whether to surface a small "ⓘ unofficial" badge.
///
/// Three tiers correspond to three observable failure modes:
///
///   - `.authoritative`     : we read it from a vendor-blessed
///     surface (Anthropic OAuth via the statusLine hook the user
///     installed; Codex `~/.codex/sessions/rollout-*.jsonl` which
///     OpenAI itself writes). Schema changes here would break the
///     vendor's own product, so we trust the shape.
///   - `.localOwned`        : Open Island wrote the file ourselves
///     (`stats.json`, RTK's history.db that we install + control).
///     Same trust as `.authoritative` for our purposes; kept
///     distinct so the UI can omit the unofficial badge here while
///     still distinguishing from vendor-blessed sources in audits.
///   - `.unofficialReversed`: schema reverse-engineered from a
///     vendor's local data (Cursor's `state.vscdb` SQLite,
///     Copilot's `gh api copilot/internal/user`). The vendor never
///     promised this shape; an upgrade can break us silently.
///     **UI surfaces this with a discreet "ⓘ unofficial" badge +
///     "Reverse-engineered from local data; may break on vendor
///     updates" tooltip.**
public enum AgentUsageSourceTier: String, Sendable, Codable, Hashable, CaseIterable {
    case authoritative
    case localOwned
    case unofficialReversed

    public var isUnofficial: Bool {
        switch self {
        case .authoritative, .localOwned: return false
        case .unofficialReversed: return true
        }
    }
}
