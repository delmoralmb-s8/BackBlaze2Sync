import SwiftUI
import AppKit

// Watches a local folder with FSEventStream and auto-uploads via RcloneManager's existing
// copy/upload queue — see project_watch_folder_plan memory for the agreed v1 scope.
struct WatchFolderView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var rclone: RcloneManager
    // .popover content doesn't reliably inherit an ancestor's .environment(\.locale, ...) on
    // macOS (it's presented via a separate NSPopover, not just nested in the same view tree) —
    // confirmed by Bernabe: switching the app language left this screen's popover stuck in
    // Spanish. Applied explicitly to the popover content below instead of assuming inheritance.
    @AppStorage("appLanguageCode") private var appLanguageCode: String = "es"

    /// First few real folders at the bucket root, offered as quick destination picks — fetched
    /// once when this view appears via the same side-channel listing ExplorerView's outline uses
    /// for on-demand children (listEntries), so it doesn't touch remoteEntries/pickerEntries.
    @State private var bucketRootFolders: [String] = []

    private var recentUploads: [OperationRecord] {
        guard let target = rclone.watchFolderTargetPath() else { return [] }
        return rclone.history.filter { $0.type == "Subida" && $0.remotePath == target }
    }

    @State private var showExistingFilesWarning = false
    @State private var existingFileCount = 0
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var showDescriptionPopover = false
    @State private var recentUploadsExpanded = false

    private var localFolderName: String {
        rclone.watchFolderPath.isEmpty ? "" : URL(fileURLWithPath: rclone.watchFolderPath).lastPathComponent
    }

    /// Built as `Text`, not `String` — a plain String handed to Text(_:) always renders
    /// verbatim (see HistoryView.detailLine's comment for the same gotcha), so the literal
    /// "(raíz del bucket)" phrasing would never localize if this returned String instead.
    private var destinationDisplayText: Text {
        if !rclone.watchFolderBucketDestination.isEmpty {
            return Text("\(rclone.watchFolderBucketDestination)/")
        }
        return localFolderName.isEmpty
            ? Text(LocalizedStringKey("(raíz del bucket)"))
            : Text(LocalizedStringKey("(raíz del bucket) → “\(localFolderName)/”"))
    }

    private var watchFolderCaption: Text {
        if rclone.watchFolderDeleteMirrorsToBucket {
            return Text("Lo que se agregue, modifique o borre en esa carpeta se refleja en “")
                + destinationDisplayText
                + Text("” en B2.")
        }
        return Text("Lo que se agregue o modifique en esa carpeta se sube a “")
            + destinationDisplayText
            + Text("” en B2. Si borras algo local, no se borra en B2.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Carpeta sincronizada").font(.headline)
                Button {
                    showDescriptionPopover = true
                } label: {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Qué es esto")
                .popover(isPresented: $showDescriptionPopover) {
                    Text("La carpeta sincronizada te permite elegir una carpeta de trabajo para subir automáticamente a tu cuenta de Backblaze B2 todos los archivos que coloques o modifiques en ella. Es de una sola dirección, desde tu Mac hacia tu nube B2, por default no borra nada en B2 si borras algo local, hay una casilla aparte para cambiar eso. Funciona mientras la app está abierta. El resultado de lo sincronizado se verá en el Historial.")
                        .font(.callout)
                        .padding()
                        .frame(width: 320)
                        .environment(\.locale, Locale(identifier: appLanguageCode))
                }
                Spacer()
                Toggle("Activo", isOn: $rclone.watchFolderActive)
                    .toggleStyle(.switch)
                    .disabled(rclone.watchFolderPath.isEmpty)
            }

            if rclone.watchFolderMissing {
                Label("La carpeta ya no existe (¿la renombraste o la borraste?). Elige otra o desactiva la sincronización.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Carpeta local")
                        Spacer()
                        Group {
                            if rclone.watchFolderPath.isEmpty {
                                Text("Ninguna elegida").foregroundStyle(.secondary)
                            } else {
                                Text(localFolderName)
                                    .foregroundStyle(.primary)
                                    .help(rclone.watchFolderPath)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Button("Elegir…") { chooseFolder() }
                    }
                    Divider()
                    HStack {
                        Text("Conexión B2")
                        Spacer()
                        Group {
                            if let name = connectionStore.active?.name {
                                Text(name)
                            } else {
                                Text("Ninguna")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Text("Destino en el bucket")
                        Spacer()
                        Menu {
                            Button {
                                rclone.watchFolderBucketDestination = ""
                            } label: {
                                if rclone.watchFolderBucketDestination.isEmpty {
                                    Label("Raíz del bucket (crear “\(localFolderName.isEmpty ? "…" : localFolderName)/”)", systemImage: "checkmark")
                                } else {
                                    Text("Raíz del bucket (crear “\(localFolderName.isEmpty ? "…" : localFolderName)/”)")
                                }
                            }
                            Divider()
                            ForEach(bucketRootFolders, id: \.self) { folder in
                                Button {
                                    rclone.watchFolderBucketDestination = folder
                                } label: {
                                    if rclone.watchFolderBucketDestination == folder {
                                        Label(folder, systemImage: "checkmark")
                                    } else {
                                        Text(folder)
                                    }
                                }
                            }
                            Divider()
                            Button {
                                newFolderName = ""
                                showNewFolderPrompt = true
                            } label: {
                                Label("Nueva carpeta…", systemImage: "folder.badge.plus")
                            }
                        } label: {
                            destinationDisplayText
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Divider()
                    Toggle("Borrar en B2 al borrar local", isOn: $rclone.watchFolderDeleteMirrorsToBucket)
                        .toggleStyle(.switch)
                        .help("Si borro un archivo en la carpeta local, también borrarlo en B2")
                }
                .padding(4)
            }
            .alert("Nueva carpeta en el bucket", isPresented: $showNewFolderPrompt) {
                TextField("Nombre de la carpeta", text: $newFolderName)
                Button("Crear") {
                    let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { rclone.watchFolderBucketDestination = trimmed }
                }
                Button("Cancelar", role: .cancel) {}
            }
            .alert("La carpeta ya tiene archivos", isPresented: $showExistingFilesWarning) {
                Button("Entendido") {}
            } message: {
                Text("Esta carpeta ya tiene \(existingFileCount) archivo(s). Al activarla, la subida a B2 comenzará de inmediato.")
            }

            watchFolderCaption
                .font(.caption)
                .foregroundStyle(.secondary)
                // Without this, Text's ideal width is "however wide it needs to be to stay on
                // one line" — with .windowResizability(.contentSize) on the window, THAT is what
                // was actually forcing the whole window wide, not the rows above. This is what
                // makes it wrap within the fixed 380pt frame below instead.
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation { recentUploadsExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: recentUploadsExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .font(.title2)
                    Text("Subidas automáticas recientes").font(.subheadline)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            if recentUploadsExpanded {
                if !rclone.watchFolderActive {
                    Text("Activa la carpeta sincronizada para empezar.")
                        .foregroundStyle(.secondary)
                } else if recentUploads.isEmpty {
                    Text("Sin subidas todavía.")
                        .foregroundStyle(.secondary)
                } else {
                    List(recentUploads) { record in
                        HStack {
                            Image(systemName: "icloud.and.arrow.up.fill").foregroundStyle(.blue)
                            if record.items.count == 1, let name = record.items.first?.id {
                                Text(name)
                            } else {
                                Text("\(record.fileCount) archivo(s)")
                            }
                            Spacer()
                            Text(record.date.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.system(size: 12.5))
                    }
                }
            }
        }
        .padding()
        // A fixed width, not just a minimum — with .windowResizability(.contentSize) on the
        // window, any un-bounded child (an un-wrapped long line, an over-wide menu label) could
        // otherwise push the window's ideal width past whatever minWidth alone asked for. Pinning
        // it here is what actually keeps the window this narrow now that the caption text and
        // menu label are set to wrap/truncate instead of demanding their own full width.
        .frame(width: 380)
        .onAppear {
            guard let prefix = connectionStore.active?.remotePrefix else { return }
            rclone.listEntries(path: prefix) { entries in
                bucketRootFolders = entries.filter(\.IsDir).prefix(4).map(\.Name)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            rclone.watchFolderPath = url.path
            // A newly picked folder always defaults back to the bucket root (creates
            // "<folderName>/" there) — without this, whatever destination was chosen for a
            // PREVIOUS folder stuck around and got reused for this unrelated one. The bucket-
            // folder suggestions menu itself is untouched, still offered as an option to pick.
            rclone.watchFolderBucketDestination = ""
            // Picking a folder here IS the "start syncing this" action — without this, choosing
            // a replacement folder (e.g. after "La carpeta ya no existe") left Activo exactly as
            // it was, which defaults to off on every launch, so nothing actually uploaded until
            // the user also separately remembered to flip Activo back on themselves.
            rclone.watchFolderActive = true
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            if count > 0 {
                existingFileCount = count
                showExistingFilesWarning = true
            }
        }
    }
}
