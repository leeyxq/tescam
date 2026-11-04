import Foundation
import Observation
import SwiftUI
import TeslaCamKit

enum SidebarFilter: Hashable, Identifiable {
    case all
    case emergency
    case kind(ClipKind)

    var id: String {
        switch self {
        case .all: "all"
        case .emergency: "emergency"
        case .kind(let kind): kind.rawValue
        }
    }

    var title: String {
        switch self {
        case .all: "全部"
        case .emergency: "紧急事件"
        case .kind(let kind): kind.displayName
        }
    }

    var symbolName: String {
        switch self {
        case .all: "tray.full"
        case .emergency: "exclamationmark.triangle"
        case .kind(let kind): kind.symbolName
        }
    }

    static let ordered: [SidebarFilter] = [.all, .kind(.recent), .kind(.saved), .kind(.sentry), .emergency]
}

@MainActor @Observable
final class LibraryModel {
    var library: TeslaCamLibrary?
    var isScanning = false
    var isImporterPresented = false
    var errorMessage: String?
    var filter: SidebarFilter = .all
    var selectedEventID: DashcamEvent.ID?

    var columnVisibility: NavigationSplitViewVisibility = .all

    private var accessedURL: URL?
    private static let bookmarkKey = "LastOpenedBookmark"

    var events: [DashcamEvent] { events(for: filter) }

    var selectedEvent: DashcamEvent? {
        library?.events.first { $0.id == selectedEventID }
    }

    func events(for filter: SidebarFilter) -> [DashcamEvent] {
        guard let library else { return [] }
        switch filter {
        case .all: return library.events
        case .emergency: return library.events.filter(\.isEmergency)
        case .kind(let kind): return library.events(of: kind)
        }
    }

    /// 打开用户选择的目录（U 盘根目录、TeslaCam 或其子目录）。保持安全作用域访问直到切换目录。
    func open(_ url: URL, remember: Bool = true) async {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }
        do {
            let scanned = try await Task.detached(priority: .userInitiated) {
                try TeslaCamScanner().scan(url)
            }.value
            library = scanned
            selectedEventID = scanned.events.first?.id
            if remember { saveBookmark(for: url) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 启动或插入 U 盘时，自动打开上次选择的目录；目录不在（U 盘未插入）则保持空白，不报错。
    func reopenLastIfAvailable() async {
        guard library == nil, !isScanning, let url = resolveBookmark(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        await open(url, remember: false)
    }

    /// U 盘拔出后清空列表，避免继续访问已不存在的文件。
    func volumeDidUnmount(_ volume: URL) {
        guard let root = library?.root, root.standardizedFileURL.path.hasPrefix(volume.standardizedFileURL.path) else { return }
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        library = nil
        selectedEventID = nil
    }

    private func saveBookmark(for url: URL) {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        if let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        #endif
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        if isStale, url.startAccessingSecurityScopedResource() {
            saveBookmark(for: url)
            url.stopAccessingSecurityScopedResource()
        }
        return url
    }
}
