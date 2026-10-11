import SwiftUI

@main
@MainActor
struct Y3ClientApp: App {
    @StateObject private var browser = BrowserModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(browser: browser)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { browser.resumeDialogs() }
                }
        }
    }
}
