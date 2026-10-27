import SwiftUI

@main
struct ClaudeFilesAccessApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            model.sceneDidChange(to: phase)
        }
    }
}
