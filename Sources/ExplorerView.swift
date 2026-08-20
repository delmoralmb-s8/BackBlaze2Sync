import SwiftUI
import UniformTypeIdentifiers

enum ExplorerViewMode: String {
    case icons, list
}

enum TransferMode {
    case move, copy
}

enum FolderPromptTarget {
    case explorer, picker
}

struct PathInfo {
    let name: String
    let isDir: Bool
    let size: Int64
}

/// Bundles the callbacks an `ExplorerNodeRow` needs, so the recursive view doesn't
/// carry half a dozen separate closure parameters at every nesting level.
struct ExplorerRowContext {
    let isSelected: (String) -> Bool
    let selectItem: (String, Bool, Bool) -> Void  // path, additive (Cmd held), rangeExtend (Shift held)
    let toggleExpand: (ExplorerNode) -> Void
    let navigateInto: (ExplorerNode) -> Void
    let iconName: (String) -> String
    let typeText: (String, Bool) -> String  // filename, isDir
    let formattedSize: (Int64) -> String
    let megabytesText: (Int64) -> String
    let formattedModTime: (String?) -> String
    /// Fetches a folder's total size lazily (only called for rows the tree actually renders) —
    /// same "on demand, not up front" trade-off as the Explorer's existing "Ver tamaño" sheet,
    /// since it's a real recursive `rclone size` call per folder, not free.
    let folderSizeText: (String) async -> String
    let contextMenu: (RemotePathItem) -> AnyView
    let onDrop: (ExplorerNode, [NSItemProvider]) -> Bool
    let onDrag: (ExplorerNode) -> NSItemProvider
    let isDropTarget: (String) -> Bool
    let setDropTarget: (String, Bool) -> Void
}

/// One row of the "vista desplegable" (Finder List View), recursing into its children when expanded.
struct ExplorerNodeRow: View {
    static let typeColumnWidth: CGFloat = 110
    static let sizeColumnWidth: CGFloat = 80
    static let modColumnWidth: CGFloat = 130

    @ObservedObject var node: ExplorerNode
    let ctx: ExplorerRowContext

    @State private var folderSizeText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Spacer().frame(width: CGFloat(node.depth) * 16)
                if node.entry.IsDir {
                    Button { ctx.toggleExpand(node) } label: {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 14)
                }
                Image(systemName: node.entry.IsDir ? "folder.fill" : ctx.iconName(node.entry.Name))
                    .foregroundStyle(node.entry.IsDir ? .orange : .secondary)
                    .frame(width: 20)
                Text(node.entry.Name).lineLimit(1)
                Spacer()
                Text(ctx.typeText(node.entry.Name, node.entry.IsDir))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.typeColumnWidth, alignment: .trailing)
                Group {
                    if node.entry.IsDir {
                        Text(folderSizeText ?? "…")
                    } else {
                        Text(ctx.megabytesText(node.entry.Size))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.sizeColumnWidth, alignment: .trailing)
                Text(ctx.formattedModTime(node.entry.ModTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.modColumnWidth, alignment: .trailing)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(ctx.isSelected(node.fullPath) ? Color.accentColor.opacity(0.25) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: node.entry.IsDir && ctx.isDropTarget(node.fullPath) ? 2 : 0)
            )
            .onTapGesture(count: 2) {
                if node.entry.IsDir { ctx.navigateInto(node) }
            }
            .onTapGesture(count: 1) {
                ctx.selectItem(node.fullPath, NSEvent.modifierFlags.contains(.command), NSEvent.modifierFlags.contains(.shift))
            }
            .contextMenu {
                ctx.contextMenu(RemotePathItem(path: node.fullPath, name: node.entry.Name, isDir: node.entry.IsDir))
            }
            .task(id: node.fullPath) {
                guard node.entry.IsDir else { return }
                folderSizeText = await ctx.folderSizeText(node.fullPath)
            }
            .onDrag { ctx.onDrag(node) }
            .onDrop(
                of: [.fileURL, .plainText],
                isTargeted: Binding(
                    get: { ctx.isDropTarget(node.fullPath) },
                    set: { ctx.setDropTarget(node.fullPath, $0) }
                )
            ) { providers in
                guard node.entry.IsDir else { return false }
                return ctx.onDrop(node, providers)
            }

            if node.isExpanded {
                if node.isLoadingChildren {
                    HStack {
                        Spacer().frame(width: CGFloat(node.depth + 1) * 16 + 20)
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                } else if node.children.isEmpty {
                    HStack {
                        Spacer().frame(width: CGFloat(node.depth + 1) * 16 + 20)
                        Text("(vacío)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    ForEach(node.children) { child in
                        ExplorerNodeRow(node: child, ctx: ctx)
                    }
                }
            }
        }
    }
}

