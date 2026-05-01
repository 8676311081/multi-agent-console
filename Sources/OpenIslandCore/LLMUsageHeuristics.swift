import Foundation

/// Which agent is talking to the proxy. Identification is User-Agent only;
/// source ports are unstable and never participate. `unknown` is a
/// legitimate bucket — anything we don't positively recognize lands here
/// rather than getting silently mis-attributed.
public enum LLMClient: String, Sendable, Codable, CaseIterable, Hashable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case unknown

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .unknown: "Unknown"
        }
    }
}

public enum LLMUsageHeuristics {
    /// Map a User-Agent string to a known client bucket.
    ///
    /// Order matters — Cursor traffic often layers an Anthropic SDK UA
    /// underneath, so we check Cursor first. Codex CLI's UA may include
    /// "OpenAI" framing, which we treat as Codex when "codex" appears
    /// anywhere in the UA.
    ///
    /// Returns `.unknown` for nil/empty UAs and anything we don't match.
    public static func clientFromUserAgent(_ ua: String?) -> LLMClient {
        guard let raw = ua, !raw.isEmpty else { return .unknown }
        let lower = raw.lowercased()
        if lower.contains("cursor") { return .cursor }
        if lower.contains("codex") { return .codex }
        if lower.contains("claude-cli")
            || lower.contains("claude-code")
            || lower.contains("anthropic") {
            return .claudeCode
        }
        return .unknown
    }
}

/// Best-effort top-level field extraction from a JSON request body. Used
/// to pull the `model` string before forwarding so we know which pricing
/// row applies.
public enum LLMRequestParsing {
    public static func extractModel(from body: Data) -> String? {
        guard !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = json["model"] as? String,
              !model.isEmpty
        else { return nil }
        return model
    }
}
