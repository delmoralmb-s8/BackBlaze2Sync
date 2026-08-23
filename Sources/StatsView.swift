import SwiftUI

struct StatsView: View {
    @EnvironmentObject var rclone: RcloneManager
    @EnvironmentObject var connectionStore: ConnectionStore

    @State private var bucketStats: BucketStats?
    @State private var isScanning = false
    @State private var scanFailed = false
    // Bumped each time a scan starts or gets cancelled, so a completion handler from a scan the
    // user already cancelled (it still fires, just with nil) can tell it's stale and stay quiet
    // instead of showing a false "scan failed" error.
    @State private var scanGeneration = 0

    // $6.95/TB/month, confirmed against backblaze.com/cloud-storage/pricing. B2's own first-10GB
    // free tier is subtracted below, everything else is one multiplication, no billing API needed.
    private static let pricePerTBPerMonth = 6.95
    private static let freeGB = 10.0

    // Same "bump 15%" convention ExplorerView already established for its toolbar (13pt body /
    // 11pt caption system defaults × 1.15), applied here to this window's own text.
    private static let headlineSize: CGFloat = 13 * 1.15
    private static let calloutSize: CGFloat = 12 * 1.15
    private static let subheadlineSize: CGFloat = 11 * 1.15
    private static let captionSize: CGFloat = 10 * 1.15

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
            Text("Estadísticas").font(.system(size: Self.headlineSize, weight: .semibold))
            Spacer()
            if isScanning {
                ProgressView().controlSize(.small)
                Button("Cancelar") { cancelScan() }
            } else if let stats = bucketStats {
                Text("Actualizado \(stats.scannedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: Self.captionSize))
                    .foregroundStyle(.secondary)
            }
            Button("Actualizar") { refresh(force: true) }
                .disabled(isScanning || basePath == nil)
        }
    }

    // MARK: - Bucket section (real scan of the whole bucket)

    private var bucketSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tu bucket ahora mismo").font(.system(size: Self.headlineSize, weight: .semibold))

            if basePath == nil {
                Text("Conéctate a un bucket para ver sus estadísticas.")
                    .font(.system(size: Self.calloutSize))
                    .foregroundStyle(.secondary)
            } else if scanFailed {
                Text("No se pudo escanear el bucket. Intenta \"Actualizar\".")
                    .font(.system(size: Self.calloutSize))
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
                    Text("Por tipo de archivo")
                        .font(.system(size: Self.subheadlineSize))
                        .padding(.top, 4)
                    ForEach(stats.categoryBytes, id: \.category) { entry in
                        HStack {
                            Text(LocalizedStringKey(entry.category))
                            Spacer()
                            Text(formattedSize(entry.bytes)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: Self.calloutSize))
                    }
                }
            } else if isScanning {
                Text("Escaneando el bucket completo… puede tardar en buckets grandes.")
                    .font(.system(size: Self.calloutSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Local activity section (this app's own history)

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tu actividad en BackBlaze2Sync").font(.system(size: Self.headlineSize, weight: .semibold))
            Text("Solo cuenta lo hecho con esta app (hasta las últimas 2000 operaciones), no todo lo que hay en el bucket.")
                .font(.system(size: Self.captionSize))
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
        .font(.system(size: Self.calloutSize))
    }

    private func refresh(force: Bool) {
        guard let basePath else { return }
        isScanning = true
        scanFailed = false
        scanGeneration += 1
        let generation = scanGeneration
        rclone.scanBucketStats(basePath: basePath, forceRefresh: force) { stats in
            guard generation == scanGeneration else { return }
            isScanning = false
            if let stats {
                bucketStats = stats
            } else {
                scanFailed = true
            }
        }
    }

    private func cancelScan() {
        rclone.cancelBucketStatsScan()
        scanGeneration += 1
        isScanning = false
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
