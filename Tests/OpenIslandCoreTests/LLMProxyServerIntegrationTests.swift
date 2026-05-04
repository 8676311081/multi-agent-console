import Foundation
import Network
import Testing
@testable import OpenIslandCore

/// End-to-end tests for `LLMProxyServer`: real NWListener + real
/// URLSession-based outbound, with `MockUpstreamProtocol` standing
/// in for `api.anthropic.com` / `api.openai.com`.
///
/// Tests are serialized — `MockUpstreamProtocol.responder` is process-
/// global state, so two suites running in parallel would race on it.
@Suite(.serialized)
struct LLMProxyServerIntegrationTests {
    // MARK: - Fixtures

    private static func makeTempStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llm-stats-\(UUID().uuidString).json")
    }

    /// Build a fresh server bound to a kernel-assigned port + an
    /// observer wired into a fresh on-disk stats store. Returns
    /// (server, store, port). Caller is responsible for `server.stop()`
    /// and removing the store URL.
    private static func makeServer(
        anthropicMock: URL = URL(string: "https://api.anthropic.com")!,
        openAIMock: URL = URL(string: "https://api.openai.com")!,
        profileResolver: (any UpstreamProfileResolver)? = nil
    ) async throws -> (LLMProxyServer, LLMStatsStore, UInt16, URL) {
        let storeURL = makeTempStoreURL()
        let store = LLMStatsStore(url: storeURL)
        let server = LLMProxyServer(
            configuration: LLMProxyConfiguration(
                port: 0,
                anthropicUpstream: anthropicMock,
                openAIUpstream: openAIMock
            ),
            additionalProtocolClasses: [MockUpstreamProtocol.self],
            profileResolver: profileResolver
        )
        let observer = LLMUsageObserver(store: store)
        server.setObserver(observer)
        try server.start()
        try await server.waitUntilReady(timeout: 3)
        guard let port = server.actualPort else {
            throw NSError(domain: "test", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no port"])
        }
        return (server, store, port, storeURL)
    }

    private static func makeClientSession() -> URLSession {
        // The client side is a plain URLSession — only the server-
        // side outbound path needs `MockUpstreamProtocol` injected.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }

    private static func proxyURL(port: UInt16, path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    /// Wait until the observer's in-flight scratchpad has drained back
    /// into the store, i.e. the request is fully recorded. The proxy's
    /// hot path is fire-and-forget into the actor, so a short poll
    /// loop on the snapshot is the cheapest sync barrier.
    private static func awaitStatsRecorded(
        in store: LLMStatsStore,
        timeout: TimeInterval = 3
    ) async throws -> LLMStatsSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = await store.currentSnapshot()
            if !snap.days.isEmpty { return snap }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        return await store.currentSnapshot()
    }

    /// Cleanup that survives a thrown test. Caller passes the store
    /// URL because `LLMStatsStore` is an actor and its `url` property
    /// can't be accessed synchronously from a nonisolated `defer`.
    private static func teardown(_ server: LLMProxyServer, _ storeURL: URL) {
        server.stop()
        try? FileManager.default.removeItem(at: storeURL)
        MockUpstreamProtocol.setResponder(nil)
    }

    // MARK: - (a) Anthropic SSE → tokens land in stats

    @Test
    func anthropicSSEStreamPushesTokensIntoStore() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        // Three SSE events: message_start (initial usage), one
        // content delta, message_delta (output cumulative). The
        // trailing `\n` is critical — SSE event termination is
        // double-LF and Swift's `"""` literal only emits a single
        // trailing newline before the closing delimiter.
        let body = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m_1","model":"claude-opus-4-7","usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":50,"cache_creation_input_tokens":0}}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}

        event: message_delta
        data: {"type":"message_delta","delta":{},"usage":{"output_tokens":42}}

        """ + "\n"
        MockUpstreamProtocol.setResponder { _ in
            MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(body.utf8)]
            )
        }

        var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-cli/2.1.123", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)

        let (data, response) = try await Self.makeClientSession().data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        // Body bytes pass through identity-decoded (no proxy
        // re-encoding).
        #expect(String(data: data, encoding: .utf8)?.contains("message_start") == true)

        // Stats land. Anthropic input = input + cacheCreate + cacheRead.
        let snap = try await Self.awaitStatsRecorded(in: store)
        let day = LLMStatsStore.dayKey(for: Date())
        let bucket = try #require(snap.days[day]?[LLMClient.claudeCode.rawValue])
        #expect(bucket.tokensIn == 150)        // 100 + 50 + 0
        #expect(bucket.tokensOut == 42)
        #expect(bucket.inputTokens == 100)
        #expect(bucket.cacheReadTokens == 50)
        #expect(bucket.cacheCreationTokens == 0)
        #expect(bucket.turns == 1)
    }

    // MARK: - (b) /v1/chat/completions: stream_options.include_usage injected

    @Test
    func openAIChatCompletionsHasStreamOptionsIncludeUsageInjected() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        // Capture the body the proxy hands to the upstream so we can
        // inspect the rewriter's effect.
        let captured = CapturedBody()
        MockUpstreamProtocol.setResponder { request in
            captured.set(request.httpBody ?? request.httpBodyStream.flatMap { Self.drainStream($0) } ?? Data())
            // Minimal SSE done-event so the path completes cleanly.
            let body = "data: [DONE]\n\n"
            return MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(body.utf8)]
            )
        }

        let inboundBody = #"{"model":"gpt-4o","stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(inboundBody.utf8)

        _ = try await Self.makeClientSession().data(for: req)

        let outbound = try #require(String(data: captured.value, encoding: .utf8))
        // Rewriter contract: stream_options.include_usage = true is
        // present; original `stream:true` survives.
        #expect(outbound.contains("\"include_usage\""))
        #expect(outbound.contains("true"))
        #expect(outbound.contains("\"stream\":true") || outbound.contains("\"stream\" : true"))
    }

    // MARK: - (c) Upstream 502 → transparent error

    @Test
    func upstream502PassesThroughVerbatim() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        let upstreamBody = #"{"error":"upstream is on fire"}"#
        MockUpstreamProtocol.setResponder { _ in
            MockUpstreamProtocol.Response(
                statusCode: 502,
                headers: ["Content-Type": "application/json"],
                bodyChunks: [Data(upstreamBody.utf8)]
            )
        }

        var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)

        let (data, response) = try await Self.makeClientSession().data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 502)
        #expect(String(data: data, encoding: .utf8) == upstreamBody)
    }

    // MARK: - (d) Duplicate tool_use within 5-min window → dup warning

    @Test
    func duplicateToolUseWithinWindowFlagsDuplicateWarning() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        // Non-streaming response with one tool_use block. Send the
        // same response (same name, same input) twice — the second
        // hit must increment duplicateToolCalls.
        let toolUseBody = """
        {
          "id":"m_1",
          "model":"claude-opus-4-7",
          "stop_reason":"tool_use",
          "content":[{"type":"tool_use","id":"t_1","name":"Bash","input":{"cmd":"ls /tmp"}}],
          "usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}
        }
        """
        MockUpstreamProtocol.setResponder { _ in
            MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                bodyChunks: [Data(toolUseBody.utf8)]
            )
        }

        for _ in 0..<2 {
            var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("claude-cli/2.1.123", forHTTPHeaderField: "User-Agent")
            req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)
            _ = try await Self.makeClientSession().data(for: req)
        }

        // Wait until both turns recorded.
        let deadline = Date().addingTimeInterval(3)
        var dupWarning = false
        while Date() < deadline {
            let snap = await store.currentSnapshot()
            let day = LLMStatsStore.dayKey(for: Date())
            if let bucket = snap.days[day]?[LLMClient.claudeCode.rawValue],
               bucket.duplicateToolCalls >= 1 {
                dupWarning = true
                break
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        #expect(dupWarning)
    }

    // MARK: - (e) Client cancel mid-stream → proxy survives

    @Test
    func clientCancelMidStreamLeavesProxyResponsive() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        // Slow chunked SSE — gives the client time to cancel mid-stream.
        MockUpstreamProtocol.setResponder { _ in
            let chunks = (0..<20).map { i in
                Data("event: ping\ndata: {\"i\":\(i)}\n\n".utf8)
            }
            return MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: chunks,
                chunkDelay: 0.05  // 50 ms between events
            )
        }

        // 1) Start a request and cancel it mid-flight.
        let cancellingTask = Task<Void, Never> {
            var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)
            _ = try? await Self.makeClientSession().data(for: req)
        }
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms in
        cancellingTask.cancel()
        try await Task.sleep(nanoseconds: 200_000_000) // settle

        // 2) Issue a fresh request — server must still accept and
        //    serve. (Implicitly proves the listener wasn't taken
        //    down by the cancelled connection.)
        let body = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m_2","model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}

        event: message_delta
        data: {"type":"message_delta","delta":{},"usage":{"output_tokens":1}}

        """ + "\n"
        MockUpstreamProtocol.setResponder { _ in
            MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(body.utf8)]
            )
        }
        var req2 = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
        req2.httpMethod = "POST"
        req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req2.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)
        let (_, resp2) = try await Self.makeClientSession().data(for: req2)
        let http2 = try #require(resp2 as? HTTPURLResponse)
        #expect(http2.statusCode == 200)
    }

    // MARK: - 1.6 hardening: 64 MiB inbound body cap

    /// Content-Length declaring a body bigger than the cap → 413,
    /// no upstream call made. Bypasses URLSession (which would
    /// otherwise overwrite our intentionally-lying Content-Length
    /// header) by speaking raw HTTP/1.1 over NWConnection.
    @Test
    func contentLengthOverCapReturns413BeforeForwarding() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        let upstreamReached = UpstreamReachFlag()
        MockUpstreamProtocol.setResponder { _ in
            upstreamReached.set()
            return MockUpstreamProtocol.Response(statusCode: 200, headers: [:], bodyChunks: [Data()])
        }

        let cap = LLMProxyHTTP.inboundBodyCapBytes
        // Raw HTTP wire bytes — explicit `\r\n` terminators rather
        // than multi-line literals, because `"""..."""` strips the
        // newline immediately before the closing `"""`, so a final
        // `\r` would land on the wire without its companion `\n`.
        let raw = "POST /v1/messages HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(cap + 1)\r\n"
            + "\r\n"
            + "{}"
        let response = try await Self.sendRawHTTP(port: port, request: Data(raw.utf8))
        let firstLine = response.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        #expect(firstLine.contains("413"))
        #expect(response.contains("64 MiB"))
        #expect(!upstreamReached.didReach)
        _ = store
    }

    /// Speak a single HTTP/1.1 request to 127.0.0.1:`port` over a
    /// raw NWConnection — bypasses URLSession's automatic
    /// Content-Length / Accept-Encoding rewriting so we can put
    /// hostile bytes on the wire and observe the proxy's response
    /// verbatim.
    private static func sendRawHTTP(
        port: UInt16,
        request: Data,
        timeout: TimeInterval = 3
    ) async throws -> String {
        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let queue = DispatchQueue(label: "test.raw-http")
        let state = RawHTTPState()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if state.markResponded() {
                    conn.cancel()
                    cont.resume(throwing: NSError(domain: "test", code: -10, userInfo: [
                        NSLocalizedDescriptionKey: "raw HTTP read timeout"
                    ]))
                }
            }
            conn.stateUpdateHandler = { connState in
                switch connState {
                case .ready:
                    conn.send(content: request, completion: .contentProcessed { _ in })
                    func readMore() {
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, _ in
                            if let chunk { state.appendBuf(chunk) }
                            // Status-line latch: once we've got the
                            // response status line (and ideally the
                            // whole body, but at minimum enough to
                            // assert on), return without waiting for
                            // a final EOF that the server may delay.
                            // 64 bytes is enough to catch
                            // `HTTP/1.1 4xx ...` + JSON error body.
                            let haveResponse = state.bufString.contains("HTTP/1.1 ")
                                && state.bufString.contains("\r\n\r\n")
                            if isComplete || haveResponse {
                                if state.markResponded() {
                                    timer.cancel()
                                    conn.cancel()
                                    cont.resume(returning: state.bufString)
                                }
                            } else {
                                readMore()
                            }
                        }
                    }
                    readMore()
                case let .failed(err):
                    if state.markResponded() {
                        timer.cancel()
                        cont.resume(throwing: err)
                    }
                default:
                    break
                }
            }
            timer.resume()
            conn.start(queue: queue)
        }
    }

    /// Same path through chunked: pre-cap chunk size in the wire-
    /// level decode is rejected as 400 malformed (single chunk is
    /// pathological at >cap) — verify end-to-end.
    @Test
    func chunkedSingleChunkOverCapReturns400() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        let upstreamReached = UpstreamReachFlag()
        MockUpstreamProtocol.setResponder { _ in
            upstreamReached.set()
            return MockUpstreamProtocol.Response(statusCode: 200, headers: [:], bodyChunks: [Data()])
        }

        let cap = LLMProxyHTTP.inboundBodyCapBytes
        let oversizeHex = String(cap + 1, radix: 16)
        let raw = "POST /v1/messages HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "\r\n"
            + "\(oversizeHex)\r\n"
        let response = try await Self.sendRawHTTP(port: port, request: Data(raw.utf8))
        let firstLine = response.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        #expect(firstLine.contains("400"))
        #expect(!upstreamReached.didReach)
        _ = store
    }

    // MARK: - (f) abc09c6 gap: outbound Accept-Encoding forced to identity

    @Test
    func outboundRequestForcesAcceptEncodingIdentity() async throws {
        let (server, store, port, storeURL) = try await Self.makeServer()
        defer { Self.teardown(server, storeURL) }

        let captured = CapturedHeaders()
        MockUpstreamProtocol.setResponder { request in
            captured.set(request.allHTTPHeaderFields ?? [:])
            return MockUpstreamProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                bodyChunks: [Data("{}".utf8)]
            )
        }

        var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Client hints gzip — proxy must override before sending
        // upstream so URLSession's auto-gunzip doesn't stomp on the
        // body before the agent sees it.
        req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)

        _ = try await Self.makeClientSession().data(for: req)

        let outbound = captured.value
        let acceptEnc = outbound["Accept-Encoding"] ?? outbound["accept-encoding"] ?? ""
        #expect(acceptEnc.lowercased() == "identity",
                "outbound Accept-Encoding was \(acceptEnc), expected identity")
    }

    // MARK: - (g) Anthropic OAuth-passthrough gate returns 409

    /// When the active profile resolves to an Anthropic-passthrough
    /// (no keychain account, host is api.anthropic.com), the proxy
    /// must short-circuit with 409 instead of forwarding — Anthropic
    /// enforces end-to-end client identity verification on Max/Pro
    /// OAuth tokens, so the request would always 401 after a full
    /// round-trip. The 409 carries an actionable error pointing the
    /// user at the `claude-native` shim.
    @Test
    func anthropicPassthroughBlockedReturns409BeforeForwarding() async throws {
        let resolver = BlockedAnthropicNativeResolver()
        let (server, store, port, storeURL) = try await Self.makeServer(
            profileResolver: resolver
        )
        defer { Self.teardown(server, storeURL) }

        let upstreamReached = UpstreamReachFlag()
        MockUpstreamProtocol.setResponder { _ in
            upstreamReached.set()
            return MockUpstreamProtocol.Response(
                statusCode: 200, headers: [:], bodyChunks: [Data()]
            )
        }

        var req = URLRequest(url: Self.proxyURL(port: port, path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // OAuth token shape (sk-ant-oat) is what claude CLI sends for a
        // Max/Pro subscriber. We don't pattern-match on the value — the
        // gate is profile-based — but using a realistic token here makes
        // the test fixture self-documenting about why this case matters.
        req.setValue("Bearer sk-ant-oat01-test-token", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(#"{"model":"claude-opus-4-7","messages":[]}"#.utf8)

        let (data, response) = try await Self.makeClientSession().data(for: req)
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 409, "expected 409 Conflict, got \(http?.statusCode ?? -1)")
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        #expect(bodyString.contains("open_island_oauth_blocked"))
        #expect(bodyString.contains("claude-native"))
        #expect(!upstreamReached.didReach,
                "upstream must NOT be reached when gate fires")
        _ = store
    }

    /// Healthz endpoint is for liveness probes and intentionally
    /// pre-empts upstream resolution at line 1 of `handleParsedRequest`.
    /// Verify the gate doesn't accidentally swallow it when a blocked
    /// profile is active.
    @Test
    func anthropicPassthroughBlockedDoesNotAffectHealthz() async throws {
        let resolver = BlockedAnthropicNativeResolver()
        let (server, _, port, storeURL) = try await Self.makeServer(
            profileResolver: resolver
        )
        defer { Self.teardown(server, storeURL) }

        let req = URLRequest(url: Self.proxyURL(port: port, path: "/healthz"))
        let (data, response) = try await Self.makeClientSession().data(for: req)
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "ok\n")
    }

    // MARK: - Helpers

    private static func drainStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

// MARK: - Test-only thread-safe captures

/// Captures the request body the mock upstream saw, across test
/// thread boundaries. Plain `var` capture would race because the mock
/// runs on a URLProtocol-internal queue.
private final class CapturedBody: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ v: Data) { lock.lock(); data = v; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class CapturedHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    func set(_ v: [String: String]) { lock.lock(); headers = v; lock.unlock() }
    var value: [String: String] { lock.lock(); defer { lock.unlock() }; return headers }
}

