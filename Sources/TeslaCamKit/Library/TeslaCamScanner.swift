import AVFoundation
import Foundation

public enum TeslaCamScanError: LocalizedError {
    case unreadable(URL)
    case noClipsFound(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): "无法读取 \(url.lastPathComponent)，可能没有访问权限或 U 盘已拔出。请点“打开”重新选择 U 盘"
        case .noClipsFound(let url): "未在 \(url.lastPathComponent) 中找到特斯拉行车记录视频"
        }
    }
}

/// 扫描 U 盘根目录、TeslaCam 目录或任意包含行车记录视频的目录。
public struct TeslaCamScanner: Sendable {
    /// RecentClips 中相邻分段间隔超过该值即视为两次行程。
    public var driveGapTolerance: TimeInterval

    public init(driveGapTolerance: TimeInterval = 90) {
        self.driveGapTolerance = driveGapTolerance
    }

    public func scan(_ root: URL) throws -> TeslaCamLibrary {
        let fileManager = FileManager.default
        // 沙盒无权限时枚举器不会报错、只是返回空，先显式读一次根目录区分“无权限”和“没有视频”
        guard (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil,
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { throw TeslaCamScanError.unreadable(root) }

        var directories: [URL: [Date: [Camera: URL]]] = [:]
        for case let url as URL in enumerator {
            guard let parsed = DashcamFileName.parse(url.lastPathComponent) else { continue }
            let directory = url.deletingLastPathComponent().standardizedFileURL
            directories[directory, default: [:]][parsed.date, default: [:]][parsed.camera] = url
        }
        guard !directories.isEmpty else { throw TeslaCamScanError.noClipsFound(root) }

        var events: [DashcamEvent] = []
        for (directory, clips) in directories {
            let segments = clips
                .map { ClipSegment(startDate: $0.key, files: $0.value) }
                .sorted { $0.startDate < $1.startDate }
            let kind = ClipKind.infer(from: directory)
            let info = EventInfo.load(from: directory.appendingPathComponent("event.json"))
            let thumbnail = directory.appendingPathComponent("thumb.png")
            let thumbnailURL = fileManager.fileExists(atPath: thumbnail.path) ? thumbnail : nil

            if info == nil && (kind == .recent || kind == .other) {
                for group in splitIntoDrives(segments) {
                    events.append(DashcamEvent(
                        id: "\(kind.rawValue)-\(directory.path)-\(DashcamFileName.string(from: group[0].startDate))",
                        kind: kind, directory: directory, segments: group, info: nil, thumbnailURL: nil))
                }
            } else {
                events.append(DashcamEvent(
                    id: "\(kind.rawValue)-\(directory.path)",
                    kind: kind, directory: directory, segments: segments, info: info, thumbnailURL: thumbnailURL))
            }
        }
        return TeslaCamLibrary(root: root, events: events)
    }

    func splitIntoDrives(_ segments: [ClipSegment]) -> [[ClipSegment]] {
        var groups: [[ClipSegment]] = []
        for segment in segments {
            if let last = groups.last?.last,
               segment.startDate.timeIntervalSince(last.startDate) <= ClipSegment.nominalDuration + driveGapTolerance {
                groups[groups.count - 1].append(segment)
            } else {
                groups.append([segment])
            }
        }
        return groups
    }
}

public enum EventTimeline {
    /// 读取首尾分段的实际视频时长，得到事件精确的时间区间（首段可能因对齐而前移）。
    public static func resolveInterval(for event: DashcamEvent) async -> DateInterval {
        let segments = event.segments
        let first = segments[0], last = segments[segments.count - 1]
        let start = SegmentAlignment.start(of: first, duration: await duration(of: first),
                                           next: segments.count > 1 ? segments[1] : nil)
        var lastDuration = await duration(of: last)
        if lastDuration <= 0 { lastDuration = ClipSegment.nominalDuration }
        return DateInterval(start: min(start, event.startDate), end: last.startDate + lastDuration)
    }

    private static func duration(of segment: ClipSegment) async -> TimeInterval {
        var duration: TimeInterval = 0
        for url in segment.files.values {
            if let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric {
                duration = max(duration, time.seconds)
            }
        }
        return duration
    }
}
