import Foundation
import OpenIslandCore
import os

/// Owns the lifecycle of `LLMProxyServer` from the app side, plus the
/// stats store + usage observer that live alongside it. Kept tiny on
/// purpose — server, store, and observer are all in Core, the UI
/// surfaces are in Views, this is just the wire between them.
@MainActor
final class LLMProxyCoordinator {
    private static let logger = Logger(subsystem: "app.openisland", category: "LLMProxyCoordinator")

    private let server: LLMProxyServer
    let statsStore: LLMStatsStore
    let usageObserver: LLMUsageObserver
    private(set) var isRunning = false

    var port: UInt16 { server.configuration.port }

    init(configuration: LLMProxyConfiguration = .default) {
        self.server = LLMProxyServer(configuration: configuration)
        let store = LLMStatsStore()
        self.statsStore = store
        self.usageObserver = LLMUsageObserver(store: store)
    }

    func start() {
        guard !isRunning else { return }
        server.setObserver(usageObserver)
        do {
            try server.start()
            isRunning = true
            Self.logger.info("LLM proxy started on port \(self.server.configuration.port)")
        } catch {
            Self.logger.error("LLM proxy failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        server.stop()
        isRunning = false
    }
}
