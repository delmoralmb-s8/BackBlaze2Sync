import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var rclone: RcloneManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Historial de operaciones").font(.headline).padding()
            Divider()
            if rclone.history.isEmpty {
                Text("Todavía no hay operaciones registradas.")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(rclone.history) { record in
                    if record.items.count > 1 {
                        DisclosureGroup {
                            ForEach(record.items) { item in
                                HStack {
                                    Text(item.id).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(String(format: "%.2f MB", item.megabytes))
                                        .font(.caption)
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
        .frame(minWidth: 560, minHeight: 400)
    }

    private func recordSummary(_ record: OperationRecord) -> some View {
        HStack {
            Text(record.date.formatted(date: .abbreviated, time: .standard))
            Spacer()
            Text(record.type).foregroundStyle(.secondary)
            Text("\(record.fileCount) archivo(s)").foregroundStyle(.secondary)
            Text(sizeLabel(for: record))
                .foregroundStyle(.secondary)
            // ponytail: ternary-of-literals into Label(_:systemImage:) picks the verbatim
            // StringProtocol overload — wrap in LocalizedStringKey so it actually localizes.
            Label(LocalizedStringKey(record.success ? "Éxito" : "Falla"), systemImage: record.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(record.success ? .green : .red)
                .labelStyle(.iconOnly)
        }
        .font(.callout)
    }

    private func sizeLabel(for record: OperationRecord) -> String {
        if record.megabytesBefore > 0 {
            return String(format: "%.1f MB → %.1f MB", record.megabytesBefore, record.megabytes)
        }
        return record.megabytes > 0 ? String(format: "%.1f MB", record.megabytes) : "—"
    }
}
