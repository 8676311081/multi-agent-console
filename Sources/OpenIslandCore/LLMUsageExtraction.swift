import CryptoKit
import Foundation

// MARK: - SSE event splitter

/// Single SSE frame after parsing: an optional `event:` name (Anthropic
/// uses these; OpenAI's chat/completions stream doesn't) and the
/// concatenated `data:` payload.
public struct SSEFrame: Sendable, Equatable {
    public let event: String?
    public let data: String
}

/// Stateful byte splitter. Feed any-size chunks via `consume(_:)`, drain
/// completed frames. Handles both `\n\n` and `\r\n\r\n` separators
/// (servers vary).
public struct SSEEventSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func consume(_ data: Data) -> [SSEFrame] {
        buffer.append(data)
        var frames: [SSEFrame] = []
        let lf = Data([0x0A, 0x0A])             // \n\n
        let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        while true {
            let lfRange = buffer.range(of: lf)
            let crlfRange = buffer.range(of: crlf)
            // Pick whichever boundary appears first.
            let separator: Range<Data.Index>?
            switch (lfRange, crlfRange) {
            case let (l?, c?): separator = l.lowerBound < c.lowerBound ? l : c
            case let (l?, nil): separator = l
            case let (nil, c?): separator = c
            case (nil, nil): separator = nil
            }
            guard let sep = separator else { break }
            let frameBytes = buffer.subdata(in: 0..<sep.lowerBound)
            buffer.removeSubrange(0..<sep.upperBound)
            if let frame = Self.parse(frame: frameBytes) {
                frames.append(frame)
            }
        }
        return frames
    }

    static func parse(frame: Data) -> SSEFrame? {
        guard !frame.isEmpty, let text = String(data: frame, encoding: .utf8) else {
            return nil
        }
        var event: String?
        var dataLines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Tolerate stray CR at end of line.
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.hasPrefix(":") {
                continue // SSE comment
            }
            if line.hasPrefix("event:") {
                event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let raw = String(line.dropFirst("data:".count))
                let trimmed = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
                dataLines.append(trimmed)
            }
        }
        if event == nil && dataLines.isEmpty { return nil }
        return SSEFrame(event: event, data: dataLines.joined(separator: "\n"))
    }
}

// MARK: - Anthropic stream

/// Side-effects extracted from a single Anthropic SSE event. The proxy
/// applies these to a per-request running snapshot.
public enum AnthropicStreamEffect: Sendable, Equatable {
    /// `message_start` carries the *initial* usage snapshot — input
    /// tokens (uncached + the two cache classes) and any output tokens
    /// the model has already produced before the stream began (usually
    /// zero, but Anthropic does report it for cached prefills).
    case usageInitial(input: Int, cacheWrite: Int, cacheRead: Int, output: Int)

    /// `message_delta` carries the *cumulative* output_tokens count.
    /// We replace, not add, on each occurrence — the last one wins.
    case usageOutputCumulative(Int)

    /// A tool_use content block has finished streaming. The proxy uses
    /// `(name, hash(input))` to spot the model re-calling the same tool
    /// with the same input within a 5-minute window.
    case toolUseComplete(name: String, inputHash: String)
}

/// Per-request accumulator for Anthropic streaming. Holds partial
/// `input_json_delta` fragments per content-block index until the
/// matching `content_block_stop` event fires.
public struct AnthropicStreamConsumer: Sendable {
    private var toolUses: [Int: ToolUseAccumulator] = [:]

    private struct ToolUseAccumulator: Sendable {
        var name: String
        var partialInput: String
    }

    public init() {}

    public mutating func process(_ frame: SSEFrame) -> [AnthropicStreamEffect] {
        guard let payload = frame.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return [] }
        switch frame.event ?? "" {
        case "message_start":
            guard let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { return [] }
            return [.usageInitial(
                input: usage["input_tokens"] as? Int ?? 0,
                cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0
            )]
        case "message_delta":
            guard let usage = json["usage"] as? [String: Any] else { return [] }
            let output = usage["output_tokens"] as? Int ?? 0
            return [.usageOutputCumulative(output)]
        case "content_block_start":
            guard let index = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any],
                  block["type"] as? String == "tool_use",
                  let name = block["name"] as? String
            else { return [] }
            toolUses[index] = ToolUseAccumulator(name: name, partialInput: "")
            return []
        case "content_block_delta":
            guard let index = json["index"] as? Int,
                  let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "input_json_delta",
                  let partial = delta["partial_json"] as? String
            else { return [] }
            toolUses[index]?.partialInput.append(partial)
            return []
        case "content_block_stop":
            guard let index = json["index"] as? Int,
                  let acc = toolUses.removeValue(forKey: index)
            else { return [] }
            return [.toolUseComplete(
                name: acc.name,
                inputHash: stableSHA256(of: acc.partialInput)
            )]
        default:
            return []
        }
    }
}

// MARK: - Anthropic non-streaming

