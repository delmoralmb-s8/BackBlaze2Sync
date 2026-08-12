import SwiftUI
import AppKit

// The AppIcon.appiconset shipped in the asset catalog only covers the light appearance — Xcode's
// newer adaptive .icon catalog format (which would let the OS swap this natively) didn't produce
// a usable app icon reference from Icon Composer's export on this Xcode version, so this swaps
// NSApp.applicationIconImage by hand instead, the same trick apps used before that format existed.
private final class AppearanceIconController {
    private var observation: NSKeyValueObservation?

    func start() {
        applyIcon(for: NSApp.effectiveAppearance)
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            self?.applyIcon(for: app.effectiveAppearance)
        }
    }

    private func applyIcon(for appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSApp.applicationIconImage = isDark ? NSImage(named: "AppIconDark") : nil
    }
}

@main
struct BackBlaze2SyncApp: App {
    @StateObject private var rclone = RcloneManager()
    @StateObject private var connectionStore = ConnectionStore()
    private let appearanceIconController = AppearanceIconController()

    // Same key ContentView's picker writes to — @AppStorage here re-runs `body` on change,
    // so every WindowGroup below re-applies `.environment(\.locale)` with the new value.
    @AppStorage("appLanguageCode") private var appLanguageCode: String = "es"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(rclone)
                .environmentObject(connectionStore)
                .environment(\.locale, Locale(identifier: appLanguageCode))
                .onAppear { appearanceIconController.start() }
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
