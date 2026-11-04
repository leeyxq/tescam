import SwiftUI
import TeslaCamKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryModel.self) private var library
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// 事件列表栏宽度，拖动右侧分隔条调整（iOS 分栏不支持系统拖动）
    @AppStorage("EventListWidth") private var listWidth: Double = 340
    #endif

    var body: some View {
        @Bindable var library = library
        NavigationSplitView(columnVisibility: $library.columnVisibility) {
            List(SidebarFilter.ordered, selection: Binding($library.filter)) { filter in
                Label(filter.title, systemImage: filter.symbolName)
                    .badge(library.events(for: filter).count)
                    .tag(filter)
            }
            .navigationTitle("TesCam")
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
            .toolbar {
                ToolbarItem {
                    Button("打开", systemImage: "externaldrive") { library.isImporterPresented = true }
                }
            }
        } content: {
            EventListView()
                #if os(iOS)
                .navigationSplitViewColumnWidth(listWidth)
                .overlay(alignment: .trailing) {
                    if horizontalSizeClass == .regular {
                        ColumnResizeHandle(width: $listWidth, range: 240...600)
                    }
                }
                #else
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
                #endif
        } detail: {
            if let event = library.selectedEvent {
                EventDetailView(event: event)
                    .id(event.id)
            } else {
                ContentUnavailableView("选择一个事件", systemImage: "play.rectangle",
                                       description: Text("从左侧列表选择行车记录、手动保存或哨兵事件"))
            }
        }
        .fileImporter(isPresented: $library.isImporterPresented, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await library.open(url) }
            }
        }
        .alert("无法打开", isPresented: Binding(get: { library.errorMessage != nil },
                                              set: { if !$0 { library.errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}

struct EventListView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        @Bindable var library = library
        Group {
            if library.isScanning {
                ProgressView("正在扫描…")
            } else if library.library == nil {
                ContentUnavailableView {
                    Label("打开 TeslaCam", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("插入特斯拉行车记录 U 盘，选择 U 盘根目录或 TeslaCam 文件夹")
                } actions: {
                    Button("选择目录") { library.isImporterPresented = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if library.events.isEmpty {
                ContentUnavailableView("没有事件", systemImage: "tray")
            } else {
                List(library.events, selection: $library.selectedEventID) { event in
                    EventRow(event: event).tag(event.id)
                }
            }
        }
        .navigationTitle(library.filter.title)
    }
}

struct EventRow: View {
    let event: DashcamEvent

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(event: event)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: event.kind.symbolName)
                        .foregroundStyle(event.isEmergency ? .red : .secondary)
                    Text(event.startDate, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(event.title).font(.subheadline).lineLimit(1)
                Text(event.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

#if os(iOS)
/// 分栏右边缘的拖动条，左右拖动改变栏宽。
private struct ColumnResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Capsule()
            .fill(startWidth == nil ? Color.secondary.opacity(0.4) : Color.accentColor)
            .frame(width: 5, height: 44)
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startWidth ?? width
                    startWidth = start
                    width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startWidth = nil })
            .accessibilityLabel("调整列表宽度")
    }
}
#endif
