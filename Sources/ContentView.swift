import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// "Oscilación" (wiggle), repeating every 3s while `isActive` — `.wiggle` itself needs
    /// macOS 15+ (this app's deployment target is 14.0), so this just quietly skips the
    /// animation on older systems instead of failing to build.
    @ViewBuilder
    func wiggleWhenActive(_ isActive: Bool) -> some View {
        if #available(macOS 15.0, *) {
            self.symbolEffect(.wiggle, options: .repeat(.periodic(delay: 2)), isActive: isActive)
        } else {
            self
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var rclone: RcloneManager
    @EnvironmentObject var connectionStore: ConnectionStore
    @Environment(\.openWindow) private var openWindow

    @State private var showNewConnectionSheet = false
    @State private var newConnName = ""
    @State private var newConnAccountID = ""
    @State private var newConnAppKey = ""
    @State private var newConnBucket = ""
    @State private var isCreatingConnection = false
    @State private var connectionErrorMessage: String?
    @State private var showDisconnectConfirm = false
    @State private var showRenameConnectionPrompt = false
    @State private var renameConnectionText = ""

    @State private var explorerExpanded = true
    @State private var showOptionsPopover = false
    @State private var logExpanded = false
    @State private var errorsExpanded = false
    @State private var pendingUploadsExpanded = false

    @AppStorage("appLanguageCode") private var appLanguageCode: String = "es"

    // Names stay in each language's own tongue on purpose, regardless of appLanguageCode.
    private static let languageOptions: [(code: String, short: String, name: String)] = [
        ("es", "ES", "Español"),
        ("en", "EN", "English"),
        ("pt", "PT", "Português"),
        ("fr", "FR", "Français"),
    ]

    var body: some View {
        if rclone.rclonePath == nil {
            rcloneMissingView
        } else {
            mainBody
        }
    }

    private var mainBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                connectionBar

                Divider()

                if let active = connectionStore.active {
                    DisclosureGroup(isExpanded: $explorerExpanded) {
                        ExplorerView(rclone: rclone, connection: active)
                            .padding(.top, 8)
                    } label: {
                        Text("Explorador B2").font(.headline)
                    }

                    progressSection

                    Divider()

                    if !rclone.failedOperations.isEmpty {
                        DisclosureGroup(isExpanded: $errorsExpanded) {
                            errorsSection.padding(.top, 8)
                        } label: {
                            Text("Errores (\(rclone.failedOperations.count))")
                                .font(.headline)
                                .foregroundStyle(.red)
                        }

                        Divider()
                    }

                    if !rclone.pendingUploads.isEmpty {
                        DisclosureGroup(isExpanded: $pendingUploadsExpanded) {
                            pendingUploadsSection.padding(.top, 8)
                        } label: {
                            Text("En cola (\(rclone.pendingUploads.count))")
                                .font(.headline)
                        }

                        Divider()
                    }

                    if let status = rclone.verifyStatusMessage {
                        Label {
                            Text(status)
                        } icon: {
                            Image(systemName: rclone.verifyStatusSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(rclone.verifyStatusSuccess ? .green : .orange)
                        }
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(rclone.verifyStatusSuccess ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Divider()

                    DisclosureGroup(isExpanded: $logExpanded) {
                        logSection.padding(.top, 8)
                    } label: {
                        Text("Log").font(.headline)
                    }
                } else {
                    disconnectedView
                }
            }
            .padding(20)
        }
        .onChange(of: rclone.failedOperations.count) { _, newCount in
            if newCount > 0 { errorsExpanded = true }
        }
        // Menu bar's "Nueva conexión B2…" lives in the App scene's Commands, outside this view's
        // state, a notification is the lightest way to reach showNewConnectionSheet from there.
        .onReceive(NotificationCenter.default.publisher(for: .bb2sNewConnection)) { _ in
            showNewConnectionSheet = true
        }
        .frame(minWidth: 560, minHeight: 500)
        .sheet(isPresented: $showNewConnectionSheet) {
            newConnectionSheet
                .environment(\.locale, Locale(identifier: appLanguageCode))
        }
        .onAppear {
            // Fires once per launch (not on every re-render) — this is what makes "última vez que
            // se abrió la app y se conectó" show up in the history at all: reconnecting to the
            // persisted active connection on launch never went through select()/addOrUpdate(),
            // so it was invisible to the history before this.
            if let active = connectionStore.active {
                rclone.recordConnectionEvent(connected: true, name: connectionLabel(active))
            }
            // Forced regardless of whether this is a fresh detection or one already known from a
            // previous session — every time you open the app with a broken watch folder, you
            // should be told, not just the one time it first happened.
            if rclone.refreshWatchFolderMissingState() {
                rclone.showWatchFolderMissingAlert = true
            }
            // "Activo" is persisted (see RcloneManager), so this is what actually resumes the
            // watcher on launch — and since startWatchFolder() re-scans the folder's current
            // contents right away, it also catches up on anything added while the app was closed.
            rclone.resumeWatchFolderIfNeeded()
        }
        .alert("Carpeta sincronizada no encontrada", isPresented: $rclone.showWatchFolderMissingAlert) {
            Button("Ir a Carpeta sincronizada") { openWindow(id: "watchfolder") }
            Button("Después", role: .cancel) {}
        } message: {
            Text("La carpeta que elegiste para sincronizar ya no existe (¿la renombraste o la borraste?). Elige otra desde Carpeta sincronizada para seguir subiendo cambios.")
        }
        .sheet(isPresented: Binding(
            get: { rclone.shutdownCountdown != nil },
            set: { if !$0 { rclone.cancelShutdownCountdown() } }
        )) {
            shutdownCountdownSheet
        }
    }

    private var shutdownCountdownSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "power.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            (Text("Apagando la Mac en ") + Text("\(rclone.shutdownCountdown ?? 0)s"))
                .font(.title3.bold())
            Text("La operación terminó y tienes activado \"Apagar Mac cuando termine\".")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancelar") { rclone.cancelShutdownCountdown() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(30)
        .frame(width: 320)
        .environment(\.locale, Locale(identifier: appLanguageCode))
    }

    // MARK: - rclone missing

    private var rcloneMissingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("No se encontró rclone")
                    .font(.title3.bold())
                Text("BackBlaze2Sync necesita rclone instalado para funcionar. Son dos comandos, una sola vez, en la app Terminal de tu Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            if !rclone.hasHomebrew {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paso 1: instalar Homebrew (gestor de paquetes de macOS)")
                        .font(.callout.bold())
                    commandRow("/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
                    Text("Te va a pedir tu contraseña de Mac: es normal, Homebrew la necesita para instalarse.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paso 2: instalar rclone")
                        .font(.callout.bold())
                    commandRow("brew install rclone")
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instalar rclone (ya tienes Homebrew)")
                        .font(.callout.bold())
                    commandRow("brew install rclone")
                }
            }

            Button("Ya lo instalé, verificar de nuevo") { rclone.recheckDependencies() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: 460, minHeight: 300)
        .padding(40)
    }

    @State private var copiedCommand: String?

    private func commandRow(_ command: String) -> some View {
        HStack {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedCommand = command
            } label: {
                Label(LocalizedStringKey(copiedCommand == command ? "Copiado" : "Copiar"), systemImage: copiedCommand == command ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Empty state (no active connection)

    private var disconnectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No hay ninguna conexión activa")
                .font(.title3.bold())
            Text("Crea una conexión con tus credenciales de Backblaze B2 para poder explorar un bucket.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                newConnName = ""
                newConnAccountID = ""
                newConnAppKey = ""
                newConnBucket = ""
                connectionErrorMessage = nil
                showNewConnectionSheet = true
            } label: {
                Label("+ Nueva conexión B2…", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(40)
    }

    // MARK: - Connection picker

    private var connectionBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let active = connectionStore.active {
                    // Deliberately OUTSIDE the Menu: macOS renders a Menu's whole label in one
                    // monochrome tint, so a colored dot or icon placed inside it never shows its real color.
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .help("Conectado")

                    // Everything besides "switch to this connection" (rename/new/disconnect)
                    // lives in this same menu now, below a Divider — one compact control instead
                    // of four separate buttons crowding the bar.
                    Menu {
                        ForEach(connectionStore.connections) { conn in
                            Button {
                                let wasAlreadyActive = conn.id == connectionStore.activeID
                                connectionStore.select(conn.id)
                                if !wasAlreadyActive { rclone.recordConnectionEvent(connected: true, name: connectionLabel(conn)) }
                            } label: {
                                if conn.id == connectionStore.activeID {
                                    Label(conn.name, systemImage: "checkmark")
                                } else {
                                    Text(conn.name)
                                }
                            }
                        }

                        Divider()

                        Button {
                            renameConnectionText = active.name
                            showRenameConnectionPrompt = true
                        } label: {
                            Label("Renombrar…", systemImage: "pencil")
                        }

                        Button {
                            newConnName = ""
                            newConnAccountID = ""
                            newConnAppKey = ""
                            newConnBucket = ""
                            connectionErrorMessage = nil
                            showNewConnectionSheet = true
                        } label: {
                            Label("+ Nueva conexión B2…", systemImage: "plus.circle.fill")
                        }

                        Button(role: .destructive) {
                            showDisconnectConfirm = true
                        } label: {
                            Label("Desconectar", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Label(active.name, systemImage: "archivebox.fill")
                            .font(.headline)
                    }
                    .alert("Renombrar conexión", isPresented: $showRenameConnectionPrompt) {
                        TextField("Nombre", text: $renameConnectionText)
                        Button("Renombrar") { renameActiveConnection() }
                        Button("Cancelar", role: .cancel) {}
                    }
                    .confirmationDialog(
                        "¿Desconectar esta conexión?",
                        isPresented: $showDisconnectConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Desconectar", role: .destructive) { disconnectActive() }
                        Button("Cancelar", role: .cancel) {}
                    } message: {
                        Text("Se olvidan sus credenciales guardadas. Tendrás que volver a capturarlas si quieres reconectarte a esta cuenta o bucket.")
                    }
                } else {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                        .help("Desconectado")
                    Text("Sin conexión activa")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showOptionsPopover = true
                } label: {
                    Label("Opciones avanzadas", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help("Opciones avanzadas")
                .popover(isPresented: $showOptionsPopover) {
                    SettingsView()
                        .padding(16)
                        .frame(width: 320)
                        .environment(\.locale, Locale(identifier: appLanguageCode))
                }

                Button {
                    openWindow(id: "history")
                    rclone.recentWatchFolderUpload = false
                } label: {
                    Label("Historial de operaciones", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                        // Wiggles once a Carpeta sincronizada upload lands, so you notice there's
                        // something new to see without having to keep this window open — stops
                        // as soon as you actually open History (see the button action above).
                        .wiggleWhenActive(rclone.recentWatchFolderUpload)
                }
                .help("Historial de operaciones")

                Button {
                    openWindow(id: "stats")
                } label: {
                    Label("Estadísticas", systemImage: "chart.bar.fill")
                        .labelStyle(.iconOnly)
                }
                .help("Estadísticas")

                // ponytail: .help() never shows up on Picker(.menu) rows on macOS — SwiftUI turns
                // them into plain NSMenuItems, which don't wire up tooltips. A Menu of Buttons
                // lets each row show its own full language name directly instead, no hover needed.
                Menu {
                    ForEach(Self.languageOptions, id: \.code) { option in
                        Button {
                            appLanguageCode = option.code
                        } label: {
                            if appLanguageCode == option.code {
                                Label("\(option.short)  \(option.name)", systemImage: "checkmark")
                            } else {
                                Text("\(option.short)  \(option.name)")
                            }
                        }
                    }
                } label: {
                    Text(appLanguageCode.uppercased())
                }
                .frame(width: 78)
                .help("Idioma")
            }

            if let active = connectionStore.active {
                Text("\(active.remoteName)_\(active.bucket)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
    }

    private var newConnectionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nueva conexión B2").font(.headline)
            Text("Crea una conexión rclone con tus propias credenciales de Backblaze B2. Se guarda para poder elegirla después junto con \"\(ConnectionStore.defaultConnection.name)\".")
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("Where do I get this?") {
                keyMappingDiagram.padding(.top, 6)
            }
            .font(.caption)

            TextField("Nombre (como se muestra en la app)", text: $newConnName)
                .textFieldStyle(.roundedBorder)
            TextField("Key ID / Account ID de B2", text: $newConnAccountID)
                .textFieldStyle(.roundedBorder)
            SecureField("Application Key de B2", text: $newConnAppKey)
                .textFieldStyle(.roundedBorder)
            TextField("Nombre del bucket", text: $newConnBucket)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancelar") { showNewConnectionSheet = false }
                Spacer()
                if isCreatingConnection { ProgressView().controlSize(.small) }
                Button("Conectar") { createConnection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreatingConnection ||
                              newConnName.trimmingCharacters(in: .whitespaces).isEmpty ||
                              newConnAccountID.trimmingCharacters(in: .whitespaces).isEmpty ||
                              newConnAppKey.isEmpty ||
                              newConnBucket.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .alert(
            "No se pudo conectar",
            isPresented: Binding(
                get: { connectionErrorMessage != nil },
                set: { if !$0 { connectionErrorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            // A plain String never auto-localizes through Text(_:) — LocalizedStringKey(_:)
            // forces the catalog lookup for the small set of known messages friendlyErrorMessage
            // returns; unrecognized rclone text (no matching key) just falls through verbatim.
            Text(LocalizedStringKey(connectionErrorMessage ?? ""))
        }
    }

    /// Schematic (no real screenshot, so it never goes stale if Backblaze redesigns its site)
    /// mapping the field names shown on Backblaze's "Application Keys" page to this form's fields.
    /// Kept in English regardless of app language — Backblaze's own field names are always
    /// English, and this is reference material, not interface copy (same call as the fixed
    /// "DELETE" confirmation word in the Gallery).
    private var keyMappingDiagram: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On Backblaze's page where you create the key (\"Application Keys\"):")
                .font(.caption2)
                .foregroundStyle(.secondary)
            keyMappingRow(b2Label: "keyID", appLabel: "Key ID / Account ID")
            keyMappingRow(b2Label: "applicationKey", appLabel: "Application Key")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func keyMappingRow(b2Label: String, appLabel: String) -> some View {
        HStack(spacing: 8) {
            Text(b2Label)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(appLabel)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    /// rclone needs a short internal remote name per connection, but that's a plumbing detail —
    /// the user only ever types the display name, so we derive a unique slug from it here instead
    /// of asking them to invent one.
    private func generateRemoteName(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let base = folded.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let root = base.isEmpty ? "b2" : base
        let existing = Set(connectionStore.connections.map(\.remoteName))
        var candidate = root
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(root)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// "Display name (bucket)" — the display name alone doesn't say which actual bucket it
    /// points at, and Bernabe names connections after himself/projects, not after buckets.
    private func connectionLabel(_ connection: Connection) -> String {
        "\(connection.name) (\(connection.bucket))"
    }

    private func disconnectActive() {
        guard let target = connectionStore.active else { return }
        connectionStore.remove(target.id)
        rclone.deleteRemote(name: target.remoteName) { _ in }
        B2CredentialsStore.delete(for: target.remoteName)
        rclone.recordConnectionEvent(connected: false, name: connectionLabel(target))
    }

    private func renameActiveConnection() {
        guard let active = connectionStore.active else { return }
        connectionStore.rename(active.id, to: renameConnectionText)
    }

    private func createConnection() {
        isCreatingConnection = true
        connectionErrorMessage = nil
        let name = newConnName.trimmingCharacters(in: .whitespaces)
        let remoteName = generateRemoteName(from: name)
        let bucket = newConnBucket.trimmingCharacters(in: .whitespaces)
        let accountID = newConnAccountID
        let appKey = newConnAppKey
        rclone.createRemote(name: remoteName, accountID: accountID, appKey: appKey) { success in
            guard success else {
                isCreatingConnection = false
                connectionErrorMessage = "No se pudo crear la conexión. Inténtalo de nuevo."
                return
            }
            // createRemote only writes rclone's config file — it never talks to Backblaze, so a
            // wrong Key ID/Application Key or bucket name "succeeds" here and would otherwise only
            // fail later, confusingly, the first time the Explorer tries to list something. This
            // validates for real before accepting the connection, and cleans up after itself if
            // it turns out to be bad.
            rclone.validateConnection(remoteName: remoteName, bucket: bucket) { errorMessage in
                isCreatingConnection = false
                if let errorMessage {
                    rclone.deleteRemote(name: remoteName) { _ in }
                    connectionErrorMessage = errorMessage
                    return
                }
                B2CredentialsStore.save(B2Credentials(accountID: accountID, appKey: appKey), for: remoteName)
                connectionStore.addOrUpdate(Connection(name: name, remoteName: remoteName, bucket: bucket))
                rclone.recordConnectionEvent(connected: true, name: "\(name) (\(bucket))")
                showNewConnectionSheet = false
            }
        }
    }

    // MARK: - Options

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: rclone.percent, total: 100)
            HStack {
                Text("\(Int(rclone.percent))%")
                if !rclone.speed.isEmpty { Text(rclone.speed) }
                if !rclone.eta.isEmpty { Text("ETA \(rclone.eta)") }
                Button("Cancelar") { rclone.cancel() }
                    .controlSize(.small)
                    .disabled(!rclone.isRunning)
                    // ponytail: ternary-of-literals passed to .help(_:) resolves to the verbatim
                    // String overload, not LocalizedStringKey — wrapping explicitly is the fix.
                    .help(rclone.isRunning ? LocalizedStringKey("Cancelar la operación en curso") : LocalizedStringKey("No hay ninguna operación en curso"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Mini-log: the latest MEANINGFUL message only (never the raw --stats noise, see
            // RcloneManager.lastMessage), overwritten in place on this one line — for someone who
            // wants a sense of what's happening without opening the full Log below.
            if !rclone.lastMessage.isEmpty {
                Text(rclone.lastMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // MARK: - Errors (separate from the log — actionable failures with a retry button)

    private var errorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rclone.failedOperations) { failure in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(LocalizedStringKey(failure.type)).font(.callout).bold()
                        Spacer()
                        Text(failure.date.formatted(date: .abbreviated, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    failure.summary
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Descartar") { rclone.dismissFailedOperation(failure.id) }
                        Button("Reintentar") { failure.retry() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Pending uploads (queued while another upload was already running)

    private var pendingUploadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rclone.pendingUploads) { pending in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Subida en cola", systemImage: "clock.badge.checkmark")
                            .font(.callout)
                            .bold()
                        Spacer()
                        Text(pending.date.formatted(date: .abbreviated, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    pending.summary
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancelar") { rclone.dismissPendingUpload(pending.id) }
                    }
                }
                .padding(10)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button("Limpiar log") { rclone.logLines.removeAll() }
                    .disabled(rclone.logLines.isEmpty)
                Button("Exportar como .txt…") { exportLogAsText() }
                    .disabled(rclone.logLines.isEmpty)
                Button("Copiar log") { copyLogToClipboard() }
                    .disabled(rclone.logLines.isEmpty)
            }
            // A single continuous Text (not one per line) so drag-selecting or Cmd+A spans the
            // whole log — SwiftUI's per-view textSelection only lets you select inside ONE Text
            // at a time, which is why selecting by hand only ever grabbed a single line before.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(visibleLogText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                }
                .onChange(of: rclone.logLines.count) {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // A long transfer (--stats 1s, one file line per item actively transferring) can pile up
    // thousands of lines in minutes — SwiftUI has to re-lay-out this WHOLE Text on every update
    // since a plain ScrollView isn't lazy like a List, so a giant single Text got measurably
    // slower (and felt like the window was about to hang) the longer a transfer ran. Rendering
    // only the tail keeps that cost constant regardless of how long the log has gotten — "Copiar
    // log"/"Exportar .txt" still use the full, uncapped history (formattedLogText below).
    private static let visibleLogLineCount = 400

    private var visibleLogText: String {
        Self.formatted(rclone.logLines.suffix(Self.visibleLogLineCount))
    }

    private var formattedLogText: String {
        Self.formatted(rclone.logLines)
    }

    private static func formatted(_ lines: some Sequence<LogLine>) -> String {
        lines
            .map { "[\($0.timestamp.formatted(date: .omitted, time: .standard))] \($0.text)" }
            .joined(separator: "\n")
    }

    private func copyLogToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formattedLogText, forType: .string)
    }

    /// A single Save panel defaulting straight to ~/Downloads with a ready-made filename — the
    /// user just confirms, no folder picking needed for the common case.
    private func exportLogAsText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "BackBlaze2Sync-log-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? formattedLogText.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The Options content, pulled out of ContentView so it can back both the quick popover (⚙️ in the
/// connection bar) and the real macOS Preferences window (⌘,, wired via a Settings scene).
struct SettingsView: View {
    @EnvironmentObject var rclone: RcloneManager
    @State private var showParallelTransfersHelp = false
    // .popover content doesn't reliably inherit an ancestor's .environment(\.locale, ...) on
    // macOS (it's presented via a separate NSPopover, not just nested in the same view tree) —
    // same gotcha already worked around for every .sheet/.popover elsewhere in this app, applied
    // explicitly below instead of assuming inheritance.
    @AppStorage("appLanguageCode") private var appLanguageCode: String = "es"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Verificar integridad después de subir (compara tamaño local vs remoto)", isOn: $rclone.verifyAfterUpload)
            Toggle("Apagar Mac cuando termine", isOn: $rclone.shutdownWhenDone)
                .help("Pide confirmación antes de apagar de verdad, no se apaga solo sin avisar")

            Divider()

            Toggle("Carpeta sincronizada activa", isOn: $rclone.watchFolderActive)
                .disabled(rclone.watchFolderPath.isEmpty)
                .help("Sube automáticamente lo que cambie en la carpeta elegida en “Carpeta sincronizada…”")
            Toggle("Borrar en el bucket lo que se borre en la carpeta local", isOn: $rclone.watchFolderDeleteMirrorsToBucket)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Límite de velocidad")
                HStack {
                    Slider(value: $rclone.bandwidthLimitMBps, in: 0...200, step: 5)
                    // ponytail: ternary-of-literals passed to Text(_:) resolves to the verbatim
                    // String overload, not LocalizedStringKey — wrapping both branches is the fix.
                    Text(rclone.bandwidthLimitMBps > 0 ? LocalizedStringKey("\(Int(rclone.bandwidthLimitMBps)) MB/s") : LocalizedStringKey("Sin límite"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Transferencias en paralelo")
                    // A hover-only tooltip wasn't discoverable, and hover itself feels unreliable
                    // on a trackpad, so this is a real click target that pops the explanation up
                    // on demand instead of waiting for a hover that may never register.
                    Button {
                        showParallelTransfersHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showParallelTransfersHelp) {
                        Text("Súbelo con conexión rápida y muchos archivos chicos; bájalo en wifi débil o compartido. 4 es un buen default.")
                            .font(.callout)
                            .padding()
                            .frame(width: 260)
                            .environment(\.locale, Locale(identifier: appLanguageCode))
                    }
                }
                Stepper(value: $rclone.parallelTransfers, in: 1...16) {
                    Text("\(rclone.parallelTransfers)")
                }
            }
        }
    }
}
