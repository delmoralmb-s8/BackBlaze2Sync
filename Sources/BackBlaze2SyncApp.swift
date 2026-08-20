import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by the menu bar's "Nueva conexión B2…" command so ContentView (which owns the sheet's
    /// @State) can react without the App scene needing direct access to that state.
    static let bb2sNewConnection = Notification.Name("mx.smh.backblaze2sync.newConnection")
}

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
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.explorerMenuActions) private var explorerMenuActions

    // Same key ContentView's picker writes to — @AppStorage here re-runs `body` on change,
    // so every WindowGroup below re-applies `.environment(\.locale)` with the new value.
    @AppStorage("appLanguageCode") private var appLanguageCode: String = "es"

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(rclone)
                .environmentObject(connectionStore)
                .environment(\.locale, Locale(identifier: appLanguageCode))
                .onAppear { appearanceIconController.start() }
        }
        .commands {
            // Mirrors what already exists as toolbar buttons in ContentView/ExplorerView, just
            // made reachable (and discoverable) from the menu bar too, next to "New Window".
            CommandGroup(after: .newItem) {
                Divider()
                Button("Nueva conexión B2…") {
                    NotificationCenter.default.post(name: .bb2sNewConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Historial de operaciones") {
                    openWindow(id: "history")
                }
            }
            // Reaches ExplorerView's own selection through ExplorerMenuActions (FocusedValue),
            // the Commands closure runs at the App scene, which has no direct access to it.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Mover selección…") {
                    explorerMenuActions?.moveSelection()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(explorerMenuActions?.hasSelection != true)
                Button("Copiar selección…") {
                    explorerMenuActions?.copySelection()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(explorerMenuActions?.hasSelection != true)
            }
            // Opens another instance of the main window, which macOS merges into a tab of the
            // existing one automatically when the system's tab preference allows it, same as
            // any other native window-per-WindowGroup SwiftUI app.
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Nueva pestaña") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("t", modifiers: .command)
            }
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
        // Wires the standard "Preferencias… ⌘," app-menu item to the same options already
        // reachable from the ⚙️ popover in ContentView, no custom Commands needed for this one.
        Settings {
            SettingsView()
                .environmentObject(rclone)
                .environment(\.locale, Locale(identifier: appLanguageCode))
                .padding(20)
                .frame(width: 380)
        }
    }
}
