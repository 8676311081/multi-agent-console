import Dispatch
import Foundation

public struct CodexSessionMetadata: Equatable, Codable, Sendable {
    public var transcriptPath: String?
    public var lastAssistantMessage: String?
    public var currentTool: String?

    public init(
        transcriptPath: String? = nil,
        lastAssistantMessage: String? = nil,
        currentTool: String? = nil
    ) {
        self.transcriptPath = transcriptPath
        self.lastAssistantMessage = lastAssistantMessage
        self.currentTool = currentTool
    }

    public var isEmpty: Bool {
        transcriptPath == nil && lastAssistantMessage == nil && currentTool == nil
    }
}

public struct CodexTrackedSessionRecord: Equatable, Codable, Sendable {
    public var sessionID: String
    public var title: String
    public var origin: SessionOrigin?
    public var summary: String
    public var phase: SessionPhase
    public var updatedAt: Date
    public var jumpTarget: JumpTarget?
    public var codexMetadata: CodexSessionMetadata?

    public init(
        sessionID: String,
        title: String,
        origin: SessionOrigin? = nil,
        summary: String,
        phase: SessionPhase,
        updatedAt: Date,
        jumpTarget: JumpTarget? = nil,
        codexMetadata: CodexSessionMetadata? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.origin = origin
        self.summary = summary
        self.phase = phase
        self.updatedAt = updatedAt
        self.jumpTarget = jumpTarget
        self.codexMetadata = codexMetadata
    }

    public init(session: AgentSession) {
        self.init(
            sessionID: session.id,
            title: session.title,
            origin: session.origin,
            summary: session.summary,
            phase: session.phase,
            updatedAt: session.updatedAt,
            jumpTarget: session.jumpTarget,
            codexMetadata: session.codexMetadata
        )
    }

    public var session: AgentSession {
        AgentSession(
            id: sessionID,
            title: title,
            tool: .codex,
            origin: origin,
            phase: phase,
            summary: summary,
            updatedAt: updatedAt,
            jumpTarget: jumpTarget,
            codexMetadata: codexMetadata
        )
    }
}

public extension CodexTrackedSessionRecord {
    var shouldRestoreToLiveState: Bool {
        origin != .demo && !LegacyMockSessionIDs.all.contains(sessionID)
    }
}

private enum LegacyMockSessionIDs {
    static let all: Set<String> = [
        "claude-fix-auth-bug",
        "codex-backend-server",
        "gemini-optimize-queries",
    ]
}

public final class CodexSessionStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager

    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/open-vibe-island", isDirectory: true)
    }

    public static var defaultFileURL: URL {
        defaultDirectoryURL.appendingPathComponent("session-terminals.json")
    }

    public init(
        fileURL: URL = CodexSessionStore.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> [CodexTrackedSessionRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CodexTrackedSessionRecord].self, from: data)
    }

    public func save(_ records: [CodexTrackedSessionRecord]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}

public final class CodexRolloutDiscovery: @unchecked Sendable {
    private struct Candidate {
        var fileURL: URL
        var modifiedAt: Date
    }

    private struct SessionMeta {
        var sessionID: String
        var cwd: String
        var timestamp: Date?

        var workspaceName: String {
            let workspace = URL(fileURLWithPath: cwd).lastPathComponent
            return workspace.isEmpty ? "Workspace" : workspace
        }

        var sessionTitle: String {
            "Codex · \(workspaceName)"
        }

        var defaultSummary: String {
            "Started Codex session in \(workspaceName)."
        }
    }

    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let maxAge: TimeInterval
    private let maxFiles: Int

    public init(
        rootURL: URL = CodexRolloutDiscovery.defaultRootURL,
        fileManager: FileManager = .default,
        maxAge: TimeInterval = 86_400,
        maxFiles: Int = 40
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.maxAge = maxAge
        self.maxFiles = maxFiles
    }

    public func discoverRecentSessions(now: Date = .now) -> [CodexTrackedSessionRecord] {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        var candidates: [Candidate] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl" else {
                continue
            }

