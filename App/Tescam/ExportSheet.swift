import QuickLook
import SwiftUI
import TeslaCamKit
#if os(macOS)
import AppKit
#endif

enum ExportLocation {
    /// iOS 上位于“文件”App 的 TesCam 目录下；macOS 上位于沙盒容器内，可通过“存储到…”另存。
    static var directory: URL { URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory) }

    /// 本次运行已分配的路径：导出刚开始时文件可能还没写出，仅查磁盘会撞名
    @MainActor private static var reserved: Set<URL> = []

    /// 同名文件或目录已存在时追加 _2、_3…，避免覆盖之前导出的视频。
    @MainActor static func unique(_ url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url
        var index = 2
        while reserved.contains(candidate) || FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
            candidate = url.deletingLastPathComponent().appending(path: name)
            index += 1
        }
        reserved.insert(candidate)
        return candidate
    }
}

struct ExportSheet: View {
    @Bindable var model: EventDetailModel
    @Environment(ExportCenter.self) private var exports
    @State private var previewURL: URL?
    @State private var quality: ExportQuality = .p1080
    @State private var codec: VideoCodec = .h264
    @State private var writeManifest = true

    var body: some View {
        NavigationStack {
            Form {
                Section("时间段") {
                    LabeledContent("起点") { Text(model.selection.start, format: .dateTime.hour().minute().second()) }
                    LabeledContent("终点") { Text(model.selection.end, format: .dateTime.hour().minute().second()) }
                    LabeledContent("时长") { Text(Duration.seconds(model.selection.duration), format: .time(pattern: .minuteSecond)) }
                }
                Section("画面") {
                    Picker("布局", selection: $model.layout) {
                        ForEach(VideoLayout.allCases) { Text($0.displayName).tag($0) }
                    }
                    ForEach(model.event.cameras) { camera in
                        Toggle(camera.displayName, isOn: Binding(
                            get: { model.cameras.contains(camera) },
                            set: { _ in model.toggleCamera(camera) }))
                    }
                }
                OverlayOptionsSection(overlay: $model.overlay, hasTelemetry: model.telemetry != nil)
                Section("输出") {
                    Picker("分辨率", selection: $quality) {
                        ForEach(ExportQuality.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("编码", selection: $codec) {
                        ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("生成证据清单（源文件 SHA-256）", isOn: $writeManifest)
                }
                ExportJobsSections(eventID: model.event.id, startTitle: "开始导出", previewURL: $previewURL, start: startExport)
            }
            .formStyle(.grouped)
            .navigationTitle("导出视频")
            .exportCloseGuard(eventID: model.event.id)
        }
        .quickLookPreview($previewURL)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private func startExport() {
        let request = model.makeRequest(interval: model.selection, quality: quality, codec: codec)
        let url = ExportLocation.unique(ExportLocation.directory.appending(path: ExportNaming.fileName(
            start: request.interval.start, label: model.event.kind.displayName)))
        let manifest = writeManifest
        let time = Date.FormatStyle().hour().minute().second()
        let title = "\(request.interval.start.formatted(time)) – \(request.interval.end.formatted(time))"
        exports.start(eventID: model.event.id, title: title, partialOutput: url) { progress in
            [try await DashcamExporter.export(request, to: url, writeManifest: manifest, progress: progress)]
        }
    }
}

struct BatchExportSheet: View {
    @Bindable var model: EventDetailModel
    @Environment(ExportCenter.self) private var exports
    @State private var previewURL: URL?
    @State private var selected: Set<RiskPoint.ID> = []
    @State private var before: Double = 10
    @State private var after: Double = 5
    @State private var quality: ExportQuality = .p1080

    var body: some View {
        NavigationStack {
            Form {
                Section("风险事件点") {
                    ForEach(model.risks) { point in
                        Toggle(isOn: Binding(
                            get: { selected.contains(point.id) },
                            set: { if $0 { selected.insert(point.id) } else { selected.remove(point.id) } })) {
                            HStack {
                                Text(point.kind.displayName)
                                Text(point.date, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("片段范围") {
                    Stepper("事件前 \(Int(before)) 秒", value: $before, in: 0...60, step: 5)
                    Stepper("事件后 \(Int(after)) 秒", value: $after, in: 0...60, step: 5)
                    Picker("布局", selection: $model.layout) {
                        ForEach(VideoLayout.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("分辨率", selection: $quality) {
                        ForEach(ExportQuality.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                OverlayOptionsSection(overlay: $model.overlay, hasTelemetry: model.telemetry != nil)
                ExportJobsSections(eventID: model.event.id, startTitle: "开始批量导出", previewURL: $previewURL, start: startExport)
            }
            .formStyle(.grouped)
            .navigationTitle("批量导出风险片段")
            .exportCloseGuard(eventID: model.event.id)
        }
        .quickLookPreview($previewURL)
        .onAppear { selected = Set(model.risks.map(\.id)) }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private func startExport() {
        let points = model.risks.filter { selected.contains($0.id) }
        guard !points.isEmpty else { return }
        let base = model.makeRequest(interval: model.interval, quality: quality)
        let directory = ExportLocation.unique(ExportLocation.directory.appending(
            path: "批量_\(ExportNaming.fileName(start: model.interval.start, label: "风险片段"))", directoryHint: .isDirectory))
        let (before, after, interval, count) = (before, after, model.interval, Double(points.count))
        exports.start(eventID: model.event.id, title: "批量 \(points.count) 个风险片段") { progress in
            try await DashcamExporter.exportRiskClips(
                points, base: base, eventInterval: interval, before: before, after: after, to: directory) { index, fraction in
                    progress((Double(index) + fraction) / count)
                }
        }
    }
}

private struct OverlayOptionsSection: View {
    @Binding var overlay: OverlayOptions
    let hasTelemetry: Bool

    var body: some View {
        Section("水印") {
            TextField("自定义文字", text: $overlay.customText, prompt: Text("例如：交通违法举报证据"))
            Toggle("时间戳", isOn: $overlay.showTimestamp)
            Toggle("事件类型与城市", isOn: $overlay.showEventInfo)
            Toggle("摄像头名称", isOn: $overlay.showCameraLabels)
            Toggle("TesCam 标识", isOn: $overlay.showBrand)
        }
        Section {
            Toggle("车速", isOn: $overlay.showSpeed)
            Picker("速度单位", selection: $overlay.speedUnit) {
                ForEach(SpeedUnit.allCases) { Text($0.symbol).tag($0) }
            }
            Toggle("档位", isOn: $overlay.showGear)
            Toggle("刹车 / 油门", isOn: $overlay.showPedals)
            Toggle("方向盘转角", isOn: $overlay.showSteering)
            Toggle("转向灯", isOn: $overlay.showBlinkers)
            Toggle("辅助驾驶状态", isOn: $overlay.showAutopilot)
            Toggle("GPS 坐标", isOn: $overlay.showLocation)
        } header: {
            Text("车辆数据")
        } footer: {
            if !hasTelemetry { Text("当前视频不含车辆数据，以上选项不会生效。") }
        }
        .disabled(!hasTelemetry)
    }
}

/// “开始导出”按钮 + 该事件的导出任务列表（关闭界面后任务继续，再次打开可查看）。
private struct ExportJobsSections: View {
    let eventID: DashcamEvent.ID
    let startTitle: String
    @Binding var previewURL: URL?
    let start: () -> Void
    @Environment(ExportCenter.self) private var exports

    var body: some View {
        Section {
            Button(startTitle, systemImage: "square.and.arrow.down", action: start)
        } footer: {
            Text("关闭此界面后导出在后台继续，再次打开可查看进度。")
        }
        ForEach(exports.jobs(for: eventID)) { job in
            ExportJobSection(job: job, previewURL: $previewURL)
        }
    }
}

private struct ExportJobSection: View {
    let job: ExportJob
    @Binding var previewURL: URL?
    @State private var isMoverPresented = false

    var body: some View {
        Section {
            switch job.phase {
            case .exporting(let fraction):
                ProgressView(value: fraction) { Text("正在导出…") } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
                Button("取消导出", systemImage: "stop.circle", role: .destructive) { job.cancel() }
            case .done(let results):
                Label("已导出 \(results.count) 个视频，点击预览", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                ForEach(results, id: \.videoURL) { result in
                    Button { previewURL = result.videoURL } label: {
                        Label(result.videoURL.lastPathComponent, systemImage: "play.rectangle")
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                let files = results.flatMap { [$0.videoURL] + ($0.manifestURL.map { [$0] } ?? []) }
                ShareLink("分享", items: results.map(\.videoURL))
                Button("存储到…", systemImage: "folder") { isMoverPresented = true }
                    .fileMover(isPresented: $isMoverPresented, files: files) { _ in }
                #if os(macOS)
                Button("在访达中显示", systemImage: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting(results.map(\.videoURL))
                }
                #endif
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled:
                Label("已取消", systemImage: "stop.circle").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(job.title)
                Spacer()
                Text(job.createdAt, format: .dateTime.hour().minute().second())
            }
        }
    }
}

/// 关闭按钮：仍有任务在导出时询问是后台继续还是取消；导出中禁止下滑关闭，避免绕过提示。
private struct ExportCloseGuard: ViewModifier {
    let eventID: DashcamEvent.ID
    @Environment(ExportCenter.self) private var exports
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

    func body(content: Content) -> some View {
        let running = exports.runningJobs(for: eventID)
        content
            .interactiveDismissDisabled(!running.isEmpty)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        if running.isEmpty { dismiss() } else { isConfirming = true }
                    }
                    .confirmationDialog("导出尚未完成", isPresented: $isConfirming, titleVisibility: .visible) {
                        Button("在后台继续导出") { dismiss() }
                        Button("取消导出", role: .destructive) {
                            running.forEach { $0.cancel() }
                            dismiss()
                        }
                        Button("返回", role: .cancel) {}
                    } message: {
                        Text("后台继续时可随时重新打开导出界面查看进度。iPhone 切到其他 App 后系统只允许短时间运行，请尽量停留在 TesCam。")
                    }
                }
            }
    }
}

extension View {
    fileprivate func exportCloseGuard(eventID: DashcamEvent.ID) -> some View {
        modifier(ExportCloseGuard(eventID: eventID))
    }
}
