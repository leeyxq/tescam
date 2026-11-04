import SwiftUI

@main
struct TescamApp: App {
    @State private var library = LibraryModel()
    @State private var exports = ExportCenter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(exports)
                .task {
                    #if DEBUG
                    // 调试用：-TesCamOpen <目录> 启动时自动打开（沙盒下只能打开已授权的目录）
                    if let path = UserDefaults.standard.string(forKey: "TesCamOpen") {
                        await library.open(URL(fileURLWithPath: path), remember: false)
                        if library.library == nil { library.errorMessage = nil }
                    }
                    #endif
                    await library.reopenLastIfAvailable()
                    #if DEBUG
                    // 调试用：-TesCamSelect <序号> 自动选中事件
                    if let index = UserDefaults.standard.object(forKey: "TesCamSelect") as? Int ?? Int(UserDefaults.standard.string(forKey: "TesCamSelect") ?? ""),
                       library.events.indices.contains(index) {
                        library.selectedEventID = library.events[index].id
                    }
                    #endif
                }
                #if os(macOS)
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
                    Task { await library.reopenLastIfAvailable() }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { note in
                    if let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                        library.volumeDidUnmount(volume)
                    }
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1440, height: 960)
        .commands {
            CommandGroup(after: .newItem) {
                Button("打开 TeslaCam 目录…") { library.isImporterPresented = true }
                    .keyboardShortcut("o")
            }
        }
        #endif
    }
}