            guard let resourceValues = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ),
            resourceValues.isRegularFile == true else {
                continue
            }

            let modifiedAt = resourceValues.contentModificationDate ?? .distantPast
            guard modifiedAt >= cutoff else {
                continue
            }

            candidates.append(Candidate(fileURL: fileURL, modifiedAt: modifiedAt))
        }

        let recentCandidates = candidates
            .sorted { lhs, rhs in
                if lhs.modifiedAt == rhs.modifiedAt {
                    return lhs.fileURL.lastPathComponent.localizedStandardCompare(rhs.fileURL.lastPathComponent) == .orderedDescending
                }

                return lhs.modifiedAt > rhs.modifiedAt
            }
            .prefix(maxFiles)

        var recordsByID: [String: CodexTrackedSessionRecord] = [:]
        for candidate in recentCandidates {
            guard let record = discoverRecord(fileURL: candidate.fileURL, modifiedAt: candidate.modifiedAt) else {
                continue
            }

            if let existing = recordsByID[record.sessionID], existing.updatedAt >= record.updatedAt {
                continue
            }

            recordsByID[record.sessionID] = record
        }

        return recordsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func discoverRecord(fileURL: URL, modifiedAt: Date) -> CodexTrackedSessionRecord? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let lines = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard !lines.isEmpty,
              let sessionMeta = sessionMeta(from: lines) else {
            return nil
        }

        let snapshot = CodexRolloutReducer.snapshot(for: lines)
        let summary = snapshot.summary ?? sessionMeta.defaultSummary
        let updatedAt = snapshot.updatedAt ?? sessionMeta.timestamp ?? modifiedAt
        let metadata = CodexSessionMetadata(
            transcriptPath: fileURL.path,
            lastAssistantMessage: snapshot.lastAssistantMessage,
            currentTool: snapshot.currentTool
        )

        return CodexTrackedSessionRecord(
            sessionID: sessionMeta.sessionID,
            title: sessionMeta.sessionTitle,
            origin: .live,
            summary: summary,
            phase: snapshot.phase,
            updatedAt: updatedAt,
            codexMetadata: metadata
        )
    }

    private func sessionMeta(from lines: [String]) -> SessionMeta? {
        for line in lines {
            guard let object = codexRolloutJSONObject(for: line),
                  object["type"] as? String == "session_meta" else {
                continue
            }

            let payload = object["payload"] as? [String: Any] ?? [:]
            guard let sessionID = payload["id"] as? String,
                  !sessionID.isEmpty,
                  let cwd = payload["cwd"] as? String,
                  !cwd.isEmpty else {
                continue
            }

            return SessionMeta(
                sessionID: sessionID,
                cwd: cwd,
                timestamp: codexRolloutParseTimestamp(
                    (payload["timestamp"] as? String) ?? (object["timestamp"] as? String)
                )
            )
        }

        return nil
    }
}

public struct CodexRolloutWatchTarget: Equatable, Sendable {
    public var sessionID: String
    public var transcriptPath: String

    public init(sessionID: String, transcriptPath: String) {
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
    }
}

public struct CodexRolloutSnapshot: Equatable, Sendable {
    public var summary: String?
    public var phase: SessionPhase
    public var updatedAt: Date?
    public var lastAssistantMessage: String?
    public var currentTool: String?
    public var isCompleted: Bool

    public init(
        summary: String? = nil,
        phase: SessionPhase = .running,
        updatedAt: Date? = nil,
        lastAssistantMessage: String? = nil,
        currentTool: String? = nil,
        isCompleted: Bool = false
    ) {
        self.summary = summary
        self.phase = phase
        self.updatedAt = updatedAt
        self.lastAssistantMessage = lastAssistantMessage
        self.currentTool = currentTool
        self.isCompleted = isCompleted
    }

    public var metadata: CodexSessionMetadata {
        CodexSessionMetadata(
            lastAssistantMessage: lastAssistantMessage,
            currentTool: currentTool
        )
    }
}

public enum CodexRolloutReducer {
    public static func snapshot(for lines: [String]) -> CodexRolloutSnapshot {
        var snapshot = CodexRolloutSnapshot()
        lines.forEach { apply(line: $0, to: &snapshot) }
        return snapshot
    }

    public static func apply(line: String, to snapshot: inout CodexRolloutSnapshot) {
        guard let object = jsonObject(for: line) else {
            return
        }

        let timestamp = parseTimestamp(object["timestamp"] as? String)
        let payload = object["payload"] as? [String: Any] ?? [:]

        switch object["type"] as? String {
        case "event_msg":
            applyEventMessage(payload, timestamp: timestamp, to: &snapshot)
        case "response_item":
            applyResponseItem(payload, timestamp: timestamp, to: &snapshot)
        default:
            break
        }
    }

