import Foundation

/// One row in the "vista desplegable" (Finder List View style) tree.
/// Children are fetched lazily the first time a folder is expanded.
@MainActor
final class ExplorerNode: ObservableObject, Identifiable {
    let entry: RemoteEntry
    let fullPath: String
    let depth: Int

    @Published var isExpanded = false
    @Published var children: [ExplorerNode] = []
    @Published var isLoadingChildren = false
    private(set) var hasLoadedChildren = false

    var id: String { fullPath }

    init(entry: RemoteEntry, parentFullPath: String, depth: Int) {
        self.entry = entry
        self.fullPath = parentFullPath.hasSuffix("/") ? parentFullPath + entry.Path : parentFullPath + "/" + entry.Path
        self.depth = depth
    }

    func markLoaded(children: [ExplorerNode]) {
        self.children = children
        self.hasLoadedChildren = true
        self.isLoadingChildren = false
        self.isExpanded = true
    }

    /// Carries over expand/children state from the previous node at the same path,
    /// so a sibling-level refresh doesn't silently collapse/re-fetch untouched subtrees.
    func restoreState(from other: ExplorerNode) {
        children = other.children
        hasLoadedChildren = other.hasLoadedChildren
        isExpanded = other.isExpanded
    }
}
