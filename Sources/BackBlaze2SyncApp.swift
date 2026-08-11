import SwiftUI

@main
struct BackBlaze2SyncApp: App {
    @StateObject private var rclone = RcloneManager()
    @StateObject private var connectionStore = ConnectionStore()

    // Same key ContentView's picker writes to — @AppStorage here re-runs `body` on change,
    // so every WindowGroup below re-applies `.environment(\.locale)` with the new value.
    @AppStorage("appLanguageCode") private var appLanguageCode: String = "es"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(rclone)
                .environmentObject(connectionStore)
                .environment(\.locale, Locale(identifier: appLanguageCode))
        }
        WindowGroup(id: "history") {
            HistoryView()
                .environmentObject(rclone)
                .environment(\.locale, Locale(identifier: appLanguageCode))
        }
        WindowGroup(id: "gallery", for: String.self) { $initialPath in
            GalleryView(initialPath: initialPath ?? "")
                .environmentObject(rclone)
                .environmentObject(connectionStore)
                .environment(\.locale, Locale(identifier: appLanguageCode))
        }
    }
}
