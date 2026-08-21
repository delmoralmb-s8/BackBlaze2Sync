import SwiftUI
import AppKit
import Sparkle

extension Notification.Name {
    /// Posted by the menu bar's "Nueva conexión B2…" command so ContentView (which owns the sheet's
    /// @State) can react without the App scene needing direct access to that state.
    static let bb2sNewConnection = Notification.Name("mx.smh.backblaze2sync.newConnection")
    /// Same idea for the Edición-menu "Mover/Copiar selección" commands, which need to reach
    /// ExplorerView's own @State selection. A @FocusedValue-based .disabled() was tried first and
    /// crashed AppKit (see the comment at its onReceive site), so this is the stable fallback.
    static let bb2sMoveSelection = Notification.Name("mx.smh.backblaze2sync.moveSelection")
    static let bb2sCopySelection = Notification.Name("mx.smh.backblaze2sync.copySelection")
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
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    @Environment(\.openWindow) private var openWindow

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
            // Replaces the default generic "About BackBlaze2Sync" with the same standard panel,
            // just adding a credits line, no custom window needed for something this simple.
            CommandGroup(replacing: .appInfo) {
                Button("Acerca de BackBlaze2Sync") {
                    showAboutPanel()
                }
                Button("Buscar actualizaciones…") {
                    updaterController.checkForUpdates(nil)
                }
            }
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
            // Reaches ExplorerView's own selection via NotificationCenter, the Commands closure
            // runs at the App scene, which has no direct access to that @State. Always enabled
            // (see ExplorerView's onReceive for why: a @FocusedValue-driven .disabled() here
            // crashed AppKit's menu system whenever the enabled state changed).
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Mover selección…") {
                    NotificationCenter.default.post(name: .bb2sMoveSelection, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Copiar selección…") {
                    NotificationCenter.default.post(name: .bb2sCopySelection, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            // openWindow(id:) alone only opens a plain new window and leaves tab-merging up to
            // the system's "Prefer tabs" setting, which defaults to not tabbing. Forcing it into
            // an actual tab regardless of that setting needs the AppKit call directly.
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Nueva pestaña") {
                    let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
                    let host = NSApp.keyWindow
                    openWindow(id: "main")
                    DispatchQueue.main.async {
                        guard let host,
                              let newWindow = NSApp.windows.first(where: { !existing.contains(ObjectIdentifier($0)) })
                        else { return }
                        host.addTabbedWindow(newWindow, ordered: .above)
                        newWindow.makeKeyAndOrderFront(nil)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            // Both just hand off to the system (browser / default Mail app), no in-app form to
            // build or maintain for a personal side project.
            CommandGroup(after: .help) {
                Divider()
                Button("Reportar un problema…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/delmoralmb-s8/BackBlaze2Sync/issues/new")!)
                }
                Button("Enviar comentarios por correo…") {
                    NSWorkspace.shared.open(URL(string: "mailto:delmoral.mb@gmail.com?subject=BackBlaze2Sync%20feedback")!)
                }
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

    /// Same standard macOS About panel every app gets for free, just with a credits line added,
    /// no reason to build a custom SwiftUI window for two lines of text and a link.
    private func showAboutPanel() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let credits = NSMutableAttributedString(
            string: "Hecho por Bernabe\n",
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
        )
        credits.append(NSAttributedString(
            string: "github.com/delmoralmb-s8/BackBlaze2Sync",
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .link: URL(string: "https://github.com/delmoralmb-s8/BackBlaze2Sync")!
            ]
        ))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
