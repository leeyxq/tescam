import Foundation

public enum RiskKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case eventTrigger
    case hardBraking
    case hardAcceleration
    case sharpTurn
    case overspeed
    case autopilotDisengaged

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .eventTrigger: "事件触发点"
        case .hardBraking: "急刹车"
        case .hardAcceleration: "急加速"
        case .sharpTurn: "急转向"
        case .overspeed: "高速行驶"
        case .autopilotDisengaged: "辅助驾驶退出"
        }
    }

    public var symbolName: String {
        switch self {
        case .eventTrigger: "exclamationmark.triangle.fill"
        case .hardBraking: "exclamationmark.octagon.fill"
        case .hardAcceleration: "hare.fill"
        case .sharpTurn: "arrow.triangle.turn.up.right.diamond.fill"
        case .overspeed: "speedometer"
        case .autopilotDisengaged: "steeringwheel"
        }
    }
}

/// 识别出的一个风险时间点。
public struct RiskPoint: Identifiable, Hashable, Sendable {
    public var kind: RiskKind
    public var date: Date
    /// 0–1，越大越严重
    public var severity: Double
    public var summary: String

    public var id: String { "\(kind.rawValue)-\(date.timeIntervalSince1970)" }

    public init(kind: RiskKind, date: Date, severity: Double, summary: String) {
        self.kind = kind
        self.date = date
        self.severity = min(max(severity, 0), 1)
        self.summary = summary
    }
}

/// 基于 SEI 车辆数据和 event.json 识别风险事件点。
public struct RiskDetector: Sendable {
    public struct Configuration: Sendable, Codable, Hashable {
        /// 急刹车减速度阈值 m/s²（约 0.36g）
        public var hardBrakingDeceleration: Double = 3.5
        /// 急加速阈值 m/s²（实测正常驾驶 99% 在 2.2 以内）
        public var hardAcceleration: Double = 3.5
        /// 急转向横向加速度阈值 m/s²
        public var lateralAcceleration: Double = 4.0
        /// 急转向方向盘转速阈值 度/秒
        public var steeringRate: Double = 250
        /// 低于该车速不判断急转向 km/h（避免停车场掉头误报）
        public var minimumTurnSpeedKmh: Double = 30
        /// 高速提醒阈值 km/h
        public var overspeedKmh: Double = 120
        /// 同类事件合并窗口 秒
        public var mergeWindow: TimeInterval = 3
        /// 高速行驶合并窗口 秒（一段高速只提示一次）
        public var overspeedMergeWindow: TimeInterval = 60
        /// 计算变化率的时间窗口（半宽）秒
        public var derivativeHalfWindow: TimeInterval = 0.25

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func detect(event: DashcamEvent, telemetry: TelemetryTrack) -> [RiskPoint] {
        var points: [RiskPoint] = []
        if let trigger = event.triggerDate {
            points.append(RiskPoint(kind: .eventTrigger, date: trigger, severity: event.isEmergency ? 1 : 0.6,
                                    summary: event.info?.reasonDescription ?? "事件触发"))
        }
        points += detect(telemetry: telemetry)
        return points.sorted { $0.date < $1.date }
    }

