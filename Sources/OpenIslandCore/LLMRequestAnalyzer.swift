// This file is READ-ONLY analysis of LLM request bodies.
//
// It MUST NOT mutate the body it inspects. Any code path that
// modifies the bytes the proxy forwards belongs in
// `LLMRequestRewriter.swift` (the one place where the proxy is
// allowed to alter request bytes, and only on the
// /v1/chat/completions opt-in path). A future contributor adding
// "rewrite" semantics here is the bug, not the use case.

import Foundation

/// Pulls structural information out of an outbound request body so
/// the observer can reason about wasted tool-schema tokens, declared
/// vs used tools, etc. — without ever changing what the proxy
/// forwards. Pure functions; no I/O.
public enum LLMRequestAnalyzer {
    public struct Declaration: Sendable, Equatable {
        /// Set of tool names declared in the request body's `tools`
        /// array. Empty if the body has no tools or wasn't
        /// JSON-parseable.
        public let toolNames: Set<String>
        /// Per-tool token estimate of the serialized definition
        /// (name + description + input/parameters schema). Used by
        /// the observer to compute unused-tool waste — schemas the
        /// model carried in its prompt budget but never invoked.
        public let estimatedTokensPerTool: [String: Int]

        public init(
            toolNames: Set<String>,
            estimatedTokensPerTool: [String: Int]
        ) {
            self.toolNames = toolNames
            self.estimatedTokensPerTool = estimatedTokensPerTool
        }

        public static let empty = Declaration(toolNames: [], estimatedTokensPerTool: [:])
    }

    /// Parse the `tools` array out of an outbound request body.
    /// Handles both upstream shapes:
    ///
    ///   - Anthropic: `tools: [{ name, description, input_schema }]`
    ///   - OpenAI:    `tools: [{ type: "function",
    ///                           function: { name, description, parameters } }]`
    ///
    /// Tools without a recognizable `name` are skipped (rare, but
    /// would produce nonsense waste numbers if we counted them).
    /// Estimates come from `LLMTokenEstimator` over the serialized
    /// per-tool dict — approximate, never used to bill.
    public static func analyzeDeclaredTools(in body: Data) -> Declaration {
        guard !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let toolsArray = json["tools"] as? [[String: Any]]
        else {
            return .empty
        }

        var names: Set<String> = []
        var estimates: [String: Int] = [:]
        for tool in toolsArray {
            let name: String?
            if let direct = tool["name"] as? String, !direct.isEmpty {
                name = direct
            } else if let fn = tool["function"] as? [String: Any],
                      let nested = fn["name"] as? String, !nested.isEmpty {
                name = nested
            } else {
                name = nil
            }

            guard let resolvedName = name else { continue }
            names.insert(resolvedName)

            // Estimate the tool's contribution to the prompt by
            // serializing the entire entry (name + description +
            // schema). Order-instability of the serialization
            // doesn't matter — token count is shape-insensitive at
            // the resolution we report.
            if let serialized = try? JSONSerialization.data(withJSONObject: tool),
               let str = String(data: serialized, encoding: .utf8) {
                estimates[resolvedName] = LLMTokenEstimator.estimateTokens(str)
            } else {
                estimates[resolvedName] = 0
            }
        }
        return Declaration(
            toolNames: names,
            estimatedTokensPerTool: estimates
        )
    }
}
