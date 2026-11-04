import AVFoundation
import Foundation
import Observation
import TeslaCamKit

@MainActor @Observable
final class EventDetailModel {
    let event: DashcamEvent
    var interval: DateInterval
    var telemetry: TelemetryTrack?
    var brakeIntervals: [DateInterval] = []
    var risks: [RiskPoint] = []
    var isLoadingTelemetry = true

    var layout: VideoLayout = .grid {
        didSet {
            guard layout != oldValue else { return }
            cameras = layout.defaultCameras(available: event.cameras)
            rebuildPreview()
        }
    }
    var cameras: [Camera]
    var overlay = OverlayOptions()

    var currentTime: TimeInterval = 0
    var isPlaying = false
    var markIn: Date?
    var markOut: Date?
    var previewAspect: CGFloat = 4 / 3
    var previewError: String?

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var telemetryTask: Task<TelemetryTrack, Never>?
    @ObservationIgnored private var composition: DashcamComposition?

    init(event: DashcamEvent) {
        self.event = event
        self.interval = DateInterval(start: event.startDate, end: event.estimatedEndDate)
        self.cameras = VideoLayout.grid.defaultCameras(available: event.cameras)
    }

    var currentDate: Date { interval.start + currentTime }

    var currentFrame: TelemetryFrame? { telemetry?.sample(at: currentDate, tolerance: 0.5) }

    /// 当前选中的导出区间，未设置起止点时为整个事件。
    var selection: DateInterval {
        let start = markIn ?? interval.start
        let end = markOut ?? interval.end
        return end > start ? DateInterval(start: start, end: end) : interval
    }

    func load() async {
        interval = await EventTimeline.resolveInterval(for: event)
        rebuildPreview()
        let event = event
        let task = Task.detached(priority: .userInitiated) { TelemetryLoader.load(for: event) }
        telemetryTask = task
        let track = await task.value
        guard !task.isCancelled else { return }
        telemetry = track.isEmpty ? nil : track
        brakeIntervals = Self.brakeIntervals(in: track)
        risks = RiskDetector().detect(event: event, telemetry: track)
        isLoadingTelemetry = false
        if telemetry != nil { rebuildPreview() }
        if let trigger = event.triggerDate, interval.contains(trigger) {
            seek(to: trigger - 5)
        }
    }

    func attach() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                // 播放器还没有内容时不覆盖模型里待定位的时间
                guard let self, self.player.currentItem != nil, time.isNumeric else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    func detach() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rebuildTask?.cancel()
        telemetryTask?.cancel()
    }

    func makeRequest(interval: DateInterval, quality: ExportQuality, codec: VideoCodec = .h264) -> ExportRequest {
        ExportRequest(event: event, interval: interval, layout: layout, cameras: cameras, overlay: overlay,
                      quality: quality, codec: codec, telemetry: telemetry)
    }

    /// 用与导出完全相同的合成器生成预览，所见即所得。
    /// 摄像头不变时（切换布局、水印、车辆数据加载完成）只替换视频合成，不重新读取文件，画面不会闪黑。
    func rebuildPreview() {
        rebuildTask?.cancel()
        let request = makeRequest(interval: interval, quality: .p720)
        if let composition, composition.canReuseTracks(for: request), let item = player.currentItem {
            let updated = composition.updating(for: request)
            self.composition = updated
            previewAspect = updated.plan.canvasSize.width / updated.plan.canvasSize.height
            item.videoComposition = updated.videoComposition
            return
        }
        rebuildTask = Task {
            do {
                // 预览合成一次装入全部摄像头，之后切换布局/摄像头只换视频合成
                var allCameras = request
                allCameras.cameras = event.cameras
                let built = try await CompositionBuilder.build(allCameras).updating(for: request)
                guard !Task.isCancelled else { return }
                composition = built
                previewAspect = built.plan.canvasSize.width / built.plan.canvasSize.height
                // 播放头以模型记录的时间为准：首次加载时播放器还没有内容，currentTime() 是无效值
                let resumeTime = CMTime(seconds: currentTime, preferredTimescale: 600)
                let wasPlaying = player.rate != 0
                player.replaceCurrentItem(with: built.makePlayerItem())
                await player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { player.play() }
                previewError = nil
            } catch {
                previewError = error.localizedDescription
            }
        }
    }

    func toggleCamera(_ camera: Camera) {
        var updated = cameras
        if let index = updated.firstIndex(of: camera) {
            guard updated.count > layout.cameraCountRange.lowerBound else { return }
            updated.remove(at: index)
        } else {
            updated.append(camera)
            if updated.count > layout.cameraCountRange.upperBound { updated.removeFirst() }
        }
        cameras = updated
        rebuildPreview()
    }

    func togglePlay() {
        if player.rate == 0 { player.play() } else { player.pause() }
        isPlaying = player.rate != 0
    }

    func step(_ seconds: TimeInterval) {
        seek(to: currentDate + seconds)
    }

    func seek(to date: Date) {
        let seconds = min(max(date.timeIntervalSince(interval.start), 0), interval.duration)
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 选区最短时长（秒）
    static let minimumSelection: TimeInterval = 1

    /// 设置开始线，限制在事件范围内且不越过结束线。
    func setMarkIn(_ date: Date) {
        let limit = selection.end - Self.minimumSelection
        markIn = max(min(date, limit), interval.start)
        if markOut == nil { markOut = interval.end }
    }

    /// 设置结束线，限制在事件范围内且不越过开始线。
    func setMarkOut(_ date: Date) {
        let limit = selection.start + Self.minimumSelection
        markOut = min(max(date, limit), interval.end)
        if markIn == nil { markIn = interval.start }
    }

    func clearSelection() {
        markIn = nil
        markOut = nil
    }

    /// 把开始线/结束线移到风险点前后，导出仍以两条线为准。
    func select(around point: RiskPoint, before: TimeInterval = 10, after: TimeInterval = 5) {
        markIn = max(point.date - before, interval.start)
        markOut = min(point.date + after, interval.end)
        seek(to: markIn!)
    }

    private static func brakeIntervals(in track: TelemetryTrack) -> [DateInterval] {
        var result: [DateInterval] = []
        var start: Date?
        for frame in track.frames {
            if frame.metadata.brakeApplied {
                if start == nil { start = frame.date }
            } else if let s = start {
                result.append(DateInterval(start: s, end: frame.date))
                start = nil
            }
        }
        if let s = start, let last = track.frames.last { result.append(DateInterval(start: s, end: last.date)) }
        return result
    }
}
