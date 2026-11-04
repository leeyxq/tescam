import Foundation

/// 特斯拉车载摄像头位置。原始值与 U 盘文件名后缀一致。
public enum Camera: String, CaseIterable, Codable, Sendable, Identifiable, Comparable {
    case front
    case back
    case leftRepeater = "left_repeater"
    case rightRepeater = "right_repeater"
    case leftPillar = "left_pillar"
    case rightPillar = "right_pillar"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .front: "前视"
        case .back: "后视"
        case .leftRepeater: "左侧后方"
        case .rightRepeater: "右侧后方"
        case .leftPillar: "左B柱"
        case .rightPillar: "右B柱"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (lhs: Camera, rhs: Camera) -> Bool { lhs.order < rhs.order }
}

/// TeslaCam 目录下的记录类型。
public enum ClipKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case recent
    case saved
    case sentry
    case other

    public var id: String { rawValue }

    public var folderName: String? {
        switch self {
        case .recent: "RecentClips"
        case .saved: "SavedClips"
        case .sentry: "SentryClips"
        case .other: nil
        }
    }

    public var displayName: String {
        switch self {
        case .recent: "行车记录"
        case .saved: "手动保存"
        case .sentry: "哨兵事件"
        case .other: "其他"
        }
    }

    public var symbolName: String {
        switch self {
        case .recent: "car"
        case .saved: "bookmark"
        case .sentry: "shield.lefthalf.filled"
        case .other: "folder"
        }
    }

    /// 根据路径中出现的 RecentClips / SavedClips / SentryClips 推断类型。
    public static func infer(from directory: URL) -> ClipKind {
        for component in directory.pathComponents.reversed() {
            for kind in allCases where kind.folderName?.caseInsensitiveCompare(component) == .orderedSame {
                return kind
            }
        }
        return .other
    }
}

/// 同一起始时间（约 1 分钟）的一组多摄像头视频文件。
public struct ClipSegment: Identifiable, Hashable, Sendable {
    /// 特斯拉单个分段的标称时长，实际时长以视频文件为准。
    public static let nominalDuration: TimeInterval = 60

    public let startDate: Date
    public var files: [Camera: URL]

    public var id: Date { startDate }
    public var cameras: [Camera] { files.keys.sorted() }

    public init(startDate: Date, files: [Camera: URL]) {
        self.startDate = startDate
        self.files = files
    }
}

public enum SegmentAlignment {
    /// 分段的实际起始时间。
    ///
    /// 车机偶尔（停车→起步、AEB 触发保存等）写出的视频时长会超过与下一段文件名的间隔，
    /// 而 SEI 帧序号表明两段首尾相接，此时以下一段起点为准，把本段整体前移。
    public static func start(of segment: ClipSegment, duration: TimeInterval, next: ClipSegment?) -> Date {
        guard let next, duration > 0, segment.startDate + duration > next.startDate + 0.5 else { return segment.startDate }
        return next.startDate - duration
    }
}

/// 解析 `2024-05-01_10-20-30-front.mp4` 形式的文件名。
public enum DashcamFileName {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // 车机按本地时间命名文件，不带时区，按当前时区解析。
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    public static func parse(_ fileName: String) -> (date: Date, camera: Camera)? {
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".mp4") else { return nil }
        let stem = lower.dropLast(4)
        guard stem.count > 20 else { return nil }
        let datePart = stem.prefix(19)
        let separator = stem[stem.index(stem.startIndex, offsetBy: 19)]
        let cameraPart = stem.dropFirst(20)
        guard separator == "-",
              let camera = Camera(rawValue: String(cameraPart)),
              let date = parseDate(String(datePart))
        else { return nil }
        return (date, camera)
    }

    public static func parseDate(_ string: String) -> Date? {
        formatter.date(from: string)
    }

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

/// Saved/Sentry 事件目录中的 event.json。
public struct EventInfo: Hashable, Sendable, Codable {
    public var timestamp: Date?
    public var city: String?
    public var street: String?
    public var latitude: Double?
    public var longitude: Double?
    public var reason: String?
    public var camera: String?

    public init(timestamp: Date? = nil, city: String? = nil, street: String? = nil, latitude: Double? = nil,
                longitude: Double? = nil, reason: String? = nil, camera: String? = nil) {
        self.timestamp = timestamp
        self.city = city
        self.street = street
        self.latitude = latitude
        self.longitude = longitude
        self.reason = reason
        self.camera = camera
    }

