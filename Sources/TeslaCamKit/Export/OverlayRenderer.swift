import CoreGraphics
import CoreImage
import CoreText
import Foundation

public enum SpeedUnit: String, CaseIterable, Codable, Sendable, Identifiable {
    case kmh, mph

    public var id: String { rawValue }
    public var symbol: String { self == .kmh ? "km/h" : "mph" }

    func convert(metersPerSecond: Double) -> Double {
        self == .kmh ? metersPerSecond * 3.6 : metersPerSecond * 2.236936
    }
}

/// 水印/数据叠加选项。
public struct OverlayOptions: Codable, Hashable, Sendable {
    public var showTimestamp = true
    public var showCameraLabels = true
    public var showEventInfo = true
    public var showSpeed = true
    public var showGear = true
    public var showPedals = true
    public var showSteering = true
    public var showBlinkers = true
    public var showAutopilot = true
    public var showLocation = true
    public var showBrand = true
    /// 自定义水印文字，例如“交通违法举报证据”
    public var customText = ""
    public var speedUnit: SpeedUnit = .kmh

    public init() {}

    var showsTelemetry: Bool {
        showSpeed || showGear || showPedals || showSteering || showBlinkers || showAutopilot || showLocation
    }

    var showsTopBand: Bool {
        showTimestamp || showEventInfo || showBrand || !customText.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 逐帧渲染时间戳与车辆数据条。线程安全：只读状态 + 加锁缓存。
final class OverlayRenderer: @unchecked Sendable {
    let plan: LayoutPlan
    let options: OverlayOptions
    let telemetry: TelemetryTrack?
    let startDate: Date
    let eventLabel: String

    /// iOS 上没有 `CGColor.white`
    private static let white = CGColor(gray: 1, alpha: 1)

    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var topCache: (second: Int, image: CIImage)?
    private lazy var labelsImage: CIImage? = renderCameraLabels()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(plan: LayoutPlan, options: OverlayOptions, telemetry: TelemetryTrack?, startDate: Date, eventLabel: String) {
        self.plan = plan
        self.options = options
        self.telemetry = telemetry
        self.startDate = startDate
        self.eventLabel = eventLabel
    }

    /// 返回 Core Image 坐标系（左下角原点）下的整幅叠加层。
    func overlay(atSeconds seconds: Double) -> CIImage? {
        let date = startDate + seconds
        var layers: [CIImage] = []
        lock.lock()
        if let labels = labelsImage { layers.append(labels) }
        if let band = plan.topBand {
            let second = Int(floor(date.timeIntervalSince1970))
            if let cache = topCache, cache.second == second {
                layers.append(cache.image)
            } else if let image = renderTopBand(band, date: date) {
                topCache = (second, image)
                layers.append(image)
            }
        }
        lock.unlock()
        if let band = plan.bottomBand, let image = renderBottomBand(band, frame: telemetry?.sample(at: date, tolerance: 0.5)) {
            layers.append(image)
        }
        return layers.reduce(nil as CIImage?) { result, layer in result.map { layer.composited(over: $0) } ?? layer }
    }

    // MARK: - Bands

    private func renderTopBand(_ band: CGRect, date: Date) -> CIImage? {
        draw(band) { ctx, size in
            ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            let fontSize = size.height * 0.5
            let padding = size.height * 0.35
            let baseline = (size.height - fontSize) / 2 + fontSize * 0.18
            var x = padding
            if options.showTimestamp {
                x += drawText(ctx, Self.timestampFormatter.string(from: date), size: fontSize, weight: .bold,
                              color: Self.white, at: CGPoint(x: x, y: baseline)) + padding
            }
            if options.showEventInfo, !eventLabel.isEmpty {
                drawText(ctx, eventLabel, size: fontSize * 0.8, color: CGColor(gray: 0.75, alpha: 1),
                         at: CGPoint(x: x, y: baseline))
            }
            var right = size.width - padding
            if options.showBrand {
                right -= drawText(ctx, "TesCam", size: fontSize * 0.8, weight: .bold,
                                  color: CGColor(red: 0.89, green: 0.1, blue: 0.13, alpha: 1),
                                  at: CGPoint(x: right, y: baseline), alignRight: true) + padding
            }
            let custom = options.customText.trimmingCharacters(in: .whitespaces)
            if !custom.isEmpty {
                drawText(ctx, custom, size: fontSize * 0.85, weight: .bold,
                         color: CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1),
                         at: CGPoint(x: right, y: baseline), alignRight: true)
            }
        }
    }

    private func renderBottomBand(_ band: CGRect, frame: TelemetryFrame?) -> CIImage? {
        draw(band) { ctx, size in
            ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            let fontSize = size.height * 0.46
            let padding = size.height * 0.35
            let baseline = (size.height - fontSize) / 2 + fontSize * 0.18
            let dim = CGColor(gray: 0.45, alpha: 1)
            guard let m = frame?.metadata else {
                drawText(ctx, "无车辆数据", size: fontSize, color: dim, at: CGPoint(x: padding, y: baseline))
                return
            }
            var x = padding
            func gap() { x += padding }

            if options.showSpeed {
                let speed = options.speedUnit.convert(metersPerSecond: m.speed)
                x += drawText(ctx, String(format: "%3.0f", speed), size: fontSize * 1.25, weight: .heavy,
                              color: Self.white, at: CGPoint(x: x, y: baseline - fontSize * 0.08), monospaced: true)
                x += fontSize * 0.2
                x += drawText(ctx, options.speedUnit.symbol, size: fontSize * 0.7, color: CGColor(gray: 0.7, alpha: 1),
                              at: CGPoint(x: x, y: baseline))
                gap()
            }
            if options.showGear {
                x += drawPill(ctx, m.gear.symbol, x: x, size: size, fontSize: fontSize,
                              fill: CGColor(gray: 0.25, alpha: 1), text: Self.white)
                gap()
            }
            if options.showPedals {
                x += drawPill(ctx, "刹车", x: x, size: size, fontSize: fontSize,
                              fill: m.brakeApplied ? CGColor(red: 0.9, green: 0.12, blue: 0.12, alpha: 1) : CGColor(gray: 0.18, alpha: 1),
                              text: m.brakeApplied ? Self.white : dim)
                gap()
                x += drawText(ctx, "油门", size: fontSize * 0.8, color: CGColor(gray: 0.7, alpha: 1), at: CGPoint(x: x, y: baseline))
                x += fontSize * 0.3
                let barWidth = fontSize * 3
                let barRect = CGRect(x: x, y: size.height * 0.38, width: barWidth, height: size.height * 0.24)
                ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
                ctx.fill(barRect)
                ctx.setFillColor(CGColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1))
                ctx.fill(CGRect(x: barRect.minX, y: barRect.minY,
                                width: barWidth * m.acceleratorPercent / 100, height: barRect.height))
                x += barWidth + fontSize * 0.3
                x += drawText(ctx, String(format: "%3.0f%%", m.acceleratorPercent), size: fontSize * 0.8,
                              color: Self.white, at: CGPoint(x: x, y: baseline), monospaced: true)
                gap()
            }
            if options.showSteering {
                x += drawText(ctx, String(format: "方向盘 %+6.1f°", m.steeringAngle), size: fontSize * 0.8,
                              color: Self.white, at: CGPoint(x: x, y: baseline), monospaced: true)
                gap()
            }
            if options.showBlinkers {
                let on = CGColor(red: 0.2, green: 0.85, blue: 0.3, alpha: 1)
                x += drawText(ctx, "◀", size: fontSize, color: m.blinkerLeft ? on : CGColor(gray: 0.25, alpha: 1),
                              at: CGPoint(x: x, y: baseline))
                x += fontSize * 0.3
                x += drawText(ctx, "▶", size: fontSize, color: m.blinkerRight ? on : CGColor(gray: 0.25, alpha: 1),
                              at: CGPoint(x: x, y: baseline))
                gap()
            }
            if options.showAutopilot {
                let active = m.autopilot != .none
                x += drawText(ctx, m.autopilot.displayName, size: fontSize * 0.8, weight: active ? .bold : .regular,
                              color: active ? CGColor(red: 0.25, green: 0.6, blue: 1, alpha: 1) : dim,
                              at: CGPoint(x: x, y: baseline))
                gap()
            }
            if options.showLocation, m.hasLocation {
                let text = String(format: "%.6f, %.6f  %03.0f°", m.latitude, m.longitude, m.heading)
                if x + measure(text, size: fontSize * 0.7, monospaced: true) < size.width - padding {
                    drawText(ctx, text, size: fontSize * 0.7, color: CGColor(gray: 0.7, alpha: 1),
                             at: CGPoint(x: size.width - padding, y: baseline), alignRight: true, monospaced: true)
                }
            }
        }
    }

