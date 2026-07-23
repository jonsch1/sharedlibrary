import SwiftUI

@main
struct SharedLibraryMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var libraryStore = MobileLibraryStore()
    @StateObject private var speechPlayer = SpeechPlayer()

    var body: some Scene {
        WindowGroup {
            LibraryRootView()
                .environmentObject(libraryStore)
                .environmentObject(speechPlayer)
                .task {
                    await libraryStore.refreshIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await libraryStore.refreshIfNeeded(maximumAge: 60)
                    }
                }
        }
    }
}
