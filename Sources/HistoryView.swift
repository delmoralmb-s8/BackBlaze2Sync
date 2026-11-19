import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var rclone: RcloneManager

    // ~15% larger than the default .callout/.caption/.caption2 this view used before, so the
    // history is easier to read at a glance — Bernabe found the previous sizes too small.
    private static let rowFontSize: CGFloat = 14
    private static let itemRowFontSize: CGFloat = 12.5
    private static let detailFontSize: CGFloat = 11.5

    private struct DayGroup: Identifiable {
        let day: Date
        let records: [OperationRecord]
        var id: Date { day }
    }

    private enum HistoryTab: Hashable {
        case all
        case watchFolder
    }

    @State private var selectedTab: HistoryTab = .all

    private var visibleHistory: [OperationRecord] {
        guard selectedTab == .watchFolder else { return rclone.history }
        guard let target = rclone.watchFolderTargetPath() else { return [] }
        return rclone.history.filter { $0.remotePath == target }
    }

    private struct WatchFolderStats {
        let firstActivatedAt: Date?
        let isCurrentlyActive: Bool
        let lastDeactivatedAt: Date?
        let uploadCount: Int
        let averageSpeedMBps: Double?
        let totalMegabytes: Double
        let destination: String?
    }

    /// Built entirely from the shared `rclone.history` — "activada"/"desactivada" events are
    /// recorded by RcloneManager itself whenever `watchFolderActive` flips, right alongside the
    /// "Conectado"/"Desconectado" connection events already logged there, so no separate
    /// persisted state is needed here to answer "when did this first turn on" or "is it on now".
    private var watchFolderStats: WatchFolderStats {
        let toggles = rclone.history
            .filter { $0.type == "Sincronización activada" || $0.type == "Sincronización desactivada" }
        let firstActivatedAt = toggles
            .filter { $0.type == "Sincronización activada" }
            .map(\.date)
            .min()
        let lastToggle = toggles.max { $0.date < $1.date }
        let isCurrentlyActive = lastToggle?.type == "Sincronización activada"

        let uploads = rclone.history.filter { $0.type == "Subida" && $0.remotePath == rclone.watchFolderTargetPath() }
        let speeds = uploads.compactMap(\.megabytesPerSecond)

        return WatchFolderStats(
            firstActivatedAt: firstActivatedAt,
            isCurrentlyActive: isCurrentlyActive,
            lastDeactivatedAt: isCurrentlyActive ? nil : lastToggle?.date,
            uploadCount: uploads.reduce(0) { $0 + $1.fileCount },
            averageSpeedMBps: speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count),
            totalMegabytes: uploads.reduce(0) { $0 + $1.megabytes },
            destination: rclone.watchFolderTargetPath() ?? uploads.first?.remotePath
        )
    }

    /// `visibleHistory` is already newest-first (rclone.history has each new entry inserted at
    /// index 0), so building `order` by first-seen day as we walk it keeps the day sections
    /// newest-first too, with no separate sort needed.
    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [OperationRecord]] = [:]
        for record in visibleHistory {
            let day = calendar.startOfDay(for: record.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(record)
        }
        return order.map { DayGroup(day: $0, records: buckets[$0] ?? []) }
    }

    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Historial de operaciones").font(.headline)
                Spacer()
                Button("Borrar historial") { showClearConfirm = true }
                    .disabled(rclone.history.isEmpty)
                    .confirmationDialog(
                        "¿Borrar todo el historial?",
                        isPresented: $showClearConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Borrar historial", role: .destructive) { rclone.clearHistory() }
                        Button("Cancelar", role: .cancel) {}
                    } message: {
                        Text("Esto no se puede deshacer.")
                    }
            }
            .padding()
            if !rclone.watchFolderPath.isEmpty {
                Picker("", selection: $selectedTab) {
                    Text("Todas").tag(HistoryTab.all)
                    Text("📁 \(URL(fileURLWithPath: rclone.watchFolderPath).lastPathComponent)").tag(HistoryTab.watchFolder)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.bottom, 10)
                if selectedTab == .watchFolder {
                    watchFolderStatsPanel
                }
            }
            Divider()
            if visibleHistory.isEmpty {
                Text("Todavía no hay operaciones registradas.")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List {
                    ForEach(groupedByDay) { group in
                        Section(header: dayHeader(for: group.day)) {
                            ForEach(group.records) { record in
                                if record.items.count > 1 {
                                    DisclosureGroup {
                                        ForEach(record.items) { item in
                                            HStack {
                                                Text(item.id).font(.system(size: Self.itemRowFontSize)).lineLimit(1)
                                                Spacer()
                                                Text(String(format: "%.2f MB", item.megabytes))
                                                    .font(.system(size: Self.itemRowFontSize))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    } label: {
                                        recordSummary(record)
                                    }
                                } else {
                                    recordSummary(record)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    private var watchFolderStatsPanel: some View {
        let stats = watchFolderStats
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                statRow(label: "Activada por primera vez", value: dateOrDashText(stats.firstActivatedAt))
                statRow(label: "Estado actual", value: statusText(for: stats))
                statRow(label: "Archivos subidos", value: Text("\(stats.uploadCount)"))
                statRow(label: "Velocidad promedio", value: stats.averageSpeedMBps.map { Text(String(format: "%.1f MB/s", $0)) } ?? Text("—"))
                statRow(label: "Destino", value: Text(stats.destination ?? "—"))
                statRow(label: "Total subido", value: Text(totalSizeLabel(megabytes: stats.totalMegabytes)))
            }
            .padding(4)
        }
        .padding(.horizontal)
    }

    private func statRow(label: LocalizedStringKey, value: Text) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            value
        }
        .font(.system(size: Self.rowFontSize))
    }

    private func dateOrDashText(_ date: Date?) -> Text {
        guard let date else { return Text("—") }
        return Text(date.formatted(date: .abbreviated, time: .shortened))
    }

    private func statusText(for stats: WatchFolderStats) -> Text {
        if stats.isCurrentlyActive { return Text(LocalizedStringKey("Activa")) }
        guard let lastDeactivatedAt = stats.lastDeactivatedAt else { return Text(LocalizedStringKey("Inactiva")) }
        return Text(LocalizedStringKey("Inactiva desde ")) + Text(lastDeactivatedAt.formatted(date: .abbreviated, time: .shortened))
    }

    private func totalSizeLabel(megabytes: Double) -> String {
        megabytes >= 1024 ? String(format: "%.2f GB", megabytes / 1024) : String(format: "%.1f MB", megabytes)
    }

    private func dayHeader(for day: Date) -> Text {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return Text("Hoy") }
        if calendar.isDateInYesterday(day) { return Text("Ayer") }
        return Text(day.formatted(date: .long, time: .omitted))
    }

    private static let eventTypes: Set<String> = [
        "Conectado", "Desconectado", "Sincronización activada", "Sincronización desactivada",
        "Carpeta no encontrada", "Carpeta encontrada de nuevo",
        "Renombrar", "Nueva carpeta", "URL generada", "Reintento",
        "Verificación de tamaño", "Verificación profunda",
        "Carpeta cambiada", "Destino cambiado", "Borrado en B2 activado", "Borrado en B2 desactivado",
        "App actualizada", "Apagado programado", "Apagado cancelado", "Mac apagada",
    ]

    @ViewBuilder
    private func recordSummary(_ record: OperationRecord) -> some View {
        if Self.eventTypes.contains(record.type) {
            eventRow(record)
        } else {
            operationRow(record)
        }
    }

    private func eventIconAndColor(for type: String) -> (symbol: String, color: Color) {
        switch type {
        case "Conectado": return ("link.circle.fill", .green)
        case "Desconectado": return ("link.circle", .secondary)
        case "Sincronización activada": return ("eye.circle.fill", .green)
        case "Sincronización desactivada": return ("eye.slash.circle", .secondary)
        case "Carpeta no encontrada": return ("exclamationmark.triangle.fill", .orange)
        case "Carpeta encontrada de nuevo": return ("checkmark.circle.fill", .green)
        case "Renombrar": return ("pencil.circle.fill", .blue)
        case "Nueva carpeta": return ("folder.badge.plus", .blue)
        case "URL generada": return ("link.badge.plus", .blue)
        case "Reintento": return ("arrow.clockwise.circle.fill", .orange)
        case "Verificación de tamaño", "Verificación profunda": return ("checkmark.shield.fill", .green)
        case "Carpeta cambiada": return ("folder.circle.fill", .blue)
        case "Destino cambiado": return ("arrow.triangle.turn.up.right.circle.fill", .blue)
        case "Borrado en B2 activado": return ("trash.circle.fill", .red)
        case "Borrado en B2 desactivado": return ("trash.slash.circle", .secondary)
        case "App actualizada": return ("arrow.down.app.fill", .green)
        case "Apagado programado": return ("power.circle.fill", .orange)
        case "Apagado cancelado": return ("xmark.circle", .secondary)
        case "Mac apagada": return ("power.circle", .secondary)
        default: return ("questionmark.circle", .secondary)
        }
    }

    /// Events that can fail show a red cross instead of their usual icon; "Carpeta no encontrada"
    /// is already a warning by nature, so it keeps its own orange triangle.
    private static let failableEvents: Set<String> = [
        "Renombrar", "Nueva carpeta", "URL generada", "Verificación de tamaño", "Verificación profunda",
    ]

    private func eventRow(_ record: OperationRecord) -> some View {
        let failed = !record.success && Self.failableEvents.contains(record.type)
        let icon = failed ? (symbol: "xmark.octagon.fill", color: Color.red) : eventIconAndColor(for: record.type)
        return HStack {
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            Image(systemName: icon.symbol).foregroundStyle(icon.color)
            Text(LocalizedStringKey(record.type))
            if let detail = record.detail {
                // "Reintento" stores the failed operation's type ("Subida"...), which does localize.
                (record.type == "Reintento" ? Text(LocalizedStringKey(detail)) : Text(detail))
                    .foregroundStyle(.secondary)
            }
            if record.type == "Verificación profunda", record.fileCount > 0 {
                Text("\(record.fileCount) archivo(s)").foregroundStyle(.secondary)
            }
            if let remotePath = record.remotePath, let prefix = Self.pathPrefix(for: record.type) {
                (Text(LocalizedStringKey(prefix)) + Text(remotePath)).foregroundStyle(.secondary)
            }
            if failed { Text(LocalizedStringKey("Falla")).foregroundStyle(.red) }
            Spacer()
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .font(.system(size: Self.rowFontSize))
    }

    /// Which events show their bucket path after the detail, and with which connecting word
    /// ("de " and "→ " already exist in the catalog from the operation rows).
    private static func pathPrefix(for type: String) -> String? {
        switch type {
        case "Renombrar", "URL generada": return "de "
        case "Nueva carpeta", "Destino cambiado": return "→ "
        default: return nil
        }
    }

    /// (SF Symbol name, tint) per operation type — record.type is always one of these six literal
    /// Spanish strings, set by RcloneManager.recordOperation's callers, never user-facing text to
    /// translate on its own.
    private func iconAndColor(for type: String) -> (symbol: String, color: Color) {
        switch type {
        case "Subida": return ("icloud.and.arrow.up.fill", .blue)
        case "Descarga": return ("icloud.and.arrow.down.fill", .blue)
        case "Mover": return ("arrow.right.circle.fill", .orange)
        case "Copiar": return ("doc.on.doc.fill", .purple)
        case "Borrar": return ("trash.fill", .red)
        case "Comprimir": return ("doc.zipper", .brown)
        default: return ("questionmark.circle.fill", .secondary)
        }
    }

    private func operationRow(_ record: OperationRecord) -> some View {
        let icon = iconAndColor(for: record.type)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.date.formatted(date: .omitted, time: .shortened))
                    .frame(width: 70, alignment: .leading)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon.symbol).foregroundStyle(icon.color)
                Text(LocalizedStringKey(record.type)).foregroundStyle(.secondary)
                Text("\(record.fileCount) archivo(s)").foregroundStyle(.secondary)
                Text(sizeLabel(for: record))
                    .foregroundStyle(.secondary)
                if let speed = record.megabytesPerSecond {
                    Text(String(format: "%.1f MB/s", speed)).foregroundStyle(.secondary)
                }
                // ponytail: ternary-of-literals into Label(_:systemImage:) picks the verbatim
                // StringProtocol overload — wrap in LocalizedStringKey so it actually localizes.
                Label(LocalizedStringKey(record.success ? "Éxito" : "Falla"), systemImage: record.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(record.success ? .green : .red)
                    .labelStyle(.iconOnly)
            }
            .font(.system(size: Self.rowFontSize))

            if let detail = detailLine(for: record) {
                detail
                    .font(.system(size: Self.detailFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// The filename only makes sense here when there's exactly one item — with more than one,
    /// the row above becomes a `DisclosureGroup` that already lists every file individually.
    /// For "Subida" that's the bucket folder it landed in; for "Descarga" it's the bucket folder
    /// it came FROM plus the local folder it landed in — B2 side and Mac side, in that order.
    ///
    /// Returns `Text`, not `String` — a plain `String` handed to `Text(_:)` always renders
    /// verbatim (the well-known gotcha elsewhere in this app), so "de"/"desde" baked into a
    /// joined String would never localize no matter what the catalog says. Building it as `Text`
    /// concatenation keeps "de"/"desde" translatable while file names and paths (real user data,
    /// correctly NOT meant to translate) stay verbatim since they're Text(variable) all along.
    private func detailLine(for record: OperationRecord) -> Text? {
        var parts: [Text] = []
        if record.items.count == 1, let name = record.items.first?.id {
            parts.append(Text(name))
        }
        if record.type == "Subida", let remotePath = record.remotePath {
            parts.append(Text("→ ") + Text(remotePath))
        }
        if record.type == "Descarga" {
            if let remotePath = record.remotePath {
                parts.append(Text("desde ") + Text(remotePath))
            }
            if let localPath = record.localPath {
                parts.append(Text("→ ") + Text(localPath))
            }
        }
        if record.type == "Borrar", let remotePath = record.remotePath {
            parts.append(Text("de ") + Text(remotePath))
        }
        if record.type == "Mover" || record.type == "Copiar" {
            if let source = record.sourceRemotePath {
                parts.append(Text("de ") + Text(source))
            }
            if let remotePath = record.remotePath {
                parts.append(Text("→ ") + Text(remotePath))
            }
        }
        // rclone's own error text for a failed operation (rclone only speaks English, so verbatim).
        if !record.success, let reason = record.detail, !reason.isEmpty {
            parts.append(Text(reason).foregroundColor(.red))
        }
        guard var result = parts.first else { return nil }
        for part in parts.dropFirst() { result = result + Text("  ") + part }
        return result
    }

    private func sizeLabel(for record: OperationRecord) -> String {
        if record.megabytesBefore > 0 {
            return String(format: "%.1f MB → %.1f MB", record.megabytesBefore, record.megabytes)
        }
        return record.megabytes > 0 ? String(format: "%.1f MB", record.megabytes) : "—"
    }
}
