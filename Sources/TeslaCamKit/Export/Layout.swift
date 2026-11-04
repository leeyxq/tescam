import CoreGraphics
import Foundation

public enum VideoLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    case single
    case sideBySide
    case pictureInPicture
    case grid
    case teslaStyle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .single: "单画面"
        case .sideBySide: "左右并排"
        case .pictureInPicture: "画中画"
        case .grid: "宫格"
        case .teslaStyle: "主视+三联"
        }
    }

    public var cameraCountRange: ClosedRange<Int> {
        switch self {
        case .single: 1...1
        case .sideBySide, .pictureInPicture: 2...2
        case .grid: 1...6
        case .teslaStyle: 4...4
        }
    }

    /// 根据可用摄像头给出默认组合。
    public func defaultCameras(available: [Camera]) -> [Camera] {
        let preferred: [Camera]
        switch self {
        case .single: preferred = [.front]
        case .sideBySide, .pictureInPicture: preferred = [.front, .back]
        case .grid:
            // 有 B 柱摄像头时按车身方位排列：上排 左B柱/前视/右B柱，下排 左后/后视/右后
            preferred = available.contains(.leftPillar) || available.contains(.rightPillar)
                ? [.leftPillar, .front, .rightPillar, .leftRepeater, .back, .rightRepeater]
                : Camera.allCases
        case .teslaStyle: preferred = [.front, .leftRepeater, .back, .rightRepeater]
        }
        var result = preferred.filter(available.contains)
        for camera in available where result.count < cameraCountRange.lowerBound && !result.contains(camera) {
            result.append(camera)
        }
        return Array(result.prefix(cameraCountRange.upperBound))
    }
}

public enum ExportQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case p720, p1080, p1440, original

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .original: "原始分辨率"
        }
    }

    var videoHeight: CGFloat? {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p1440: 1440
        case .original: nil
        }
    }
}

/// 一次合成的画布布局。坐标原点在左上角。
public struct LayoutPlan: Sendable, Hashable {
    public struct Cell: Sendable, Hashable {
        public var camera: Camera
        public var rect: CGRect
    }

    public var canvasSize: CGSize
    public var cells: [Cell]
    /// 时间戳/自定义文字条，位于视频区上方；nil 表示不显示
    public var topBand: CGRect?
    /// 车辆数据条，位于视频区下方；nil 表示不显示
    public var bottomBand: CGRect?

    /// 4K 像素预算，保证 H.264 编码器可用。
    static let maxPixels: CGFloat = 3840 * 2160
    static let maxDimension: CGFloat = 4096

    public static func make(layout: VideoLayout, cameras: [Camera], cellAspect: CGFloat, sourceCellWidth: CGFloat,
                            quality: ExportQuality, topBand: Bool, bottomBand: Bool) -> LayoutPlan {
        let aspect = cellAspect > 0 ? cellAspect : 4.0 / 3.0
        let h = 1 / aspect
        var units: [(Camera, CGRect)] = []
        var unitSize = CGSize(width: 1, height: h)
        // 原始分辨率下“1 个单位”对应的源像素宽度
        var unitSourceWidth = sourceCellWidth

        switch layout {
        case .single:
            units = cameras.prefix(1).map { ($0, CGRect(x: 0, y: 0, width: 1, height: h)) }
        case .sideBySide:
            units = cameras.prefix(2).enumerated().map { ($1, CGRect(x: CGFloat($0), y: 0, width: 1, height: h)) }
            unitSize = CGSize(width: CGFloat(units.count), height: h)
        case .pictureInPicture:
            if let main = cameras.first { units.append((main, CGRect(x: 0, y: 0, width: 1, height: h))) }
            if cameras.count > 1 {
                units.append((cameras[1], CGRect(x: 1 - 0.32 - 0.02, y: 0.02, width: 0.32, height: 0.32 * h)))
            }
        case .grid, .teslaStyle:
            if layout == .teslaStyle && cameras.count >= 4 {
                units.append((cameras[0], CGRect(x: 0, y: 0, width: 3, height: 3 * h)))
                for (index, camera) in cameras[1..<4].enumerated() {
                    units.append((camera, CGRect(x: CGFloat(index), y: 3 * h, width: 1, height: h)))
                }
                unitSize = CGSize(width: 3, height: 4 * h)
                unitSourceWidth = sourceCellWidth / 3
            } else {
                let count = max(cameras.count, 1)
                let columns = count <= 2 ? count : (count <= 4 ? 2 : 3)
                let rows = Int((Double(count) / Double(columns)).rounded(.up))
                for (index, camera) in cameras.enumerated() {
                    let row = index / columns
                    let inRow = min(columns, count - row * columns)
                    let offset = CGFloat(columns - inRow) / 2 // 末行居中
                    units.append((camera, CGRect(x: CGFloat(index % columns) + offset, y: CGFloat(row) * h,
                                                 width: 1, height: h)))
                }
                unitSize = CGSize(width: CGFloat(columns), height: CGFloat(rows) * h)
            }
        }

        var scale: CGFloat
        if let height = quality.videoHeight {
            scale = height / unitSize.height
        } else {
            scale = max(unitSourceWidth, 320)
        }
        let bandRatio: CGFloat = 0.035
        func bandHeight(_ width: CGFloat) -> CGFloat { max(36, (width * bandRatio).rounded()) }
        // 限制最大尺寸与像素数
        for _ in 0..<2 {
            let width = unitSize.width * scale
            let bands = CGFloat((topBand ? 1 : 0) + (bottomBand ? 1 : 0)) * bandHeight(width)
            let height = unitSize.height * scale + bands
            let factor = min(1, maxDimension / width, maxDimension / height, sqrt(maxPixels / (width * height)))
            scale *= factor
        }

        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        let videoWidth = even(unitSize.width * scale)
        let videoHeight = even(unitSize.height * scale)
        let band = even(bandHeight(videoWidth))
        let top: CGFloat = topBand ? band : 0
        let bottom: CGFloat = bottomBand ? band : 0

        let cells = units.map { camera, rect in
            Cell(camera: camera, rect: CGRect(x: (rect.minX * scale).rounded(), y: top + (rect.minY * scale).rounded(),
                                              width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded()))
        }
        return LayoutPlan(
            canvasSize: CGSize(width: videoWidth, height: top + videoHeight + bottom),
            cells: cells,
            topBand: topBand ? CGRect(x: 0, y: 0, width: videoWidth, height: top) : nil,
            bottomBand: bottomBand ? CGRect(x: 0, y: top + videoHeight, width: videoWidth, height: bottom) : nil)
    }
}
