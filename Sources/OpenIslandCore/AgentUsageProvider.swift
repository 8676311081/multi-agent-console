import Foundation

/// One usage period for one client (e.g. "5h", "7d", "monthly"). The
/// provider decides what "100%" means — Anthropic's `used_percentage`,
/// Codex's `used` over `limit`, Cursor's stripe-based monthly slow-
/// premium quota, etc. The UI renders the percentage verbatim and
/// shows `resetsAt` as a relative-time hint.
public struct AgentUsageWindow: Sendable, Equatable, Codable {
    public var label: String
    public var usedPercentage: Double
    public var resetsAt: Date?

    public init(label: String, usedPercentage: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

/// Cross-agent usage shape. Aggregated by the LLM Spend pane in 2.5
/// to render one card per provider that returned a non-nil snapshot.
public struct AgentUsageSnapshot: Sendable, Equatable, Codable {
    public var client: LLMClient
    public var source: AgentUsageSourceTier
    public var windows: [AgentUsageWindow]
    /// Optional plan-tier label (e.g. "Pro", "Pro+", "Business",
    /// "Free"). UI shows it as a small chip next to the client name
    /// when non-nil.
    public var planLabel: String?
    /// When the underlying data was last written. Nil if the
    /// provider can't observe this.
    public var capturedAt: Date?

    public init(
        client: LLMClient,
        source: AgentUsageSourceTier,
        windows: [AgentUsageWindow],
        planLabel: String? = nil,
        capturedAt: Date? = nil
    ) {
        self.client = client
        self.source = source
        self.windows = windows
        self.planLabel = planLabel
        self.capturedAt = capturedAt
    }

    /// `true` when the snapshot has nothing the UI would render —
    /// no windows AND no plan label. A snapshot with only a plan
    /// label (e.g. Cursor reports "Free" but ships no local quota
    /// data) still displays as a card with "quota unavailable",
    /// which is more useful than dropping the agent from the panel
    /// entirely.
    public var isEmpty: Bool { windows.isEmpty && planLabel == nil }
}

/// One per agent. The 2.5 panel asks each provider concurrently;
/// providers must return `nil` for "no data, no error worth
/// surfacing" (file missing, vendor not configured) and a populated
/// `AgentUsageSnapshot` only when there's something for the UI to
/// render.
///
/// Implementations live in their own file (`Cursor…`, `Copilot…`),
/// so the protocol stays a thin shape contract.
public protocol AgentUsageProvider: Sendable {
    var client: LLMClient { get }

    /// Snapshot for the panel. Should not throw — providers are
    /// expected to swallow expected absences (file not present, vendor
    /// unauthenticated) and return `nil`. An exception escaping here
    /// surfaces as "this provider crashed" in the UI.
    func load() async -> AgentUsageSnapshot?
}

// MARK: - Adapters around existing loaders

/// Wraps `ClaudeUsageLoader.load()` (the statusLine hook's
/// rate-limit cache) into the unified `AgentUsageProvider` shape.
/// Marked `.authoritative` because the cache is written from the
/// Anthropic OAuth `/api/oauth/usage` endpoint via the user's
/// Claude Code statusLine hook — vendor-blessed.
public struct ClaudeAgentUsageProvider: AgentUsageProvider {
    public let client: LLMClient = .claudeCode
    public init() {}

    public func load() async -> AgentUsageSnapshot? {
        guard let snap = try? ClaudeUsageLoader.load(), !snap.isEmpty else {
            return nil
        }
        var windows: [AgentUsageWindow] = []
        if let w = snap.fiveHour {
            windows.append(AgentUsageWindow(
                label: "5h",
                usedPercentage: w.usedPercentage,
                resetsAt: w.resetsAt
            ))
        }
        if let w = snap.sevenDay {
            windows.append(AgentUsageWindow(
                label: "7d",
                usedPercentage: w.usedPercentage,
                resetsAt: w.resetsAt
            ))
        }
        guard !windows.isEmpty else { return nil }
        return AgentUsageSnapshot(
            client: .claudeCode,
            source: .authoritative,
            windows: windows,
            capturedAt: snap.cachedAt
        )
    }
}

/// Wraps `CodexUsageLoader.load()` (rollout JSONL parsing) into the
/// unified provider. Marked `.authoritative` because OpenAI's Codex
/// CLI itself writes `~/.codex/sessions/rollout-*.jsonl` — schema
/// changes here would break their own product.
public struct CodexAgentUsageProvider: AgentUsageProvider {
    public let client: LLMClient = .codex
    public init() {}

    public func load() async -> AgentUsageSnapshot? {
        guard let snap = try? CodexUsageLoader.load(), !snap.isEmpty else {
            return nil
        }
        let windows = snap.windows.map { w in
            AgentUsageWindow(
                label: w.label,
                usedPercentage: w.usedPercentage,
                resetsAt: w.resetsAt
            )
        }
        guard !windows.isEmpty else { return nil }
        return AgentUsageSnapshot(
            client: .codex,
            source: .authoritative,
            windows: windows,
            planLabel: snap.planType,
            capturedAt: snap.capturedAt
        )
    }
}
