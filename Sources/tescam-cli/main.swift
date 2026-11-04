import Foundation
import TeslaCamKit

let usage = """
用法：
  tescam scan <目录>                                列出事件
  tescam telemetry <视频.mp4>                       以 CSV 输出 SEI 车辆数据
  tescam risks <目录> [--event N]                   识别风险事件点
  tescam export <目录> [选项]                        导出带水印视频
  tescam batch <目录> --event N [--before 10] [--after 5] --out-dir <目录>
                                                    批量导出该事件所有风险片段

export 选项：
  --event N            事件序号（见 scan，默认 0）
  --offset 秒           相对事件开始的起点（默认 0）
  --start "yyyy-MM-dd HH:mm:ss"  绝对起点
  --duration 秒         时长（默认到事件结束）
  --layout single|sideBySide|pictureInPicture|grid|teslaStyle（默认 grid）
  --cameras front,back,left_repeater,right_repeater,left_pillar,right_pillar
  --quality p720|p1080|p1440|original（默认 p1080）
  --hevc               使用 HEVC 编码
  --text "文字"         自定义水印
  --no-telemetry       不叠加车辆数据
  --no-manifest        不生成证据清单
  --out 文件.mp4
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: [String]) {
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if ["hevc", "no-telemetry", "no-manifest"].contains(key) {
                    flags.insert(key)
                } else if let value = iterator.next() {
                    options[key] = value
                }
            } else {
                positional.append(arg)
            }
        }
    }

    func double(_ key: String) -> Double? { options[key].flatMap(Double.init) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let displayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func loadEvent(_ args: Arguments) throws -> DashcamEvent {
    guard let path = args.positional.dropFirst().first else { fail(usage) }
    let library = try TeslaCamScanner().scan(URL(fileURLWithPath: path))
    let index = Int(args.options["event"] ?? "0") ?? 0
    guard library.events.indices.contains(index) else { fail("事件序号超出范围（共 \(library.events.count) 个）") }
    return library.events[index]
}

@Sendable func printProgress(_ fraction: Double) {
    FileHandle.standardError.write(Data(String(format: "\r导出中 %5.1f%%", fraction * 100).utf8))
}

let args = Arguments(Array(CommandLine.arguments.dropFirst()))
do {
    switch args.positional.first {
    case "scan":
        guard let path = args.positional.dropFirst().first else { fail(usage) }
        let library = try TeslaCamScanner().scan(URL(fileURLWithPath: path))
        for (index, event) in library.events.enumerated() {
            let cameras = event.cameras.map(\.rawValue).joined(separator: ",")
            print("[\(index)] \(event.kind.displayName)  \(displayFormatter.string(from: event.startDate))  "
                + "\(event.segments.count) 段  \(event.title)  [\(cameras)]")
        }

    case "telemetry":
        guard let path = args.positional.dropFirst().first else { fail(usage) }
        let samples = try SEIExtractor.extract(contentsOf: URL(fileURLWithPath: path))
        print("time,frame,speed_kmh,gear,brake,accelerator,steering,blinker_left,blinker_right,autopilot,lat,lon,heading,ax,ay,az")
        for s in samples {
            let m = s.metadata
            print(String(format: "%.3f,%llu,%.2f,%@,%d,%.1f,%.1f,%d,%d,%@,%.6f,%.6f,%.1f,%.2f,%.2f,%.2f",
                         s.time, m.frameSequence, m.speedKmh, m.gear.symbol, m.brakeApplied ? 1 : 0,
                         m.acceleratorPercent, m.steeringAngle, m.blinkerLeft ? 1 : 0, m.blinkerRight ? 1 : 0,
                         m.autopilot.displayName, m.latitude, m.longitude, m.heading,
                         m.accelerationX, m.accelerationY, m.accelerationZ))
        }
        if samples.isEmpty { FileHandle.standardError.write(Data("未找到 SEI 车辆数据（需要较新固件录制的视频）\n".utf8)) }

    case "risks":
        let event = try loadEvent(args)
        let telemetry = TelemetryLoader.load(for: event)
        print("车辆数据帧数：\(telemetry.frames.count)")
        for point in RiskDetector().detect(event: event, telemetry: telemetry) {
            print("\(displayFormatter.string(from: point.date))  \(point.kind.displayName)  "
                + String(format: "严重度 %.2f  ", point.severity) + point.summary)
        }

    case "export":
        let event = try loadEvent(args)
        let full = await EventTimeline.resolveInterval(for: event)
        var start = full.start + (args.double("offset") ?? 0)
        if let text = args.options["start"] {
            guard let date = displayFormatter.date(from: text) else { fail("无法解析 --start") }
            start = date
        }
        let end = args.double("duration").map { min(start + $0, full.end) } ?? full.end
        guard end > start else { fail("时间范围为空") }

        let layout = args.options["layout"].flatMap(VideoLayout.init(rawValue:)) ?? .grid
        var overlay = OverlayOptions()
        overlay.customText = args.options["text"] ?? ""
        let telemetry = args.flags.contains("no-telemetry") ? nil : TelemetryLoader.load(for: event)
        let request = ExportRequest(
            event: event, interval: DateInterval(start: start, end: end), layout: layout,
            cameras: args.options["cameras"].map { $0.split(separator: ",").compactMap { Camera(rawValue: String($0)) } },
            overlay: overlay,
            quality: args.options["quality"].flatMap(ExportQuality.init(rawValue:)) ?? .p1080,
            codec: args.flags.contains("hevc") ? .hevc : .h264,
            telemetry: telemetry)
        let out = URL(fileURLWithPath: args.options["out"] ?? ExportNaming.fileName(start: start, label: event.kind.displayName))
        let result = try await DashcamExporter.export(request, to: out, writeManifest: !args.flags.contains("no-manifest"),
                                                      progress: printProgress)
        print("\n已导出：\(result.videoURL.path)")
        if let manifest = result.manifestURL { print("证据清单：\(manifest.path)") }

    case "batch":
        let event = try loadEvent(args)
        guard let outDir = args.options["out-dir"] else { fail(usage) }
        let full = await EventTimeline.resolveInterval(for: event)
        let telemetry = TelemetryLoader.load(for: event)
        let points = RiskDetector().detect(event: event, telemetry: telemetry)
        guard !points.isEmpty else { fail("该事件没有识别到风险点") }
        var overlay = OverlayOptions()
        overlay.customText = args.options["text"] ?? ""
        let base = ExportRequest(event: event, interval: full, layout: .grid, overlay: overlay, telemetry: telemetry)
        let results = try await DashcamExporter.exportRiskClips(
            points, base: base, eventInterval: full, before: args.double("before") ?? 10, after: args.double("after") ?? 5,
            to: URL(fileURLWithPath: outDir)) { index, fraction in
                FileHandle.standardError.write(Data(String(format: "\r[%d/%d] %5.1f%%", index + 1, points.count, fraction * 100).utf8))
            }
        print("\n已导出 \(results.count) 个片段到 \(outDir)")

    default:
        print(usage)
    }
} catch {
    fail("错误：\(error.localizedDescription)")
}
