import Foundation
import Testing
@testable import OpenIslandCore

struct LLMUsageExtractionDeepSeekCacheTests {
    /// OpenAI's standard cache-hit field is at
    /// `usage.prompt_tokens_details.cached_tokens`. The existing path covers it.
    @Test
    func openAIStandardCachedTokensExtracted() {
        let body = #"""
        {
          "id": "chatcmpl-1",
          "choices": [{"finish_reason": "stop", "delta": {}}],
          "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "prompt_tokens_details": {"cached_tokens": 80}
          }
        }
        """#
        var consumer = OpenAIStreamConsumer()
        let frame = SSEFrame(event: nil, data: body)
        let effects = consumer.process(frame)
        let usageEffect = effects.first { effect in
            if case .usageFinal = effect { return true } else { return false }
        }
        guard case let .usageFinal(_, cacheRead, _) = usageEffect else {
            #expect(Bool(false), "expected usageFinal effect")
            return
        }
        #expect(cacheRead == 80)
    }

    /// DeepSeek exposes the same signal at `usage.prompt_cache_hit_tokens`
    /// (top-level, not nested under prompt_tokens_details). Without the
    /// shim DeepSeek's cache hits are silently zeroed in the spend stats
    /// table.
    @Test
    func deepSeekTopLevelCacheHitTokensExtracted() {
        let body = #"""
        {
          "id": "chatcmpl-2",
          "choices": [{"finish_reason": "stop", "delta": {}}],
          "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "prompt_cache_hit_tokens": 80,
            "prompt_cache_miss_tokens": 20
          }
        }
        """#
        var consumer = OpenAIStreamConsumer()
        let frame = SSEFrame(event: nil, data: body)
        let effects = consumer.process(frame)
        let usageEffect = effects.first { effect in
            if case .usageFinal = effect { return true } else { return false }
        }
        guard case let .usageFinal(_, cacheRead, _) = usageEffect else {
            #expect(Bool(false), "expected usageFinal effect")
            return
        }
        #expect(cacheRead == 80, "DeepSeek prompt_cache_hit_tokens should map to cacheRead")
    }

    /// OpenAI's standard wins over DeepSeek's when both are present
    /// (the chain falls back to DeepSeek only when OpenAI's nested
    /// path is missing).
    @Test
    func openAIStandardTakesPrecedenceOverDeepSeekFallback() {
        let body = #"""
        {
          "id": "chatcmpl-3",
          "choices": [{"finish_reason": "stop", "delta": {}}],
          "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "prompt_tokens_details": {"cached_tokens": 80},
            "prompt_cache_hit_tokens": 999
          }
        }
        """#
        var consumer = OpenAIStreamConsumer()
        let frame = SSEFrame(event: nil, data: body)
        let effects = consumer.process(frame)
        guard case let .usageFinal(_, cacheRead, _) = effects.first(where: { effect in
            if case .usageFinal = effect { return true } else { return false }
        }) else {
            #expect(Bool(false))
            return
        }
        #expect(cacheRead == 80, "OpenAI nested path should win when present")
    }

    /// Non-streaming chat/completions endpoint also picks up DeepSeek's field.
    @Test
    func nonStreamingChatCompletionsPicksUpDeepSeekField() {
        let body = Data(#"""
        {
          "id": "chatcmpl-ns",
          "choices": [{"message": {"content": "hi"}}],
          "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "prompt_cache_hit_tokens": 70
          }
        }
        """#.utf8)
        let result = OpenAINonStreaming.extractChatCompletions(body)
        #expect(result?.usage.cacheRead == 70)
        #expect(result?.usage.input == 100)
        #expect(result?.usage.output == 50)
    }
}