    public func detect(telemetry: TelemetryTrack) -> [RiskPoint] {
        let frames = telemetry.frames
        guard frames.count > 2 else { return [] }
        let c = configuration
        var candidates: [RiskPoint] = []
        // 实测车身 IMU：ax 为横向、ay 为纵向。新固件不一定写 GPS，横向加速度优先用 IMU
        let hasIMU = frames.contains { $0.metadata.accelerationX != 0 || $0.metadata.accelerationY != 0 }
        var lateralPrefix = [0.0]
        lateralPrefix.reserveCapacity(frames.count + 1)
        for frame in frames { lateralPrefix.append(lateralPrefix[lateralPrefix.count - 1] + frame.metadata.accelerationX) }

        var low = 0
        var high = 0
        for i in frames.indices {
            let date = frames[i].date
            while low < i, frames[low].date < date - c.derivativeHalfWindow { low += 1 }
            while high + 1 < frames.count, frames[high + 1].date <= date + c.derivativeHalfWindow { high += 1 }
            let dt = frames[high].date.timeIntervalSince(frames[low].date)
            let current = frames[i].metadata
            let speedKmh = current.speedKmh

            if dt >= 0.2 {
                let before = frames[low].metadata
                let after = frames[high].metadata
                let accel = (after.speed - before.speed) / dt
                if accel <= -c.hardBrakingDeceleration {
                    let severity = 0.3 + 0.7 * (-accel - c.hardBrakingDeceleration) / max(8 - c.hardBrakingDeceleration, 0.1)
                    let brake = current.brakeApplied ? "，踩下刹车" : ""
                    candidates.append(RiskPoint(kind: .hardBraking, date: date, severity: severity,
                                                summary: String(format: "减速度 %.2fg，车速 %.0f km/h%@", -accel / 9.81, speedKmh, brake)))
                } else if accel >= c.hardAcceleration {
                    let severity = 0.3 + 0.7 * (accel - c.hardAcceleration) / max(7 - c.hardAcceleration, 0.1)
                    candidates.append(RiskPoint(kind: .hardAcceleration, date: date, severity: severity,
                                                summary: String(format: "加速度 %.2fg，车速 %.0f km/h", accel / 9.81, speedKmh)))
                }

                if speedKmh >= c.minimumTurnSpeedKmh {
                    let steeringRate = abs(after.steeringAngle - before.steeringAngle) / dt
                    var lateral = 0.0
                    if hasIMU {
                        lateral = abs((lateralPrefix[high + 1] - lateralPrefix[low]) / Double(high - low + 1))
                    } else if before.hasLocation && after.hasLocation {
                        var delta = after.heading - before.heading
                        delta = (delta + 540).truncatingRemainder(dividingBy: 360) - 180
                        lateral = abs(current.speed * delta * .pi / 180 / dt)
                    }
                    if lateral >= c.lateralAcceleration || steeringRate >= c.steeringRate {
                        let severity = max(
                            0.3 + 0.7 * (lateral - c.lateralAcceleration) / max(8 - c.lateralAcceleration, 0.1),
                            0.3 + 0.7 * (steeringRate - c.steeringRate) / max(720 - c.steeringRate, 1))
                        candidates.append(RiskPoint(kind: .sharpTurn, date: date, severity: severity,
                                                    summary: String(format: "方向盘转速 %.0f°/s，横向 %.2fg，车速 %.0f km/h",
                                                                    steeringRate, lateral / 9.81, speedKmh)))
                    }
                }
            }

            if speedKmh >= c.overspeedKmh {
                candidates.append(RiskPoint(kind: .overspeed, date: date,
                                            severity: 0.3 + 0.7 * (speedKmh - c.overspeedKmh) / 60,
                                            summary: String(format: "车速 %.0f km/h", speedKmh)))
            }

            if i > 0, frames[i - 1].metadata.autopilot != .none, current.autopilot == .none, speedKmh > 5 {
                candidates.append(RiskPoint(kind: .autopilotDisengaged, date: date, severity: 0.5,
                                            summary: "\(frames[i - 1].metadata.autopilot.displayName) 退出，车速 \(Int(speedKmh)) km/h"))
            }
        }
        return merge(candidates)
    }

    /// 同类、时间相近的候选点合并为一个，保留最严重的那一帧。
    func merge(_ candidates: [RiskPoint]) -> [RiskPoint] {
        var merged: [RiskPoint] = []
        var lastDate: [RiskKind: Date] = [:]
        var openIndex: [RiskKind: Int] = [:]
        for point in candidates.sorted(by: { $0.date < $1.date }) {
            if let last = lastDate[point.kind], let index = openIndex[point.kind],
               point.date.timeIntervalSince(last)
                <= (point.kind == .overspeed ? configuration.overspeedMergeWindow : configuration.mergeWindow) {
                if point.severity > merged[index].severity { merged[index] = point }
            } else {
                openIndex[point.kind] = merged.count
                merged.append(point)
            }
            lastDate[point.kind] = point.date
        }
        return merged
    }
}
