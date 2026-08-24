import SwiftUI
import Charts
import AppKit

/// Sube el brillo (HSB) de un color sin tocar su tono/saturación, para que la paleta de
/// Estadísticas se vea más viva sin dejar de ser "el mismo color" que pidió Bernabe.
private func brightened(_ color: Color, by amount: CGFloat = 0.22) -> Color {
    guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return color }
    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
    rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    return Color(hue: hue, saturation: saturation, brightness: min(1, brightness + amount), opacity: alpha)
}

/// Paleta pedida por Bernabe para las gráficas de Estadísticas. Con más de 8 categorías en un
/// bucket real (Fotos/PDF/Documentos/Instaladores/Video/Audio/Comprimidos/Otros) los 5 colores
/// originales se repetían y dos categorías distintas se veían idénticas (Video/PDF ambos rojo
/// oscuro) — se agregaron 2 tintes más de los mismos colores para cubrir hasta 7 categorías
/// reales sin repetir (Otros siempre sale gris aparte, ver `categoryColor`).
private let statsChartPalette: [Color] = [
    Color(red: 0x8B / 255, green: 0x00 / 255, blue: 0x00 / 255),  // Deep Red
    Color(red: 0xD2 / 255, green: 0xB4 / 255, blue: 0x8C / 255),  // Marrón Pastel
    Color(red: 0xB8 / 255, green: 0x73 / 255, blue: 0x33 / 255),  // Tan Leather
    Color(red: 0xCD / 255, green: 0x7F / 255, blue: 0x32 / 255),  // Cuero Tan (bronze)
    Color(red: 0x4A / 255, green: 0x2E / 255, blue: 0x1B / 255),  // Dark Wood Brown
    Color(red: 0xB4 / 255, green: 0x59 / 255, blue: 0x59 / 255),  // Deep Red aclarado
    Color(red: 0x90 / 255, green: 0x59 / 255, blue: 0x23 / 255),  // Bronce oscurecido
].map { brightened($0) }

struct StatsView: View {
    @EnvironmentObject var rclone: RcloneManager
    @EnvironmentObject var connectionStore: ConnectionStore

    @State private var bucketStats: BucketStats?
    @State private var hoveredDay: RcloneManager.DailyUpload?
    @State private var hoveredCategory: String?
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
                    categoryDonut(stats.categoryBytes, totalBytes: stats.totalBytes)
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

            let daily = rclone.dailyUploadMB()
            if daily.contains(where: { $0.megabytes > 0 }) {
                dailyUploadChart(daily)
            }

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

    /// Un color fijo por categoría (nunca por índice de arreglo): "Otros" siempre gris, y las
    /// demás toman colores de la paleta en el orden en que aparecen — así "Otros" no desperdicia
    /// un color de la paleta y dos categorías reales nunca terminan compartiendo color.
    private func categoryColorMap(_ categories: [(category: String, bytes: Int64)]) -> [String: Color] {
        var map: [String: Color] = [:]
        var nextColorIndex = 0
        for entry in categories where map[entry.category] == nil {
            if entry.category == "Otros" {
                map[entry.category] = Color.gray.opacity(0.5)
            } else {
                map[entry.category] = statsChartPalette[nextColorIndex % statsChartPalette.count]
                nextColorIndex += 1
            }
        }
        return map
    }

    /// Sin esto, una categoría que sea <1% del total (común: Audio/PDF/Documentos sueltos junto a
    /// Video/Fotos gigantes) dibuja una rebanada de ancho ~0 — el color está bien asignado, solo
    /// invisible. Se le da a cada rebanada un piso del 3% del círculo (quitado proporcionalmente
    /// de las demás) para que las 8 categorías siempre se puedan ver y distinguir; el tamaño real
    /// sigue mostrándose tal cual en la leyenda, esto solo afecta el dibujo del ángulo.
    private static let minSlicePortion = 0.03

    private func donutAngles(for categories: [(category: String, bytes: Int64)]) -> [Int64] {
        let total = categories.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else { return categories.map { _ in 0 } }
        let floor = total * Self.minSlicePortion
        let boosted = categories.map { max(Double($0.bytes), floor) }
        let boostedTotal = boosted.reduce(0, +)
        // Reescala para que la suma de ángulos siga sumando el total original (el "peso extra"
        // dado a las rebanadas chicas se resta proporcionalmente de las grandes).
        return boosted.map { Int64(($0 / boostedTotal) * total) }
    }

