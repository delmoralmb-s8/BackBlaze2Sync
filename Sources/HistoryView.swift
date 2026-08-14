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

    /// `rclone.history` is already newest-first (each new entry is inserted at index 0), so
    /// building `order` by first-seen day as we walk it keeps the day sections newest-first too,
    /// with no separate sort needed.
    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [OperationRecord]] = [:]
        for record in rclone.history {
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
            Divider()
            if rclone.history.isEmpty {
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

    private func dayHeader(for day: Date) -> Text {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return Text("Hoy") }
        if calendar.isDateInYesterday(day) { return Text("Ayer") }
        return Text(day.formatted(date: .long, time: .omitted))
    }

    @ViewBuilder
    private func recordSummary(_ record: OperationRecord) -> some View {
        if record.type == "Conectado" || record.type == "Desconectado" {
            connectionEventRow(record)
        } else {
            operationRow(record)
        }
    }

    private func connectionEventRow(_ record: OperationRecord) -> some View {
        HStack {
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            Image(systemName: record.type == "Conectado" ? "link.circle.fill" : "link.circle")
                .foregroundStyle(record.type == "Conectado" ? .green : .secondary)
            Text(LocalizedStringKey(record.type))
            if let detail = record.detail {
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: Self.rowFontSize))
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
                Text(record.type).foregroundStyle(.secondary)
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
