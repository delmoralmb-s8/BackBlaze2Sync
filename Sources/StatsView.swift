import SwiftUI

struct StatsView: View {
    @EnvironmentObject var rclone: RcloneManager
    @EnvironmentObject var connectionStore: ConnectionStore

    @State private var bucketStats: BucketStats?
    @State private var isScanning = false
    @State private var scanFailed = false

    // $6.95/TB/month, confirmed against backblaze.com/cloud-storage/pricing. B2's own first-10GB
    // free tier is subtracted below, everything else is one multiplication, no billing API needed.
    private static let pricePerTBPerMonth = 6.95
    private static let freeGB = 10.0

    private var basePath: String? {
        connectionStore.active.map { $0.remotePrefix }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                bucketSection
                Divider()
                activitySection
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 520)
        .task { refresh(force: false) }
    }

    private var header: some View {
        HStack {
            Text("Estadísticas").font(.headline)
            Spacer()
            if isScanning {
                ProgressView().controlSize(.small)
            } else if let stats = bucketStats {
                Text("Actualizado \(stats.scannedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Actualizar") { refresh(force: true) }
                .disabled(isScanning || basePath == nil)
        }
    }

    // MARK: - Bucket section (real scan of the whole bucket)

    private var bucketSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tu bucket ahora mismo").font(.headline)

            if basePath == nil {
                Text("Conéctate a un bucket para ver sus estadísticas.")
                    .foregroundStyle(.secondary)
            } else if scanFailed {
                Text("No se pudo escanear el bucket. Intenta \"Actualizar\".")
                    .foregroundStyle(.secondary)
            } else if let stats = bucketStats {
                statCard(icon: "externaldrive.fill", title: "Tamaño total", value: formattedSize(stats.totalBytes))
                statCard(icon: "clock.arrow.circlepath", title: "Archivo más antiguo", value: stats.oldestFileDate.map { $0.formatted(date: .long, time: .omitted) } ?? "—")
                if let largest = stats.largestFile {
                    statCard(icon: "doc.fill", title: "Archivo más pesado", value: "\(largest.name) (\(formattedSize(largest.bytes)))")
                }
                if let folder = stats.largestTopFolder {
                    statCard(icon: "folder.fill", title: "Carpeta más pesada", value: "\(folder.name) (\(formattedSize(folder.bytes)))")
                }
                statCard(icon: "dollarsign.circle.fill", title: "Costo estimado en B2", value: estimatedCost(totalBytes: stats.totalBytes))

                if !stats.categoryBytes.isEmpty {
                    Text("Por tipo de archivo").font(.subheadline).padding(.top, 4)
                    ForEach(stats.categoryBytes, id: \.category) { entry in
                        HStack {
                            Text(LocalizedStringKey(entry.category))
                            Spacer()
                            Text(formattedSize(entry.bytes)).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            } else if isScanning {
                Text("Escaneando el bucket completo… puede tardar en buckets grandes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Local activity section (this app's own history)

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tu actividad en BackBlaze2Sync").font(.headline)
            Text("Solo cuenta lo hecho con esta app (hasta las últimas 2000 operaciones), no todo lo que hay en el bucket.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let activity = rclone.localActivityStats()
            if let average = activity.averageMBPerDayUploaded {
                statCard(icon: "arrow.up.circle.fill", title: "Promedio subido por día", value: formattedMB(average) + "/día")
            }
            if let hour = activity.peakUploadHour {
                statCard(icon: "clock.fill", title: "Hora en la que más subes", value: String(format: "%02d:00", hour))
            }
            statCard(icon: "arrow.down.circle.fill", title: "Total descargado", value: formattedMB(activity.totalDownloadedMB))
        }
    }

    // MARK: - Helpers

    private func statCard(icon: String, title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func refresh(force: Bool) {
        guard let basePath else { return }
        isScanning = true
        scanFailed = false
        rclone.scanBucketStats(basePath: basePath, forceRefresh: force) { stats in
            isScanning = false
            if let stats {
                bucketStats = stats
            } else {
                scanFailed = true
            }
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formattedMB(_ megabytes: Double) -> String {
        megabytes >= 1000 ? String(format: "%.1f GB", megabytes / 1024) : String(format: "%.1f MB", megabytes)
    }

    private func estimatedCost(totalBytes: Int64) -> String {
        let totalGB = Double(totalBytes) / 1_073_741_824
        let billableGB = max(0, totalGB - Self.freeGB)
        let monthlyCost = (billableGB / 1024) * Self.pricePerTBPerMonth
        return String(format: "$%.2f/mes", monthlyCost)
    }
}