    public static func load(from url: URL) -> EventInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// event.json 中数值常以字符串保存，这里宽松解析。
    public static func parse(_ data: Data) -> EventInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            switch object[key] {
            case let value as String: value.isEmpty ? nil : value
            case let value as NSNumber: value.stringValue
            default: nil
            }
        }
        func double(_ key: String) -> Double? { string(key).flatMap(Double.init) }

        var info = EventInfo()
        if let raw = string("timestamp") {
            info.timestamp = timestampFormatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }
        info.city = string("city")
        info.street = string("street")
        info.latitude = double("est_lat")
        info.longitude = double("est_lon")
        info.reason = string("reason")
        info.camera = string("camera")
        return info
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// 是否为碰撞、紧急制动、车身震动等紧急事件。
    public var isEmergency: Bool {
        guard let reason = reason?.lowercased() else { return false }
        return ["collision", "crash", "emergency", "accel", "airbag"].contains { reason.contains($0) }
    }

    public var reasonDescription: String {
        guard let reason, !reason.isEmpty else { return "未知原因" }
        let lower = reason.lowercased()
        switch lower {
        case "sentry_aware_object_detection": return "哨兵：检测到物体靠近"
        case "user_interaction_dashcam_icon_tapped": return "手动保存（点击行车记录仪图标）"
        case "user_interaction_dashcam_panel_save": return "手动保存（行车记录仪面板）"
        case "user_interaction_dashcam_launcher_action_tapped": return "手动保存（快捷启动）"
        case "user_interaction_honk": return "鸣笛自动保存"
        case "vehicle_auto_emergency_braking": return "自动紧急制动（AEB）"
        case "sentry_locked_handle_pulled": return "哨兵：锁车状态下有人拉车门把手"
        default: break
        }
        if lower.contains("collision") || lower.contains("crash") || lower.contains("airbag") { return "碰撞检测自动保存" }
        if lower.contains("emergency") { return "紧急制动自动保存" }
        if lower.hasPrefix("sentry") && lower.contains("accel") { return "哨兵：车身震动/碰撞" }
        if lower.hasPrefix("sentry") { return "哨兵事件" }
        if lower.hasPrefix("user_interaction") { return "手动保存" }
        return reason
    }
}

/// 一个可浏览/导出的事件：Saved/Sentry 的一个目录，或 RecentClips 中一段连续行驶。
public struct DashcamEvent: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: ClipKind
    public let directory: URL
    /// 按时间升序，非空。
    public let segments: [ClipSegment]
    public let info: EventInfo?
    public let thumbnailURL: URL?

    public init(id: String, kind: ClipKind, directory: URL, segments: [ClipSegment],
                info: EventInfo?, thumbnailURL: URL?) {
        precondition(!segments.isEmpty, "DashcamEvent requires at least one segment")
        self.id = id
        self.kind = kind
        self.directory = directory
        self.segments = segments.sorted { $0.startDate < $1.startDate }
        self.info = info
        self.thumbnailURL = thumbnailURL
    }

    public var startDate: Date { segments[0].startDate }
    /// 按标称分段时长估算的结束时间；精确值见 `EventTimeline.resolveInterval`。
    public var estimatedEndDate: Date { segments[segments.count - 1].startDate + ClipSegment.nominalDuration }
    public var triggerDate: Date? { info?.timestamp }
    public var isEmergency: Bool { info?.isEmergency ?? false }

    public var cameras: [Camera] {
        Array(Set(segments.flatMap { $0.files.keys })).sorted()
    }

    public var title: String {
        if let info { return info.reasonDescription }
        return kind == .recent ? "行车记录 · \(segments.count) 段" : "\(kind.displayName) · \(segments.count) 段"
    }

    public var location: String? {
        let parts = [info?.city, info?.street].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public var subtitle: String {
        [location, directory.lastPathComponent].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 一次扫描得到的全部事件。
public struct TeslaCamLibrary: Sendable {
    public let root: URL
    /// 按开始时间倒序。
    public let events: [DashcamEvent]

    public init(root: URL, events: [DashcamEvent]) {
        self.root = root
        self.events = events.sorted { $0.startDate > $1.startDate }
    }

    public func events(of kind: ClipKind) -> [DashcamEvent] {
        events.filter { $0.kind == kind }
    }
}
