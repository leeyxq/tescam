import AVKit
import Charts
import SwiftUI
import TeslaCamKit

struct EventDetailView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ExportCenter.self) private var exports
    @State private var model: EventDetailModel
    @State private var isExportPresented = false
    @State private var isBatchPresented = false
    /// 播放区高度，拖动分隔条调整，跨事件记住
    @AppStorage("PlayerHeight") private var playerHeight: Double = 480
    @State private var dragStartHeight: Double?
    @State private var isExpanded = false
    @State private var isFullScreen = false

    /// 放大时给播放控制栏和车速时间轴留出的高度
    private static let reservedBelowPlayer: CGFloat = 270
    private static let minimumPlayerHeight: CGFloat = 200

    init(event: DashcamEvent) {
        _model = State(initialValue: EventDetailModel(event: event))
    }

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(geometry.size.height - Self.reservedBelowPlayer, Self.minimumPlayerHeight)
            let height = isExpanded ? maximum : min(max(playerHeight, Self.minimumPlayerHeight), maximum)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VideoPlayer(player: model.player)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            if let error = model.previewError {
                                Text(error).foregroundStyle(.white).padding().background(.red.opacity(0.8), in: .rect(cornerRadius: 6))
                            }
                        }
                    PlayerResizeHandle()
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartHeight ?? height
                                dragStartHeight = start
                                isExpanded = false
                                playerHeight = min(max(start + value.translation.height, Self.minimumPlayerHeight), maximum)
                            }
                            .onEnded { _ in dragStartHeight = nil })
                    VStack(alignment: .leading, spacing: 16) {
                        PlaybackControls(model: model, isExpanded: isExpanded, onToggleExpand: toggleExpand,
                                         onFullScreen: { setFullScreen(true) }) {
                            isExportPresented = true
                        }
                        TelemetryChart(model: model)
                            .frame(height: 170)
                        LayoutControls(model: model)
                        RiskList(model: model)
                    }
                }
                .padding([.horizontal, .bottom])
                .padding(.top, 8)
            }
        }
        .navigationTitle(model.event.title)
        #if os(iOS)
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenPlayer(model: model) { setFullScreen(false) }
        }
        #else
        .overlay {
            if isFullScreen {
                FullScreenPlayer(model: model) { setFullScreen(false) }
            }
        }
        .toolbar(isFullScreen ? .hidden : .automatic, for: .windowToolbar)
        #endif
        .toolbar {
            ToolbarItemGroup {
                let running = exports.runningJobs(for: model.event.id)
                if !running.isEmpty {
                    // 后台导出进度，点按回到导出界面查看
                    Button { isExportPresented = true } label: {
                        Gauge(value: running.map(\.progress).reduce(0, +) / Double(running.count)) {
                            Text("导出中")
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .scaleEffect(0.45)
                        .frame(width: 26, height: 26)
                    }
                    .help("正在导出 \(running.count) 个任务，点按查看")
                }
                Button("批量导出风险片段", systemImage: "square.stack.3d.down.right") { isBatchPresented = true }
                    .disabled(model.risks.isEmpty)
                Button("导出选区", systemImage: "square.and.arrow.up") { isExportPresented = true }
            }
        }
        .task {
            model.attach()
            await model.load()
        }
        .onDisappear {
            model.detach()
            if isExpanded { library.columnVisibility = .all }
        }
        .sheet(isPresented: $isExportPresented, onDismiss: model.rebuildPreview) {
            ExportSheet(model: model)
        }
        .sheet(isPresented: $isBatchPresented) {
            BatchExportSheet(model: model)
        }
    }

    private func setFullScreen(_ on: Bool) {
        #if os(macOS)
        // 同时让窗口进入/退出系统全屏，并隐藏侧边栏
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) != on {
            window.toggleFullScreen(nil)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            library.columnVisibility = on || isExpanded ? .detailOnly : .all
            isFullScreen = on
        }
        #else
        isFullScreen = on
        #endif
    }

    private func toggleExpand() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
            library.columnVisibility = isExpanded ? .detailOnly : .all
        }
    }
}

/// 全屏播放：与详情页共用同一个播放器，进度和合成画面保持一致。
private struct FullScreenPlayer: View {
    let model: EventDetailModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: model.player)
                .ignoresSafeArea()
            Button("退出全屏", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.5), in: Circle())
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding()
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
    }
}

/// 播放区与下方时间轴之间的分隔条，上下拖动改变播放区高度。
private struct PlayerResizeHandle: View {
    @State private var isHovering = false

    var body: some View {
        Capsule()
            .fill(isHovering ? Color.accentColor : Color.secondary.opacity(0.5))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .contentShape(Rectangle())
            .help("上下拖动调整播放区大小")
            .onHover { hovering in
                isHovering = hovering
                #if os(macOS)
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                #endif
            }
    }
}

private struct PlaybackControls: View {
    @Bindable var model: EventDetailModel
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onFullScreen: () -> Void
    let onExport: () -> Void

