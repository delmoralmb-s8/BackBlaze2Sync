import Foundation

/// Single source of truth for "is this file an image" — shared between the Explorer
/// (icon choice) and the Gallery (what shows up in the thumbnail grid).
enum ImageKind {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "webp", "tif", "tiff"]

    static func isImage(_ filename: String) -> Bool {
        extensions.contains((filename as NSString).pathExtension.lowercased())
    }
}