/// Folder-only tree row for the move/copy destination picker. Simpler than `ExplorerNodeRow`:
/// no multi-selection, no context menu, no drag & drop — a single click just targets that
/// folder as the destination, while the triangle (or a double click) reveals its subfolders.
struct PickerNodeRow: View {
    @ObservedObject var node: ExplorerNode
    let isTarget: (String) -> Bool
    let onTarget: (ExplorerNode) -> Void
    let onToggleExpand: (ExplorerNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Spacer().frame(width: CGFloat(node.depth) * 16)
                Button { onToggleExpand(node) } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                Image(systemName: "folder.fill").foregroundStyle(.orange).frame(width: 20)
                Text(node.entry.Name).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(isTarget(node.fullPath) ? Color.accentColor.opacity(0.25) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onTapGesture(count: 2) { onToggleExpand(node) }
            .onTapGesture(count: 1) { onTarget(node) }

            if node.isExpanded {
                if node.isLoadingChildren {
                    HStack {
                        Spacer().frame(width: CGFloat(node.depth + 1) * 16 + 20)
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                } else if node.children.isEmpty {
                    HStack {
                        Spacer().frame(width: CGFloat(node.depth + 1) * 16 + 20)
                        Text("(sin subcarpetas)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    ForEach(node.children) { child in
                        PickerNodeRow(node: child, isTarget: isTarget, onTarget: onTarget, onToggleExpand: onToggleExpand)
                    }
                }
            }
        }
    }
}

struct ExplorerView: View {
    @ObservedObject var rclone: RcloneManager
    let connection: Connection
    @Environment(\.openWindow) private var openWindow
    // Sheets don't reliably inherit the .locale set on the WindowGroup's content on macOS, so
    // every .sheet here reapplies it explicitly — same pattern as BackBlaze2SyncApp's WindowGroups.
    @AppStorage("appLanguageCode") private var appLanguageCode: String = "es"

    /// A finished upload/download, shown as a confirmation alert. `titleKey` is a fixed,
    /// localizable phrase ("Descarga completada"/"Subida completada"); `detail` (a filename or
    /// "N elemento(s)") is shown verbatim since names/counts are never translated. `revealURL` is
    /// only set for downloads — there's nothing local to reveal for an upload.
    private struct OperationCompletion: Identifiable {
        let id = UUID()
        let titleKey: String
        let detail: String
        let revealURL: URL?
    }
    @State private var completionAlert: OperationCompletion?
    /// Pulled out of the `.alert` call itself — same type-checker timeout as `moveConfirmTitle`.
    private var showCompletionAlert: Binding<Bool> {
        Binding(get: { completionAlert != nil }, set: { if !$0 { completionAlert = nil } })
    }

    @State private var browsePath = ""
    @State private var pathInput = ""
    @State private var backStack: [String] = []
    @State private var forwardStack: [String] = []
    @State private var viewMode: ExplorerViewMode = .list

    enum ListSortColumn { case name, type, size, modified }
    @State private var sortColumn: ListSortColumn = .name
    @State private var sortAscending = true
    // ponytail: reflects "last bulk action taken via this button", not a live re-derivation of
    // every node's isExpanded — the latter doesn't trigger a re-render here since ExplorerView
    // doesn't subscribe to individual ExplorerNode publishers, which was the original bug.
    @State private var topLevelExpanded = false

    @State private var pathRegistry: [String: PathInfo] = [:]
    @State private var selectedPaths: Set<String> = []
    // The last item clicked WITHOUT Shift — Shift+click ranges from here to the new click, same
    // as Finder. Stays put across consecutive Shift+clicks so you can extend/shrink a range
    // without it jumping to whatever you last shift-clicked.
    @State private var selectionAnchor: String?
    @State private var rootNodes: [ExplorerNode] = []

    @State private var showDeleteConfirm = false

    @State private var showTransferSheet = false
    @State private var transferMode: TransferMode = .move
    @State private var pickerPath = ""
    @State private var pickerTargetPath: String?
    @State private var pickerRootNodes: [ExplorerNode] = []

    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var newFolderTarget: FolderPromptTarget = .explorer

    @State private var showRenamePrompt = false
    @State private var renameTarget: RemotePathItem?
    @State private var renameNewName = ""

    @State private var infoItem: RemotePathItem?
    @State private var infoFolderSize: FolderSizeInfo?
    @State private var isLoadingInfoSize = false
    @State private var infoDetail: RemoteEntryDetail?
    @State private var isLoadingInfoDetail = false

    @State private var isDropTargetedBackground = false
    @State private var dropTargetPath: String?

    @State private var searchQuery = ""
    @State private var searchResults: [RemoteEntry]?
    // Rows are selected via .onTapGesture, not a real focusable AppKit control, so nothing ever
    // naturally takes keyboard focus away from the search field once it has it — Space then types
    // a literal space into the field instead of reaching the hidden Quick Look shortcut button.
    @FocusState private var searchFieldFocused: Bool
    @State private var isSearching = false
    @State private var searchStartDate: Date?
    @State private var searchGeneration = 0

    @State private var showFileActionDialog = false
    @State private var fileActionEntry: RemoteEntry?

    @State private var showMoveConfirm = false
    @State private var pendingMoveItems: [RemotePathItem] = []
    @State private var pendingMoveDestination = ""

    @State private var showEmptyFoldersAlert = false
    @State private var pendingEmptyFolders: [String] = []
    @State private var pendingUploadPaths: [String] = []
    @State private var pendingUploadDestination = ""

    @State private var showShareSheet = false
    @State private var shareItem: RemotePathItem?
    @State private var shareDurationDays = 7
    @State private var shareViewLink: String?
    @State private var isGeneratingViewLink = false
    @State private var viewLinkCopied = false
    @State private var shareDownloadLink: String?
    @State private var isGeneratingDownloadLink = false
    @State private var downloadLinkCopied = false
    @State private var downloadCredAccountID = ""
    @State private var downloadCredAppKey = ""
    @State private var shareLinkErrorMessage: String?

    @State private var verifyItem: RemotePathItem?
    @State private var pendingVerifyLocalURL: URL?
    @State private var showVerifyNameMismatchAlert = false
    @State private var showVerifySheet = false
    @State private var verifyIsRunning = false
    @State private var verifyProgressDone = 0
    @State private var verifyProgressTotal = 0
    @State private var verifyResult: IntegrityResult?
    @State private var verifyFailed = false

    private var fullBrowsePath: String { connection.remotePrefix + browsePath }

    /// Pulled out of the `.confirmationDialog` call itself — inlined there, the type checker
    /// timed out ("unable to type-check this expression in reasonable time") once enough other
    /// modifiers piled up earlier in the same view's modifier chain.
    private var moveConfirmTitle: String {
        "¿Mover a /\(connection.bucket)/\(pendingMoveDestination)?"
    }

    // ponytail: `.map { ... } ?? ""` produces a plain String at the call site (not a literal),
    // which binds confirmationDialog's verbatim StringProtocol overload — typing the closure's
    // return as LocalizedStringKey makes the interpolation build a real catalog lookup (with
    // entry.Name substituted via %@) instead of baking the filename into an unmatchable key.
    private var fileActionDialogTitle: LocalizedStringKey {
        fileActionEntry.map { (entry: RemoteEntry) -> LocalizedStringKey in "¿Qué quieres hacer con \(entry.Name)?" } ?? ""
    }
    private var fullPickerPath: String { connection.remotePrefix + pickerPath }

    /// The destination folder actually targeted in the transfer sheet: defaults to the tree's
    /// root (`pickerPath`) until the user clicks a specific (possibly nested) folder in it.
    private var effectivePickerTargetPath: String { pickerTargetPath ?? pickerPath }
    private var fullPickerTargetPath: String { connection.remotePrefix + effectivePickerTargetPath }

    private var selectedItems: [RemotePathItem] {
        selectedPaths.compactMap { p in
            pathRegistry[p].map { RemotePathItem(path: p, name: $0.name, isDir: $0.isDir) }
        }
    }

    private var currentFolderHasImages: Bool {
        rclone.remoteEntries.contains { !$0.IsDir && ImageKind.isImage($0.Name) }
    }

    /// "Expandir todo"/"Colapsar todo" only makes sense when there's at least one subfolder to
    /// expand — a folder of plain files has nothing for it to do.
    private var currentFolderHasSubfolders: Bool {
        rclone.remoteEntries.contains { $0.IsDir }
    }

    private var allSelected: Bool {
        !rclone.remoteEntries.isEmpty &&
        rclone.remoteEntries.allSatisfy { selectedPaths.contains(fullPath(for: $0, parent: fullBrowsePath)) }
    }

    // Split into stages + a chain of small helper methods below — with this many alerts/sheets/
    // onChange handlers attached to one view, the type checker started timing out trying to
    // solve the whole modifier chain as a single expression ("unable to type-check this
    // expression in reasonable time"). Each stage is independently cheap to check.
    var body: some View {
        let withLifecycle = applyLifecycleHandlers(to: mainContent)
        let withCore = applyCoreDialogs(to: withLifecycle)
        let withSheets = applySheetsAndVerify(to: withCore)
        let withTransfers = applyTransferDialogs(to: withSheets)
        return withTransfers
            .background(keyboardShortcutButtons)
            // ponytail: a @FocusedValue-driven .disabled() on these same Commands crashed AppKit
            // (NSMenu setItemArray: / NSTaggedPointerString hash) whenever the menu's enabled
            // state changed while the user had the menu bar open, a real AppKit/SwiftUI bug, not
            // fixable from here. NotificationCenter avoids touching the menu's enabled state at
            // all: the item is always enabled, and this just no-ops quietly with no selection.
            .onReceive(NotificationCenter.default.publisher(for: .bb2sMoveSelection)) { _ in
                guard !selectedPaths.isEmpty else { return }
                openTransferSheet(.move)
            }
            .onReceive(NotificationCenter.default.publisher(for: .bb2sCopySelection)) { _ in
                guard !selectedPaths.isEmpty else { return }
                openTransferSheet(.copy)
            }
    }

    // Toolbar row + breadcrumb + path-input row icons/text, bumped 15% at Bernabe's request
    // (13pt body / 11pt caption system defaults × 1.15) — one shared source so every element in
    // that block scales by the exact same factor instead of hand-picked, inconsistent sizes.
    private let toolbarBodySize: CGFloat = 13 * 1.15
    private let toolbarCaptionSize: CGFloat = 11 * 1.15

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Un clic selecciona (reemplaza la selección); Cmd+clic agrega o quita de la selección. Doble clic entra a la carpeta. Clic en vacío deselecciona. Clic derecho para más opciones.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 9) {
                Button { goBack() } label: { Image(systemName: "chevron.left").font(.system(size: toolbarBodySize)) }
                    .disabled(backStack.isEmpty)
                    .help("Atrás")
                    .keyboardShortcut("[", modifiers: .command)
                Button { goForward() } label: { Image(systemName: "chevron.right").font(.system(size: toolbarBodySize)) }
                    .disabled(forwardStack.isEmpty)
                    .help("Adelante")
                    .keyboardShortcut("]", modifiers: .command)
                Button { navigateUp() } label: { Image(systemName: "arrow.up").font(.system(size: toolbarBodySize)) }
                    .disabled(browsePath.isEmpty)
                    .help("Subir un nivel")
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button { refreshCurrentFolder() } label: { Image(systemName: "arrow.clockwise").font(.system(size: toolbarBodySize)) }
                    .disabled(rclone.isListingRemote || rclone.isRunning)
                    .help("Actualizar esta carpeta")
                    .keyboardShortcut("r", modifiers: .command)
                Button { goTo("") } label: { Image(systemName: "house").font(.system(size: toolbarBodySize)) }
                    .disabled(browsePath.isEmpty)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .help("Ir a la raíz del bucket")

                Menu {
                    Button("Subir archivo… (⌘U)") { uploadFiles(into: fullBrowsePath) }
                    Button("Subir carpeta… (⌘⇧U)") { uploadFolder(into: fullBrowsePath) }
                } label: {
                    Image(systemName: "icloud.and.arrow.up").font(.system(size: toolbarBodySize))
                }
                .disabled(rclone.isRunning)
                .help("Subir archivo o carpeta a esta ubicación")

                searchBar

                Picker("", selection: $viewMode) {
                    Label("Vista Iconos", systemImage: "square.grid.2x2")
                        .labelStyle(.iconOnly)
                        .font(.system(size: toolbarBodySize))
                        .help("Vista Iconos")
                        .tag(ExplorerViewMode.icons)
                    Label("Vista desplegable", systemImage: "list.bullet")
                        .labelStyle(.iconOnly)
                        .font(.system(size: toolbarBodySize))
                        .help("Vista desplegable")
                        .tag(ExplorerViewMode.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 104)

                Button {
                    newFolderTarget = .explorer
                    newFolderName = ""
                    showNewFolderPrompt = true
                } label: {
                    Label("Nueva carpeta…", systemImage: "folder.badge.plus")
                        .font(.system(size: toolbarBodySize))
                }
                .disabled(rclone.isRunning)
            }

            HStack {
                pathMenu(current: browsePath) { newPath in goTo(newPath) }
                Spacer()
            }

            HStack {
                TextField("carpeta/subcarpeta (sin el nombre del bucket)", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: toolbarCaptionSize))
                    .onSubmit { goTo(pathInput) }
                // goTo(_:) sets browsePath verbatim — no "bucket:" prefix or leading "/" is ever
                // parsed out, so the only valid syntax really is a bare relative path. This is the
                // one place that says so explicitly instead of leaving it to be guessed.
                Image(systemName: "questionmark.circle")
                    .font(.system(size: toolbarBodySize))
                    .foregroundStyle(.secondary)
                    // Same fix as the parallel-transfers tooltip: a bare SF Symbol's hoverable
                    // area is only its tight glyph bounds, easy to miss entirely — a real frame +
                    // contentShape makes the whole visible circle (and the padding around it)
                    // actually trigger .help().
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .help("Escribe una ruta relativa dentro de \(connection.bucket), sin el nombre del bucket ni \":\". Ejemplo: carpeta/subcarpeta")
                Button("Ir") { goTo(pathInput) }
                    .font(.system(size: toolbarBodySize))
                    .disabled(rclone.isListingRemote || rclone.isRunning)
            }

            if searchResults != nil {
                searchResultsView
            } else if rclone.isListingRemote {
                ProgressView().controlSize(.small)
            } else if !rclone.remoteEntries.isEmpty {
                HStack {
                    // ponytail: ternary-of-literals into Button(_:)/.help(_:) resolves to the
                    // verbatim StringProtocol overload — LocalizedStringKey(_:) wrap fixes it.
                    Button(LocalizedStringKey(allSelected ? "Deseleccionar todo" : "Seleccionar todo")) { toggleSelectAll() }
                    Button("Galería de fotos") { openWindow(id: "gallery", value: rclone.explorerPath) }
                        .disabled(!currentFolderHasImages)
                        .help(currentFolderHasImages ? LocalizedStringKey("Ver las imágenes de esta carpeta") : LocalizedStringKey("Esta carpeta no tiene imágenes"))
                    if !selectedPaths.isEmpty {
                        Button("Deseleccionar") { selectedPaths.removeAll() }
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    if viewMode == .list && currentFolderHasSubfolders {
                        Button(LocalizedStringKey(topLevelExpanded ? "Colapsar todo" : "Expandir todo")) {
                            if topLevelExpanded { collapseAllTopLevel() } else { expandAllTopLevel() }
                        }
                    }
                    Spacer()
                    Text("\(selectedPaths.count) seleccionado(s)").font(.caption).foregroundStyle(.secondary)
                }

                if viewMode == .icons {
                    iconGrid
                } else {
                    listTree
                }

                HStack {
                    // Shortcuts for these two now live on the Edición-menu Commands (via
                    // ExplorerMenuActions) instead of here, so the combo isn't registered twice.
                    Button("Mover selección…") { openTransferSheet(.move) }
                        .disabled(selectedPaths.isEmpty || rclone.isRunning)
                    Button("Copiar selección…") { openTransferSheet(.copy) }
                        .disabled(selectedPaths.isEmpty || rclone.isRunning)
                    Button("Borrar seleccionados (\(selectedPaths.count))") { showDeleteConfirm = true }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(selectedPaths.isEmpty || rclone.isRunning)
                        .tint(.red)
                    Spacer()
                }
            }
        }
    }