    var body: some View {
        // 按可用宽度依次尝试：单行 → 两行 → 两行精简（iPhone 竖屏）
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                transport(fullDate: true)
                Spacer(minLength: 0)
                editing(compact: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) { transport(fullDate: true) }
                HStack(spacing: 14) {
                    editing(compact: false)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) { transport(fullDate: false) }
                HStack(spacing: 12) {
                    editing(compact: true)
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .lineLimit(1)
    }

    /// 播放按钮、当前时间、车速
    @ViewBuilder
    private func transport(fullDate: Bool) -> some View {
        Button("后退5秒", systemImage: "gobackward.5") { model.step(-5) }
        Button(model.isPlaying ? "暂停" : "播放", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
            model.togglePlay()
        }
        .keyboardShortcut(.space, modifiers: [])
        Button("前进5秒", systemImage: "goforward.5") { model.step(5) }
        Group {
            if fullDate {
                Text(model.currentDate, format: .dateTime.year().month().day().hour().minute().second())
            } else {
                Text(model.currentDate, format: .dateTime.hour().minute().second())
            }
        }
        .font(.callout.monospacedDigit())
        .fixedSize()
        if let frame = model.currentFrame {
            Text(String(format: "%.0f km/h", frame.metadata.speedKmh))
                .font(.callout.monospacedDigit().bold())
                .fixedSize()
            if frame.metadata.brakeApplied {
                Text("刹车").font(.caption.bold()).foregroundStyle(.red).fixedSize()
            }
        }
    }

    /// 放大、开始/结束线、选区信息、导出；compact 时选区只显示时长
    @ViewBuilder
    private func editing(compact: Bool) -> some View {
        Button(isExpanded ? "还原播放区" : "放大播放区",
               systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
               action: onToggleExpand)
            .keyboardShortcut("f", modifiers: [])
            .help(isExpanded ? "还原播放区（F）" : "放大播放区，隐藏左侧列表（F）")
        Button("全屏播放", systemImage: "arrow.up.backward.and.arrow.down.forward.rectangle", action: onFullScreen)
            .keyboardShortcut("f", modifiers: [.control, .command])
            .help("全屏播放（⌃⌘F）")
        Button("设为开始", systemImage: "chevron.left.to.line") { model.setMarkIn(model.currentDate) }
            .keyboardShortcut("i", modifiers: [])
            .help("把开始线移到播放头（I）")
        Button("设为结束", systemImage: "chevron.right.to.line") { model.setMarkOut(model.currentDate) }
            .keyboardShortcut("o", modifiers: [])
            .help("把结束线移到播放头（O）")
        if model.markIn != nil || model.markOut != nil {
            let duration = Duration.seconds(model.selection.duration).formatted(.time(pattern: .minuteSecond))
            Group {
                if compact {
                    Text(duration)
                } else {
                    Text("\(model.selection.start.formatted(.dateTime.hour().minute().second())) – \(model.selection.end.formatted(.dateTime.hour().minute().second()))  \(duration)")
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .fixedSize()
            Button("清除选区", systemImage: "xmark.circle") { model.clearSelection() }
        }
        Spacer(minLength: 0)
        Button("导出选区", systemImage: "square.and.arrow.up", action: onExport)
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .keyboardShortcut("e", modifiers: .command)
            .help("按开始线和结束线导出（⌘E）")
    }
}

private struct TelemetryChart: View {
    let model: EventDetailModel

    private enum DragTarget { case markIn, markOut, playhead }
    @State private var dragTarget: DragTarget?
    @State private var hoveringHandle = false
    /// 开始/结束线的抓取范围（点）
    private let grabDistance: CGFloat = 10
    /// 开始/结束标签的大致宽度，用于决定标签朝哪边
    private let labelWidth: CGFloat = 90

    var body: some View {
        let samples = model.telemetry?.downsampled(maxCount: 600) ?? []
        let selection = model.selection
        let hasSelection = model.markIn != nil || model.markOut != nil
        Chart {
            ForEach(Array(model.brakeIntervals.enumerated()), id: \.offset) { _, range in
                RectangleMark(xStart: .value("开始", range.start), xEnd: .value("结束", range.end))
                    .foregroundStyle(.red.opacity(0.15))
            }
            if hasSelection {
                // 选区外变暗
                RectangleMark(xStart: .value("事件开始", model.interval.start), xEnd: .value("开始线", selection.start))
                    .foregroundStyle(.gray.opacity(0.25))
                RectangleMark(xStart: .value("结束线", selection.end), xEnd: .value("事件结束", model.interval.end))
                    .foregroundStyle(.gray.opacity(0.25))
            }
            ForEach(Array(samples.enumerated()), id: \.offset) { _, frame in
                LineMark(x: .value("时间", frame.date), y: .value("车速 km/h", frame.metadata.speedKmh))
                    .interpolationMethod(.monotone)
            }
            ForEach(model.risks) { point in
                RuleMark(x: .value("风险", point.date))
                    .foregroundStyle(point.severity > 0.7 ? .red : .orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .annotation(position: .top, spacing: 0) {
                        Image(systemName: point.kind.symbolName).font(.caption2).foregroundStyle(.orange)
                    }
            }
            RuleMark(x: .value("播放头", model.currentDate)).foregroundStyle(.primary)
        }
        .chartXScale(domain: model.interval.start...model.interval.end)
        .chartYAxisLabel("km/h")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let plot = geometry[plotFrame]
                    let inX = plot.minX + (proxy.position(forX: selection.start) ?? 0)
                    let outX = plot.minX + (proxy.position(forX: selection.end) ?? plot.width)
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if dragTarget == nil {
                                        dragTarget = target(at: value.startLocation.x, inX: inX, outX: outX)
                                    }
                                    guard let date: Date = proxy.value(atX: value.location.x - plot.minX) else { return }
                                    switch dragTarget {
                                    case .markIn:
                                        model.setMarkIn(date)
                                        model.seek(to: model.selection.start)
                                    case .markOut:
                                        model.setMarkOut(date)
                                        model.seek(to: model.selection.end)
                                    default:
                                        model.seek(to: date)
                                    }
                                }
                                .onEnded { _ in dragTarget = nil })
                        #if os(macOS)
                            .onContinuousHover { phase in
                                let near: Bool
                                if case .active(let location) = phase {
                                    near = target(at: location.x, inX: inX, outX: outX) != .playhead
                                } else {
                                    near = false
                                }
                                guard near != hoveringHandle else { return }
                                hoveringHandle = near
                                if near { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                        #endif
                        // 标签朝选区外侧，避免两条线靠近时标签交叉；外侧放不下再朝内
                        SelectionHandle(title: "开始", date: selection.start, color: .green,
                                        alignment: inX - plot.minX >= labelWidth ? .trailing : .leading,
                                        isActive: dragTarget == .markIn)
                            .frame(height: plot.height + 18)
                            .position(x: inX, y: plot.minY + (plot.height - 18) / 2)
                        SelectionHandle(title: "结束", date: selection.end, color: .red,
                                        alignment: plot.maxX - outX >= labelWidth ? .leading : .trailing,
                                        isActive: dragTarget == .markOut)
                            .frame(height: plot.height + 18)
                            .position(x: outX, y: plot.minY + (plot.height - 18) / 2)
                    }
                }
            }
        }
        .padding(.top, 18)
        .overlay {
            if model.isLoadingTelemetry {
                ProgressView("读取车辆数据…").controlSize(.small)
            } else if model.telemetry == nil {
                Text("视频中无车辆数据（需较新固件），仅显示事件触发点")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 按按下位置决定拖动开始线、结束线还是播放头；两条线重叠时取更近的一条。
    private func target(at x: CGFloat, inX: CGFloat, outX: CGFloat) -> DragTarget {
        let toIn = abs(x - inX), toOut = abs(x - outX)
        if min(toIn, toOut) > grabDistance { return .playhead }
        if toIn == toOut { return x < inX ? .markIn : .markOut }
        return toIn < toOut ? .markIn : .markOut
    }
}

/// 可拖动的开始线/结束线：竖线 + 顶部时间标签。
private struct SelectionHandle: View {
    let title: String
    let date: Date
    let color: Color
    let alignment: HorizontalAlignment
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("\(title) \(date.formatted(.dateTime.hour().minute().second()))")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(height: 16)
                .background(color, in: .rect(cornerRadius: 3))
                .fixedSize()
                .frame(width: 0, alignment: alignment == .leading ? .leading : .trailing)
            Rectangle()
                .fill(color)
                .frame(width: isActive ? 3 : 2)
                .padding(.top, 2)
        }
        .frame(width: 2)
        .allowsHitTesting(false)
    }
}

private struct LayoutControls: View {
    @Bindable var model: EventDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("布局", selection: $model.layout) {
                ForEach(VideoLayout.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                ForEach(model.event.cameras) { camera in
                    Toggle(camera.displayName, isOn: Binding(
                        get: { model.cameras.contains(camera) },
                        set: { _ in model.toggleCamera(camera) }))
                    .toggleStyle(.button)
                }
            }
            .controlSize(.small)
        }
    }
}

private struct RiskList: View {
    let model: EventDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("风险事件点（\(model.risks.count)）").font(.headline)
            if model.risks.isEmpty && !model.isLoadingTelemetry {
                Text("未识别到风险事件").foregroundStyle(.secondary)
            }
            ForEach(model.risks) { point in
                HStack(spacing: 10) {
                    Image(systemName: point.kind.symbolName)
                        .foregroundStyle(point.severity > 0.7 ? .red : .orange)
                        .frame(width: 22)
                    VStack(alignment: .leading) {
                        HStack {
                            Text(point.kind.displayName).bold()
                            Text(point.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(point.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("定位") { model.seek(to: point.date - 3) }
                    Button("框选") { model.select(around: point) }
                        .help("把开始线、结束线移到该点前 10 秒、后 5 秒，可再拖动微调")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Divider()
            }
        }
    }
}