/// Stand-in for `UpstreamProfileStore` in router-gate tests. Always
/// resolves to the built-in Anthropic-native profile (`baseURL =
/// api.anthropic.com`, `keychainAccount = nil`) — the canonical
/// "blocked" shape that triggers `isAnthropicPassthroughBlocked`.
private struct BlockedAnthropicNativeResolver: UpstreamProfileResolver {
    func profileMatching(url: URL) -> UpstreamProfile? {
        BuiltinProfiles.anthropicNative
    }
    func currentActiveProfile() -> UpstreamProfile {
        BuiltinProfiles.anthropicNative
    }
}

/// Tracks whether the mock upstream was ever invoked. Used by the
/// `contentLengthOverCapReturns413BeforeForwarding` test to verify
/// the 413 fires *before* any upstream call.
private final class UpstreamReachFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    func set() { lock.lock(); reached = true; lock.unlock() }
    var didReach: Bool { lock.lock(); defer { lock.unlock() }; return reached }
}

/// Lock-protected shared state for `sendRawHTTP`. Holds the
/// inbound buffer + a `responded` latch so the timer / receive
/// callbacks running on the same DispatchQueue don't race.
private final class RawHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var responded = false
    private var buf = Data()

    /// Atomic test-and-set: returns `true` exactly once.
    func markResponded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if responded { return false }
        responded = true
        return true
    }

    func appendBuf(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buf.append(chunk)
    }

    var bufCount: Int { lock.lock(); defer { lock.unlock() }; return buf.count }
    var bufString: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: buf, encoding: .utf8) ?? ""
    }
}
