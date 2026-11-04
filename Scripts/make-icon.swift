// 生成 App 图标：swift Scripts/make-icon.swift <输出目录>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func render(size: CGFloat, inset: CGFloat, file: String) {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let body = rect.insetBy(dx: inset, dy: inset)
        let radius = inset == 0 ? 0 : body.width * 0.225
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSGradient(colors: [NSColor(red: 0.89, green: 0.13, blue: 0.16, alpha: 1),
                            NSColor(red: 0.55, green: 0.04, blue: 0.08, alpha: 1)])!.draw(in: path, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.46, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: body.midX - s.width / 2, y: body.midY - s.height / 2 + body.height * 0.06,
                                   width: s.width, height: s.height))
        }
        let text = NSAttributedString(string: "TesCam", attributes: [
            .font: NSFont.systemFont(ofSize: body.width * 0.13, weight: .heavy), .foregroundColor: NSColor.white])
        let t = text.size()
        text.draw(at: NSPoint(x: body.midX - t.width / 2, y: body.minY + body.height * 0.14))
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(file))
}
// iOS 图标由系统加圆角，需铺满且不透明；macOS 图标按设计规范留边
render(size: 1024, inset: 0, file: "icon-ios.png")
render(size: 512, inset: 50, file: "icon-mac-512.png")
render(size: 1024, inset: 100, file: "icon-mac-1024.png")
