import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var rclone: RcloneManager
    @EnvironmentObject var connectionStore: ConnectionStore
    @Environment(\.openWindow) private var openWindow

    @State private var confirmBeforeStart = true
    @State private var shutdownWhenDone = false

    @State private var showNewConnectionSheet = false
    @State private var newConnName = ""
    @State private var newConnRemoteName = ""
    @State private var newConnAccountID = ""
    @State private var newConnAppKey = ""
    @State private var newConnBucket = ""
    @State private var isCreatingConnection = false

    @State private var explorerExpanded = true
    @State private var optionsExpanded = false
    @State private var logExpanded = false
    @State private var errorsExpanded = false

    @AppStorage("appLanguageCode") private var appLanguageCode: String = "es"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                connectionBar

                Divider()

                DisclosureGroup(isExpanded: $explorerExpanded) {
                    ExplorerView(rclone: rclone, connection: connectionStore.active)
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

                DisclosureGroup(isExpanded: $optionsExpanded) {
                    optionsSection.padding(.top, 8)
                } label: {
                    Text("Opciones").font(.headline)
                }

                if let status = rclone.verifyStatusMessage {
                    Text(status)
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(status.hasPrefix("✅") ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Divider()

                DisclosureGroup(isExpanded: $logExpanded) {
                    logSection.padding(.top, 8)
                } label: {
                    Text("Log").font(.headline)
                }
            }
            .padding(20)
        }
        .onChange(of: rclone.logLines.count) { _, newCount in
            if newCount > 0 { logExpanded = true }
        }
        .onChange(of: rclone.failedOperations.count) { _, newCount in
            if newCount > 0 { errorsExpanded = true }
        }
        .frame(minWidth: 560, minHeight: 500)
        .sheet(isPresented: $showNewConnectionSheet) {
            newConnectionSheet
        }
    }

    // MARK: - Connection picker

    private var connectionBar: some View {
        HStack(spacing: 8) {
            // Deliberately OUTSIDE the Menu: macOS renders a Menu's whole label in one
            // monochrome tint, so a colored dot or icon placed inside it never shows its real color.
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .help("Conectado")

            Menu {
                ForEach(connectionStore.connections) { conn in
                    Button {
                        connectionStore.select(conn.id)
                    } label: {
                        if conn.id == connectionStore.activeID {
                            Label(conn.name, systemImage: "checkmark")
                        } else {
                            Text(conn.name)
                        }
                    }
                }
                Divider()
                Button("+ Nueva conexión B2…") {
                    newConnName = ""
                    newConnRemoteName = ""
                    newConnAccountID = ""
                    newConnAppKey = ""
                    newConnBucket = ""
                    showNewConnectionSheet = true
                }
            } label: {
                Label(connectionStore.active.name, systemImage: "archivebox.fill")
                    .font(.headline)
            }

            Text(connectionStore.active.remotePrefix)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Historial de operaciones") { openWindow(id: "history") }

            // ponytail: plain Picker writing straight to the @AppStorage key is all the
            // "language switcher" needs — BlackBlaze2SyncApp reads the same key and re-applies
            // .environment(\.locale) on change, so no extra plumbing lives here.
            Picker("", selection: $appLanguageCode) {
                Text("🇲🇽 ES").tag("es")
                Text("🇺🇸 EN").tag("en")
                Text("🇵🇹 PT").tag("pt")
                Text("🇫🇷 FR").tag("fr")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 78)
            .help("Idioma")
        }
    }

    private var newConnectionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nueva conexión B2").font(.headline)
            Text("Crea una conexión rclone con tus propias credenciales de Backblaze B2. Se guarda para poder elegirla después junto con \"\(ConnectionStore.defaultConnection.name)\".")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Nombre (como se muestra en la app)", text: $newConnName)
                .textFieldStyle(.roundedBorder)
            TextField("ID interno, sin espacios (ej. mib2-2)", text: $newConnRemoteName)
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
                              newConnRemoteName.trimmingCharacters(in: .whitespaces).isEmpty ||
                              newConnAccountID.trimmingCharacters(in: .whitespaces).isEmpty ||
                              newConnAppKey.isEmpty ||
                              newConnBucket.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func createConnection() {
        isCreatingConnection = true
        let name = newConnName.trimmingCharacters(in: .whitespaces)
        let remoteName = newConnRemoteName.trimmingCharacters(in: .whitespaces)
        let bucket = newConnBucket.trimmingCharacters(in: .whitespaces)
        rclone.createRemote(name: remoteName, accountID: newConnAccountID, appKey: newConnAppKey) { success in
            isCreatingConnection = false
            guard success else { return }
            B2CredentialsStore.save(B2Credentials(accountID: newConnAccountID, appKey: newConnAppKey), for: remoteName)
            connectionStore.addOrUpdate(Connection(name: name, remoteName: remoteName, bucket: bucket))
            showNewConnectionSheet = false
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Verificar integridad después de subir (compara tamaño local vs remoto)", isOn: $rclone.verifyAfterUpload)
            Toggle("Mostrar confirmación antes de iniciar", isOn: $confirmBeforeStart)
            Toggle("Apagar Mac cuando termine", isOn: $shutdownWhenDone)
                .disabled(true)
                .help("Pendiente de implementar, como pidió Bernabe para después")
        }
    }

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
        }
    }

    // MARK: - Errors (separate from the log — actionable failures with a retry button)

    private var errorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rclone.failedOperations) { failure in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(failure.type).font(.callout).bold()
                        Spacer()
                        Text(failure.date.formatted(date: .abbreviated, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(failure.summary)
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
                        Text(formattedLogText)
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

    private var formattedLogText: String {
        rclone.logLines
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
        panel.nameFieldStringValue = "BlackBlaze2Sync-log-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? formattedLogText.write(to: url, atomically: true, encoding: .utf8)
    }
}
