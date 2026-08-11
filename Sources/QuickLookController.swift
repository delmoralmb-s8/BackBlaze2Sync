import Quartz

/// Bridges macOS's native Quick Look panel (the same one Finder shows on Space) into the app.
/// Every file here lives in B2, not locally, so the caller downloads it to a temp path first and
/// hands this the resulting local URL — Quick Look itself only ever sees a local file.
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var url: URL?

    func show(url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}
