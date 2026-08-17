import CryptoKit
import Foundation

struct IntegrityMismatch: Identifiable {
    let id = UUID()
    let relativePath: String
    let reason: String
}

struct IntegrityResult {
    let totalCompared: Int
    let mismatches: [IntegrityMismatch]
    var isPerfectMatch: Bool { mismatches.isEmpty }
}

struct LogLine: Identifiable {
    let id = UUID()
    let timestamp: Date
    let text: String
}

struct RemoteEntry: Codable, Identifiable, Equatable {
    let Path: String
    let Name: String
    let Size: Int64
    let IsDir: Bool
    let ModTime: String?
    var id: String { Path }
}

/// Everything `rclone lsjson --stat --hash` can tell us about exactly one item — used by
/// "Mostrar información", which wants more than the 4 fields `RemoteEntry` keeps for listings.
struct RemoteEntryDetail: Codable {
    let Path: String
    let Name: String
    let Size: Int64
    let IsDir: Bool
    let ModTime: String?
    let MimeType: String?
    let Hashes: [String: String]?
}

/// A remote file/folder addressed by its full path (e.g. "b2:mybucket/books/foo.epub"),
/// used once an item is selected — independent of which listing (flat or nested) produced it.
struct RemotePathItem: Hashable, Identifiable {
    let path: String
    let name: String
    let isDir: Bool
    var id: String { path }
}

struct FolderSizeInfo {
    let count: Int
    let bytes: Int64
}

enum RemoteListTarget {
    case main, picker
}

struct OperationFileEntry: Codable, Identifiable {
    let id: String  // path relative to what was dropped, e.g. "books/foo.epub"
    let megabytes: Double
}

/// A transfer that failed (or was cancelled), kept separate from the log/history so it's
/// actionable on its own — `retry` re-runs the exact same operation with the same arguments.
struct FailedOperation: Identifiable {
    let id: UUID
    let date: Date
    let type: String
    let summary: String
    let retry: () -> Void
}

struct OperationRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let type: String
    let fileCount: Int
    let percent: Double
    let success: Bool
    let megabytes: Double
    /// Only set for "Comprimir" — the original folder's size before compression, so the
    /// history can show the before/after (folder size → .zip size).
    let megabytesBefore: Double
    let items: [OperationFileEntry]
    /// Only set for "Conectado"/"Desconectado" — the connection's display name. Adding this field
    /// resets any history saved before this update (same accepted trade-off as previous schema
    /// changes here: it's only the log, nothing else depends on it surviving an app update).
    var detail: String? = nil
    /// Only set for "Descarga" — the local folder it landed in, so history answers "where did
    /// that go" without having to remember or guess.
    var localPath: String? = nil
    /// The B2 side of the transfer — destination folder for "Subida"/"Mover"/"Copiar", source
    /// folder for "Descarga"/"Borrar" — so history answers "where in the bucket" without
    /// cross-referencing the log.
    var remotePath: String? = nil
    /// Only set for "Mover"/"Copiar" — the shared source folder (both are B2→B2, so unlike
    /// Subida/Descarga there are two bucket-side paths to show, not one). Assumes every item in
    /// the batch came from the same folder, true for how the Explorer's selection works (you
    /// select within one listing, then move/copy that selection) — same simplifying assumption
    /// "Borrar" already makes for its own remotePath.
    var sourceRemotePath: String? = nil
    /// Average throughput for the whole operation (total bytes / total wall-clock seconds), only
    /// set for "Subida"/"Descarga". nil rather than 0 when the operation was too fast to time
    /// meaningfully, so the UI can tell "no data" apart from "genuinely instant".
    var megabytesPerSecond: Double? = nil
}

@MainActor
final class RcloneManager: ObservableObject {
    @Published var isRunning = false
    @Published var percent: Double = 0
    @Published var speed = ""
    @Published var eta = ""
    @Published var logLines: [LogLine] = []
    // The latest MEANINGFUL message ("Subiendo N elemento(s)…", "[OK] Subida completa.") for the
    // one-line status under the progress bar — set only by log(_:), never by the raw rclone
    // --stats passthrough (logRaw), which would otherwise flood it with "* file.raf: 34%..." noise.
    @Published var lastMessage = ""
    @Published var lastResult: String?
    @Published var remoteEntries: [RemoteEntry] = []
    @Published var isListingRemote = false
    @Published var pickerEntries: [RemoteEntry] = []
    @Published var isListingPicker = false
    @Published var verifyAfterUpload = false
    // 0 = sin límite. Applied globally in run(arguments:) as --bwlimit/--transfers so every
    // transfer command picks it up without threading it through each caller individually.
    @Published var bandwidthLimitMBps: Double = 0
    @Published var parallelTransfers: Int = 4
    @Published var shutdownWhenDone = false
    // nil = no countdown running. Ticks down from 30; reaching 0 shuts down for real.
    @Published var shutdownCountdown: Int?
    private var shutdownTimer: Timer?
    @Published var verifyStatusMessage: String?
    // Kept separate from the message text itself instead of sniffing an emoji prefix out of a
    // string — the view renders the real success/fail state as a native SF Symbol, not a glyph
    // baked into the text.
    @Published var verifyStatusSuccess = false
    @Published private(set) var history: [OperationRecord] = []
    @Published private(set) var failedOperations: [FailedOperation] = []
    /// The Explorer's current relative browse path, mirrored here so a new Gallery window can
    /// open at the same folder instead of always starting at the bucket root.
    @Published var explorerPath = ""

    /// nil means rclone wasn't found anywhere — the UI shows an install prompt instead of the
    /// normal explorer, since every single operation needs this to run at all.
    @Published private(set) var rclonePath: String?
    /// Whether Homebrew itself is present — `brew install rclone` (the fix the app suggests) is
    /// itself a no-op error ("brew: command not found") without it, so the UI needs to know
    /// whether to walk the user through installing Homebrew first.
    @Published private(set) var hasHomebrew = false

    /// Without these, a stalled connection (bad wifi, B2 hiccup) hangs an rclone process forever —
    /// nothing else in the app notices, so it just looks frozen with no error and no way out.
    /// `--timeout` is an IDLE timeout (no bytes moving for that long), not a total-duration cap, so
    /// it won't abort a real transfer that's just slow — only one that's truly stuck.
    private static let networkTimeoutArgs = ["--contimeout", "15s", "--timeout", "30s"]

    /// Dedup key for the last error logged by a per-item background op (thumbnails, folder
    /// sizes, hashes) — those can fire dozens of times for the same underlying failure (e.g. one
    /// bad credential breaking every thumbnail in a gallery), so only the first occurrence of a
    /// given message logs, instead of flooding the log with identical lines.
    private var lastBackgroundErrorLogged: String?

    private func logBackgroundErrorOnce(_ context: String, _ errorText: String?) {
        guard let errorText, !errorText.isEmpty else { return }
        let key = "\(context)|\(errorText)"
        guard key != lastBackgroundErrorLogged else { return }
        lastBackgroundErrorLogged = key
        log("[ERROR] \(context): \(errorText)")
    }
    private var process: Process?
    private let historyKey = "b2sync.history.v1"

    // MARK: - Batch progress (across ALL items in one action, not reset per file)
    //
    // rclone's own --progress is per-invocation, and transferSequential/moveSequential run one
    // rclone process per item — without this, percent snapped back to 0% at the start of every
    // file, sawtoothing for multi-file actions. Precomputing every item's size upfront lets us
    // weight each item's own 0-100% into one continuously-increasing whole, with an ETA based on
    // total bytes remaining instead of just the current file's.
    private struct BatchProgress {
        let itemBytes: [Int64]
        let totalBytes: Int64
        var completedBytes: Int64 = 0
        var index: Int = 0
    }
    private var batch: BatchProgress?

