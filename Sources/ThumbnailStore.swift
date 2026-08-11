import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Small semaphore-style actor bounding how many `rclone cat` processes run at once —
/// without this, opening a folder with hundreds of photos would spawn hundreds of
/// processes simultaneously.
actor Limiter {
    private let max: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(max: Int) { self.max = max }

    func wait() async {
        if count < max {
            count += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        count += 1
    }

    func signal() {
        count -= 1
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }
}

/// Fetches, downscales, and disk/memory-caches thumbnails for images browsed in the
/// Gallery. Deliberately separate from RcloneManager — this is CPU-bound image work,
/// not another Process wrapper — but calls into RcloneManager.fetchFileBytes (a
/// side-channel that doesn't touch isRunning/percent) to get the raw bytes.
@MainActor
final class ThumbnailStore: ObservableObject {
    private let memCache = NSCache<NSString, NSImage>()
    /// Full-resolution images opened in the lightbox, memory-only (never written to disk —
    /// these are several MB each, unlike the tiny thumbnails). NSCache self-evicts under
    /// memory pressure, so this can't grow the way an unbounded disk cache could; it just
    /// makes revisiting the same photo via Anterior/Siguiente instant within a session.
    private let fullImageCache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let limiter = Limiter(max: 4)
    private let cacheDir: URL

    private static let maxCacheBytes: Int64 = 300_000_000
    private static let targetCacheBytes: Int64 = 250_000_000

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = base.appendingPathComponent("mx.smh.backblaze2sync/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        Self.enforceCacheLimit(in: cacheDir)
    }

    /// Cache-only lookup (memory, then disk) — never triggers a network fetch. Used by the
    /// lightbox to show an instant low-res placeholder while the full-res image loads.
    func cachedThumbnailIfAvailable(for entry: RemoteEntry, remotePath: String) -> NSImage? {
        let key = Self.cacheKey(remotePath: remotePath, entry: entry)
        if let cached = memCache.object(forKey: key as NSString) { return cached }
        return loadFromDisk(key: key)
    }

    /// Full-resolution image for the lightbox. Not disk-cached (see fullImageCache doc),
    /// but memory-cached for the session so re-opening the same photo is instant.
    func fullImage(remotePath: String, rclone: RcloneManager) async -> NSImage? {
        if let cached = fullImageCache.object(forKey: remotePath as NSString) { return cached }
        let data: Data? = await withCheckedContinuation { continuation in
            rclone.fetchFileBytes(path: remotePath) { continuation.resume(returning: $0) }
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        fullImageCache.setObject(image, forKey: remotePath as NSString)
        return image
    }

    /// Safety net so browsing many albums can't grow the disk cache without bound — each
    /// thumbnail is individually tiny (a few KB), but this caps the total anyway rather than
    /// just trusting that forever. Prunes oldest-modified files first, off the main thread.
    nonisolated private static func enforceCacheLimit(in dir: URL) {
        Task.detached {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
            var items: [(url: URL, date: Date, size: Int64)] = files.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate, let size = values.fileSize else { return nil }
                return (url, date, Int64(size))
            }
            var total = items.reduce(Int64(0)) { $0 + $1.size }
            guard total > maxCacheBytes else { return }
            items.sort { $0.date < $1.date }
            for item in items {
                guard total > targetCacheBytes else { break }
                try? fm.removeItem(at: item.url)
                total -= item.size
            }
        }
    }

    /// Returns a cached or freshly-generated thumbnail for this entry. Safe to call
    /// repeatedly for the same entry (in-flight requests are deduped) and safe to call
    /// for many different entries at once (fetches are capped by `limiter`).
    func thumbnail(for entry: RemoteEntry, remotePath: String, rclone: RcloneManager) async -> NSImage? {
        let key = Self.cacheKey(remotePath: remotePath, entry: entry)
        if let cached = memCache.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task { [weak self] () -> NSImage? in
            await self?.loadAndCache(key: key, remotePath: remotePath, rclone: rclone)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func loadAndCache(key: String, remotePath: String, rclone: RcloneManager) async -> NSImage? {
        if let onDisk = loadFromDisk(key: key) {
            memCache.setObject(onDisk, forKey: key as NSString)
            return onDisk
        }

        await limiter.wait()
        let data: Data? = await withCheckedContinuation { continuation in
            rclone.fetchFileBytes(path: remotePath) { continuation.resume(returning: $0) }
        }
        await limiter.signal()

        guard let data else { return nil }
        let cgImage = await Task.detached { () -> CGImage? in
            Self.makeThumbnail(data: data)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        memCache.setObject(image, forKey: key as NSString)
        saveToDisk(key: key, cgImage: cgImage)
        return image
    }

    private func fileURL(for key: String) -> URL {
        cacheDir.appendingPathComponent(key + ".jpg")
    }

    private func loadFromDisk(key: String) -> NSImage? {
        NSImage(contentsOf: fileURL(for: key))
    }

    private func saveToDisk(key: String, cgImage: CGImage) {
        let url = fileURL(for: key)
        Task.detached {
            guard let data = Self.encodeJPEG(cgImage) else { return }
            try? data.write(to: url)
        }
    }

    /// Includes the item's size and mod time in the key so a changed source file
    /// naturally misses the cache — no explicit invalidation logic needed.
    private static func cacheKey(remotePath: String, entry: RemoteEntry) -> String {
        let raw = "\(remotePath)|\(entry.Size)|\(entry.ModTime ?? "")"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes directly at the target size instead of decoding full-res first — much
    /// cheaper for large JPEGs/HEICs. Runs off the main actor via Task.detached.
    nonisolated private static func makeThumbnail(data: Data, maxPixelSize: CGFloat = 256) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
