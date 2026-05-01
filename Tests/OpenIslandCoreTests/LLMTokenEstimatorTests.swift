import Foundation
import Testing
@testable import OpenIslandCore

struct LLMTokenEstimatorTests {
    @Test
    func emptyStringReturnsZero() {
        #expect(LLMTokenEstimator.estimateTokens("") == 0)
    }

    @Test
    func pureEnglishUsesQuarterCharRatio() {
        // 16 chars → 16 × 0.25 = 4 tokens.
        #expect(LLMTokenEstimator.estimateTokens("Hello, world! ABC") == 5)  // 17 × 0.25 = 4.25 → 5
        // 4 chars → 1 token (1.0 ceil = 1).
        #expect(LLMTokenEstimator.estimateTokens("test") == 1)
        // 1 char → 1 token (0.25 ceil = 1; never round to 0 for non-empty).
        #expect(LLMTokenEstimator.estimateTokens("a") == 1)
    }

    @Test
    func pureCJKUsesPointSevenRatio() {
        // 10 chars × 0.7 = 7 tokens
        let chinese = "今天天气真不错啊呀嗯"
        #expect(chinese.count == 10)
        #expect(LLMTokenEstimator.estimateTokens(chinese) == 7)

        // Japanese hiragana/katakana
        let japanese = "こんにちは"  // 5 chars × 0.7 = 3.5 → 4
        #expect(LLMTokenEstimator.estimateTokens(japanese) == 4)

        // Korean Hangul
        let korean = "안녕하세요"  // 5 chars × 0.7 = 3.5 → 4
        #expect(LLMTokenEstimator.estimateTokens(korean) == 4)
    }

    @Test
    func mixedEnglishAndCJK() {
        // "Hello 世界" — 5 ASCII + 1 space + 2 CJK
        // ASCII+space: 6 × 0.25 = 1.5
        // CJK: 2 × 0.7 = 1.4
        // Total: 2.9 → ceil = 3
        #expect(LLMTokenEstimator.estimateTokens("Hello 世界") == 3)
    }

    @Test
    func emojiCountAsNonCJK() {
        // 🎉 is U+1F389 — outside our CJK ranges. Falls under
        // "other" — 1 scalar × 0.25 = 0.25 → ceil = 1.
        #expect(LLMTokenEstimator.estimateTokens("🎉") == 1)
        // "🎉🎉🎉🎉" — 4 scalars × 0.25 = 1.0 → 1
        #expect(LLMTokenEstimator.estimateTokens("🎉🎉🎉🎉") == 1)
    }

    @Test
    func cjkBoundaryDetectionMatchesDocumentedRanges() {
        // U+3040 is the lower bound (Hiragana) — must be CJK.
        #expect(LLMTokenEstimator.isCJK(Unicode.Scalar(0x3040)!))
        // U+9FFF — upper bound of CJK Unified — must be CJK.
        #expect(LLMTokenEstimator.isCJK(Unicode.Scalar(0x9FFF)!))
        // U+AC00 / U+D7AF — Hangul syllable bounds.
        #expect(LLMTokenEstimator.isCJK(Unicode.Scalar(0xAC00)!))
        #expect(LLMTokenEstimator.isCJK(Unicode.Scalar(0xD7AF)!))
        // Just outside the lower CJK range.
        #expect(!LLMTokenEstimator.isCJK(Unicode.Scalar(0x303F)!))
        // Latin small "a" — definitely not CJK.
        #expect(!LLMTokenEstimator.isCJK(Unicode.Scalar(0x0061)!))
    }
}
