import AVFoundation
import Foundation

public enum VideoCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case h264, hevc

    public var id: String { rawValue }
    public var displayName: String { self == .h264 ? "H.264（兼容性好）" : "HEVC（体积小）" }
}

/// 一次导出/预览的完整参数。
public struct ExportRequest: Sendable {
    public var event: DashcamEvent
    public var interval: DateInterval
    public var layout: VideoLayout
    public var cameras: [Camera]
    public var overlay: OverlayOptions
    public var quality: ExportQuality
    public var codec: VideoCodec
    public var telemetry: TelemetryTrack?

    public init(event: DashcamEvent, interval: DateInterval, layout: VideoLayout = .grid, cameras: [Camera]? = nil,
                overlay: OverlayOptions = OverlayOptions(), quality: ExportQuality = .p1080, codec: VideoCodec = .h264,
                telemetry: TelemetryTrack? = nil) {
        self.event = event
        self.interval = interval
        self.layout = layout
        self.cameras = cameras ?? layout.defaultCameras(available: event.cameras)
        self.overlay = overlay
        self.quality = quality
        self.codec = codec
        self.telemetry = telemetry
    }
}

public enum CompositionError: LocalizedError {
    case noCameras
    case emptyRange

    public var errorDescription: String? {
        switch self {
        case .noCameras: "没有可用的摄像头画面"
        case .emptyRange: "所选时间段内没有视频"
        }
    }
}

/// 合成结果，可直接用于 AVPlayerItem 预览或导出。
public struct DashcamComposition: @unchecked Sendable {
    public let asset: AVComposition
    public let videoComposition: AVVideoComposition
    public let plan: LayoutPlan
    /// 实际覆盖的时间区间（已按视频可用范围裁剪）
    public let interval: DateInterval
    /// 每路摄像头实际使用的源文件
    public let sources: [(camera: Camera, segmentStart: Date, url: URL)]
    /// 合成中实际包含的摄像头轨道
    public let trackIDs: [Camera: CMPersistentTrackID]
    let sourceSize: CGSize
    let frameRate: Float

    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        return item
    }

    /// 所需摄像头都已在合成中且起点不变时，可只替换布局/水印/车辆数据，不重新读取视频文件。
    /// 未用到的轨道不在合成指令的 requiredSourceTrackIDs 中，不会被解码。
    public func canReuseTracks(for request: ExportRequest) -> Bool {
        let cameras = Set(request.cameras.filter(request.event.cameras.contains))
        return !cameras.isEmpty && cameras.isSubset(of: trackIDs.keys)
            && abs(request.interval.start.timeIntervalSince(interval.start)) < 0.001
    }

    /// 用新的布局、水印或车辆数据生成视频合成，可直接赋给当前 AVPlayerItem.videoComposition。
    public func updating(for request: ExportRequest) -> DashcamComposition {
        CompositionBuilder.finish(request, asset: asset, trackIDs: trackIDs, sources: sources,
                                  sourceSize: sourceSize, frameRate: frameRate)
    }
}

public enum CompositionBuilder {
    public static func build(_ request: ExportRequest) async throws -> DashcamComposition {
        let cameras = request.cameras.filter(request.event.cameras.contains)
        guard !cameras.isEmpty else { throw CompositionError.noCameras }

        let composition = AVMutableComposition()
        let timescale: CMTimeScale = 600
        func time(_ seconds: TimeInterval) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

        var trackIDs: [Camera: CMPersistentTrackID] = [:]
        var sources: [(Camera, Date, URL)] = []
        var mainSize: CGSize?
        var frameRate: Float = 0

        for camera in cameras {
            guard let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var cursor: TimeInterval = 0
            let segments = request.event.segments
            for (index, segment) in segments.enumerated() {
                guard let url = segment.files[camera] else { continue }
                let asset = AVURLAsset(url: url)
                guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
                let (sourceRange, size, fps) = try await source.load(.timeRange, .naturalSize, .nominalFrameRate)
                let segmentStart = SegmentAlignment.start(of: segment, duration: sourceRange.duration.seconds,
                                                          next: segments.indices.contains(index + 1) ? segments[index + 1] : nil)
                let segmentEnd = segmentStart + sourceRange.duration.seconds
                // 相邻分段可能有少量重叠，从当前轨道末尾之后开始取
                let overlapStart = max(segmentStart, request.interval.start, request.interval.start + cursor)
                let overlapEnd = min(segmentEnd, request.interval.end)
                guard overlapEnd.timeIntervalSince(overlapStart) > 0.05 else { continue }

                let destination = overlapStart.timeIntervalSince(request.interval.start)
                if destination - cursor > 0.01 {
                    track.insertEmptyTimeRange(CMTimeRange(start: time(cursor), end: time(destination)))
                }
                let sourceStart = sourceRange.start + time(overlapStart.timeIntervalSince(segmentStart))
                let duration = time(overlapEnd.timeIntervalSince(overlapStart))
                try track.insertTimeRange(CMTimeRange(start: sourceStart, duration: duration), of: source, at: time(destination))
                cursor = destination + duration.seconds
                sources.append((camera, segment.startDate, url))
                if camera == cameras[0], mainSize == nil { mainSize = size }
                frameRate = max(frameRate, fps)
            }
            if track.segments.isEmpty {
                composition.removeTrack(track)
            } else {
                trackIDs[camera] = track.trackID
            }
        }

        guard !trackIDs.isEmpty, composition.duration.seconds > 0 else { throw CompositionError.emptyRange }
        return finish(request, asset: composition, trackIDs: trackIDs, sources: sources,
                      sourceSize: mainSize ?? CGSize(width: 1280, height: 960), frameRate: frameRate)
    }

    static func finish(_ request: ExportRequest, asset: AVComposition, trackIDs: [Camera: CMPersistentTrackID],
                       sources: [(camera: Camera, segmentStart: Date, url: URL)], sourceSize size: CGSize,
                       frameRate: Float) -> DashcamComposition {
        let cameras = request.cameras.filter { trackIDs[$0] != nil }
        let showBottom = request.overlay.showsTelemetry && !(request.telemetry?.isEmpty ?? true)
        let plan = LayoutPlan.make(layout: request.layout, cameras: cameras,
                                   cellAspect: size.width / max(size.height, 1), sourceCellWidth: size.width,
                                   quality: request.quality, topBand: request.overlay.showsTopBand, bottomBand: showBottom)

        let eventLabel = [request.event.kind.displayName, request.event.location].compactMap { $0 }.joined(separator: " · ")
        let overlay = OverlayRenderer(plan: plan, options: request.overlay, telemetry: request.telemetry,
                                      startDate: request.interval.start, eventLabel: eventLabel)
        let instruction = DashcamInstruction(timeRange: CMTimeRange(start: .zero, duration: asset.duration),
                                             plan: plan, trackIDs: trackIDs.filter { cameras.contains($0.key) },
                                             overlay: overlay)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = DashcamCompositor.self
        videoComposition.renderSize = plan.canvasSize
        let fps = frameRate > 0 ? min(Int32(frameRate.rounded()), 60) : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
        videoComposition.instructions = [instruction]

        let interval = DateInterval(start: request.interval.start, duration: asset.duration.seconds)
        return DashcamComposition(asset: asset, videoComposition: videoComposition, plan: plan,
                                  interval: interval, sources: sources, trackIDs: trackIDs,
                                  sourceSize: size, frameRate: frameRate)
    }
}