    private func renderCameraLabels() -> CIImage? {
        guard options.showCameraLabels, plan.cells.count > 1 || plan.cells.first.map({ $0.camera != .front }) == true
        else { return nil }
        let canvas = CGRect(origin: .zero, size: plan.canvasSize)
        return draw(canvas) { ctx, size in
            for cell in plan.cells {
                let fontSize = max(14, cell.rect.height * 0.035)
                let text = cell.camera.displayName
                let width = measure(text, size: fontSize) + fontSize
                let height = fontSize * 1.5
                // CG 坐标系：左下角原点
                let rect = CGRect(x: cell.rect.minX + fontSize * 0.5,
                                  y: size.height - cell.rect.minY - fontSize * 0.5 - height,
                                  width: width, height: height)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: height * 0.25, cornerHeight: height * 0.25, transform: nil))
                ctx.fillPath()
                drawText(ctx, text, size: fontSize, weight: .bold, color: Self.white,
                         at: CGPoint(x: rect.minX + fontSize * 0.5, y: rect.minY + fontSize * 0.42))
            }
        }
    }

    // MARK: - Drawing helpers

    /// 在 band（画布坐标，左上原点）大小的位图中绘制，并放到 CI 坐标中的对应位置。
    private func draw(_ band: CGRect, _ body: (CGContext, CGSize) -> Void) -> CIImage? {
        let width = Int(band.width), height = Int(band.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        body(ctx, CGSize(width: width, height: height))
        guard let image = ctx.makeImage() else { return nil }
        let y = plan.canvasSize.height - band.maxY
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: band.minX, y: y))
    }

    private enum Weight { case regular, bold, heavy }

    private func font(size: CGFloat, weight: Weight, monospaced: Bool) -> CTFont {
        let type: CTFontUIFontType = weight == .regular ? .system : .emphasizedSystem
        var font = CTFontCreateUIFontForLanguage(type, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        if monospaced {
            let feature: [CFString: Any] = [
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ]
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(font), [kCTFontFeatureSettingsAttribute: [feature]] as CFDictionary)
            font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        return font
    }

    private func line(_ text: String, size: CGFloat, weight: Weight, color: CGColor, monospaced: Bool) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, weight: weight, monospaced: monospaced),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private func measure(_ text: String, size: CGFloat, weight: Weight = .regular, monospaced: Bool = false) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, size: size, weight: weight, color: Self.white, monospaced: monospaced), nil, nil, nil))
    }

    /// 返回绘制宽度。`point.y` 为基线。
    @discardableResult
    private func drawText(_ ctx: CGContext, _ text: String, size: CGFloat, weight: Weight = .regular, color: CGColor,
                          at point: CGPoint, alignRight: Bool = false, monospaced: Bool = false) -> CGFloat {
        let line = line(text, size: size, weight: weight, color: color, monospaced: monospaced)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: alignRight ? point.x - width : point.x, y: point.y)
        CTLineDraw(line, ctx)
        return width
    }

    private func drawPill(_ ctx: CGContext, _ text: String, x: CGFloat, size: CGSize, fontSize: CGFloat,
                          fill: CGColor, text textColor: CGColor) -> CGFloat {
        let textSize = fontSize * 0.8
        let width = measure(text, size: textSize, weight: .bold) + fontSize * 0.8
        let height = size.height * 0.62
        let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
        ctx.setFillColor(fill)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: height * 0.25, cornerHeight: height * 0.25, transform: nil))
        ctx.fillPath()
        drawText(ctx, text, size: textSize, weight: .bold, color: textColor,
                 at: CGPoint(x: x + fontSize * 0.4, y: rect.midY - textSize * 0.35))
        return width
    }
}