    public static func events(
        from oldSnapshot: CodexRolloutSnapshot?,
        to newSnapshot: CodexRolloutSnapshot,
        sessionID: String,
        transcriptPath: String
    ) -> [AgentEvent] {
        var events: [AgentEvent] = []
        let timestamp = newSnapshot.updatedAt ?? .now
        let oldMetadata = oldSnapshot.map {
            CodexSessionMetadata(
                transcriptPath: transcriptPath,
                lastAssistantMessage: $0.lastAssistantMessage,
                currentTool: $0.currentTool
            )
        }
        let newMetadata = CodexSessionMetadata(
            transcriptPath: transcriptPath,
            lastAssistantMessage: newSnapshot.lastAssistantMessage,
            currentTool: newSnapshot.currentTool
        )

        if oldMetadata != newMetadata {
            events.append(
                .sessionMetadataUpdated(
                    SessionMetadataUpdated(
                        sessionID: sessionID,
                        codexMetadata: newMetadata,
                        timestamp: timestamp
                    )
                )
            )
        }

        let oldSummary = oldSnapshot?.summary
        let oldPhase = oldSnapshot?.phase
        let oldCompleted = oldSnapshot?.isCompleted ?? false
        let newSummary = newSnapshot.summary ?? oldSummary ?? "Codex updated the current turn."

        if newSnapshot.isCompleted {
            if !oldCompleted || oldSummary != newSummary {
                events.append(
                    .sessionCompleted(
                        SessionCompleted(
                            sessionID: sessionID,
                            summary: newSummary,
                            timestamp: timestamp
                        )
                    )
                )
            }
        } else if oldSummary != newSummary || oldPhase != newSnapshot.phase {
            events.append(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: sessionID,
                        summary: newSummary,
                        phase: newSnapshot.phase,
                        timestamp: timestamp
                    )
                )
            )
        }

        return events
    }

    private static func applyEventMessage(
        _ payload: [String: Any],
        timestamp: Date?,
        to snapshot: inout CodexRolloutSnapshot
    ) {
        switch payload["type"] as? String {
        case "task_started":
            snapshot.phase = .running
            snapshot.isCompleted = false
            snapshot.summary = snapshot.summary ?? "Codex started a new turn."
        case "agent_message":
            guard let message = payload["message"] as? String, !message.isEmpty else {
                break
            }

            snapshot.lastAssistantMessage = message
            snapshot.summary = message
            snapshot.phase = .running
            snapshot.isCompleted = false
        case "task_complete":
            snapshot.currentTool = nil
            snapshot.phase = .completed
            snapshot.isCompleted = true

            if let message = payload["last_agent_message"] as? String, !message.isEmpty {
                snapshot.lastAssistantMessage = message
                snapshot.summary = message
            } else {
                snapshot.summary = snapshot.summary ?? "Codex completed the turn."
            }
        case "turn_aborted":
            snapshot.currentTool = nil
            snapshot.phase = .completed
            snapshot.isCompleted = true
            snapshot.summary = "Codex turn was interrupted."
        case "exec_command_end":
            snapshot.currentTool = nil
            if !snapshot.isCompleted {
                snapshot.phase = .running
            }
            snapshot.summary = "Command finished."
        case "patch_apply_end":
            snapshot.currentTool = nil
            if !snapshot.isCompleted {
                snapshot.phase = .running
            }
            snapshot.summary = "Patch applied."
        default:
            break
        }

        if let timestamp {
            snapshot.updatedAt = timestamp
        }
    }

    private static func applyResponseItem(
        _ payload: [String: Any],
        timestamp: Date?,
        to snapshot: inout CodexRolloutSnapshot
    ) {
        let itemType = payload["type"] as? String
        guard itemType == "function_call" || itemType == "custom_tool_call" else {
            return
        }

        guard let toolName = payload["name"] as? String, !toolName.isEmpty else {
            return
        }

        snapshot.currentTool = toolName
        snapshot.phase = .running
        snapshot.isCompleted = false
        snapshot.summary = "Running \(displayName(for: toolName))."

        if let timestamp {
            snapshot.updatedAt = timestamp
        }
    }

    private static func displayName(for toolName: String) -> String {
        switch toolName {
        case "exec_command":
            "command"
        case "apply_patch":
            "patch"
        default:
            toolName
        }
    }

    private static func jsonObject(for line: String) -> [String: Any]? {
        codexRolloutJSONObject(for: line)
    }

    private static func parseTimestamp(_ string: String?) -> Date? {
        codexRolloutParseTimestamp(string)
    }
}

