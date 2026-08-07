import SwiftUI

/// An image entry paired with its fully-qualified remote path — computed once per
/// listing so grid cells and the lightbox don't each need to reconstruct it.
private struct GalleryImage: Identifiable {
    let entry: RemoteEntry
    let fullPath: String
    var id: String { fullPath }
}

/// Independent, read-only image browser — its own navigation state after opening, shares only
/// the active connection and RcloneManager with the main window. Opens at whichever folder the
/// Explorer was showing at the moment the window was created (see `initialPath`); navigates
/// independently from there on — no selection, upload, or mutation here (that's Explorer's job).
struct GalleryView: View {
    /// Fixed on purpose — always "DELETE" in every language, per Bernabe's request, instead of
    /// localizing the word itself (which used to be the Spanish "borrar" in all locales).
    static let deleteConfirmWord = "DELETE"

    @EnvironmentObject var rclone: RcloneManager
    @EnvironmentObject var connectionStore: ConnectionStore
    @StateObject private var thumbnails = ThumbnailStore()

    @State private var browsePath: String
    @State private var entries: [RemoteEntry] = []
    @State private var isLoading = false
    @State private var lightboxIndex: Int?

    @State private var showInfoSheet = false
    @State private var infoEntry: RemoteEntry?
    @State private var infoPath = ""
    @State private var infoFolderSize: FolderSizeInfo?
    @State private var isLoadingInfoSize = false

    @State private var showDeleteSheet = false
    @State private var deleteEntry: RemoteEntry?
    @State private var deletePath = ""
    @State private var deleteConfirmText = ""

    init(initialPath: String) {
        _browsePath = State(initialValue: initialPath)
    }

    private var connection: Connection { connectionStore.active }
    private var fullBrowsePath: String { connection.remotePrefix + browsePath }

