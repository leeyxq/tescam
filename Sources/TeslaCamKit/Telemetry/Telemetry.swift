import Foundation

/// 特斯拉在行车记录视频每帧 SEI 中写入的车辆数据（参考 teslamotors/dashcam 的 dashcam.proto）。
public struct SEIMetadata: Hashable, Sendable {
    public enum Gear: Int, Sendable, Codable {
        case park = 0, drive, reverse, neutral

        public var symbol: String {
            switch self {
            case .park: "P"
            case .drive: "D"
            case .reverse: "R"
            case .neutral: "N"
            }
        }
    }

    public enum AutopilotState: Int, Sendable, Codable {
        case none = 0, selfDriving, autosteer, tacc

        public var displayName: String {
            switch self {
            case .none: "手动驾驶"
            case .selfDriving: "FSD"
            case .autosteer: "自动辅助转向"
            case .tacc: "TACC"
            }
        }
    }

    public var version: UInt32 = 0
    public var gear: Gear = .park
    public var frameSequence: UInt64 = 0
    /// 米/秒
    public var speed: Double = 0
    /// 油门踏板开度（原始值，可能是 0–1 或 0–100）
    public var acceleratorPedal: Double = 0
    /// 方向盘转角，度
    public var steeringAngle: Double = 0
    public var blinkerLeft = false
    public var blinkerRight = false
    public var brakeApplied = false
    public var autopilot: AutopilotState = .none
    public var latitude: Double = 0
    public var longitude: Double = 0
    public var heading: Double = 0
    /// 车身线性加速度 m/s²
    public var accelerationX: Double = 0
    public var accelerationY: Double = 0
    public var accelerationZ: Double = 0

    public init() {}

    init(protobuf bytes: ArraySlice<UInt8>) throws {
        var reader = ProtobufReader(bytes)
        var recognized = 0
        while let (number, value) = try reader.nextField() {
            recognized += 1
            switch number {
            case 1: version = UInt32(truncatingIfNeeded: value.uint64Value)
            case 2: gear = Gear(rawValue: Int(truncatingIfNeeded: value.uint64Value)) ?? .park
            case 3: frameSequence = value.uint64Value
            case 4: speed = value.doubleValue
            case 5: acceleratorPedal = value.doubleValue
            case 6: steeringAngle = value.doubleValue
            case 7: blinkerLeft = value.boolValue
            case 8: blinkerRight = value.boolValue
            case 9: brakeApplied = value.boolValue
            case 10: autopilot = AutopilotState(rawValue: Int(truncatingIfNeeded: value.uint64Value)) ?? .none
            case 11: latitude = value.doubleValue
            case 12: longitude = value.doubleValue
            case 13: heading = value.doubleValue
            case 14: accelerationX = value.doubleValue
            case 15: accelerationY = value.doubleValue
            case 16: accelerationZ = value.doubleValue
            default: recognized -= 1
            }
        }
        guard recognized > 0 else { throw ProtobufError.truncated }
    }

    /// 过滤掉误把其他 SEI 数据当作车辆数据解码的情况。
    var isPlausible: Bool {
        speed.isFinite && speed >= 0 && speed < 120
            && steeringAngle.isFinite && abs(steeringAngle) < 3600
            && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    public var speedKmh: Double { speed * 3.6 }
    /// 统一为 0–100 的百分比。
    public var acceleratorPercent: Double {
        let value = acceleratorPedal <= 1.0 ? acceleratorPedal * 100 : acceleratorPedal
        return min(max(value, 0), 100)
    }
    public var hasLocation: Bool { latitude != 0 || longitude != 0 }
}

/// 带绝对时间的一帧车辆数据。
public struct TelemetryFrame: Hashable, Sendable {
    public var date: Date
    public var metadata: SEIMetadata

    public init(date: Date, metadata: SEIMetadata) {
        self.date = date
        self.metadata = metadata
    }
}

/// 一个事件的完整车辆数据时间序列。
public struct TelemetryTrack: Sendable {
    public let frames: [TelemetryFrame]

    public init(frames: [TelemetryFrame]) {
        self.frames = frames.sorted { $0.date < $1.date }
    }

    public var isEmpty: Bool { frames.isEmpty }

    /// 取离给定时间最近的一帧；超出容差返回 nil。
    public func sample(at date: Date, tolerance: TimeInterval = 1.0) -> TelemetryFrame? {
        guard !frames.isEmpty else { return nil }
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].date < date { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { frames.indices.contains($0) }
        guard let best = candidates.min(by: {
            abs(frames[$0].date.timeIntervalSince(date)) < abs(frames[$1].date.timeIntervalSince(date))
        }) else { return nil }
        return abs(frames[best].date.timeIntervalSince(date)) <= tolerance ? frames[best] : nil
    }

    public func frames(in interval: DateInterval) -> [TelemetryFrame] {
        frames.filter { interval.contains($0.date) }
    }

    /// 降采样，用于绘制图表。
    public func downsampled(maxCount: Int) -> [TelemetryFrame] {
        guard frames.count > maxCount, maxCount > 0 else { return frames }
        let step = Double(frames.count) / Double(maxCount)
        return (0..<maxCount).map { frames[Int(Double($0) * step)] }
    }
}

public enum TelemetryLoader {
    /// 逐个分段读取 SEI，优先使用前视摄像头文件。同步 IO，请在后台调用；所在任务取消时提前返回已读部分。
    public static func load(for event: DashcamEvent, preferring camera: Camera = .front) -> TelemetryTrack {
        var frames: [TelemetryFrame] = []
        let segments = event.segments
        for (index, segment) in segments.enumerated() {
            // 切换事件后取消，避免继续占用 U 盘读取带宽
            if Task.isCancelled { break }
            // 各路摄像头的 SEI 相同；停车录像所有摄像头都没有 SEI，因此只读一路
            guard let url = segment.files[camera] ?? segment.cameras.first.flatMap({ segment.files[$0] }),
                  let clip = try? SEIExtractor.extractClip(contentsOf: url), !clip.samples.isEmpty else { continue }
            let start = SegmentAlignment.start(of: segment, duration: clip.duration ?? 0,
                                               next: segments.indices.contains(index + 1) ? segments[index + 1] : nil)
            frames += clip.samples.map { TelemetryFrame(date: start + $0.time, metadata: $0.metadata) }
        }
        return TelemetryTrack(frames: frames)
    }
}