public final class CodexRolloutWatcher: @unchecked Sendable {
    private struct Observation {
        var target: CodexRolloutWatchTarget
        var offset: UInt64 = 0
        var pendingBuffer = Data()
        var snapshot = CodexRolloutSnapshot()
    }

    public var eventHandler: (@Sendable (AgentEvent) -> Void)?

    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "app.vibeisland.codex.rollout-watcher")
    private var timer: DispatchSourceTimer?
    private var observations: [String: Observation] = [:]

    public init(pollInterval: TimeInterval = 0.75) {
        self.pollInterval = pollInterval
    }

    deinit {
        stop()
    }

    public func sync(targets: [CodexRolloutWatchTarget]) {
        queue.sync {
            syncLocked(targets: targets)
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            observations.removeAll()
        }
    }

    private func syncLocked(targets: [CodexRolloutWatchTarget]) {
        let targetMap = Dictionary(uniqueKeysWithValues: targets.map { ($0.sessionID, $0) })

        observations = observations.reduce(into: [:]) { partialResult, pair in
            guard let updatedTarget = targetMap[pair.key] else {
                return
            }

            if pair.value.target == updatedTarget {
                partialResult[pair.key] = pair.value
            } else {
                partialResult[pair.key] = Observation(target: updatedTarget)
            }
        }

        for target in targets where observations[target.sessionID] == nil {
            observations[target.sessionID] = Observation(target: target)
        }

        if observations.isEmpty {
            timer?.cancel()
            timer = nil
            return
        }

        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in
                self?.pollLocked()
            }
            self.timer = timer
            timer.resume()
        }

        pollLocked()
    }

    private func pollLocked() {
        let sessionIDs = Array(observations.keys)

        for sessionID in sessionIDs {
            guard var observation = observations[sessionID] else {
                continue
            }

            let events = refresh(observation: &observation)
            observations[sessionID] = observation
            events.forEach { eventHandler?($0) }
        }
    }

    private func refresh(observation: inout Observation) -> [AgentEvent] {
        let fileURL = URL(fileURLWithPath: observation.target.transcriptPath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }

        defer {
            try? fileHandle.close()
        }

        let fileSize = (try? fileHandle.seekToEnd()) ?? 0
        if fileSize < observation.offset {
            observation.offset = 0
            observation.pendingBuffer.removeAll(keepingCapacity: false)
            observation.snapshot = CodexRolloutSnapshot()
        }

        do {
            try fileHandle.seek(toOffset: observation.offset)
            let data = try fileHandle.readToEnd() ?? Data()
            guard !data.isEmpty else {
                return []
            }

            observation.offset += UInt64(data.count)
            observation.pendingBuffer.append(data)

            let lines = completeLines(from: &observation.pendingBuffer)
            guard !lines.isEmpty else {
                return []
            }

            let oldSnapshot = observation.snapshot
            lines.forEach { CodexRolloutReducer.apply(line: $0, to: &observation.snapshot) }

            return CodexRolloutReducer.events(
                from: oldSnapshot,
                to: observation.snapshot,
                sessionID: observation.target.sessionID,
                transcriptPath: observation.target.transcriptPath
            )
        } catch {
            return []
        }
    }

    private func completeLines(from buffer: inout Data) -> [String] {
        let newline = UInt8(ascii: "\n")
        var lines: [String] = []

        while let newlineIndex = buffer.firstIndex(of: newline) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)

            guard !lineData.isEmpty else {
                continue
            }

            lines.append(String(decoding: lineData, as: UTF8.self))
        }

        return lines
    }
}

private func codexRolloutJSONObject(for line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        return nil
    }

    return dictionary
}

private func codexRolloutParseTimestamp(_ string: String?) -> Date? {
    guard let string else {
        return nil
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
}
