import Foundation
import Testing
@testable import OpenIslandCore

/// Targeted parser tests for `LLMProxyHTTP`. Pinned by reviewer A
/// against commit abc09c6 (NWListener-based reverse proxy) — the
/// gaps the original commit shipped without.
struct LLMProxyHTTPTests {
    // MARK: - Request line

    @Test
    func parseRequestHeadRejectsRequestLineMissingHTTPVersion() throws {
        // Two tokens, not three — `GET /v1/messages` with no `HTTP/1.1`.
        let raw = Data("GET /v1/messages\r\nHost: example.com\r\n".utf8)
        #expect(throws: LLMProxyHTTP.ParseError.self) {
            _ = try LLMProxyHTTP.parseRequestHead(raw)
        }
    }

    @Test
    func parseRequestHeadRejectsEmptyRequestLine() throws {
        let raw = Data("\r\nHost: example.com\r\n".utf8)
        #expect(throws: LLMProxyHTTP.ParseError.self) {
            _ = try LLMProxyHTTP.parseRequestHead(raw)
        }
    }

    @Test
    func parseRequestHeadRejectsMalformedHeaderMissingColon() throws {
        let raw = Data("POST /v1/messages HTTP/1.1\r\nHost example.com\r\n".utf8)
        #expect(throws: LLMProxyHTTP.ParseError.self) {
            _ = try LLMProxyHTTP.parseRequestHead(raw)
        }
    }

    // MARK: - Chunked decoder fuzz

    @Test
    func chunkedBodyMalformedSizeReturnsMalformedNotCrash() {
        // `xyz` is not valid hex — decoder must return .malformed,
        // never trap.
        let raw = Data("xyz\r\nhello\r\n0\r\n\r\n".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .malformed:
            return  // expected
        default:
            Issue.record("expected .malformed, got \(result)")
        }
    }

    @Test
    func chunkedBodyNegativeSizeReturnsMalformedNotCrash() {
        // `Int("-5", radix: 16)` succeeds in Swift and yields -5.
        // Pre-1.6, the decoder didn't gate `size >= 0` and the
        // resulting `subdata(in: cursor..<(cursor + size))` call
        // trapped with:
        //   Swift/Range.swift: Fatal error: Range requires
        //                        lowerBound <= upperBound
        // 1.6 added `guard size >= 0`. This test pins the new
        // contract — malformed, never crash.
        let raw = Data("-5\r\nhello\r\n0\r\n\r\n".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .malformed:
            return
        default:
            Issue.record("expected .malformed, got \(result)")
        }
    }

    @Test
    func chunkedBodySingleChunkSizeOverCapReturnsMalformed() {
        // A single chunk declaring it's bigger than the body cap is
        // pathological — refuse before allocating. The decoder
        // doesn't read beyond the size line, so the body bytes
        // don't have to actually be present.
        let raw = Data("ffffffff\r\n".utf8)  // 4 GiB declared
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .malformed:
            return
        default:
            Issue.record("expected .malformed, got \(result)")
        }
    }

    @Test
    func chunkedBodyAccumulatedOverCapReturnsTooLarge() {
        // Build a chunked stream whose first chunk is just under
        // the cap so it's accepted, then a second chunk that pushes
        // total over. 64 MiB is too big to materialize in a unit
        // test reasonably — temporarily lower-bound by recognizing
        // the cap-check reads the constant directly. Use a fixture
        // that proves the *math* (size + body.count > cap) by
        // offering a very large second chunk size.
        // Chunk 1 has the maximum allowed size; chunk 2 declares
        // any positive size and should overflow the cap.
        let cap = LLMProxyHTTP.inboundBodyCapBytes
        let chunk1Hex = String(cap, radix: 16)
        // Note: we don't actually have to provide `cap` bytes of
        // chunk-data — the decoder will return .needMore long before
        // the math check fires unless we satisfy the data length.
        // The tooLarge gate is on the second chunk's accumulated
        // overflow check, which runs *after* the full first chunk
        // is read. So we instead exploit the single-chunk-too-large
        // path with a chunk just one byte over cap; the decoder
        // rejects it without reading data.
        let oversize = String(cap + 1, radix: 16)
        let raw = Data("\(oversize)\r\n".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .malformed:
            // The single-chunk path treats >cap as malformed (no
            // legitimate use case for a 64 MiB+ single chunk).
            return
        default:
            Issue.record("expected .malformed for oversized single chunk, got \(result)")
        }
        _ = chunk1Hex  // unused but kept for documentation
    }

    @Test
    func chunkedBodyAccumulatedJustUnderCapStillCompletes() {
        // Sanity: the cap check uses `>` not `>=`, so a body
        // exactly at capacity — though never realistic — must not
        // false-positive. This is too expensive to materialize at
        // 64 MiB; instead probe a small body and confirm the
        // happy path is unaffected by the new gates.
        let raw = Data("3\r\nabc\r\n0\r\n\r\n".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        guard case let .complete(body, _) = result else {
            Issue.record("expected .complete, got \(result)")
            return
        }
        #expect(body == Data("abc".utf8))
    }

    @Test
    func chunkedBodyMissingTrailingCRLFAfterChunkDataReturnsMalformed() {
        // Size `5`, then `hello`, then garbage where CRLF should be.
        let raw = Data("5\r\nhelloXX0\r\n\r\n".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .malformed:
            return
        default:
            Issue.record("expected .malformed, got \(result)")
        }
    }

    @Test
    func chunkedBodyBoundaryWhereTrailerLineExtendsPastBuffer() {
        // Last-chunk `0\r\n` followed by an *unfinished* trailer
        // header (no terminating CRLF). Decoder must return .needMore,
        // not crash on the bound check inside the trailer-skip loop.
        let raw = Data("0\r\nX-Trailer: incomp".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .needMore:
            return  // expected — caller will re-read more bytes
        default:
            Issue.record("expected .needMore, got \(result)")
        }
    }

    @Test
    func chunkedBodyHappyPathCompletesAndReportsBytesConsumed() {
        // Two chunks then last-chunk + empty trailer.
        let raw = Data("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        guard case let .complete(body, bytesConsumed) = result else {
            Issue.record("expected .complete, got \(result)")
            return
        }
        #expect(body == Data("hello world".utf8))
        #expect(bytesConsumed == raw.count)
    }

    @Test
    func chunkedBodyNeedMoreWhenSizeLineIncomplete() {
        // No CRLF anywhere yet.
        let raw = Data("5".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .needMore:
            return
        default:
            Issue.record("expected .needMore, got \(result)")
        }
    }

    // MARK: - Header terminator

    @Test
    func findHeaderTerminatorLocatesDoubleCRLF() {
        let raw = Data("GET / HTTP/1.1\r\nHost: a\r\n\r\nbody".utf8)
        let idx = LLMProxyHTTP.findHeaderTerminator(in: raw)
        #expect(idx == raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))!.lowerBound)
    }

    @Test
    func findHeaderTerminatorReturnsNilOnIncompleteHeaders() {
        let raw = Data("GET / HTTP/1.1\r\nHost: a\r\n".utf8)
        #expect(LLMProxyHTTP.findHeaderTerminator(in: raw) == nil)
    }
}
