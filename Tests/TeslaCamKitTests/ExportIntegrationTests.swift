import Foundation
import Testing
@testable import TeslaCamKit

/// 端到端导出测试。需要先用 Scripts/make-sample-teslacam.sh 生成样例目录，
/// 并设置环境变量 TESCAM_SAMPLE=<样例目录>，TESCAM_OUT=<输出目录>。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TESCAM_SAMPLE"] != nil))
struct ExportIntegrationTests {
    @Test func exportsWithSyntheticTelemetry() async throws {
        let env = ProcessInfo.processInfo.environment
        let library = try TeslaCamScanner().scan(URL(fileURLWithPath: env["TESCAM_SAMPLE"]!))
        let event = try #require(library.events(of: .saved).first)
        let interval = await EventTimeline.resolveInterval(for: event)

        // 模拟：60 km/h 匀速 → 第 5 秒急刹，同时左转向灯、辅助驾驶退出
        let frames = stride(from: 0.0, to: interval.duration, by: 1.0 / 36).map { t -> TelemetryFrame in
            var m = SEIMetadata()
            m.gear = .drive
            m.speed = (t < 5 ? 60 : max(60 - (t - 5) * 40, 10)) / 3.6
            m.brakeApplied = t >= 5
            m.acceleratorPedal = t < 5 ? 0.3 : 0
            m.steeringAngle = sin(t) * 15
            m.blinkerLeft = Int(t * 2) % 2 == 0
            m.autopilot = t < 5 ? .autosteer : .none
            m.latitude = 31.2304
            m.longitude = 121.4737
            m.heading = 92
            return TelemetryFrame(date: interval.start + t, metadata: m)
        }
        let telemetry = TelemetryTrack(frames: frames)
        let risks = RiskDetector().detect(event: event, telemetry: telemetry)
        #expect(risks.contains { $0.kind == .hardBraking })
        #expect(risks.contains { $0.kind == .autopilotDisengaged })
        #expect(risks.contains { $0.kind == .eventTrigger })

        var overlay = OverlayOptions()
        overlay.customText = "交通违法举报证据"
        let request = ExportRequest(event: event, interval: interval, layout: .grid, overlay: overlay,
                                    quality: .p1080, telemetry: telemetry)
        let out = URL(fileURLWithPath: env["TESCAM_OUT"] ?? NSTemporaryDirectory()).appendingPathComponent("telemetry.mp4")
        let result = try await DashcamExporter.export(request, to: out)
        #expect(FileManager.default.fileExists(atPath: result.videoURL.path))

        let batchDir = out.deletingLastPathComponent().appendingPathComponent("batch")
        let clips = try await DashcamExporter.exportRiskClips(risks, base: request, eventInterval: interval,
                                                              before: 2, after: 2, to: batchDir)
        #expect(clips.count == risks.count)
    }
}

/// 用真实特斯拉视频校验：sample table 快速路径与全量 mdat 扫描结果一致。
/// TESCAM_REAL_CLIP=<某个行驶中录制的 front.mp4>
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TESCAM_REAL_CLIP"] != nil))
struct RealClipTests {
    @Test func sampleTableMatchesFullScan() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TESCAM_REAL_CLIP"]!)
        let fast = try #require(try SEIExtractor.extractUsingSampleTable(url))
        let full = try SEIExtractor.extract(mp4: Data(contentsOf: url, options: .alwaysMapped))
        #expect(!fast.isEmpty)
        #expect(fast.count == full.count)
        #expect(fast.map(\.metadata) == full.map(\.metadata))
        // 全量扫描按平均帧间隔估算时间，变帧率片段（停车→起步）会偏；快速路径用 stts 中的真实帧时间
        #expect(zip(fast, fast.dropFirst()).allSatisfy { $0.time < $1.time })
    }
}