    private func applyLifecycleHandlers(to content: some View) -> some View {
        content
            .onAppear {
                if rclone.remoteEntries.isEmpty && !rclone.isListingRemote {
                    listCurrentPath()
                }
            }
            // Keyed on remotePrefix (remote + bucket), not connection.id (the display name) —
            // renaming a connection doesn't change what's being browsed, so it shouldn't blow
            // away the explorer's state. It used to: renaming re-fetched the SAME listing (same
            // bucket), so .onChange(of: rclone.remoteEntries) below never re-fired (equal value),
            // leaving rootNodes stuck at the [] this handler had just set — the list view (which
            // renders from rootNodes) went blank, while the icon view (reads remoteEntries
            // directly) didn't.
            .onChange(of: connection.remotePrefix) { _, _ in
                browsePath = ""
                pathInput = ""
                backStack = []
                forwardStack = []
                topLevelExpanded = false
                selectedPaths = []
                pathRegistry = [:]
                rootNodes = []
                clearSearch()
                listCurrentPath()
            }
            .onChange(of: browsePath) { _, newValue in
                pathInput = newValue
                rclone.explorerPath = newValue
            }
            .onChange(of: sortColumn) { resortWholeTree() }
            .onChange(of: sortAscending) { resortWholeTree() }
            .onChange(of: rclone.remoteEntries) { _, newEntries in
                register(parentPath: fullBrowsePath, entries: newEntries)
                let previousByPath = Dictionary(uniqueKeysWithValues: rootNodes.map { ($0.fullPath, $0) })
                rootNodes = sortedEntries(newEntries).map { entry in
                    let node = ExplorerNode(entry: entry, parentFullPath: fullBrowsePath, depth: 0)
                    if let previous = previousByPath[node.fullPath] {
                        node.restoreState(from: previous)
                    }
                    return node
                }
            }
            .onChange(of: rclone.pickerEntries) { _, newEntries in
                let dirs = newEntries.filter(\.IsDir)
                let previousByPath = Dictionary(uniqueKeysWithValues: pickerRootNodes.map { ($0.fullPath, $0) })
                pickerRootNodes = dirs.map { entry in
                    let node = ExplorerNode(entry: entry, parentFullPath: fullPickerPath, depth: 0)
                    if let previous = previousByPath[node.fullPath] {
                        node.restoreState(from: previous)
                    }
                    return node
                }
            }
    }

    private func applyCoreDialogs(to content: some View) -> some View {
        content
            .confirmationDialog("¿Borrar de B2? Esto no se puede deshacer.", isPresented: $showDeleteConfirm) {
                Button("Borrar \(selectedPaths.count) elemento(s)", role: .destructive) { performDelete() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(deleteConfirmMessage)
            }
            .alert("Nueva carpeta", isPresented: $showNewFolderPrompt) {
                TextField("Nombre", text: $newFolderName)
                Button("Crear") { confirmCreateFolder() }
                Button("Cancelar", role: .cancel) { newFolderName = "" }
            } message: {
                Text("Se creará dentro de \(newFolderTarget == .explorer ? fullBrowsePath : fullPickerTargetPath)")
            }
            .alert("Renombrar", isPresented: $showRenamePrompt) {
                TextField("Nuevo nombre", text: $renameNewName)
                Button("Renombrar") { confirmRename() }
                Button("Cancelar", role: .cancel) { renameNewName = "" }
            } message: {
                if let target = renameTarget { Text("Renombrando \"\(target.name)\"") }
            }
            .alert(
                "Listo",
                isPresented: showCompletionAlert,
                presenting: completionAlert
            ) { info in
                if let url = info.revealURL {
                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("OK") {}
            } message: { info in
                Text(LocalizedStringKey(info.titleKey)) + Text(": ") + Text(info.detail)
            }
    }

    private func applySheetsAndVerify(to content: some View) -> some View {
        content
            .sheet(isPresented: $showTransferSheet) { transferSheet.environment(\.locale, Locale(identifier: appLanguageCode)) }
            .sheet(item: $infoItem) { item in infoSheet(for: item).environment(\.locale, Locale(identifier: appLanguageCode)) }
            .sheet(isPresented: $showShareSheet) { shareSheet.environment(\.locale, Locale(identifier: appLanguageCode)) }
            .sheet(isPresented: $showVerifySheet) { verifySheet.environment(\.locale, Locale(identifier: appLanguageCode)) }
            .alert("Nombre(s) de archivo(s) no son idénticos, ¿quieres continuar?", isPresented: $showVerifyNameMismatchAlert) {
                Button("Continuar") {
                    if let url = pendingVerifyLocalURL, let item = verifyItem {
                        beginVerify(localURL: url, item: item)
                    }
                    pendingVerifyLocalURL = nil
                }
                Button("Cancelar", role: .cancel) {
                    pendingVerifyLocalURL = nil
                    verifyItem = nil
                }
            } message: {
                if let url = pendingVerifyLocalURL, let item = verifyItem {
                    Text("Local: \(url.lastPathComponent)\nB2: \(item.name)")
                }
            }
    }

    private func applyTransferDialogs(to content: some View) -> some View {
        content
            .confirmationDialog(moveConfirmTitle, isPresented: $showMoveConfirm) {
                Button("Mover \(pendingMoveItems.count) elemento(s)") { performDragMove() }
                Button("Cancelar", role: .cancel) { pendingMoveItems = []; pendingMoveDestination = "" }
            } message: {
                Text(pendingMoveItems.map(\.name).joined(separator: ", "))
            }
            .alert("Carpetas vacías detectadas", isPresented: $showEmptyFoldersAlert) {
                Button("Subir de todas formas") {
                    performUpload(paths: pendingUploadPaths, into: pendingUploadDestination)
                    pendingUploadPaths = []
                    pendingEmptyFolders = []
                }
                Button("Cancelar", role: .cancel) {
                    pendingUploadPaths = []
                    pendingEmptyFolders = []
                }
            } message: {
                // ponytail: keep the dynamic folder list (data) out of the literal, but interpolate
                // it inline so the fixed lead sentence still localizes instead of riding along
                // verbatim inside a pre-built String.
                Text("B2 no guarda carpetas vacías. No van a aparecer del otro lado:\n\(emptyFoldersPreview)")
            }
            .confirmationDialog(
                fileActionDialogTitle,
                isPresented: $showFileActionDialog,
                titleVisibility: .visible
            ) {
                if let entry = fileActionEntry {
                    Button("Abrir") { openSearchResult(entry) }
                    Button("Descargar") { downloadDefault([searchResultItem(entry)]) }
                    Button("Descargar a…") { downloadChoosingFolder([searchResultItem(entry)]) }
                }
                Button("Cancelar", role: .cancel) {}
            }
    }

    private var emptyFoldersPreview: String {
        let preview = pendingEmptyFolders.prefix(10).joined(separator: "\n")
        let extra = pendingEmptyFolders.count > 10 ? "\n… y \(pendingEmptyFolders.count - 10) más" : ""
        return preview + extra
    }

    // MARK: - Search (recursive, whole bucket — flat results, not a filtered tree; clicking one
    // jumps the Explorer there and clears the search. Simpler than reconstructing an expandable
    // tree out of arbitrary scattered matches, and just as fast to get to the file.)

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: toolbarBodySize))
                    .foregroundStyle(.secondary)
                TextField("Buscar en todo el bucket…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: toolbarCaptionSize))
                    .focused($searchFieldFocused)
                    .onSubmit { performSearch() }
                if isSearching {
                    Button("Detener") { cancelSearch() }.font(.system(size: toolbarCaptionSize))
                } else if searchResults != nil {
                    Button("Limpiar") { clearSearch() }.font(.system(size: toolbarCaptionSize))
                } else {
                    Button("Buscar") { performSearch() }
                        .font(.system(size: toolbarCaptionSize))
                        .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if isSearching {
                searchingIndicator
            }
        }
        .frame(width: 345)
    }