    init() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([OperationRecord].self, from: data) {
            history = decoded
        }
        recheckDependencies()
    }

    /// Re-runs the rclone/Homebrew detection — lets "Verificar de nuevo" in the missing-rclone
    /// screen pick up a fresh install without having to fully quit and relaunch the app.
    func recheckDependencies() {
        rclonePath = Self.locateExecutable("rclone", knownPaths: ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/opt/local/bin/rclone"])
        hasHomebrew = Self.locateExecutable("brew", knownPaths: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) != nil
    }

    /// Checks the known Homebrew install locations (Apple Silicon vs Intel) plus whatever `name`
    /// resolves to on the user's PATH, covering MacPorts and any manual install too.
    private static func locateExecutable(_ name: String, knownPaths: [String]) -> String? {
        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        which.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // Matches ONLY the bytes-transferred stats line, e.g.:
    // Transferred:   	  1.499 GiB / 3.300 GiB, 45%, 1.300 MiB/s, ETA 34m12s
    //
    // rclone's --stats output prints several OTHER lines per second that also contain "N%",
    // e.g. "Checks: 5 / 5, 100%" and "Transferred: 3 / 10, 30%" (file-count progress, not
    // bytes — confusingly also starts with "Transferred:"). Those never carry a speed/ETA, so
    // requiring both here (previously optional) is what keeps them from ever matching and
    // clobbering the real byte percentage with an unrelated one each second.
    private static let progressRegex = try! NSRegularExpression(
        pattern: #"(\d+)%,\s*([\d.]+\s*\w+/s),\s*ETA\s*(\S+)"#
    )

    // A long-running transfer prints a progress line every second via `--stats 1s` — over a
    // multi-hour upload that's tens of thousands of lines with no cap, which is almost certainly
    // why copying the log to the clipboard felt like it froze the window (building/joining a
    // giant string on the main thread). Capping keeps both memory and "Copiar log" bounded.
    private static let maxLogLines = 5000

    func log(_ text: String) {
        logLines.append(LogLine(timestamp: Date(), text: text))
        lastMessage = text
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }

    /// Same as `log(_:)` but doesn't touch `lastMessage` — used only for rclone's raw `--stats`
    /// passthrough, which fires ~10 times a second per active transfer and would otherwise turn
    /// the one-line mini status under the progress bar into unreadable noise.
    private func logRaw(_ text: String) {
        logLines.append(LogLine(timestamp: Date(), text: text))
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }

    // MARK: - History

    private static let maxHistoryEntries = 2000

    private func recordOperation(type: String, fileCount: Int, success: Bool, bytes: Int64 = 0, bytesBefore: Int64 = 0, items: [OperationFileEntry] = [], detail: String? = nil, localPath: String? = nil, remotePath: String? = nil, sourceRemotePath: String? = nil, elapsedSeconds: TimeInterval = 0) {
        let megabytes = Double(max(bytes, 0)) / 1_048_576
        let megabytesBefore = Double(max(bytesBefore, 0)) / 1_048_576
        // Anything under ~1s is too noisy to call a real rate (process startup, cache hits, tiny
        // files) — leave it nil rather than report a misleadingly huge or tiny number.
        let speed: Double? = elapsedSeconds > 1 ? megabytes / elapsedSeconds : nil
        history.insert(OperationRecord(id: UUID(), date: Date(), type: type, fileCount: fileCount, percent: success ? 100 : percent, success: success, megabytes: megabytes, megabytesBefore: megabytesBefore, items: items, detail: detail, localPath: localPath, remotePath: remotePath, sourceRemotePath: sourceRemotePath, megabytesPerSecond: speed), at: 0)
        if history.count > Self.maxHistoryEntries { history.removeLast(history.count - Self.maxHistoryEntries) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    /// Called from ContentView whenever the active connection changes (switch, new connection,
    /// or explicit "Desconectar") — lets the history answer "when was I connected to what",
    /// which the log alone doesn't (it only keeps the last 5000 lines, history keeps 2000 events).
    func recordConnectionEvent(connected: Bool, name: String) {
        recordOperation(type: connected ? "Conectado" : "Desconectado", fileCount: 0, success: true, detail: name)
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    // MARK: - Failed operations (separate from the log — actionable, with a retry button)

    private func recordFailure(type: String, summary: String, retry: @escaping () -> Void) {
        let id = UUID()
        let wrappedRetry: () -> Void = { [weak self] in
            self?.failedOperations.removeAll { $0.id == id }
            retry()
        }
        failedOperations.append(FailedOperation(id: id, date: Date(), type: type, summary: summary, retry: wrappedRetry))
    }

    func dismissFailedOperation(_ id: UUID) {
        failedOperations.removeAll { $0.id == id }
    }

    /// Walks a dropped/selected local path (file or folder) into its individual files with sizes,
    /// so a folder upload can be shown expanded in the history instead of as one opaque blob.
    private static func fileEntries(localPath: String) -> [OperationFileEntry] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir) else { return [] }
        let baseName = (localPath as NSString).lastPathComponent
        if !isDir.boolValue {
            let size = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int64) ?? 0
            return [OperationFileEntry(id: baseName, megabytes: Double(size) / 1_048_576)]
        }
        guard let enumerator = FileManager.default.enumerator(atPath: localPath) else { return [] }
        var result: [OperationFileEntry] = []
        for case let relative as String in enumerator {
            guard !isMacJunkPath(relative) else { continue }
            let full = (localPath as NSString).appendingPathComponent(relative)
            var childIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &childIsDir), !childIsDir.boolValue else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int64) ?? 0
            result.append(OperationFileEntry(id: baseName + "/" + relative, megabytes: Double(size) / 1_048_576))
        }
        return result
    }

    // MARK: - Integrity check
    // ponytail: not called from any UI right now (the old whole-folder sync button was removed
    // in favor of the Explorer's "Subir carpeta…"); kept because "Verificar integridad" in
    // Opciones still needs a home once it's reconnected to something.

    func runCheck(source: String, destination: String) {
        log("Verificando integridad (rclone check)…")
        run(arguments: ["check", source, destination]) { [weak self] success in
            guard let self else { return }
            self.log(success ? "[OK] Verificación OK: no se encontraron diferencias." : "[WARN] Verificación encontró diferencias, revisa el log.")
            self.lastResult = success ? "success" : "error"
        }
    }

    func cancel() {
        process?.terminate()
    }

    // MARK: - Connections (rclone remotes)

    /// `rclone config create` only writes a config file — it never contacts Backblaze, so bad
    /// credentials or a typo'd bucket name "succeed" at creation time and only fail later, the
    /// first time something tries to actually list the bucket. This runs that real check right
    /// away, translating rclone's raw (English, technical) error into what actually went wrong.
    func validateConnection(remoteName: String, bucket: String, completion: @escaping (String?) -> Void) {
        runLsJSON(path: "\(remoteName):\(bucket)/") { _, ok, errorText in
            completion(ok ? nil : Self.friendlyErrorMessage(from: errorText))
        }
    }

    static func friendlyErrorMessage(from rawError: String?) -> String {
        guard let rawError, !rawError.isEmpty else {
            return "No se pudo conectar. Revisa tu conexión a internet e inténtalo de nuevo."
        }
        let lower = rawError.lowercased()
        if lower.contains("bad_auth_token") || lower.contains("401") || lower.contains("unauthorized") {
            return "El Key ID o el Application Key no son correctos. Revisa que los copiaste completos, sin espacios ni caracteres de más, desde tu cuenta de Backblaze."
        }
        if lower.contains("bucket_not_found") || lower.contains("404") {
            return "No se encontró ese bucket en tu cuenta de Backblaze. Revisa que el nombre esté escrito exactamente igual (B2 distingue mayúsculas y minúsculas)."
        }
        if lower.contains("no such host") || lower.contains("network is unreachable") || lower.contains("timeout") || lower.contains("timed out") {
            return "No se pudo conectar a Backblaze. Revisa tu conexión a internet e inténtalo de nuevo."
        }
        return rawError
    }

    func createRemote(name: String, accountID: String, appKey: String, completion: @escaping (Bool) -> Void) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !accountID.isEmpty, !appKey.isEmpty else { completion(false); return }
        log("Creando conexión rclone: \(trimmed)")
        run(arguments: ["config", "create", trimmed, "b2", "account=\(accountID)", "key=\(appKey)"]) { [weak self] success in
            self?.log(success ? "[OK] Conexión creada." : "[ERROR] No se pudo crear la conexión (revisa las credenciales).")
            completion(success)
        }
    }

    func deleteRemote(name: String, completion: @escaping (Bool) -> Void) {
        log("Desconectando: \(name)")
        run(arguments: ["config", "delete", name]) { success in
            completion(success)
        }
    }

    // MARK: - Listing (cached: re-entering a folder you've already listed is instant)

    private var listCache: [String: (entries: [RemoteEntry], date: Date)] = [:]
    private static let cacheTTL: TimeInterval = 60

    private func cachedEntries(for path: String) -> [RemoteEntry]? {
        guard let cached = listCache[path], Date().timeIntervalSince(cached.date) < Self.cacheTTL else { return nil }
        return cached.entries
    }

    /// Called whenever a mutation (upload/move/copy/delete/rename/mkdir) touches a folder, so the
    /// next listing of that folder always hits the network instead of serving a stale snapshot.
    private func invalidateCache(path: String) {
        listCache.removeValue(forKey: path)
        // The search index is a snapshot of the WHOLE connection, so any mutation anywhere in it
        // makes the snapshot stale — there's no per-path slice of it to expire selectively.
        searchIndex = nil
    }

    /// Manual "Actualizar" — bypasses the 60s cache so a change made outside the app (or missed by
    /// the automatic refresh after an upload/move/delete) shows up immediately on demand.
    func refreshRemote(path: String, target: RemoteListTarget = .main) {
        invalidateCache(path: path)
        listRemote(path: path, target: target)
    }

    func listRemote(path: String, target: RemoteListTarget = .main) {
        // No isRunning guard here on purpose: listing is read-only, runs its own separate
        // process/pipe (runLsJSON), and never touches percent/process/isRunning — same
        // side-channel shape as folderSize/searchAll/generateShareLink, all of which already run
        // freely during a transfer. Gating navigation on isRunning meant clicking into a folder
        // while an upload ran just silently did nothing (felt like the window had frozen).
        if let cached = cachedEntries(for: path) {
            switch target {
            case .main:
                isListingRemote = false
                remoteEntries = cached
            case .picker:
                isListingPicker = false
                pickerEntries = cached
            }
            log("Listados \(cached.count) elemento(s) en \(path) (caché)")
            return
        }
        switch target {
        case .main:
            isListingRemote = true
            remoteEntries = []
        case .picker:
            isListingPicker = true
            pickerEntries = []
        }

        runLsJSON(path: path) { [weak self] entries, ok, errorText in
            guard let self else { return }
            switch target {
            case .main:
                self.isListingRemote = false
                self.remoteEntries = entries
            case .picker:
                self.isListingPicker = false
                self.pickerEntries = entries
            }
            if ok { self.listCache[path] = (entries, Date()) }
            if ok {
                self.log("Listados \(entries.count) elemento(s) en \(path)")
            } else {
                self.log("[ERROR] No se pudo listar \(path)" + (errorText.map { ": \($0)" } ?? ""))
            }
        }
    }

    /// Same as `listRemote` but doesn't touch the published `remoteEntries`/`pickerEntries` —
    /// used by the outline/list view to lazily fetch a single node's children on demand.
    func listEntries(path: String, completion: @escaping ([RemoteEntry]) -> Void) {
        if let cached = cachedEntries(for: path) {
            completion(cached)
            return
        }
        runLsJSON(path: path) { [weak self] entries, ok, errorText in
            if ok {
                self?.listCache[path] = (entries, Date())
            } else if let errorText {
                self?.log("[ERROR] No se pudo listar \(path): \(errorText)")
            }
            completion(entries)
        }
    }

    // MARK: - Share link

    /// `rclone link` reuses whichever B2 credentials are already configured for this connection's
    /// remote, so it works per-connection with no extra credential plumbing (unlike shelling out to
    /// the separate `b2` CLI, which is authorized independently of the app's saved connections).
    private var shareLinkProcess: Process?

    /// Lets the UI offer a real "Cancelar" instead of only a spinner with no way out — terminates
    /// whatever `generateShareLink` process is in flight; its own completion still fires (with
    /// a non-zero exit), the caller just needs to treat that the same as any other failure.
    func cancelShareLink() {
        shareLinkProcess?.terminate()
        shareLinkProcess = nil
    }

    func generateShareLink(path: String, expireDays: Int, completion: @escaping (String?) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: rclonePath ?? "/usr/bin/false")
        task.arguments = Self.networkTimeoutArgs + ["link", "--expire", "\(max(expireDays, 1))d", path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.terminationHandler = { [weak self] proc in
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                self?.shareLinkProcess = nil
                let link = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0, let link, !link.isEmpty {
                    self?.log("[OK] URL para compartir generada (\(expireDays) día(s)).")
                    completion(link)
                } else {
                    let errorText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = (errorText?.isEmpty ?? true) ? "" : ": \(errorText!)"
                    self?.log("[ERROR] No se pudo generar la URL para compartir\(suffix)")
                    completion(nil)
                }
            }
        }
        do {
            shareLinkProcess = task
            try task.run()
        } catch {
            shareLinkProcess = nil
            log("[ERROR] No se pudo ejecutar rclone: \(error.localizedDescription)")
            completion(nil)
        }
    }

    /// Downloads one remote file's raw bytes into memory via `rclone cat`. Side-channel like
    /// generateShareLink/folderSize — does NOT touch isRunning/percent, safe to call while a real
    /// transfer is in progress or many times concurrently (used by the Gallery to fetch images
    /// for thumbnailing without fighting the Explorer's upload/download progress bar).
    func fetchFileBytes(path: String, completion: @escaping (Data?) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: rclonePath ?? "/usr/bin/false")
        task.arguments = Self.networkTimeoutArgs + ["cat", path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            completion(nil)
            return
        }

        // Photos are several MB — bigger than the pipe's ~64KB kernel buffer. Reading only
        // after the process exits deadlocks: rclone blocks writing to a full pipe that nobody
        // is draining, so it never exits. readDataToEndOfFile() must run concurrently on its
        // own queue, draining the pipe as rclone writes, until it sees EOF at process exit.
        DispatchQueue.global(qos: .utility).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let ok = task.terminationStatus == 0
            Task { @MainActor in
                if !ok {
                    let errorText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.logBackgroundErrorOnce("No se pudo descargar \(path)", errorText)
                }
                completion(ok ? data : nil)
            }
        }
    }

    private var searchTask: Process?

    /// One whole-connection listing with each path pre-folded for accent/case-insensitive matching.
    private typealias SearchIndexEntry = (entry: RemoteEntry, folded: String)
    private var searchIndex: (basePath: String, entries: [SearchIndexEntry], date: Date)?
    // ponytail: longer than listCache's 60s because a miss here costs a ~15s bucket listing, not a
    // ~1s folder one. Changes made through the app clear it immediately regardless; this TTL only
    // bounds how stale a change made OUTSIDE the app (B2 web UI, another machine) can look.
    private static let searchIndexTTL: TimeInterval = 300

    /// Recursive search across the whole connection, from `basePath` down. Side-channel like
    /// `fetchFileBytes`/`generateShareLink` — doesn't touch isRunning/percent. Reads the pipe
    /// concurrently while `rclone` is still running (same fix as `fetchFileBytes`): a full-bucket
    /// recursive `lsjson` can produce well over the pipe's ~64KB kernel buffer, and reading only
    /// after the process exits would deadlock exactly like that bug did.
    ///
    /// Matching is deliberately loose, not an exact filename match: the query is split into
    /// words, accents/case are folded away, and it's matched against the FULL relative path (not
    /// just the file's own name) — so "factura marzo" finds "2026/facturas/Marzo_2026.pdf"
    /// regardless of word order, accents, or which folder the word actually came from.
    func searchAll(basePath: String, query: String, completion: @escaping ([RemoteEntry]) -> Void) {
        let words = Self.searchWords(from: query)
        guard !words.isEmpty else { completion([]); return }

        // Second and later searches skip the network entirely. Measured on a real 40k-object
        // bucket, the listing is ~12-18s while the matching itself is milliseconds — so without
        // this, searching three things in a row costs three full bucket listings for data that
        // barely changed. Any mutation through the app drops the index (see invalidateCache).
        if let index = searchIndex, index.basePath == basePath,
           Date().timeIntervalSince(index.date) < Self.searchIndexTTL {
            completion(Self.matches(in: index.entries, words: words))
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: rclonePath ?? "/usr/bin/false")
        // --fast-list makes B2 (and other bucket backends) page through one flat listing instead
        // of walking directory by directory: measured ~17.9s -> ~11.5s median on that same bucket.
        // --no-mimetype/--no-modtime drop two fields search never looks at, shaving the JSON down.
        // (--checkers was measured too and made it WORSE — B2 throttles the extra parallelism.)
        task.arguments = Self.networkTimeoutArgs
            + ["lsjson", "--recursive", "--fast-list", "--no-mimetype", "--no-modtime", basePath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            log("[ERROR] No se pudo buscar: \(error.localizedDescription)")
            completion([])
            return
        }
        searchTask = task
        DispatchQueue.global(qos: .utility).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let decoded = task.terminationStatus == 0 ? (try? JSONDecoder().decode([RemoteEntry].self, from: data)) : nil
            // Fold each path once here, at index-build time, instead of once per entry per search
            // — the folded string is what every subsequent cached search matches against.
            let indexed = (decoded ?? [])
                .filter { $0.Name != ".bzEmpty" }
                .map { (entry: $0, folded: Self.foldedForSearch($0.Path)) }
            let matches = Self.matches(in: indexed, words: words)
            Task { @MainActor in
                self.searchTask = nil
                // A cancelled search also exits non-zero — only log when it actually failed.
                if decoded == nil, task.terminationStatus != 0, task.terminationReason != .uncaughtSignal {
                    let errorText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = (errorText?.isEmpty ?? true) ? "" : ": \(errorText!)"
                    self.log("[ERROR] No se pudo buscar\(suffix)")
                } else if decoded != nil {
                    self.searchIndex = (basePath: basePath, entries: indexed, date: Date())
                }
                completion(matches)
            }
        }
    }

    private static func matches(in indexed: [SearchIndexEntry], words: [String]) -> [RemoteEntry] {
        indexed
            .filter { candidate in words.allSatisfy { candidate.folded.contains($0) } }
            .map(\.entry)
            .sorted { $0.Path.localizedStandardCompare($1.Path) == .orderedAscending }
    }

    /// Stops an in-flight `searchAll` — its completion handler still fires (with whatever rclone
    /// had already produced, likely empty since a killed process exits non-zero), the caller just
    /// needs to ignore a stale result if a newer search has started since.
    func cancelSearch() {
        searchTask?.terminate()
        searchTask = nil
    }

    private static func foldedForSearch(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private static func searchWords(from query: String) -> [String] {
        foldedForSearch(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private func runLsJSON(path: String, completion: @escaping (_ entries: [RemoteEntry], _ ok: Bool, _ errorText: String?) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: rclonePath ?? "/usr/bin/false")
        task.arguments = Self.networkTimeoutArgs + ["lsjson", path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        task.terminationHandler = { proc in
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                let decoded = proc.terminationStatus == 0 ? (try? JSONDecoder().decode([RemoteEntry].self, from: data)) : nil
                // .bzEmpty is the placeholder file createFolder() drops to make empty folders visible — hide it.
                let sorted = (decoded ?? [])
                    .filter { $0.Name != ".bzEmpty" }
                    .sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
                let errorText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(sorted, decoded != nil, (errorText?.isEmpty ?? true) ? nil : errorText)
            }
        }

        do {
            try task.run()
        } catch {
            completion([], false, error.localizedDescription)
        }
    }

    /// Full metadata for a single item, used by "Mostrar información" — `--stat` points rclone at
    /// exactly this path instead of listing its parent folder, and `--hash` adds whatever checksum
    /// the remote already has on file (B2 stores SHA1 for every object for free).
    func statItem(path: String, completion: @escaping (RemoteEntryDetail?) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: rclonePath ?? "/usr/bin/false")
        task.arguments = Self.networkTimeoutArgs + ["lsjson", "--stat", "--hash", path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        task.terminationHandler = { proc in
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard proc.terminationStatus == 0 else { completion(nil); return }
                completion(try? JSONDecoder().decode(RemoteEntryDetail.self, from: data))
            }
        }

        do {
            try task.run()
        } catch {
            completion(nil)
        }
    }

    /// Caps concurrent `rclone size` processes — without it, the list view's per-folder size
    /// column (one lazy fetch per visible row) could fire off a process per folder all at once,
    /// piling on top of whatever transfer is already running. Same pattern as `ThumbnailStore`'s
    /// `Limiter` for concurrent thumbnail fetches.
    private let folderSizeLimiter = Limiter(max: 4)

    func folderSize(path: String, completion: @escaping (FolderSizeInfo?) -> Void) {
        struct SizeResult: Codable { let count: Int; let bytes: Int64 }
        Task { @MainActor in
            await folderSizeLimiter.wait()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: rclonePath ?? "/usr/bin/false")
            task.arguments = Self.networkTimeoutArgs + ["size", path, "--json", "--exclude", ".bzEmpty"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            task.terminationHandler = { proc in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                Task { @MainActor in
                    await self.folderSizeLimiter.signal()
                    guard proc.terminationStatus == 0,
                          let result = try? JSONDecoder().decode(SizeResult.self, from: data) else {
                        let errorText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.logBackgroundErrorOnce("No se pudo calcular el tamaño de \(path)", errorText)
                        completion(nil)
                        return
                    }
                    completion(FolderSizeInfo(count: result.count, bytes: result.bytes))
                }
            }
            do {
                try task.run()
            } catch {
                await folderSizeLimiter.signal()
                completion(nil)
            }
        }
    }

    // MARK: - Create folder

    func createFolder(at basePath: String, name: String, completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            log("[WARN] Ya hay una operación en curso, espera a que termine.")
            completion(false)
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { completion(false); return }
        let full = Self.destPath(basePath, trimmed)
        // B2 (like S3) has no real empty directories — `rclone mkdir` is a documented no-op there.
        // Match what the B2 web UI does: drop an empty marker file so the folder actually shows up.
        let marker = full + "/.bzEmpty"
        invalidateCache(path: basePath)
        log("Creando carpeta: \(full)")
        run(arguments: ["touch", marker]) { [weak self] success in
            self?.log(success ? "[OK] Carpeta creada." : "[ERROR] No se pudo crear la carpeta.")
            completion(success)
        }
    }

    // MARK: - Delete

    func deleteItems(_ items: [RemotePathItem], completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isRunning else {
            log("[WARN] Ya hay una operación en curso, espera a que termine.")
            completion(false)
            return
        }
        guard !items.isEmpty else { completion(false); return }
        lastResult = nil
        for item in items {
            invalidateCache(path: Self.parentPath(of: item.path))
            invalidateCache(path: item.path)
        }
        log("Borrando \(items.count) elemento(s) de B2…")
        deleteSequential(items.map { (path: $0.path, isDir: $0.isDir) }) { [weak self] success in
            self?.log(success ? "[OK] Borrado completado." : "[ERROR] Hubo errores al borrar algunos elementos.")
            self?.lastResult = success ? "success" : "error"
            self?.recordOperation(
                type: "Borrar",
                fileCount: items.count,
                success: success,
                items: items.map { OperationFileEntry(id: $0.name, megabytes: 0) },
                remotePath: Self.parentPath(of: items.first?.path ?? "")
            )
            completion(success)
        }
    }

    private func deleteSequential(_ items: [(path: String, isDir: Bool)], allSucceeded: Bool = true, onDone: @escaping (Bool) -> Void) {
        guard let first = items.first else { onDone(allSucceeded); return }
        let rest = Array(items.dropFirst())
        let args = first.isDir ? ["purge", first.path] : ["deletefile", first.path]
        run(arguments: args) { [weak self] success in
            self?.log(success ? "[OK] Borrado: \(first.path)" : "[ERROR] No se pudo borrar: \(first.path)")
            self?.deleteSequential(rest, allSucceeded: allSucceeded && success, onDone: onDone)
        }
    }

    // MARK: - Move (destructive: deletes the source)

    func moveItems(_ items: [RemotePathItem], toBase: String, trackFailure: Bool = true, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isRunning else {
            log("[WARN] Ya hay una operación en curso, espera a que termine.")
            completion(false)
            return
        }
        guard !items.isEmpty else { completion(false); return }
        lastResult = nil
        isRunning = true
        let pairs = items.map { (from: $0.path, to: Self.destPath(toBase, $0.name), isDir: $0.isDir) }
        for item in items { invalidateCache(path: Self.parentPath(of: item.path)) }
        invalidateCache(path: toBase)
        log("Moviendo \(pairs.count) elemento(s) a \(toBase)…")
        totalRemoteSizes(forPaths: items.map(\.path)) { [weak self] sizes in
            guard let self else { return }
            self.startBatch(itemBytes: sizes)
            self.moveSequential(pairs) { success in
                self.endBatch()
                self.log(success ? "[OK] Movido correctamente." : "[ERROR] Hubo errores moviendo algunos elementos.")
                self.lastResult = success ? "success" : "error"
                self.recordOperation(
                    type: "Mover",
                    fileCount: pairs.count,
                    success: success,
                    items: items.map { OperationFileEntry(id: $0.name, megabytes: 0) },
                    remotePath: toBase,
                    sourceRemotePath: Self.parentPath(of: items.first?.path ?? "")
                )
                if !success && trackFailure {
                    self.recordFailure(type: "Mover", summary: "\(pairs.count) elemento(s) → \(toBase)") { [weak self] in
                        self?.moveItems(items, toBase: toBase, trackFailure: trackFailure, completion: completion)
                    }
                }
                self.maybeOfferShutdown()
                completion(success)
            }
        }
    }

    /// Renames within the same parent folder — just a move to a sibling path with a new name.
    func renameItem(_ item: RemotePathItem, to newName: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isRunning else {
            log("[WARN] Ya hay una operación en curso, espera a que termine.")
            completion(false)
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else { completion(false); return }
        let newPath = Self.destPath(Self.parentPath(of: item.path), trimmed)
        lastResult = nil
        invalidateCache(path: Self.parentPath(of: item.path))
        log("Renombrando \(item.name) → \(trimmed)")
        moveOneStaged(from: item.path, to: newPath, isDir: item.isDir) { [weak self] success in
            self?.log(success ? "[OK] Renombrado." : "[ERROR] No se pudo renombrar.")
            self?.lastResult = success ? "success" : "error"
            completion(success)
        }
    }

    private func moveSequential(_ items: [(from: String, to: String, isDir: Bool)], allSucceeded: Bool = true, onDone: @escaping (Bool) -> Void) {
        guard let first = items.first else { onDone(allSucceeded); return }
        let rest = Array(items.dropFirst())
        moveOneStaged(from: first.from, to: first.to, isDir: first.isDir) { [weak self] success in
            guard let self else { return }
            self.log(success ? "[OK] Movido: \(first.from)" : "[ERROR] No se pudo mover: \(first.from)")
            self.advanceBatch()
            self.moveSequential(rest, allSucceeded: allSucceeded && success, onDone: onDone)
        }
    }

    // rclone refuses to move when source/dest overlap (e.g. moving "books" into "books/sub"),
    // so stage through a temporary sibling path in that case.
    //
    // `move`/`copy` ALWAYS treat their destination argument as a container to place the source's
    // own basename into — for a directory source that's exactly what we want (the dest path IS
    // the folder's new home), but for a FILE source it means "move x.txt to y.txt" doesn't rename
    // it to y.txt at all: it creates a y.txt DIRECTORY and drops the original x.txt inside it.
    // `moveto` is rclone's explicit file-to-file/exact-path variant — use it whenever the source
    // isn't a directory.
    // ponytail: the staged two-phase move still resets progress mid-item even inside a batch
    // (phase 2 restarts its own 0-100%) — a real sawtooth, but only for this rare overlap case.
    private func moveOneStaged(from: String, to: String, isDir: Bool, completion: @escaping (Bool) -> Void) {
        let subcommand = isDir ? "move" : "moveto"
        if batch == nil { percent = 0; speed = ""; eta = "" }
        guard Self.pathsOverlap(from, to) else {
            run(arguments: [subcommand, from, to, "--progress", "--stats", "1s"], completion: completion)
            return
        }
        let temp = Self.siblingTempPath(of: from)
        log("Destino anidado en origen, uso ruta temporal: \(from) → \(temp) → \(to)")
        run(arguments: [subcommand, from, temp, "--progress", "--stats", "1s"]) { [weak self] success in
            guard let self else { completion(false); return }
            guard success else {
                self.log("[ERROR] Falló el primer paso del movimiento, nada se perdió (\(from) intacto).")
                completion(false)
                return
            }
            if self.batch == nil { self.percent = 0; self.speed = ""; self.eta = "" }
            self.run(arguments: [subcommand, temp, to, "--progress", "--stats", "1s"]) { success2 in
                if !success2 {
                    self.log("[WARN] El segundo paso falló, revisa \(temp) manualmente, ahí quedaron los archivos.")
                }
                completion(success2)
            }
        }
    }

    private static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        let a2 = a.hasSuffix("/") ? a : a + "/"
        let b2 = b.hasSuffix("/") ? b : b + "/"
        return a2 == b2 || a2.hasPrefix(b2) || b2.hasPrefix(a2)
    }

    private static func siblingTempPath(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let tempName = ".b2sync-tmp-" + UUID().uuidString.prefix(8)
        if let idx = trimmed.lastIndex(of: "/") {
            return String(trimmed[..<idx]) + "/" + tempName
        }
        // ponytail: path has no parent segment (moving a whole bucket root) — temp ends up
        // nested under `from` here, which the general case avoids. Not handled specially.
        return trimmed + "/" + tempName
    }

    // MARK: - Copy / download / upload (all non-destructive: source is left in place)
    //
    // rclone treats "copy source dest" the same way whether either side is local or remote,
    // so copy-within-B2, download-to-Mac and upload-from-Mac all reuse the same engine.

    func copyItems(_ items: [RemotePathItem], toBase: String, trackFailure: Bool = true, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isRunning else {
            log("[WARN] Ya hay una operación en curso, espera a que termine.")
            completion(false)
            return
        }
        guard !items.isEmpty else { completion(false); return }
        lastResult = nil
        isRunning = true
        let pairs = items.map { (from: $0.path, to: Self.destPath(toBase, $0.name), isDir: $0.isDir) }
        invalidateCache(path: toBase)
        log("Copiando \(pairs.count) elemento(s) a \(toBase)…")
        totalRemoteSizes(forPaths: items.map(\.path)) { [weak self] sizes in
            guard let self else { return }
            self.startBatch(itemBytes: sizes)
            self.transferSequential(pairs) { success in
                self.endBatch()
                self.log(success ? "[OK] Copiado completo." : "[ERROR] Hubo errores al copiar.")
                self.lastResult = success ? "success" : "error"
                self.recordOperation(
                    type: "Copiar",
                    fileCount: pairs.count,
                    success: success,
                    items: items.map { OperationFileEntry(id: $0.name, megabytes: 0) },
                    remotePath: toBase,
                    sourceRemotePath: Self.parentPath(of: items.first?.path ?? "")
                )
                if !success && trackFailure {
                    self.recordFailure(type: "Copiar", summary: "\(pairs.count) elemento(s) → \(toBase)") { [weak self] in
                        self?.copyItems(items, toBase: toBase, trackFailure: trackFailure, completion: completion)
                    }
                }
                self.maybeOfferShutdown()
                completion(success)
            }
        }
    }

    func downloadItems(_ items: [RemotePathItem], toLocalFolder: String, recordHistory: Bool = true, trackFailure: Bool = true, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isRunning else {
            log("[WARN] Ya hay una operación en curso, espera a que termine.")
            completion(false)
            return
        }
        guard !items.isEmpty else { completion(false); return }
        lastResult = nil
        isRunning = true
        let startedAt = Date()
        let pairs = items.map { (from: $0.path, to: Self.destPath(toLocalFolder, $0.name), isDir: $0.isDir) }
        log("Descargando \(pairs.count) elemento(s) a \(toLocalFolder)…")
        totalRemoteSizes(forPaths: items.map(\.path)) { [weak self] sizes in
            guard let self else { return }
            self.startBatch(itemBytes: sizes)
            self.transferSequential(pairs) { success in
                self.endBatch()
                self.log(success ? "[OK] Descarga completa." : "[ERROR] Hubo errores al descargar.")
                self.lastResult = success ? "success" : "error"
                if recordHistory {
                    let entries = pairs.flatMap { Self.fileEntries(localPath: $0.to) }
                    let bytes = Int64(entries.reduce(0.0) { $0 + $1.megabytes } * 1_048_576)
                    self.recordOperation(
                        type: "Descarga",
                        fileCount: entries.isEmpty ? pairs.count : entries.count,
                        success: success,
                        bytes: bytes,
                        items: entries,
                        localPath: toLocalFolder,
                        remotePath: items.first.map { Self.parentPath(of: $0.path) },
                        elapsedSeconds: Date().timeIntervalSince(startedAt)
                    )
                }
                if !success && trackFailure {
                    self.recordFailure(type: "Descarga", summary: "\(pairs.count) elemento(s) → \(toLocalFolder)") { [weak self] in
                        self?.downloadItems(items, toLocalFolder: toLocalFolder, recordHistory: recordHistory, trackFailure: trackFailure, completion: completion)
                    }
                }
                self.maybeOfferShutdown()
                completion(success)
            }
        }
    }

    func uploadLocalPaths(_ localPaths: [String], toRemoteFolder: String, recordHistory: Bool = true, trackFailure: Bool = true, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isRunning else {
            log("[WARN] Ya hay una operación en curso, espera a que termine.")
            completion(false)
            return
        }
        guard !localPaths.isEmpty else { completion(false); return }
        lastResult = nil
        verifyStatusMessage = nil
        let startedAt = Date()
        let pairs = localPaths.map { local -> (from: String, to: String, isDir: Bool) in
            let name = (local as NSString).lastPathComponent
            var isDirFlag: ObjCBool = false
            FileManager.default.fileExists(atPath: local, isDirectory: &isDirFlag)
            return (local, Self.destPath(toRemoteFolder, name), isDirFlag.boolValue)
        }
        invalidateCache(path: toRemoteFolder)
        log("Subiendo \(pairs.count) elemento(s) a \(toRemoteFolder)…")
        startBatch(itemBytes: pairs.map { max(Self.localSize(path: $0.from), 0) })
        transferSequential(pairs) { [weak self] success in
            guard let self else { completion(success); return }
            self.endBatch()
            self.log(success ? "[OK] Subida completa." : "[ERROR] Hubo errores al subir.")
            self.lastResult = success ? "success" : "error"
            if recordHistory {
                let entries = pairs.flatMap { Self.fileEntries(localPath: $0.from) }
                let bytes = Int64(entries.reduce(0.0) { $0 + $1.megabytes } * 1_048_576)
                self.recordOperation(
                    type: "Subida",
                    fileCount: entries.isEmpty ? pairs.count : entries.count,
                    success: success,
                    bytes: bytes,
                    items: entries,
                    remotePath: toRemoteFolder,
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                )
            }
            if !success && trackFailure {
                self.recordFailure(type: "Subida", summary: "\(pairs.count) elemento(s) → \(toRemoteFolder)") { [weak self] in
                    self?.uploadLocalPaths(localPaths, toRemoteFolder: toRemoteFolder, recordHistory: recordHistory, trackFailure: trackFailure, completion: completion)
                }
            }
            if self.verifyAfterUpload {
                // run()'s terminationHandler already cleared isRunning for the transfer itself —
                // re-raise it for the verify pass so a second upload can't start mid-comparison
                // and have its own verifyStatusMessage overwritten by this one finishing late.
                self.isRunning = true
                self.verifySizes(pairs: pairs.map { (from: $0.from, to: $0.to) }) {
                    self.isRunning = false
                    self.maybeOfferShutdown()
                    completion(success)
                }
            } else {
                self.maybeOfferShutdown()
                completion(success)
            }
        }
    }

    // MARK: - Compress a remote folder into a .zip (B2 has no server-side compute for this —
    // downloads to a temp folder, zips locally with `ditto` (same tool Finder's own "Compress"
    // uses), uploads the .zip next to the original folder, then cleans up the temp copy).

    func compressFolder(_ item: RemotePathItem, trackFailure: Bool = true, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isRunning else {
            log("[WARN] Ya hay una operación en curso, espera a que termine.")
            completion(false)
            return
        }
        guard item.isDir else { completion(false); return }
        lastResult = nil
        let tempDir = NSTemporaryDirectory() + "b2sync-zip-" + UUID().uuidString
        let localFolder = Self.destPath(tempDir, item.name)
        let zipPath = tempDir + "/" + item.name + ".zip"
        let destFolder = Self.parentPath(of: item.path)

        // Retrying re-runs the whole download→zip→upload pipeline from scratch — the inner
        // downloadItems/uploadLocalPaths calls below intentionally skip their OWN retry tracking
        // (trackFailure: false) since a partial retry would try to zip/upload from a temp folder
        // that's already been cleaned up.
        func fail() {
            if trackFailure {
                self.recordFailure(type: "Comprimir", summary: "\(item.name) → \(destFolder)") { [weak self] in
                    self?.compressFolder(item, trackFailure: trackFailure, completion: completion)
                }
            }
            completion(false)
        }

        do {
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        } catch {
            log("[ERROR] No se pudo crear una carpeta temporal para comprimir: \(error.localizedDescription)")
            fail()
            return
        }

        log("Comprimiendo \(item.name): descargando temporalmente…")
        downloadItems([item], toLocalFolder: tempDir, recordHistory: false, trackFailure: false) { [weak self] downloadOK in
            guard let self else { completion(false); return }
            guard downloadOK else {
                self.log("[ERROR] Falló la descarga temporal, no se generó el .zip.")
                try? FileManager.default.removeItem(atPath: tempDir)
                self.recordOperation(type: "Comprimir", fileCount: 0, success: false)
                fail()
                return
            }
            // Snapshot the original folder's contents/size before zipping — this becomes the
            // "before" side of the history entry (and its expandable per-file breakdown).
            let originalEntries = Self.fileEntries(localPath: localFolder)
            let bytesBefore = Int64(originalEntries.reduce(0.0) { $0 + $1.megabytes } * 1_048_576)

            self.log("Comprimiendo \(item.name).zip…")
            // ditto runs outside run()'s isRunning bookkeeping — bracket it manually so a second
            // operation can't slip in between the download finishing and the upload starting.
            self.isRunning = true
            self.zipFolder(at: localFolder, to: zipPath) { [weak self] zipOK in
                guard let self else { completion(false); return }
                self.isRunning = false
                guard zipOK else {
                    self.log("[ERROR] No se pudo comprimir la carpeta.")
                    try? FileManager.default.removeItem(atPath: tempDir)
                    self.recordOperation(type: "Comprimir", fileCount: originalEntries.count, success: false, bytesBefore: bytesBefore, items: originalEntries)
                    fail()
                    return
                }
                let zipBytes = max(Self.localSize(path: zipPath), 0)
                self.log("Subiendo \(item.name).zip…")
                self.uploadLocalPaths([zipPath], toRemoteFolder: destFolder, recordHistory: false, trackFailure: false) { uploadOK in
                    try? FileManager.default.removeItem(atPath: tempDir)
                    self.log(uploadOK ? "[OK] \(item.name).zip subido." : "[ERROR] No se pudo subir el .zip.")
                    self.recordOperation(type: "Comprimir", fileCount: originalEntries.count, success: uploadOK, bytes: zipBytes, bytesBefore: bytesBefore, items: originalEntries)
                    if uploadOK {
                        completion(true)
                    } else {
                        fail()
                    }
                }
            }
        }
    }

    private func zipFolder(at path: String, to zipPath: String, completion: @escaping (Bool) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", path, zipPath]
        task.terminationHandler = { proc in
            Task { @MainActor in completion(proc.terminationStatus == 0) }
        }
        do {
            try task.run()
        } catch {
            completion(false)
        }
    }

    /// Downloads a whole B2 folder and saves it locally as a single .zip in ~/Downloads — same
    /// download+zip machinery as compressFolder, but the result stays on the Mac instead of being
    /// uploaded back to B2. Used by the Gallery's "Descargar carpeta como .zip".
    func downloadFolderAsZip(_ item: RemotePathItem, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isRunning else {
            log("[WARN] Ya hay una operación en curso, espera a que termine.")
            completion(false)
            return
        }
        guard item.isDir else { completion(false); return }
        let tempDir = NSTemporaryDirectory() + "b2sync-dlzip-" + UUID().uuidString
        let localFolder = Self.destPath(tempDir, item.name)
        let zipPath = tempDir + "/" + item.name + ".zip"
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Downloads")
        let finalZipPath = Self.destPath(downloadsDir, item.name + ".zip")

        do {
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        } catch {
            log("[ERROR] No se pudo crear una carpeta temporal: \(error.localizedDescription)")
            completion(false)
            return
        }

        log("Descargando \(item.name) para comprimir…")
        downloadItems([item], toLocalFolder: tempDir, recordHistory: false, trackFailure: false) { [weak self] downloadOK in
            guard let self else { completion(false); return }
            guard downloadOK else {
                self.log("[ERROR] Falló la descarga, no se generó el .zip.")
                try? FileManager.default.removeItem(atPath: tempDir)
                completion(false)
                return
            }
            self.log("Comprimiendo \(item.name).zip…")
            // Same manual bracket as compressFolder — ditto isn't covered by run()'s isRunning.
            self.isRunning = true
            self.zipFolder(at: localFolder, to: zipPath) { [weak self] zipOK in
                guard let self else { completion(false); return }
                self.isRunning = false
                defer { try? FileManager.default.removeItem(atPath: tempDir) }
                guard zipOK else {
                    self.log("[ERROR] No se pudo comprimir la carpeta.")
                    completion(false)
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: finalZipPath) {
                        try FileManager.default.removeItem(atPath: finalZipPath)
                    }
                    try FileManager.default.moveItem(atPath: zipPath, toPath: finalZipPath)
                    self.log("[OK] \(item.name).zip guardado en Descargas.")
                    completion(true)
                } catch {
                    self.log("[ERROR] No se pudo mover el .zip a Descargas: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }
    }

    // MARK: - Integrity verification (local size vs remote size, files and folders alike)

    private func verifySizes(pairs: [(from: String, to: String)], index: Int = 0, okCount: Int = 0, failures: [String] = [], completion: @escaping () -> Void) {
        guard index < pairs.count else {
            verifyStatusSuccess = failures.isEmpty
            verifyStatusMessage = failures.isEmpty
                ? "[OK] Archivos subidos correctamente \(okCount)/\(pairs.count)"
                : "[WARN] Diferencia de tamaño en \(failures.count)/\(pairs.count): " + failures.joined(separator: "; ")
            completion()
            return
        }
        let pair = pairs[index]
        let localBytes = Self.localSize(path: pair.from)
        folderSize(path: pair.to) { [weak self] info in
            guard let self else { return }
            let remoteBytes = info?.bytes ?? -1
            let matched = localBytes >= 0 && localBytes == remoteBytes
            var newFailures = failures
            if !matched {
                let name = (pair.from as NSString).lastPathComponent
                let localText = localBytes >= 0 ? Self.formatBytes(localBytes) : "no se pudo leer localmente"
                let remoteText = remoteBytes >= 0 ? Self.formatBytes(remoteBytes) : "no se encontró en B2"
                newFailures.append("\(name) (local: \(localText), B2: \(remoteText))")
            }
            self.verifySizes(
                pairs: pairs,
                index: index + 1,
                okCount: okCount + (matched ? 1 : 0),
                failures: newFailures,
                completion: completion
            )
        }
    }

    // MARK: - Deep integrity check (SHA1 content hash, on demand from the context menu)
    //
    // Unlike `verifySizes` (automatic, size-only, runs right after an upload), this is a manual,
    // heavier check the user asks for explicitly — real content hashing, not just byte counts, so
    // it also catches same-size-but-corrupted transfers. B2 already stores each object's SHA1 for
    // free (one `rclone hashsum` call lists a whole folder's hashes at once); the local side has
    // to actually read every byte, which is the real cost for large files and runs off the main
    // actor so the UI doesn't freeze.

    /// Fetches every file's SHA1 under `path` in one call (recursive for a folder, one line for a
    /// single file) and parses `rclone hashsum`'s "hash<TAB-or-2-spaces>relative/path" text format
    /// into a lookup keyed by relative path. Side-channel like `fetchFileBytes` — doesn't touch
    /// isRunning/percent, and reads the pipe concurrently while the process is still running (same
    /// deadlock fix as `fetchFileBytes`): a folder with many files can produce well over the
    /// pipe's ~64KB buffer.
    private func remoteSHA1Hashes(path: String, completion: @escaping ([String: String]?) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: rclonePath ?? "/usr/bin/false")
        task.arguments = Self.networkTimeoutArgs + ["hashsum", "sha1", path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
                let errorText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in
                    self.logBackgroundErrorOnce("No se pudo verificar la integridad de \(path)", errorText)
                    completion(nil)
                }
                return
            }
            var result: [String: String] = [:]
            for line in text.split(separator: "\n") {
                // rclone's sha1sum-style format: 40 hex chars, two spaces, then the relative path.
                guard line.count > 42 else { continue }
                let hash = String(line.prefix(40))
                let relPath = String(line.dropFirst(42))
                result[relPath] = hash
            }
            Task { @MainActor in completion(result) }
        }
    }

    nonisolated private static func localSHA1(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while true {
            let chunk = handle.readData(ofLength: 4_194_304)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Walks a local file or folder computing SHA1 for every file, keyed by path relative to
    /// `rootPath` (just the basename for a single file) — matches the key shape
    /// `remoteSHA1Hashes` produces, so the two dictionaries can be compared directly by key.
    /// Reports progress by file count, not bytes — a per-byte progress bar would be overkill for
    /// what's meant to be a simple "N of M files checked" readout.
    nonisolated private static func localSHA1Tree(rootPath: String, isDir: Bool, onFile: @escaping (Int, Int) -> Void) -> [String: String] {
        guard isDir else {
            let name = (rootPath as NSString).lastPathComponent
            let hash = localSHA1(path: rootPath)
            onFile(1, 1)
            return hash.map { [name: $0] } ?? [:]
        }
        guard let enumerator = FileManager.default.enumerator(atPath: rootPath) else { return [:] }
        var files: [String] = []
        for case let relative as String in enumerator {
            guard !isMacJunkPath(relative) else { continue }
            var isFileDir: ObjCBool = false
            let full = (rootPath as NSString).appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isFileDir), !isFileDir.boolValue else { continue }
            files.append(relative)
        }
        var result: [String: String] = [:]
        onFile(0, files.count)
        for (index, relative) in files.enumerated() {
            let full = (rootPath as NSString).appendingPathComponent(relative)
            if let hash = localSHA1(path: full) {
                result[relative] = hash
            }
            onFile(index + 1, files.count)
        }
        return result
    }

    /// Compares a local file/folder against its B2 counterpart by SHA1 content hash — catches
    /// corruption that a same-size check would miss. Matches entries by path relative to each
    /// root, independent of whatever the two roots themselves are named (the caller is expected
    /// to warn separately if the picked local item's own name doesn't match the remote item's).
    /// `onProgress(done, total)` convention: `(0, 0)` means "still fetching B2's hash list" (no
    /// file-count known yet — that step alone can take a while for a folder with many files, with
    /// nothing else to show for it), anything with `total >= 1` is real local-hashing progress.
    func verifyIntegrity(
        localPath: String,
        remotePath: String,
        isDir: Bool,
        onProgress: @escaping (Int, Int) -> Void,
        completion: @escaping (IntegrityResult?) -> Void
    ) {
        onProgress(0, 0)
        remoteSHA1Hashes(path: remotePath) { remoteHashes in
            guard let remoteHashes else { completion(nil); return }
            Task.detached {
                let localHashes = Self.localSHA1Tree(rootPath: localPath, isDir: isDir) { done, total in
                    Task { @MainActor in onProgress(done, total) }
                }
                let allKeys = Set(localHashes.keys).union(remoteHashes.keys)
                var mismatches: [IntegrityMismatch] = []
                for key in allKeys.sorted() {
                    switch (localHashes[key], remoteHashes[key]) {
                    case (nil, _):
                        mismatches.append(IntegrityMismatch(relativePath: key, reason: "Solo existe en B2"))
                    case (_, nil):
                        mismatches.append(IntegrityMismatch(relativePath: key, reason: "Solo existe en local"))
                    case let (l?, r?) where l != r:
                        mismatches.append(IntegrityMismatch(relativePath: key, reason: "Contenido distinto"))
                    default:
                        break
                    }
                }
                let result = IntegrityResult(totalCompared: allKeys.count, mismatches: mismatches)
                await MainActor.run { completion(result) }
            }
        }
    }

    private func startBatch(itemBytes: [Int64]) {
        let total = itemBytes.reduce(0, +)
        batch = total > 0 ? BatchProgress(itemBytes: itemBytes, totalBytes: total) : nil
    }

    private func advanceBatch() {
        guard let current = batch, current.index < current.itemBytes.count else { return }
        batch?.completedBytes += current.itemBytes[current.index]
        batch?.index += 1
    }

    private func endBatch() {
        batch = nil
        // Nothing ever reset these after a batch finished — the bar just sat at "100% ... ETA 0s"
        // until the next operation started. Shared by upload/move/copy/download (every endBatch()
        // caller), so fixing it here covers all four instead of duplicating it four times.
        percent = 0
        speed = ""
        eta = ""
    }

    /// Called at the TRUE end of upload/move/copy/download — deliberately NOT from endBatch(),
    /// because upload's own "verify integrity" step runs AFTER endBatch() but BEFORE the operation
    /// is actually done. Starting the countdown from endBatch() would race: it could reach 0 and
    /// shut the Mac down mid-verification, before verifyStatusMessage ever appears.
    private func maybeOfferShutdown() {
        guard shutdownWhenDone else { return }
        shutdownCountdown = 30
        shutdownTimer?.invalidate()
        shutdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let remaining = self.shutdownCountdown else { return }
                if remaining <= 1 {
                    self.shutdownTimer?.invalidate()
                    self.shutdownTimer = nil
                    self.shutdownCountdown = nil
                    self.shutdownMac()
                } else {
                    self.shutdownCountdown = remaining - 1
                }
            }
        }
    }

    /// The only way out of the countdown besides letting it hit 0 — meant for the sheet's
    /// "Cancelar" button.
    func cancelShutdownCountdown() {
        shutdownTimer?.invalidate()
        shutdownTimer = nil
        shutdownCountdown = nil
    }

    /// Runs via System Events (not a raw `shutdown` binary call, which needs root) — macOS will
    /// ask the user to grant Automation permission the first time this fires. No password needed
    /// or stored: Apple Events aren't `sudo`, and a stored password would show up in `ps aux`
    /// for anyone else on the machine to read as a process argument — worse than not having the
    /// feature at all.
    func shutdownMac() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to shut down"]
        try? task.run()
    }

    /// Fans out `rclone size` across every item concurrently — needed before a multi-item
    /// download/move/copy can show aggregate progress, since remote items don't carry their size
    /// (unlike local paths, where `localSize` is instant and synchronous).
    private func totalRemoteSizes(forPaths paths: [String], completion: @escaping ([Int64]) -> Void) {
        guard !paths.isEmpty else { completion([]); return }
        var results = [Int64](repeating: 0, count: paths.count)
        let group = DispatchGroup()
        for (index, path) in paths.enumerated() {
            group.enter()
            folderSize(path: path) { info in
                results[index] = info?.bytes ?? 0
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(results) }
    }

    private static func localSize(path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return -1 }
        if !isDir.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? -1
        }
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return -1 }
        var total: Int64 = 0
        for case let file as String in enumerator {
            guard !isMacJunkPath(file) else { continue }
            let full = (path as NSString).appendingPathComponent(file)
            if let size = try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    // ponytail: excludes macOS housekeeping junk from copy/upload/download — no reason to ever
    // ship .DS_Store or AppleDouble resource-fork files to B2, or waste bandwidth re-fetching
    // them back down.
    private static let macJunkExcludes = [".DS_Store", "._*", ".Spotlight-V100/**", ".Trashes/**", ".fseventsd/**", ".TemporaryItems/**"]
    private static var macJunkExcludeArgs: [String] { macJunkExcludes.flatMap { ["--exclude", $0] } }
    private static let macJunkDirNames: Set<String> = [".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems"]

    /// Local-side equivalent of `macJunkExcludes` (rclone's own `--exclude` glob patterns can't be
    /// reused directly here) — MUST stay in sync with it. Without this, `localSize`/`fileEntries`
    /// would count bytes for files rclone actually skips uploading, making a fully successful
    /// upload look like a size mismatch during "Verificar integridad".
    nonisolated private static func isMacJunkPath(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        if let name = components.last, name == ".DS_Store" || name.hasPrefix("._") { return true }
        return components.contains { macJunkDirNames.contains($0) }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `copy` treats its destination as a container to place the source's basename into — right
    /// for a directory source (the dest path IS the folder's new home), wrong for a FILE source
    /// (copying x.txt to ".../y.txt" wouldn't rename it to y.txt, it'd create a y.txt DIRECTORY
    /// with x.txt inside it). `copyto` is rclone's exact-path file copy — use it for files.
    private func transferSequential(_ items: [(from: String, to: String, isDir: Bool)], allSucceeded: Bool = true, onDone: @escaping (Bool) -> Void) {
        guard let first = items.first else { onDone(allSucceeded); return }
        let rest = Array(items.dropFirst())
        if batch == nil { percent = 0; speed = ""; eta = "" }
        // rclone refuses filter flags (--exclude) together with a single-file `copyto` ("can't
        // limit to single files when using filters") — moot anyway, since a lone selected file
        // was already explicitly chosen, not discovered by scanning a tree of junk to skip.
        let subcommand = first.isDir ? "copy" : "copyto"
        let excludeArgs = first.isDir ? Self.macJunkExcludeArgs : []
        run(arguments: [subcommand, first.from, first.to, "--progress", "--stats", "1s"] + excludeArgs) { [weak self] success in
            guard let self else { return }
            self.log(success ? "[OK] \(first.from) → \(first.to)" : "[ERROR] Falló: \(first.from)")
            self.advanceBatch()
            self.transferSequential(rest, allSucceeded: allSucceeded && success, onDone: onDone)
        }
    }

    private static func destPath(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    private static func parentPath(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return path }
        return String(path[..<idx])
    }

    // MARK: - Process plumbing

    private func run(arguments: [String], completion: @escaping (Bool) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: rclonePath ?? "/usr/bin/false")
        var fullArgs = Self.networkTimeoutArgs + ["--transfers", "\(max(parallelTransfers, 1))"]
        if bandwidthLimitMBps > 0 {
            fullArgs += ["--bwlimit", "\(bandwidthLimitMBps)M"]
        }
        task.arguments = fullArgs + arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        var buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            buffer += chunk
            // rclone rewrites progress in place using \r, not \n
            let pieces = buffer.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
            buffer = ""
            Task { @MainActor in
                for line in pieces where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    self?.handle(line: line)
                }
            }
        }

        task.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                // ponytail: an unguarded caller (e.g. createFolder) could slip in and start its own
                // run() while this one is still active — only clear shared state if we're still
                // the current process, so we never stomp a newer operation's isRunning/Cancelar.
                if self?.process === task {
                    self?.isRunning = false
                    self?.process = nil
                }
                completion(proc.terminationStatus == 0)
            }
        }

        do {
            isRunning = true
            process = task
            try task.run()
        } catch {
            isRunning = false
            log("[ERROR] No se pudo ejecutar rclone: \(error.localizedDescription)")
            completion(false)
        }
    }

    private func handle(line: String) {
        if line.contains("%") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = Self.progressRegex.firstMatch(in: line, range: range) {
                let itemPercent = Range(match.range(at: 1), in: line).flatMap { Double(line[$0]) }
                let speedText = Range(match.range(at: 2), in: line).map { String(line[$0]) }

                if let itemPercent {
                    if let batch, batch.index < batch.itemBytes.count {
                        let currentItemBytes = batch.itemBytes[batch.index]
                        let currentItemDone = Double(currentItemBytes) * min(max(itemPercent, 0), 100) / 100
                        let overallDone = Double(batch.completedBytes) + currentItemDone
                        percent = min(100, overallDone / Double(batch.totalBytes) * 100)
                        if let speedText, let bytesPerSecond = Self.parseSpeedBytesPerSecond(speedText), bytesPerSecond > 0 {
                            let remaining = max(Double(batch.totalBytes) - overallDone, 0)
                            eta = Self.formatETA(seconds: remaining / bytesPerSecond)
                        }
                    } else {
                        percent = itemPercent
                        if let r = Range(match.range(at: 3), in: line) {
                            eta = String(line[r])
                        }
                    }
                }
                if let speedText {
                    speed = speedText
                }
            }
        }
        logRaw(line)
    }

    /// Parses rclone's human-readable speed ("1.300 MiB/s", "850 KiB/s") into bytes/second,
    /// so the batch ETA can be computed from total bytes remaining instead of one file's own ETA.
    private static func parseSpeedBytesPerSecond(_ text: String) -> Double? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        let multipliers: [String: Double] = [
            "B/s": 1, "KiB/s": 1024, "MiB/s": 1024 * 1024, "GiB/s": 1024 * 1024 * 1024, "TiB/s": 1024 * 1024 * 1024 * 1024
        ]
        guard let multiplier = multipliers[String(parts[1])] else { return nil }
        return value * multiplier
    }

    private static func formatETA(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)m\(s)s" }
        return "\(s)s"
    }
}