    /// Rango angular (en grados, 0 = arriba, sentido horario) de cada categoría dentro de la
    /// dona, en el mismo orden en que `Chart` dibuja los `SectorMark` — necesario para poder
    /// traducir "dónde está el mouse" a "qué categoría es" en el hover.
    private func donutAngleRanges(for categories: [(category: String, bytes: Int64)], angles: [Int64]) -> [(category: String, start: Double, end: Double)] {
        let totalAngle = Double(angles.reduce(0, +))
        guard totalAngle > 0 else { return [] }
        var ranges: [(category: String, start: Double, end: Double)] = []
        var cursor = 0.0
        for (index, angle) in angles.enumerated() {
            let sweep = Double(angle) / totalAngle * 360
            ranges.append((categories[index].category, cursor, cursor + sweep))
            cursor += sweep
        }
        return ranges
    }

    private func categoryDonut(_ categories: [(category: String, bytes: Int64)], totalBytes: Int64) -> some View {
        let colors = categoryColorMap(categories)
        let angles = donutAngles(for: categories)
        let ranges = donutAngleRanges(for: categories, angles: angles)
        let hoveredEntry = categories.first { $0.category == hoveredCategory }

        return HStack(alignment: .center, spacing: 20) {
            Chart(Array(zip(categories, angles).enumerated()), id: \.offset) { _, pair in
                let (entry, angle) = pair
                SectorMark(angle: .value("Bytes", angle), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .foregroundStyle((colors[entry.category] ?? .gray).opacity(hoveredCategory == nil || hoveredCategory == entry.category ? 1 : 0.45))
            }
            .frame(width: 132, height: 132)
            .chartBackground { _ in
                VStack(spacing: 2) {
                    if let hoveredEntry {
                        Text(LocalizedStringKey(hoveredEntry.category)).font(.system(size: Self.captionSize)).foregroundStyle(.secondary)
                        Text(formattedSize(hoveredEntry.bytes)).font(.system(size: Self.subheadlineSize, weight: .semibold))
                    } else {
                        Text("Por tipo").font(.system(size: Self.captionSize)).foregroundStyle(.secondary)
                        Text(formattedSize(totalBytes)).font(.system(size: Self.subheadlineSize, weight: .semibold))
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plotFrame = geometry[proxy.plotAreaFrame]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let center = CGPoint(x: plotFrame.midX, y: plotFrame.midY)
                                let dx = location.x - center.x
                                let dy = location.y - center.y
                                let outerRadius = min(plotFrame.width, plotFrame.height) / 2
                                let innerRadius = outerRadius * 0.62
                                let radius = (dx * dx + dy * dy).squareRoot()
                                guard radius >= innerRadius, radius <= outerRadius else {
                                    hoveredCategory = nil
                                    return
                                }
                                var angleDegrees = atan2(dx, -dy) * 180 / .pi
                                if angleDegrees < 0 { angleDegrees += 360 }
                                hoveredCategory = ranges.first { angleDegrees >= $0.start && angleDegrees < $0.end }?.category
                            case .ended:
                                hoveredCategory = nil
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(categories.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Circle().fill(colors[entry.category] ?? .gray).frame(width: 9, height: 9)
                        Text(LocalizedStringKey(entry.category))
                        Spacer()
                        Text(formattedSize(entry.bytes)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: Self.calloutSize, weight: hoveredCategory == entry.category ? .semibold : .regular))
                    .opacity(hoveredCategory == nil || hoveredCategory == entry.category ? 1 : 0.45)
                }
            }
        }
    }

    private func dailyUploadChart(_ daily: [RcloneManager.DailyUpload]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart(daily) { entry in
                BarMark(x: .value("Día", entry.day, unit: .day), y: .value("MB", entry.megabytes))
                    .foregroundStyle(statsChartPalette[0].opacity(hoveredDay?.day == entry.day ? 1 : 0.75))
                    .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 88)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let originX = geometry[proxy.plotAreaFrame].origin.x
                                guard let date: Date = proxy.value(atX: location.x - originX) else { return }
                                hoveredDay = daily.min { a, b in
                                    abs(a.day.timeIntervalSince(date)) < abs(b.day.timeIntervalSince(date))
                                }
                            case .ended:
                                hoveredDay = nil
                            }
                        }
                }
            }
            .overlay(alignment: .top) {
                if let hoveredDay {
                    Text("\(dayFormatter.string(from: hoveredDay.day)) · \(formattedMB(hoveredDay.megabytes))")
                        .font(.system(size: Self.captionSize, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .offset(y: -20)
                }
            }

            HStack {
                Text("hace \(daily.count) días").foregroundStyle(.secondary)
                Spacer()
                Text("hoy").foregroundStyle(.secondary)
            }
            .font(.system(size: Self.captionSize))
        }
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }

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