    private var folders: [RemoteEntry] { entries.filter(\.IsDir) }
    private var images: [GalleryImage] {
        entries
            .filter { !$0.IsDir && ImageKind.isImage($0.Name) }
            .map { GalleryImage(entry: $0, fullPath: fullPath(for: $0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 12)], spacing: 12) {
                    ForEach(folders) { entry in
                        folderCell(entry)
                    }
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        imageCell(image, index: index)
                    }
                }
                .padding()
            }

            if entries.isEmpty && !isLoading {
                Text("Esta carpeta no tiene imágenes ni subcarpetas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task(id: fullBrowsePath) { await load() }
        .overlay {
            if let index = lightboxIndex, images.indices.contains(index) {
                LightboxView(
                    images: images,
                    index: index,
                    thumbnails: thumbnails,
                    rclone: rclone,
                    onClose: { lightboxIndex = nil },
                    onNavigate: { lightboxIndex = $0 },
                    onDownload: { downloadOriginal($0.entry, path: $0.fullPath) },
                    onShowInfo: { showInfo(for: $0.entry, path: $0.fullPath) },
                    onDelete: {
                        lightboxIndex = nil
                        startDelete(for: $0.entry, path: $0.fullPath)
                    }
                )
            }
        }
        .sheet(isPresented: $showInfoSheet) { infoSheet }
        .sheet(isPresented: $showDeleteSheet) { deleteSheet }
    }

    private var header: some View {
        HStack {
            Button { navigateUp() } label: { Image(systemName: "arrow.up") }
                .disabled(browsePath.isEmpty)
                .help("Subir un nivel")
            Text(browsePath.isEmpty ? "/\(connection.bucket)" : "/\(connection.bucket)/\(browsePath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding([.horizontal, .top])
    }

    private func folderCell(_ entry: RemoteEntry) -> some View {
        let path = fullPath(for: entry)
        return VStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .frame(height: 60)
            Text(entry.Name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: 140, height: 120)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { navigateInto(entry) }
        .contextMenu {
            Button("Descargar carpeta como .zip") { downloadFolderZip(entry, path: path) }
            Button("Ver tamaño") { showInfo(for: entry, path: path) }
            Divider()
            Button("Borrar…", role: .destructive) { startDelete(for: entry, path: path) }
        }
    }

    private func imageCell(_ image: GalleryImage, index: Int) -> some View {
        VStack(spacing: 4) {
            ThumbnailCell(entry: image.entry, remotePath: image.fullPath, thumbnails: thumbnails, rclone: rclone)
            Text(image.entry.Name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(megabytesText(image.entry.Size)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: ThumbnailCell.side)
        .contentShape(Rectangle())
        .onTapGesture { lightboxIndex = index }
        .contextMenu {
            Button("Descargar foto original") { downloadOriginal(image.entry, path: image.fullPath) }
            Button("Ver tamaño") { showInfo(for: image.entry, path: image.fullPath) }
            Divider()
            Button("Borrar…", role: .destructive) { startDelete(for: image.entry, path: image.fullPath) }
        }
    }

    // MARK: - Context menu actions

    private func downloadFolderZip(_ entry: RemoteEntry, path: String) {
        rclone.downloadFolderAsZip(RemotePathItem(path: path, name: entry.Name, isDir: true))
    }

    private func downloadOriginal(_ entry: RemoteEntry, path: String) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Downloads")
        rclone.downloadItems([RemotePathItem(path: path, name: entry.Name, isDir: false)], toLocalFolder: downloads)
    }

    private func showInfo(for entry: RemoteEntry, path: String) {
        infoEntry = entry
        infoPath = path
        infoFolderSize = nil
        showInfoSheet = true
        if entry.IsDir {
            isLoadingInfoSize = true
            rclone.folderSize(path: path) { size in
                infoFolderSize = size
                isLoadingInfoSize = false
            }
        }
    }

    private var infoSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = infoEntry {
                Text(entry.Name).font(.headline)
                Divider()
                LabeledContent("Ruta", value: infoPath)
                // ponytail: LabeledContent's `value:` parameter is typed as plain StringProtocol,
                // never LocalizedStringKey — even a literal ternary there stays verbatim, so wrap
                // explicitly with String(localized:) to actually pull from the catalog.
                LabeledContent("Tipo", value: entry.IsDir ? String(localized: "Carpeta") : String(localized: "Archivo"))
                if entry.IsDir {
                    if isLoadingInfoSize {
                        ProgressView().controlSize(.small)
                    } else if let size = infoFolderSize {
                        LabeledContent("Elementos", value: "\(size.count)")
                        LabeledContent("Tamaño total", value: formattedSize(size.bytes))
                    } else {
                        Text("No se pudo calcular el tamaño.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Tamaño", value: formattedSize(entry.Size))
                }
            }
            HStack {
                Spacer()
                Button("Cerrar") { showInfoSheet = false }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func startDelete(for entry: RemoteEntry, path: String) {
        deleteEntry = entry
        deletePath = path
        deleteConfirmText = ""
        showDeleteSheet = true
    }

    private var deleteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ponytail: a ternary of two literals passed straight to Text() resolves to the
            // verbatim String overload (same for the ternary nested inside string interpolation
            // just below) — LocalizedStringKey(_:) wrap fixes the title, and splitting the two
            // full sentences into their own literal Text() calls fixes the message.
            Text(LocalizedStringKey(deleteEntry?.IsDir == true ? "Borrar carpeta" : "Borrar archivo")).font(.headline)
            if let entry = deleteEntry {
                Group {
                    if entry.IsDir {
                        Text("\"\(entry.Name)\" y todo su contenido se va a borrar de B2. Esto no se puede deshacer.")
                    } else {
                        Text("\"\(entry.Name)\" se va a borrar de B2. Esto no se puede deshacer.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            // Note: the required word is always "DELETE" (English), in every language, on
            // purpose — the actual check below compares against the literal string "delete"
            // regardless of locale. Only the sentence AROUND it is translated; the word itself is
            // interpolated so it stays fixed while the sentence structure still localizes.
            Text("Escribe **\(Self.deleteConfirmWord)** para confirmar:")
                .font(.caption)
            TextField(Self.deleteConfirmWord, text: $deleteConfirmText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancelar") { showDeleteSheet = false }
                Spacer()
                Button("Borrar") { confirmDelete() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(deleteConfirmText.trimmingCharacters(in: .whitespaces).uppercased() != Self.deleteConfirmWord)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func confirmDelete() {
        guard let entry = deleteEntry else { return }
        let item = RemotePathItem(path: deletePath, name: entry.Name, isDir: entry.IsDir)
        showDeleteSheet = false
        rclone.deleteItems([item]) { _ in
            Task { await load() }
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        bytes < 0 ? "" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func megabytesText(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(max(bytes, 0)) / 1_048_576)
    }

    private func fullPath(for entry: RemoteEntry) -> String {
        fullBrowsePath.hasSuffix("/") ? fullBrowsePath + entry.Path : fullBrowsePath + "/" + entry.Path
    }

    private func navigateInto(_ entry: RemoteEntry) {
        guard entry.IsDir else { return }
        browsePath = browsePath.isEmpty ? entry.Name : "\(browsePath)/\(entry.Name)"
    }

    private func navigateUp() {
        if let idx = browsePath.lastIndex(of: "/") {
            browsePath = String(browsePath[..<idx])
        } else {
            browsePath = ""
        }
    }

    private func load() async {
        isLoading = true
        entries = await withCheckedContinuation { continuation in
            rclone.listEntries(path: fullBrowsePath) { continuation.resume(returning: $0) }
        }
        isLoading = false
    }
}

/// One grid cell: shows a spinner until its thumbnail loads (or comes from cache), and
/// cancels its own fetch automatically when scrolled off-screen (LazyVGrid + .task(id:)).
///
/// The `.frame` + `.clipped()` on the Image itself (not just the outer container) is what
/// actually stops a wide/tall photo from bleeding into neighboring cells — `aspectRatio(.fill)`
/// deliberately renders bigger than its box to cover it, so without clipping right where it's
/// sized, the overflow paints over whatever grid cell happens to be next to it.
private struct ThumbnailCell: View {
    static let side: CGFloat = 140

    let entry: RemoteEntry
    let remotePath: String
    let thumbnails: ThumbnailStore
    let rclone: RcloneManager

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipped()
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: entry.Path) {
            image = await thumbnails.thumbnail(for: entry, remotePath: remotePath, rclone: rclone)
        }
    }
}

/// Full-screen viewer. The full-resolution image itself is only cached in memory for
/// this session (not disk — see roadmap.md on why), but reopening the SAME photo via
/// Anterior/Siguiente is instant once loaded once. Opening shows the already-cached
/// thumbnail immediately (blurred, as a placeholder) while the full-res fetch runs, so
/// there's something on screen right away instead of a blank spinner.
private struct LightboxView: View {
    let images: [GalleryImage]
    let index: Int
    let thumbnails: ThumbnailStore
    let rclone: RcloneManager
    let onClose: () -> Void
    let onNavigate: (Int) -> Void
    let onDownload: (GalleryImage) -> Void
    let onShowInfo: (GalleryImage) -> Void
    let onDelete: (GalleryImage) -> Void

    @State private var placeholder: NSImage?
    @State private var image: NSImage?
    @FocusState private var isFocused: Bool

    private var current: GalleryImage { images[index] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(40)
                    .contextMenu {
                        Button("Descargar foto original") { onDownload(current) }
                        Button("Ver tamaño") { onShowInfo(current) }
                        Divider()
                        Button("Borrar…", role: .destructive) { onDelete(current) }
                    }
            } else if let placeholder {
                Image(nsImage: placeholder)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(40)
                    .blur(radius: 10)
                    .overlay(ProgressView().controlSize(.large).tint(.white))
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding()
                }
                Spacer()
                HStack {
                    Button { onNavigate(index - 1) } label: {
                        Image(systemName: "chevron.left.circle.fill").font(.system(size: 32))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    Spacer()
                    Text(current.entry.Name).font(.caption)
                    Spacer()
                    Button { onNavigate(index + 1) } label: {
                        Image(systemName: "chevron.right.circle.fill").font(.system(size: 32))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == images.count - 1)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .task(id: current.fullPath) {
            image = nil
            placeholder = await thumbnails.cachedThumbnailIfAvailable(for: current.entry, remotePath: current.fullPath)
            image = await thumbnails.fullImage(remotePath: current.fullPath, rclone: rclone)
        }
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) {
            if index > 0 { onNavigate(index - 1) }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if index < images.count - 1 { onNavigate(index + 1) }
            return .handled
        }
    }
}
