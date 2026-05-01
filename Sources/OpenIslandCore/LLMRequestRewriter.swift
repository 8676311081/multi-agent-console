import Foundation

/// THE ONE PERMITTED BODY MUTATION.
///
/// The proxy is otherwise an opaque forwarder — bodies pass through
/// verbatim. This file is the single sanctioned exception, and it is
/// scoped tightly: only OpenAI's `/v1/chat/completions`, only when the
/// request asked for streaming, only when the client did not already
/// state a preference about `stream_options.include_usage`.
///
/// **Why** the exception exists: OpenAI's chat/completions streaming
/// endpoint omits the final `usage` block unless the request opted in
/// via `stream_options: {include_usage: true}`. Codex CLI's recent
/// versions opt in by default; older clients and ad-hoc tools may not.
/// Without this hint we cannot keep token stats honest, so we add it.
///
/// **What** we do not touch: the request stays bit-for-bit identical
/// in every other respect — model, messages, temperature, tools, all
/// preserved. We only set a single key inside `stream_options`. If the
/// client explicitly set `include_usage: false`, we respect that.
///
/// If you ever feel tempted to add a second mutation here, push back.
/// The proxy's value comes from being passive; observability that
/// distorts traffic is worse than no observability at all.
public enum LLMRequestRewriter {
    /// Path-based gate. Only chat/completions needs the hint:
    ///   * Anthropic /v1/messages always emits `message_start` with
    ///     `usage.input_tokens`.
    ///   * OpenAI /v1/responses always returns a `response.completed`
    ///     event with `usage` in the envelope.
    ///   * OpenAI /v1/chat/completions is the outlier.
    public static func shouldRewrite(path: String) -> Bool {
        path.lowercased().hasPrefix("/v1/chat/completions")
    }

    public static func rewrittenChatCompletionsBody(_ body: Data) -> Data {
        guard !body.isEmpty,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return body }
        guard let stream = json["stream"] as? Bool, stream == true else {
            return body
        }
        var streamOptions = json["stream_options"] as? [String: Any] ?? [:]
        if streamOptions["include_usage"] != nil {
            // Client made an explicit choice — respect it, even if false.
            return body
        }
        streamOptions["include_usage"] = true
        json["stream_options"] = streamOptions
        guard let rewritten = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        return rewritten
    }
}
