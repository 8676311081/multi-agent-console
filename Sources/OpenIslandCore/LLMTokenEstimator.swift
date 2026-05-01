import Foundation

/// Rough token-count estimation from a string, without invoking a real
/// tokenizer. Designed for "approximate billing" surfaces where the
/// caller cares about order-of-magnitude (e.g. "is this tool schema
/// big enough that listing it as unused matters?"). Never used to bill
/// the user — the proxy reads exact `usage.input_tokens` from upstream
/// for that.
///
/// Heuristic (matches the tokenizer ratios most Claude/GPT users
/// internalize):
///
///   - CJK / Hangul characters → 0.7 tokens each (one character is
///     usually one token, sometimes two for less common glyphs)
///   - All other characters    → 0.25 tokens each (i.e. ÷4 — the
///     "4 chars per token" rule of thumb for English)
///
/// Output rounded UP — better to over-estimate by 1 than to under-
/// estimate when the value drives "is this worth showing" decisions.
public enum LLMTokenEstimator {
    /// Unicode ranges Open Island treats as CJK for the 0.7-tokens-
    /// per-character ratio.
    ///
    /// - 0x3040–0x9FFF: Hiragana, Katakana, CJK Unified Ideographs
    ///   (the bulk of Japanese + Chinese)
    /// - 0xAC00–0xD7AF: Hangul syllables (Korean)
    /// - 0x4E00–0x9FEF: CJK Unified Ideographs (overlaps with the
    ///   first range — kept explicit because the spec asked for it
    ///   and the redundancy costs nothing)
    static let cjkRanges: [ClosedRange<UInt32>] = [
        0x3040...0x9FFF,
        0xAC00...0xD7AF,
        0x4E00...0x9FEF,
    ]

    /// Returns the estimated token count for `text`. Always ≥ 0; rounds
    /// up so a 1-character string returns at least 1 token.
    public static func estimateTokens(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else {
                other += 1
            }
        }
        let raw = Double(cjk) * 0.7 + Double(other) * 0.25
        return Int(raw.rounded(.up))
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        for range in cjkRanges where range.contains(value) {
            return true
        }
        return false
    }
}