    /// Shows the real `rclone` command right when the search starts (`lsjson` doesn't stream
    /// progress line-by-line like `--progress` transfers do, so there's no real log to show, but
    /// the command itself is real information) — then, since a whole-bucket recursive listing can
    /// take a while, cycles into a few reassuring messages every 3s so it doesn't look stuck.
    private var searchingIndicator: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let elapsed = searchStartDate.map { context.date.timeIntervalSince($0) } ?? 0
            let dots = String(repeating: ".", count: Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4)
            Group {
                switch Int(elapsed / 3) % 4 {
                case 0:
                    (Text("rclone lsjson --recursive \(connection.remotePrefix)") + Text(dots))
                        .font(.system(.caption2, design: .monospaced))
                case 1:
                    (Text("Sí estoy buscando") + Text(dots)).font(.caption2)
                case 2:
                    (Text("No desesperes, en verdad estoy buscando") + Text(dots)).font(.caption2)
                default:
                    (Text("La búsqueda es en la nube, no esperes tanta rapidez") + Text(dots)).font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    /// `searchGeneration` invalidates a search's own completion handler once a newer search has
    /// started (or the user hit "Detener") — without it, a slow search that finishes AFTER a
    /// second, faster one would clobber those newer results with its own stale ones.
    private func performSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchStartDate = Date()
        rclone.searchAll(basePath: connection.remotePrefix, query: trimmed) { results in
            guard generation == searchGeneration else { return }
            isSearching = false
            searchStartDate = nil
            searchResults = results
        }
    }

    private func cancelSearch() {
        searchGeneration += 1
        rclone.cancelSearch()
        isSearching = false
        searchStartDate = nil
        searchResults = nil
    }

    private func clearSearch() {
        searchGeneration += 1
        rclone.cancelSearch()
        searchQuery = ""
        isSearching = false
        searchStartDate = nil
        searchResults = nil
    }

    private var searchResultsView: some View {
        Group {
            if let results = searchResults {
                if results.isEmpty {
                    Text("Sin resultados para \"\(searchQuery)\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(results) { entry in
                                searchResultRow(entry)
                            }
                        }
                        .padding(4)
                    }
                    .frame(minHeight: 240, maxHeight: 320)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func searchResultRow(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.IsDir ? "folder.fill" : iconName(for: entry.Name))
                .foregroundStyle(entry.IsDir ? .orange : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                highlightedName(entry.Name)
                Text("/\(connection.bucket)/\(entry.Path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if !entry.IsDir {
                Text(formattedSize(entry.Size)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.IsDir {
                jumpToResult(entry)
            } else {
                fileActionEntry = entry
                showFileActionDialog = true
            }
        }
        .onTapGesture(count: 1) { jumpToResult(entry) }
    }

    /// Highlights the first query word found in this particular name — a match can also come
    /// from a folder name higher up in the path (searchAll matches the whole path), in which
    /// case nothing here highlights and that's fine, the path line underneath shows where it hit.
    private func highlightedName(_ name: String) -> Text {
        let words = searchQuery.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        for word in words {
            if let range = name.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                return Text(name[name.startIndex..<range.lowerBound])
                    + Text(name[range]).bold().foregroundColor(.accentColor)
                    + Text(name[range.upperBound...])
            }
        }
        return Text(name)
    }

    /// Jumps the Explorer to where a result lives: a matched folder is opened directly, a matched
    /// file's containing folder is opened instead (so the file is visible in the listing).
    private func jumpToResult(_ entry: RemoteEntry) {
        let relativeTarget: String
        if entry.IsDir {
            relativeTarget = entry.Path
        } else if let idx = entry.Path.lastIndex(of: "/") {
            relativeTarget = String(entry.Path[..<idx])
        } else {
            relativeTarget = ""
        }
        clearSearch()
        goTo(relativeTarget)
    }

    private func searchResultItem(_ entry: RemoteEntry) -> RemotePathItem {
        RemotePathItem(path: connection.remotePrefix + entry.Path, name: entry.Name, isDir: entry.IsDir)
    }

    /// Downloads a search result to a throwaway temp folder and opens it with whatever app macOS
    /// would normally use (double-click behavior, without leaving the file in ~/Downloads).
    // ponytail: the temp copy is never cleaned up afterward — same trade-off already accepted for
    // the Gallery's thumbnail cache; macOS reclaims /tmp under disk pressure on its own.
    private func openSearchResult(_ entry: RemoteEntry) {
        let item = searchResultItem(entry)
        let tempDir = NSTemporaryDirectory() + "b2sync-open-" + UUID().uuidString
        do {
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        } catch {
            return
        }
        rclone.downloadItems([item], toLocalFolder: tempDir, recordHistory: false, trackFailure: false) { success in
            guard success else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: tempDir).appendingPathComponent(entry.Name))
        }
    }

    /// Same download-to-temp dance as `openSearchResult`, but hands the result to Quick Look
    /// instead of the file's default app — a fast look at what's inside, no app launch, no
    /// editing risk.
    private func previewFile(_ item: RemotePathItem) {
        let tempDir = NSTemporaryDirectory() + "b2sync-preview-" + UUID().uuidString
        do {
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        } catch {
            return
        }
        rclone.downloadItems([item], toLocalFolder: tempDir, recordHistory: false, trackFailure: false) { success in
            guard success else { return }
            QuickLookController.shared.show(url: URL(fileURLWithPath: Self.localDestPath(tempDir, item.name)))
        }
    }

    // MARK: - Icon grid

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 110), spacing: 12)], spacing: 12) {
                ForEach(rclone.remoteEntries) { entry in
                    explorerGridItem(entry)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { selectedPaths.removeAll() }
            .contextMenu { emptyAreaContextMenuItems() }
        }
        .frame(minHeight: 240, maxHeight: 320)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargetedBackground) { providers in
            handleLocalDrop(providers, intoRemoteFolder: fullBrowsePath)
        }
    }

    private func explorerGridItem(_ entry: RemoteEntry) -> some View {
        let fp = fullPath(for: entry, parent: fullBrowsePath)
        let isSelected = selectedPaths.contains(fp)
        return VStack(spacing: 4) {
            Image(systemName: entry.IsDir ? "folder.fill" : iconName(for: entry.Name))
                .font(.system(size: 36))
                .foregroundStyle(entry.IsDir ? .orange : .secondary)
                .frame(height: 40)
            Text(entry.Name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            if !entry.IsDir {
                Text(formattedSize(entry.Size)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(width: 96)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: entry.IsDir && isDropTarget(fp) ? 2.5 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.IsDir { navigateInto(entry) }
        }
        .onTapGesture(count: 1) {
            selectItem(fp, additive: NSEvent.modifierFlags.contains(.command), rangeExtend: NSEvent.modifierFlags.contains(.shift))
        }
        .contextMenu {
            contextMenuItems(clicked: RemotePathItem(path: fp, name: entry.Name, isDir: entry.IsDir))
        }
        .onDrag { dragProvider(for: RemotePathItem(path: fp, name: entry.Name, isDir: entry.IsDir)) }
        .onDrop(
            of: [.fileURL, .plainText],
            isTargeted: Binding(get: { isDropTarget(fp) }, set: { setDropTarget(fp, $0) })
        ) { providers in
            guard entry.IsDir else { return false }
            return handleDrop(providers, intoRemoteFolder: fp)
        }
    }

    /// Drives the accent-color border shown on a folder while something is being dragged over it
    /// (Finder file or another B2 item) — previously `isTargeted: nil` meant no hover feedback at
    /// all, so there was no way to tell where a drop would land until after releasing.
    private func isDropTarget(_ path: String) -> Bool { dropTargetPath == path }

    private func setDropTarget(_ path: String, _ isTargeted: Bool) {
        if isTargeted {
            dropTargetPath = path
        } else if dropTargetPath == path {
            dropTargetPath = nil
        }
    }

    // MARK: - List / outline view

    private var listColumnHeader: some View {
        HStack(spacing: 4) {
            sortHeaderButton("Nombre", column: .name)
            Spacer()
            sortHeaderButton("Tipo", column: .type, width: ExplorerNodeRow.typeColumnWidth)
            sortHeaderButton("Tamaño", column: .size, width: ExplorerNodeRow.sizeColumnWidth)
            sortHeaderButton("Modificación", column: .modified, width: ExplorerNodeRow.modColumnWidth)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    /// Clicking a header sorts by that column; clicking the active one again flips direction —
    /// same as Finder's own list view column headers.
    private func sortHeaderButton(_ title: LocalizedStringKey, column: ListSortColumn, width: CGFloat? = nil) -> some View {
        Button {
            if sortColumn == column { sortAscending.toggle() } else { sortColumn = column; sortAscending = true }
        } label: {
            HStack(spacing: 2) {
                if width != nil { Spacer(minLength: 0) }
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: width == nil ? .leading : .trailing)
    }

    private var listTree: some View {
        VStack(alignment: .leading, spacing: 4) {
            listColumnHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rootNodes) { node in
                        ExplorerNodeRow(node: node, ctx: rowContext)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { selectedPaths.removeAll() }
                .contextMenu { emptyAreaContextMenuItems() }
            }
            .frame(minHeight: 240, maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onDrop(of: [.fileURL], isTargeted: $isDropTargetedBackground) { providers in
                handleLocalDrop(providers, intoRemoteFolder: fullBrowsePath)
            }
        }
    }

    private var rowContext: ExplorerRowContext {
        ExplorerRowContext(
            isSelected: { selectedPaths.contains($0) },
            selectItem: { path, additive, rangeExtend in selectItem(path, additive: additive, rangeExtend: rangeExtend) },
            toggleExpand: { toggleExpand($0) },
            navigateInto: { navigateToNode($0) },
            iconName: { iconName(for: $0) },
            typeText: { name, isDir in typeLabel(name: name, isDir: isDir) },
            formattedSize: { formattedSize($0) },
            megabytesText: { megabytesText($0) },
            formattedModTime: { formattedModTime($0) },
            folderSizeText: { path in
                await withCheckedContinuation { continuation in
                    rclone.folderSize(path: path) { info in
                        continuation.resume(returning: info.map { megabytesText($0.bytes) } ?? "—")
                    }
                }
            },
            contextMenu: { AnyView(contextMenuItems(clicked: $0)) },
            onDrop: { node, providers in handleDrop(providers, intoRemoteFolder: node.fullPath) },
            onDrag: { node in dragProvider(for: RemotePathItem(path: node.fullPath, name: node.entry.Name, isDir: node.entry.IsDir)) },
            isDropTarget: { isDropTarget($0) },
            setDropTarget: { path, isTargeted in setDropTarget(path, isTargeted) }
        )
    }

    /// Navigates the whole browser into a node from the list-view tree, however deeply nested —
    /// unlike toggleExpand (which just expands it in place), this replaces the current listing.
    private func navigateToNode(_ node: ExplorerNode) {
        guard node.entry.IsDir, node.fullPath.hasPrefix(connection.remotePrefix) else { return }
        goTo(String(node.fullPath.dropFirst(connection.remotePrefix.count)))
    }

    private func toggleExpand(_ node: ExplorerNode) {
        guard !node.isLoadingChildren else { return }
        if node.isExpanded {
            node.isExpanded = false
            return
        }
        if node.hasLoadedChildren {
            node.isExpanded = true
            return
        }
        loadChildren(of: node)
    }

    /// Expands every root folder exactly one level — never deeper, even if one of their children
    /// was already expanded further down from an earlier manual triangle-click during this same
    /// session (that state stays cached on the child `ExplorerNode`, so without collapsing it
    /// here first, re-expanding the parent would silently reveal that leftover deeper state too).
    private func expandAllTopLevel() {
        topLevelExpanded = true
        for node in rootNodes where node.entry.IsDir {
            for child in node.children { child.isExpanded = false }
            if !node.isExpanded { toggleExpand(node) }
        }
    }

    private func collapseAllTopLevel() {
        topLevelExpanded = false
        for node in rootNodes { node.isExpanded = false }
    }

    private func loadChildren(of node: ExplorerNode) {
        node.isLoadingChildren = true
        rclone.listEntries(path: node.fullPath) { entries in
            register(parentPath: node.fullPath, entries: entries)
            let children = sortedEntries(entries).map { ExplorerNode(entry: $0, parentFullPath: node.fullPath, depth: node.depth + 1) }
            node.markLoaded(children: children)
        }
    }

    private func refreshNodeIfPresent(path: String) {
        func search(_ nodes: [ExplorerNode]) -> ExplorerNode? {
            for n in nodes {
                if n.fullPath == path { return n }
                if let found = search(n.children) { return found }
            }
            return nil
        }
        guard let node = search(rootNodes) else { return }
        loadChildren(of: node)
    }

    private func togglePickerExpand(_ node: ExplorerNode) {
        guard !node.isLoadingChildren else { return }
        if node.isExpanded {
            node.isExpanded = false
            return
        }
        if node.hasLoadedChildren {
            node.isExpanded = true
            return
        }
        loadPickerChildren(of: node)
    }

    private func targetPickerNode(_ node: ExplorerNode) {
        guard node.fullPath.hasPrefix(connection.remotePrefix) else { return }
        pickerTargetPath = String(node.fullPath.dropFirst(connection.remotePrefix.count))
    }

    private func loadPickerChildren(of node: ExplorerNode) {
        node.isLoadingChildren = true
        rclone.listEntries(path: node.fullPath) { entries in
            let children = entries.filter(\.IsDir).map {
                ExplorerNode(entry: $0, parentFullPath: node.fullPath, depth: node.depth + 1)
            }
            node.markLoaded(children: children)
        }
    }

    private func refreshPickerNodeIfPresent(path: String) {
        func search(_ nodes: [ExplorerNode]) -> ExplorerNode? {
            for n in nodes {
                if n.fullPath == path { return n }
                if let found = search(n.children) { return found }
            }
            return nil
        }
        guard let node = search(pickerRootNodes) else { return }
        loadPickerChildren(of: node)
    }

    private func refreshPickerAfterChange(at path: String) {
        if normalizedPath(path) == normalizedPath(fullPickerPath) {
            listPickerPath()
        } else {
            refreshPickerNodeIfPresent(path: path)
        }
    }

    private func refreshAfterRemoteChange(at path: String) {
        // fullBrowsePath always has a trailing "/" (from connection.remotePrefix at the
        // bucket root); parentPath(of:) never does — normalize before comparing.
        // Uses refreshCurrentFolder() (same as the "Actualizar" button), not listCurrentPath():
        // the mutation already invalidated this path's cache entry when it started, but if
        // anything else re-listed the same folder while the mutation was still running, that
        // read could have repopulated the cache with pre-mutation data — invalidating again
        // right before listing closes that race instead of risking a stale view.
        if normalizedPath(path) == normalizedPath(fullBrowsePath) {
            refreshCurrentFolder()
        } else {
            refreshNodeIfPresent(path: path)
        }
    }

    private func normalizedPath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - Context menu actions

    @ViewBuilder
    private func contextMenuItems(clicked: RemotePathItem) -> some View {
        let targets = selectedPaths.contains(clicked.path) ? selectedItems : [clicked]

        // The shortcut hints below are text, not real `.keyboardShortcut()` bindings — a native
        // contextual NSMenu's key equivalents only ever fire while that specific menu is open on
        // screen, never as an app-wide shortcut. Attaching them here looked right but didn't
        // actually make Return/Space/⌘⇧N work outside the open menu, and worse, having the same
        // shortcut declared once per visible row risked SwiftUI treating it as ambiguous and
        // firing NONE of them. The real, working bindings live in `keyboardShortcutButtons`
        // below, which act on the current selection regardless of any menu.
        Button {
            newFolderTarget = .explorer
            newFolderName = ""
            showNewFolderPrompt = true
        } label: {
            Label("Nueva carpeta… (⌘⇧N)", systemImage: "folder.badge.plus")
        }

        Button("Renombrar… (Return)") {
            renameTarget = clicked
            renameNewName = clicked.name
            showRenamePrompt = true
        }

        Button("Copiar ruta (⌘⌥C)") {
            copyToPasteboard(targets.map(\.path).joined(separator: "\n"))
        }

        Divider()

        Button("Descargar (⌘D)") { downloadDefault(targets) }
        Button("Descargar a… (⌘⇧D)") { downloadChoosingFolder(targets) }

        if !clicked.isDir {
            // No extension whitelist on purpose — Quick Look itself already knows what it can
            // and can't render (same as pressing Space in Finder on any file), so gating this on
            // a hand-maintained list of extensions would just be a second, incomplete copy of
            // that same knowledge.
            Button("Vista previa (Espacio)") { previewFile(clicked) }
        }

        if !clicked.isDir {
            Button("Generar URL para compartir… (⌘L)") {
                shareItem = clicked
                shareViewLink = nil
                shareDownloadLink = nil
                viewLinkCopied = false
                downloadLinkCopied = false
                downloadCredAccountID = ""
                downloadCredAppKey = ""
                shareDurationDays = 7
                shareLinkErrorMessage = nil
                isGeneratingViewLink = false
                isGeneratingDownloadLink = false
                // Deferred for the same reason as "Mostrar información…" — see its comment.
                DispatchQueue.main.async { showShareSheet = true }
            }
        }

        if clicked.isDir {
            Button("Comprimir en .zip…") { compressFolder(clicked) }
        }

        Divider()

        Button("Subir archivo… (⌘U)") { uploadFiles(into: clicked.isDir ? clicked.path : fullBrowsePath) }
        Button("Subir carpeta… (⌘⇧U)") { uploadFolder(into: clicked.isDir ? clicked.path : fullBrowsePath) }

        Divider()

        Button(LocalizedStringKey(clicked.isDir ? "Mostrar información de carpeta (⌘I)" : "Mostrar información de archivo (⌘I)")) {
            showInfo(for: clicked)
        }
        Button("Verificar integridad…") { startVerify(clicked) }
    }

    /// Right-click on empty space (nothing under the cursor): only actions that make sense
    /// without a specific target, applied to the folder currently being browsed.
    @ViewBuilder
    private func emptyAreaContextMenuItems() -> some View {
        Button {
            newFolderTarget = .explorer
            newFolderName = ""
            showNewFolderPrompt = true
        } label: {
            Label("Nueva carpeta…", systemImage: "folder.badge.plus")
        }
        Divider()
        Button("Subir archivo…") { uploadFiles(into: fullBrowsePath) }
        Button("Subir carpeta…") { uploadFolder(into: fullBrowsePath) }
        Divider()
        Button("Actualizar") { refreshCurrentFolder() }
    }

    private func downloadDefault(_ items: [RemotePathItem]) {
        guard !items.isEmpty else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Downloads")
        performDownload(items, toLocalFolder: downloads)
    }

    private func downloadChoosingFolder(_ items: [RemotePathItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Descargar aquí"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performDownload(items, toLocalFolder: url.path)
    }

    /// Single choke point for every "Descargar"/"Descargar a…" call — shows a completion alert
    /// with a "Mostrar en Finder" button pointed at the actual downloaded file (or the
    /// destination folder itself, for multi-item downloads where there's no single file to select).
    private func performDownload(_ items: [RemotePathItem], toLocalFolder: String) {
        rclone.downloadItems(items, toLocalFolder: toLocalFolder) { success in
            guard success else { return }
            let detail: String
            let revealURL: URL
            if items.count == 1 {
                detail = items[0].name
                revealURL = URL(fileURLWithPath: Self.localDestPath(toLocalFolder, items[0].name))
            } else {
                detail = "\(items.count) elemento(s)"
                revealURL = URL(fileURLWithPath: toLocalFolder)
            }
            completionAlert = OperationCompletion(titleKey: "Descarga completada", detail: detail, revealURL: revealURL)
        }
    }

    private static func localDestPath(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    private func uploadFiles(into remoteFolder: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Subir"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        guard !paths.isEmpty else { return }
        startUpload(paths: paths, into: remoteFolder)
    }

    private func uploadFolder(into remoteFolder: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Subir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startUpload(paths: [url.path], into: remoteFolder)
    }

    /// Checks any folders among `paths` for dead-end empty subfolders before uploading — B2 has
    /// no real empty directories, so those would silently vanish otherwise. Warns once, lets the
    /// user upload anyway or cancel, instead of surprising them after the fact.
    private func startUpload(paths: [String], into remoteFolder: String) {
        let empties = paths.flatMap { path -> [String] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return [] }
            let baseName = (path as NSString).lastPathComponent
            return findEmptySubfolders(in: path).map { baseName + "/" + $0 }
        }
        guard !empties.isEmpty else {
            performUpload(paths: paths, into: remoteFolder)
            return
        }
        pendingEmptyFolders = empties
        pendingUploadPaths = paths
        pendingUploadDestination = remoteFolder
        showEmptyFoldersAlert = true
    }

    private func performUpload(paths: [String], into remoteFolder: String) {
        rclone.uploadLocalPaths(paths, toRemoteFolder: remoteFolder) { success in
            refreshAfterRemoteChange(at: remoteFolder)
            guard success else { return }
            let detail = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) elemento(s)"
            completionAlert = OperationCompletion(titleKey: "Subida completada", detail: detail, revealURL: nil)
        }
    }

    /// Relative paths (from `rootPath`) of every subfolder whose whole subtree has zero files —
    /// these are exactly the folders that won't exist in B2 after a plain recursive upload.
    private func findEmptySubfolders(in rootPath: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: rootPath) else { return [] }
        var allDirs: [String] = []
        var dirsWithFiles: Set<String> = []
        while let relative = enumerator.nextObject() as? String {
            let full = (rootPath as NSString).appendingPathComponent(relative)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                allDirs.append(relative)
            } else {
                var dir = (relative as NSString).deletingLastPathComponent
                while true {
                    dirsWithFiles.insert(dir)
                    if dir.isEmpty { break }
                    dir = (dir as NSString).deletingLastPathComponent
                }
            }
        }
        return allDirs.filter { !dirsWithFiles.contains($0) }.sorted()
    }

    private func compressFolder(_ item: RemotePathItem) {
        let parent = parentPath(of: item.path)
        rclone.compressFolder(item) { _ in
            refreshAfterRemoteChange(at: parent)
        }
    }

    /// Drag source for an item already listed in B2: carries the selection's full paths (or just
    /// this item's, if it isn't part of the current selection) as plain text, registered by hand
    /// (not via `NSItemProvider(object: NSString)`).
    ///
    /// That distinction is the actual fix for a real bug: `NSItemProvider(object: someNSString)`
    /// lets NSString's own default writer conformance decide what to expose, and for a string
    /// that resembles a path WITH an extension (e.g. "b2:mybucket/foo.txt") it auto-promotes to
    /// ALSO register `public.file-url` — confirmed by logging `registeredTypeIdentifiers` mid-drag,
    /// which showed exactly `["public.file-url"]` for a lone dragged file (no plain-text at all).
    /// A folder name has no dot, so it never got promoted, which is why dragging folders always
    /// "just worked" already. Registering the data ourselves via `registerDataRepresentation`
    /// bypasses that writer entirely — this provider only ever exposes what we explicitly put in
    /// it (plain text), regardless of what the text looks like.
    private func dragProvider(for item: RemotePathItem) -> NSItemProvider {
        let items = selectedPaths.contains(item.path) ? selectedItems : [item]
        let payload = items.map(\.path).joined(separator: "\n")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(payload.data(using: .utf8), nil)
            return nil
        }
        return provider
    }

    /// Dispatches to the Finder-upload path or the internal B2 move, based on what the drop
    /// actually carries. A real Finder drag always carries `public.file-url` — our own drag
    /// (built above) never does, so checking for that specific type is unambiguous now that it's
    /// no longer at risk of the auto-promotion described above.
    private func handleDrop(_ providers: [NSItemProvider], intoRemoteFolder remoteFolder: String) -> Bool {
        let isLocal = providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        if isLocal {
            return handleLocalDrop(providers, intoRemoteFolder: remoteFolder)
        }
        return handleRemoteDrop(providers, intoRemoteFolder: remoteFolder)
    }

    private func handleRemoteDrop(_ providers: [NSItemProvider], intoRemoteFolder remoteFolder: String) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data, let str = String(data: data, encoding: .utf8) else { return }
            let paths = str.split(separator: "\n").map(String.init)
            DispatchQueue.main.async {
                let items = paths.compactMap { p -> RemotePathItem? in
                    pathRegistry[p].map { RemotePathItem(path: p, name: $0.name, isDir: $0.isDir) }
                }
                // Drop onto own parent (no-op) or onto itself/a descendant of itself: refuse silently.
                let usable = items.filter {
                    parentPath(of: $0.path) != remoteFolder &&
                    $0.path != remoteFolder &&
                    !(remoteFolder + "/").hasPrefix($0.path + "/")
                }
                guard !usable.isEmpty else { return }
                pendingMoveItems = usable
                pendingMoveDestination = String(remoteFolder.dropFirst(connection.remotePrefix.count))
                showMoveConfirm = true
            }
        }
        return true
    }

    private func performDragMove() {
        let items = pendingMoveItems
        let dest = connection.remotePrefix + pendingMoveDestination
        pendingMoveItems = []
        pendingMoveDestination = ""
        let sourceParents = Set(items.map { parentPath(of: $0.path) })
        rclone.moveItems(items, toBase: dest) { _ in
            for p in sourceParents { refreshAfterRemoteChange(at: p) }
            refreshAfterRemoteChange(at: dest)
        }
        selectedPaths.subtract(items.map(\.path))
    }

    private func handleLocalDrop(_ providers: [NSItemProvider], intoRemoteFolder remoteFolder: String) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        var collected: [String] = []
        let lock = NSLock()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); collected.append(url.path); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            startUpload(paths: collected, into: remoteFolder)
        }
        return true
    }

    private func showInfo(for item: RemotePathItem) {
        infoFolderSize = nil
        infoDetail = nil
        if item.isDir {
            isLoadingInfoSize = true
            rclone.folderSize(path: item.path) { size in
                infoFolderSize = size
                isLoadingInfoSize = false
            }
        } else {
            isLoadingInfoDetail = true
            rclone.statItem(path: item.path) { detail in
                infoDetail = detail
                isLoadingInfoDetail = false
            }
        }
        // Deferred: assigning straight into a @State value synchronously inside a .contextMenu
        // Button action can fail to actually trigger presentation on macOS — the right-click
        // menu's own tracking session hasn't fully torn down yet. Every other menu action that
        // reaches a sheet/panel either blocks on a modal (NSOpenPanel in "Verificar integridad…")
        // or goes through an .alert instead, which is why only this one (and "Generar URL para
        // compartir…", same shape) needs the explicit next-runloop-tick dispatch. Using
        // `.sheet(item:)` bound directly to `infoItem` (instead of a separate isPresented flag)
        // also means there's no longer any way for the sheet to present with stale/nil data.
        DispatchQueue.main.async { infoItem = item }
    }

    private func infoSheet(for item: RemotePathItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.name).font(.headline)
            Divider()
            LabeledContent("Ruta", value: item.path)
            LabeledContent("Tipo", value: item.isDir ? String(localized: "Carpeta") : String(localized: "Archivo"))
            if item.isDir {
                if isLoadingInfoSize {
                    ProgressView().controlSize(.small)
                } else if let size = infoFolderSize {
                    LabeledContent("Elementos", value: "\(size.count)")
                    LabeledContent("Tamaño total", value: formattedSize(size.bytes))
                } else {
                    Text("No se pudo calcular el tamaño.").font(.caption).foregroundStyle(.secondary)
                }
            } else if isLoadingInfoDetail {
                ProgressView().controlSize(.small)
            } else if let detail = infoDetail {
                LabeledContent("Tamaño", value: formattedSize(detail.Size))
                LabeledContent("Modificado", value: formattedModTime(detail.ModTime))
                if let mime = detail.MimeType, !mime.isEmpty {
                    LabeledContent("Tipo MIME", value: mime)
                }
                if let hashes = detail.Hashes {
                    ForEach(hashes.keys.sorted(), id: \.self) { hashType in
                        LabeledContent(hashType.uppercased(), value: hashes[hashType] ?? "")
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("No se pudo obtener la información de rclone.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cerrar") { infoItem = nil }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Deep integrity check (SHA1, on demand)

    /// Asks for the local counterpart via a file/folder picker (matching `clicked.isDir`), then
    /// warns if the picked item's name doesn't match the remote one before actually comparing —
    /// a mismatched name isn't necessarily wrong (Bernabe hit this for real: same file, renamed
    /// on upload), but it's worth a confirmation since it usually means "wrong file picked."
    private func startVerify(_ item: RemotePathItem) {
        verifyItem = item
        let panel = NSOpenPanel()
        panel.canChooseDirectories = item.isDir
        panel.canChooseFiles = !item.isDir
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir"
        panel.message = "Elige el \(item.isDir ? "carpeta" : "archivo") local que corresponde a \"\(item.name)\""
        guard panel.runModal() == .OK, let url = panel.url else {
            verifyItem = nil
            return
        }
        if url.lastPathComponent != item.name {
            pendingVerifyLocalURL = url
            showVerifyNameMismatchAlert = true
        } else {
            beginVerify(localURL: url, item: item)
        }
    }

    private func beginVerify(localURL: URL, item: RemotePathItem) {
        showVerifySheet = true
        verifyIsRunning = true
        verifyResult = nil
        verifyFailed = false
        verifyProgressDone = 0
        verifyProgressTotal = 0
        rclone.verifyIntegrity(
            localPath: localURL.path,
            remotePath: item.path,
            isDir: item.isDir,
            onProgress: { done, total in
                verifyProgressDone = done
                verifyProgressTotal = total
            },
            completion: { result in
                verifyIsRunning = false
                if let result {
                    verifyResult = result
                } else {
                    verifyFailed = true
                }
            }
        )
    }

    private var verifySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(verifyIsRunning ? "Verificando integridad…" : "Verificar integridad")).font(.headline)
            if let item = verifyItem {
                Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            if verifyIsRunning {
                // Three distinct states so there's always something concrete on screen instead of
                // a bare spinner: (0,0) = still fetching B2's hash list (no count yet), total==1 =
                // one big file being hashed (no byte-level progress, so an indeterminate spinner
                // is honest — a determinate bar stuck at 0% until the very end would read as
                // frozen), total>1 = a folder, where per-file count IS real, so show it.
                if verifyProgressTotal > 1 {
                    ProgressView(value: Double(verifyProgressDone), total: Double(verifyProgressTotal))
                    Text("Verificando \(verifyProgressDone) de \(verifyProgressTotal) archivo(s)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if verifyProgressTotal == 1 {
                    ProgressView().controlSize(.small)
                    Text("Calculando hash del archivo… puede tardar con archivos grandes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Reuniendo información de B2…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if verifyFailed {
                Label("No se pudo verificar (revisa la conexión o que la ruta siga existiendo en B2).", systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let result = verifyResult {
                if result.isPerfectMatch {
                    Label("Coincide perfectamente (\(result.totalCompared) archivo(s) comparado(s)).", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Label("\(result.mismatches.count) diferencia(s) de \(result.totalCompared) archivo(s):", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(result.mismatches) { mismatch in
                                Text("\(mismatch.relativePath): \(mismatch.reason)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }

            HStack {
                Spacer()
                Button("Cerrar") { showVerifySheet = false }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Share link
    //
    // Two independent links: "Ver" goes through `rclone link` (no credentials needed, matches
    // whatever the browser does by default with the file's stored content-type). "Descargar"
    // needs Backblaze's raw API (see B2API.swift) because only `b2_get_download_authorization`
    // can bake a Content-Disposition override into the token itself — appending it to an
    // already-issued rclone/b2-CLI link just invalidates that link's signature (tested: 401
    // bad_auth_token). That raw call needs the connection's real B2 key, stored in Keychain
    // once (see B2CredentialsStore) since the app normally only hands it to rclone.

    private var shareSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generar URL para compartir").font(.headline)
            if let item = shareItem {
                Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Stepper(value: $shareDurationDays, in: 1...7) {
                    Text("Duración: \(shareDurationDays) día(s)")
                }
                Text("Backblaze B2 no permite más de 7 días para este tipo de link.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let link = shareViewLink {
                shareLinkRow(title: "Ver en navegador", link: link, isCopied: viewLinkCopied) {
                    copyToPasteboard(link)
                    viewLinkCopied = true
                }
            } else if isGeneratingViewLink {
                generatingIndicator("rclone link \(shareItem?.name ?? "")")
            }

            if let link = shareDownloadLink {
                shareLinkRow(title: "Descargar (fuerza guardar archivo)", link: link, isCopied: downloadLinkCopied) {
                    copyToPasteboard(link)
                    downloadLinkCopied = true
                }
            } else if isGeneratingDownloadLink {
                generatingIndicator("Autorizando con Backblaze B2")
            } else if shareViewLink != nil, B2CredentialsStore.load(for: connection.remoteName) == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Para el link de descarga, captura una vez tus credenciales de B2 (se guardan en el Keychain de tu Mac):")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Key ID de B2", text: $downloadCredAccountID)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    SecureField("Application Key de B2", text: $downloadCredAppKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Guardar y generar link de descarga") { saveCredentialsAndGenerateDownloadLink() }
                        .disabled(downloadCredAccountID.trimmingCharacters(in: .whitespaces).isEmpty || downloadCredAppKey.isEmpty)
                }
            }

            if let shareLinkErrorMessage {
                Text(LocalizedStringKey(shareLinkErrorMessage))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cerrar") { showShareSheet = false }
                Spacer()
                if isGeneratingViewLink || isGeneratingDownloadLink {
                    Button("Cancelar", role: .cancel) { cancelLinkGeneration() }
                        .font(.caption)
                }
                Button(LocalizedStringKey(shareViewLink == nil ? "Generar" : "Regenerar")) { generateLinks() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGeneratingViewLink || isGeneratingDownloadLink)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Same idea as the search indicator: no meaningful progress to show mid-request, but naming
    /// the actual thing that's happening (plus a moving dot) reads as "still working", not stuck.
    private func generatingIndicator(_ label: String) -> some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let dots = String(repeating: ".", count: Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(label)\(dots)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // ponytail: `title` used to be a plain String — Text(String) is the VERBATIM overload, so the
    // two call sites' literal titles never localized no matter what the catalog said. Typing the
    // parameter as LocalizedStringKey instead (call sites already only ever pass literals) fixes it.
    private func shareLinkRow(title: LocalizedStringKey, link: String, isCopied: Bool, onCopy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("", text: .constant(link))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .textSelection(.enabled)
                Button(action: onCopy) {
                    Label(LocalizedStringKey(isCopied ? "Copiado" : "Copiar"), systemImage: isCopied ? "checkmark" : "doc.on.doc")
                }
            }
        }
    }

    /// Bumped on every new attempt AND on "Cancelar" — a completion only applies its result if
    /// this still matches, so a cancelled or superseded request can't clobber the sheet with a
    /// stale link/error after the user has already moved on. Same pattern as ExplorerView's own
    /// `searchGeneration`.
    @State private var linkGeneration = 0

    private func generateLinks() {
        guard let item = shareItem else { return }
        linkGeneration += 1
        let generation = linkGeneration
        shareLinkErrorMessage = nil
        isGeneratingViewLink = true
        viewLinkCopied = false
        shareViewLink = nil
        rclone.generateShareLink(path: item.path, expireDays: shareDurationDays) { link in
            guard generation == linkGeneration else { return }
            isGeneratingViewLink = false
            shareViewLink = link
            if link == nil {
                shareLinkErrorMessage = "No se pudo generar el link para ver en el navegador. Puede que la conexión esté lenta o caída. Inténtalo de nuevo."
            }
        }
        generateDownloadLinkIfPossible(generation: generation)
    }

    private func generateDownloadLinkIfPossible(generation: Int) {
        guard let item = shareItem, let creds = B2CredentialsStore.load(for: connection.remoteName) else {
            shareDownloadLink = nil
            return
        }
        isGeneratingDownloadLink = true
        downloadLinkCopied = false
        shareDownloadLink = nil
        let relativePath = String(item.path.dropFirst(connection.remotePrefix.count))
        B2API.generateForcedDownloadLink(
            accountID: creds.accountID,
            appKey: creds.appKey,
            bucketName: connection.bucket,
            relativePath: relativePath,
            fileName: item.name,
            expireDays: shareDurationDays
        ) { link in
            guard generation == linkGeneration else { return }
            isGeneratingDownloadLink = false
            shareDownloadLink = link
            if link == nil {
                shareLinkErrorMessage = "No se pudo generar el link de descarga. Puede que la conexión esté lenta o caída. Inténtalo de nuevo."
            }
        }
    }

    /// The URLSession requests behind the download link aren't actually aborted — they'll just
    /// finish in the background and get ignored by the generation check above. Fine: they're
    /// capped at 15s each now, so "ignored eventually" isn't "ignored forever" like before.
    private func cancelLinkGeneration() {
        linkGeneration += 1
        rclone.cancelShareLink()
        isGeneratingViewLink = false
        isGeneratingDownloadLink = false
        shareLinkErrorMessage = "Cancelado."
    }

    private func saveCredentialsAndGenerateDownloadLink() {
        let accountID = downloadCredAccountID.trimmingCharacters(in: .whitespaces)
        let appKey = downloadCredAppKey
        guard !accountID.isEmpty, !appKey.isEmpty else { return }
        B2CredentialsStore.save(B2Credentials(accountID: accountID, appKey: appKey), for: connection.remoteName)
        downloadCredAccountID = ""
        downloadCredAppKey = ""
        linkGeneration += 1
        generateDownloadLinkIfPossible(generation: linkGeneration)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Transfer sheet (move / copy destination picker)

    private func openTransferSheet(_ mode: TransferMode) {
        transferMode = mode
        pickerPath = browsePath
        pickerTargetPath = nil
        pickerRootNodes = []
        rclone.listRemote(path: fullPickerPath, target: .picker)
        showTransferSheet = true
    }

    private var transferSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ponytail: a ternary of two literal words embedded INSIDE a string interpolation
            // gets substituted as opaque %@ data — it never re-localizes on its own. Splitting
            // into two full literal Text() calls lets each one carry its own catalog key.
            Group {
                if transferMode == .move {
                    Text("Mover \(selectedPaths.count) elemento(s) a…")
                } else {
                    Text("Copiar \(selectedPaths.count) elemento(s) a…")
                }
            }
            .font(.headline)

            HStack(spacing: 8) {
                Button { navigatePickerUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(pickerPath.isEmpty)
                pathMenu(current: pickerPath) { newPath in
                    pickerPath = newPath
                    listPickerPath()
                }
                Button {
                    newFolderTarget = .picker
                    newFolderName = ""
                    showNewFolderPrompt = true
                } label: {
                    Label("Nueva carpeta…", systemImage: "folder.badge.plus")
                }
            }

            HStack {
                TextField("o escribe/pega una ruta raíz para explorar", text: $pickerPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { listPickerPath() }
                Button("Ir") { listPickerPath() }
            }

            Text("Clic en una carpeta la marca como destino; el triángulo (o doble clic) explora más adentro.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if rclone.isListingPicker {
                ProgressView().controlSize(.small)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pickerRootNodes) { node in
                            PickerNodeRow(
                                node: node,
                                isTarget: { $0 == fullPickerTargetPath },
                                onTarget: { targetPickerNode($0) },
                                onToggleExpand: { togglePickerExpand($0) }
                            )
                        }
                    }
                    .padding(4)
                }
                .frame(minHeight: 220, maxHeight: 280)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text("Destino: /\(connection.bucket)/\(effectivePickerTargetPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            HStack {
                Button("Cancelar") { showTransferSheet = false }
                Spacer()
                Button(LocalizedStringKey(transferMode == .move ? "Mover aquí" : "Copiar aquí")) {
                    let items = selectedItems
                    let dest = fullPickerTargetPath
                    let sourceParents = Set(items.map { parentPath(of: $0.path) })
                    if transferMode == .move {
                        rclone.moveItems(items, toBase: dest) { _ in
                            for p in sourceParents { refreshAfterRemoteChange(at: p) }
                            refreshPickerAfterChange(at: dest)
                        }
                        selectedPaths.subtract(items.map(\.path))
                    } else {
                        rclone.copyItems(items, toBase: dest) { _ in
                            refreshPickerAfterChange(at: dest)
                        }
                    }
                    showTransferSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(fullPickerTargetPath == fullBrowsePath)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Delete

    private var deleteConfirmMessage: String {
        let names = selectedItems.map { $0.isDir ? "\($0.name)/ (carpeta completa)" : $0.name }
        guard !names.isEmpty else { return "Nada seleccionado" }
        let preview = names.prefix(8).joined(separator: "\n")
        let extra = names.count > 8 ? "\n… y \(names.count - 8) más" : ""
        return preview + extra
    }

    private func performDelete() {
        let items = selectedItems
        let parentPaths = Set(items.map { parentPath(of: $0.path) })
        rclone.deleteItems(items) { _ in
            for p in parentPaths { refreshAfterRemoteChange(at: p) }
        }
        selectedPaths.subtract(items.map(\.path))
    }

    // MARK: - Cyberduck-style path popup

    private func pathMenu(current: String, onJump: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(ancestors(of: current), id: \.path) { item in
                Button {
                    onJump(item.path)
                } label: {
                    if item.path == current {
                        Label(item.label, systemImage: "checkmark")
                    } else {
                        Text(item.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: toolbarBodySize))
                    .foregroundStyle(.orange)
                Text(current.isEmpty ? "/\(connection.bucket)" : "/\(connection.bucket)/\(current)")
                    .font(.system(size: toolbarBodySize))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ancestors(of path: String) -> [(label: String, path: String)] {
        var segments = path.split(separator: "/").map(String.init)
        var result: [(label: String, path: String)] = []
        while true {
            let p = segments.joined(separator: "/")
            result.append(("/\(connection.bucket)" + (p.isEmpty ? "" : "/\(p)"), p))
            if segments.isEmpty { break }
            segments.removeLast()
        }
        return result
    }

    // MARK: - Navigation

    private func listCurrentPath() {
        selectedPaths.removeAll()
        rclone.listRemote(path: fullBrowsePath)
    }

    /// Manual "Actualizar" button — unlike `listCurrentPath` (used on first appear / navigation),
    /// this bypasses the 60s listing cache, for when a change made outside the app (or missed by
    /// the automatic post-mutation refresh) needs to show up right now.
    private func refreshCurrentFolder() {
        rclone.refreshRemote(path: fullBrowsePath)
    }

    /// Moves to a new directory (as opposed to `listCurrentPath`, which just re-lists whichever
    /// directory `browsePath` already points at) — pushes history so Back/Forward can undo it.
    private func goTo(_ newPath: String) {
        guard newPath != browsePath else { return }
        backStack.append(browsePath)
        forwardStack.removeAll()
        topLevelExpanded = false
        browsePath = newPath
        listCurrentPath()
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(browsePath)
        topLevelExpanded = false
        browsePath = previous
        listCurrentPath()
    }

    private func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(browsePath)
        topLevelExpanded = false
        browsePath = next
        listCurrentPath()
    }

    private func navigateInto(_ entry: RemoteEntry) {
        guard entry.IsDir else { return }
        goTo(browsePath.isEmpty ? entry.Name : "\(browsePath)/\(entry.Name)")
    }

    private func navigateUp() {
        if let idx = browsePath.lastIndex(of: "/") {
            goTo(String(browsePath[..<idx]))
        } else {
            goTo("")
        }
    }

    private func listPickerPath() {
        pickerTargetPath = nil
        rclone.listRemote(path: fullPickerPath, target: .picker)
    }

    private func navigatePickerUp() {
        if let idx = pickerPath.lastIndex(of: "/") {
            pickerPath = String(pickerPath[..<idx])
        } else {
            pickerPath = ""
        }
        listPickerPath()
    }

    private func confirmRename() {
        guard let target = renameTarget else { return }
        let newName = renameNewName
        renameNewName = ""
        let parent = parentPath(of: target.path)
        rclone.renameItem(target, to: newName) { _ in
            refreshAfterRemoteChange(at: parent)
        }
        selectedPaths.remove(target.path)
    }

    private func confirmCreateFolder() {
        let base = newFolderTarget == .explorer ? fullBrowsePath : fullPickerTargetPath
        let name = newFolderName
        newFolderName = ""
        rclone.createFolder(at: base, name: name) { success in
            guard success else { return }
            if newFolderTarget == .explorer {
                refreshCurrentFolder()
            } else {
                refreshPickerAfterChange(at: base)
            }
        }
    }

    // MARK: - Selection helpers

    private func fullPath(for entry: RemoteEntry, parent: String) -> String {
        parent.hasSuffix("/") ? parent + entry.Path : parent + "/" + entry.Path
    }

    private func parentPath(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return path }
        return String(path[..<idx])
    }

    private func register(parentPath: String, entries: [RemoteEntry]) {
        for e in entries {
            let fp = fullPath(for: e, parent: parentPath)
            pathRegistry[fp] = PathInfo(name: e.Name, isDir: e.IsDir, size: e.Size)
        }
    }

    private func toggleSelection(_ path: String) {
        if selectedPaths.contains(path) { selectedPaths.remove(path) } else { selectedPaths.insert(path) }
    }

    /// Plain click selects only this item (Finder-style) and moves the range anchor here;
    /// Cmd-click adds/removes it from the selection; Shift-click selects everything visible
    /// between the anchor and this item, same as Finder, without moving the anchor.
    private func selectItem(_ path: String, additive: Bool, rangeExtend: Bool = false) {
        searchFieldFocused = false
        if rangeExtend, let anchor = selectionAnchor {
            let order = visiblePathsInOrder
            if let anchorIndex = order.firstIndex(of: anchor), let targetIndex = order.firstIndex(of: path) {
                let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
                selectedPaths = Set(order[range])
                return
            }
        }
        selectionAnchor = path
        if additive {
            toggleSelection(path)
        } else {
            selectedPaths = [path]
        }
    }

    /// Every path currently on screen, in on-screen order — icons view is just the flat current
    /// folder; list view walks the tree but only descends into folders the user has expanded, so
    /// a Shift-click range matches exactly what's visible, not the whole (possibly huge) subtree.
    private var visiblePathsInOrder: [String] {
        switch viewMode {
        case .icons:
            return rclone.remoteEntries.map { fullPath(for: $0, parent: fullBrowsePath) }
        case .list:
            func flatten(_ nodes: [ExplorerNode]) -> [String] {
                nodes.flatMap { node -> [String] in
                    var result = [node.fullPath]
                    if node.isExpanded { result += flatten(node.children) }
                    return result
                }
            }
            return flatten(rootNodes)
        }
    }

    private func toggleSelectAll() {
        let topLevelPaths = rclone.remoteEntries.map { fullPath(for: $0, parent: fullBrowsePath) }
        if allSelected {
            selectedPaths.subtract(topLevelPaths)
        } else {
            selectedPaths.formUnion(topLevelPaths)
        }
    }

    /// Unconditional version of the toggle above, for ⌘A — pressing "select all" again while
    /// everything is already selected should stay a no-op, never flip into deselecting.
    private func selectAllTopLevel() {
        selectedPaths.formUnion(rclone.remoteEntries.map { fullPath(for: $0, parent: fullBrowsePath) })
    }

    // MARK: - Keyboard shortcuts (act on the current selection, same as Finder — no menu needs
    // to be open). Each guards its own precondition (single item, non-empty selection, etc.) so
    // the shortcut is simply a no-op when it doesn't apply, instead of needing `.disabled` logic
    // wired up for a button nobody sees.

    private func shortcutPreview() {
        guard selectedItems.count == 1, let item = selectedItems.first, !item.isDir else { return }
        previewFile(item)
    }

    private func shortcutRename() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        renameTarget = item
        renameNewName = item.name
        showRenamePrompt = true
    }

    private func shortcutCopyPath() {
        guard !selectedItems.isEmpty else { return }
        copyToPasteboard(selectedItems.map(\.path).joined(separator: "\n"))
    }

    private func shortcutShowInfo() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        showInfo(for: item)
    }

    private func shortcutDownload() {
        guard !selectedItems.isEmpty else { return }
        downloadDefault(selectedItems)
    }

    private func shortcutDownloadChoosing() {
        guard !selectedItems.isEmpty else { return }
        downloadChoosingFolder(selectedItems)
    }

    private func shortcutShareLink() {
        guard selectedItems.count == 1, let item = selectedItems.first, !item.isDir else { return }
        shareItem = item
        shareViewLink = nil
        shareDownloadLink = nil
        viewLinkCopied = false
        downloadLinkCopied = false
        downloadCredAccountID = ""
        downloadCredAppKey = ""
        shareDurationDays = 7
        shareLinkErrorMessage = nil
        isGeneratingViewLink = false
        isGeneratingDownloadLink = false
        showShareSheet = true
    }

    /// Invisible buttons — `.keyboardShortcut` needs an actual view in the hierarchy to bind to,
    /// but there's no matching visible button for these (they only otherwise exist inside the
    /// right-click menu). `.hidden()` keeps them out of layout/sight while keeping the shortcut live.
    private var keyboardShortcutButtons: some View {
        // Split into two Groups — SwiftUI's ViewBuilder only synthesizes buildBlock up to 10
        // children per block, and this needs 11 buttons.
        Group {
            Group {
                Button("") {
                    newFolderTarget = .explorer
                    newFolderName = ""
                    showNewFolderPrompt = true
                }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("", action: shortcutPreview).keyboardShortcut(.space, modifiers: [])
                Button("", action: shortcutRename).keyboardShortcut(.return, modifiers: [])
                Button("", action: shortcutCopyPath).keyboardShortcut("c", modifiers: [.command, .option])
                Button("", action: shortcutShowInfo).keyboardShortcut("i", modifiers: .command)
            }
            Group {
                Button("", action: shortcutDownload).keyboardShortcut("d", modifiers: .command)
                Button("", action: shortcutDownloadChoosing).keyboardShortcut("d", modifiers: [.command, .shift])
                Button("") { uploadFiles(into: fullBrowsePath) }.keyboardShortcut("u", modifiers: .command)
                Button("") { uploadFolder(into: fullBrowsePath) }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("", action: shortcutShareLink).keyboardShortcut("l", modifiers: .command)
                Button("", action: selectAllTopLevel).keyboardShortcut("a", modifiers: .command)
            }
        }
        .hidden()
    }

    // MARK: - Formatting

    /// Re-sorts the tree in place (root + every already-expanded folder, recursively) instead of
    /// rebuilding it — clicking a column header shouldn't collapse folders you already opened or
    /// re-fetch children that are already loaded, just reorder what's already there.
    private func resortWholeTree() {
        rootNodes = sortedNodes(rootNodes)
        func sortChildren(_ node: ExplorerNode) {
            node.children = sortedNodes(node.children)
            for child in node.children { sortChildren(child) }
        }
        for node in rootNodes { sortChildren(node) }
    }

    private func sortedNodes(_ nodes: [ExplorerNode]) -> [ExplorerNode] {
        let byPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.entry.Path, $0) })
        return sortedEntries(nodes.map(\.entry)).compactMap { byPath[$0.Path] }
    }

    /// Applied wherever the list view builds a level of the tree (root + each expanded folder's
    /// children) — the icon grid is untouched, this is specifically about the list's columns.
    private func sortedEntries(_ entries: [RemoteEntry]) -> [RemoteEntry] {
        let ascending = entries.sorted { a, b in
            switch sortColumn {
            case .name:
                return a.Name.localizedStandardCompare(b.Name) == .orderedAscending
            case .type:
                let ta = typeLabel(name: a.Name, isDir: a.IsDir)
                let tb = typeLabel(name: b.Name, isDir: b.IsDir)
                return ta == tb
                    ? a.Name.localizedStandardCompare(b.Name) == .orderedAscending
                    : ta.localizedStandardCompare(tb) == .orderedAscending
            case .size:
                return a.Size < b.Size
            case .modified:
                return (a.ModTime ?? "") < (b.ModTime ?? "")
            }
        }
        return sortAscending ? ascending : ascending.reversed()
    }

    /// Human-readable kind for the "Tipo" column — UTType already knows "PDF document"/"JPEG
    /// image"/etc. per extension and gives it in the system's own language, same source macOS's
    /// own Finder "Kind" column uses, instead of hand-maintaining a translation table per extension.
    private func typeLabel(name: String, isDir: Bool) -> String {
        if isDir { return String(localized: "Carpeta") }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return String(localized: "Documento")
        }
        return type.localizedDescription ?? ext.uppercased()
    }

    private func iconName(for filename: String) -> String {
        if ImageKind.isImage(filename) { return "photo.fill" }
        switch (filename as NSString).pathExtension.lowercased() {
        case "epub": return "book.closed.fill"
        case "pdf": return "doc.richtext.fill"
        case "zip", "rar", "7z": return "doc.zipper"
        case "mp4", "mov", "m4v": return "film.fill"
        default: return "doc.fill"
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        bytes < 0 ? "" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func megabytesText(_ bytes: Int64) -> String {
        guard bytes >= 0 else { return "—" }
        let megabytes = Double(bytes) / 1_048_576
        guard megabytes >= 1000 else { return String(format: "%.1f MB", megabytes) }
        return String(format: "%.1f GB", megabytes / 1024)
    }

    private static let modTimeParsers: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()

    private static let modTimeDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yy/MM/dd - HH:mm"
        return f
    }()

    private func formattedModTime(_ modTime: String?) -> String {
        guard let modTime, let date = Self.modTimeParsers.lazy.compactMap({ $0.date(from: modTime) }).first else {
            return "—"
        }
        return Self.modTimeDisplay.string(from: date)
    }
}
