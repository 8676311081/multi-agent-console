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
    static let portDefaultsKey = "OpenIsland.LLMProxy.port"
    static let defaultPort: UInt16 = 9710

    private var server: LLMProxyServer
    let statsStore: LLMStatsStore
    let usageObserver: LLMUsageObserver
    private(set) var isRunning = false

    var port: UInt16 { server.configuration.port }

    init() {
        self.server = LLMProxyServer(configuration: Self.makeConfiguration())
        let store = LLMStatsStore()
        self.statsStore = store
        self.usageObserver = LLMUsageObserver(store: store)
    }

    static func makeConfiguration() -> LLMProxyConfiguration {
        let raw = UserDefaults.standard.integer(forKey: portDefaultsKey)
        let port: UInt16 = (raw > 0 && raw <= 65535) ? UInt16(raw) : defaultPort
        return LLMProxyConfiguration(port: port)
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

    /// Persist the new port and rebuild the underlying NWListener.
    /// Stops + restarts only if it was running; if the user manually
    /// stopped the proxy and edits the port, the next manual start
    /// picks up the new value.
    func setPort(_ newPort: UInt16) {
        UserDefaults.standard.set(Int(newPort), forKey: Self.portDefaultsKey)
        let wasRunning = isRunning
        if wasRunning { stop() }
        self.server = LLMProxyServer(configuration: LLMProxyConfiguration(port: newPort))
        if wasRunning { start() }
    }
}
