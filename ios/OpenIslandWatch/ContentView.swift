import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    var body: some View {
        NavigationStack {
            Group {
                if sessionManager.pendingEvents.isEmpty {
                    emptyState
                } else {
                    eventList
                }
            }
            .navigationTitle("Open Island")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("等待 Agent 事件")
                .font(.headline)

            Text(sessionManager.isPhoneReachable ? "iPhone 已连接" : "iPhone 未连接")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var eventList: some View {
        List(sessionManager.pendingEvents) { event in
            HStack(spacing: 8) {
                Image(systemName: iconName(for: event.message))
                    .foregroundStyle(iconColor(for: event.message))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: event.message))
                        .font(.headline)
                        .lineLimit(1)

                    Text(event.receivedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func iconName(for message: WatchMessage) -> String {
        switch message {
        case .permissionRequest: return "lock.shield"
        case .question: return "questionmark.circle"
        case .sessionCompleted: return "checkmark.seal"
        case .resolved: return "checkmark"
        }
    }

    private func iconColor(for message: WatchMessage) -> Color {
        switch message {
        case .permissionRequest: return .orange
        case .question: return .blue
        case .sessionCompleted: return .green
        case .resolved: return .secondary
        }
    }

    private func title(for message: WatchMessage) -> String {
        switch message {
        case .permissionRequest(let p): return p.title
        case .question(let q): return q.title
        case .sessionCompleted(let c): return c.summary
        case .resolved: return "已处理"
        }
    }
}