/// Pull usage and tool_use signatures from a complete non-streaming
/// Anthropic JSON response body.
public enum AnthropicNonStreaming {
    public static func extract(_ body: Data) -> (usage: TokenUsage, toolUses: [(name: String, inputHash: String)])? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        var usage = TokenUsage.zero
        if let u = json["usage"] as? [String: Any] {
            usage.input = u["input_tokens"] as? Int ?? 0
            usage.cacheWrite = u["cache_creation_input_tokens"] as? Int ?? 0
            usage.cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
            usage.output = u["output_tokens"] as? Int ?? 0
        }
        var tools: [(name: String, inputHash: String)] = []
        if let content = json["content"] as? [[String: Any]] {
            for block in content where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String else { continue }
                let input = block["input"].map(jsonStableString) ?? ""
                tools.append((name: name, inputHash: stableSHA256(of: input)))
            }
        }
        return (usage, tools)
    }
}

// MARK: - OpenAI chat/completions

/// Side-effects extracted from a single OpenAI chat/completions stream
/// event. OpenAI streams raw `data: {...}` frames without `event:` names.
public enum OpenAIStreamEffect: Sendable, Equatable {
    /// Final `usage` block — only emitted when the request opted in via
    /// `stream_options.include_usage` (the proxy injects this for us).
    case usageFinal(input: Int, cacheRead: Int, output: Int)
    case toolUseComplete(name: String, inputHash: String)
}

public struct OpenAIStreamConsumer: Sendable {
    private var toolCalls: [Int: ToolCallAccumulator] = [:]

    private struct ToolCallAccumulator: Sendable {
        var name: String?
        var arguments: String
    }

    public init() {}

    public mutating func process(_ frame: SSEFrame) -> [OpenAIStreamEffect] {
        // Stream terminator.
        if frame.data == "[DONE]" {
            return finalize()
        }
        guard let payload = frame.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return [] }

        var effects: [OpenAIStreamEffect] = []

        if let usage = json["usage"] as? [String: Any] {
            let input = usage["prompt_tokens"] as? Int ?? 0
            let output = usage["completion_tokens"] as? Int ?? 0
            let cacheRead = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            effects.append(.usageFinal(input: input, cacheRead: cacheRead, output: output))
        }

        if let choices = json["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any],
                   let calls = delta["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        guard let index = call["index"] as? Int else { continue }
                        var acc = toolCalls[index] ?? ToolCallAccumulator(name: nil, arguments: "")
                        if let function = call["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty {
                                acc.name = name
                            }
                            if let args = function["arguments"] as? String {
                                acc.arguments.append(args)
                            }
                        }
                        toolCalls[index] = acc
                    }
                }
                if let finishReason = choice["finish_reason"] as? String,
                   finishReason == "tool_calls" || finishReason == "stop" {
                    effects.append(contentsOf: finalize())
                }
            }
        }

        return effects
    }

    private mutating func finalize() -> [OpenAIStreamEffect] {
        let drained = toolCalls.values.compactMap { acc -> OpenAIStreamEffect? in
            guard let name = acc.name else { return nil }
            return .toolUseComplete(name: name, inputHash: stableSHA256(of: acc.arguments))
        }
        toolCalls.removeAll()
        return drained
    }
}

// MARK: - OpenAI non-streaming + responses API

public enum OpenAINonStreaming {
    public static func extractChatCompletions(_ body: Data) -> (usage: TokenUsage, toolUses: [(name: String, inputHash: String)])? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        var usage = TokenUsage.zero
        if let u = json["usage"] as? [String: Any] {
            usage.input = u["prompt_tokens"] as? Int ?? 0
            usage.output = u["completion_tokens"] as? Int ?? 0
            if let details = u["prompt_tokens_details"] as? [String: Any] {
                usage.cacheRead = details["cached_tokens"] as? Int ?? 0
            }
        }
        var tools: [(name: String, inputHash: String)] = []
        if let choices = json["choices"] as? [[String: Any]] {
            for choice in choices {
                if let message = choice["message"] as? [String: Any],
                   let calls = message["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        guard let function = call["function"] as? [String: Any],
                              let name = function["name"] as? String
                        else { continue }
                        let args = function["arguments"] as? String ?? ""
                        tools.append((name: name, inputHash: stableSHA256(of: args)))
                    }
                }
            }
        }
        return (usage, tools)
    }

    /// Best-effort extractor for the OpenAI Responses API — both streaming
    /// (look for the `response.completed` event with the `response`
    /// envelope) and non-streaming (the body itself is the envelope).
    public static func extractResponsesEnvelope(_ body: Data) -> TokenUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        // Streaming wrapper: events have a "response" sub-object.
        let envelope = (json["response"] as? [String: Any]) ?? json
        guard let u = envelope["usage"] as? [String: Any] else { return nil }
        var usage = TokenUsage.zero
        usage.input = u["input_tokens"] as? Int ?? 0
        usage.output = u["output_tokens"] as? Int ?? 0
        if let details = u["input_tokens_details"] as? [String: Any] {
            usage.cacheRead = details["cached_tokens"] as? Int ?? 0
        }
        return usage
    }
}

// MARK: - Hashing helpers

func stableSHA256(of string: String) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Serialize a JSON value with sorted keys so the same logical input
/// hashes to the same digest every time.
func jsonStableString(_ value: Any) -> String {
    if let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
    ),
        let s = String(data: data, encoding: .utf8)
    {
        return s
    }
    return String(describing: value)
}
