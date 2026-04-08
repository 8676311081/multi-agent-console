import SwiftUI
import WatchKit

@main
struct OpenIslandWatchApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sessionManager = WatchSessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
        }
    }
}

final class AppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchSessionManager.shared.activate()
    }
}
