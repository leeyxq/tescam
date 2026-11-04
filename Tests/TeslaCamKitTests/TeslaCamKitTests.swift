import Foundation
import Testing
@testable import TeslaCamKit

@Suite struct FileNameTests {
    @Test func parsesCameraAndDate() throws {
        let parsed = try #require(DashcamFileName.parse("2024-05-01_10-20-30-left_repeater.mp4"))
        #expect(parsed.camera == .leftRepeater)
        #expect(DashcamFileName.string(from: parsed.date) == "2024-05-01_10-20-30")
    }

    @Test func rejectsOtherFiles() {
        #expect(DashcamFileName.parse("thumb.png") == nil)
        #expect(DashcamFileName.parse("2024-05-01_10-20-30-unknown.mp4") == nil)
        #expect(DashcamFileName.parse("event.mp4") == nil)
    }

    @Test func parsesEventJSON() throws {
        let json = #"{"timestamp":"2024-05-01T10:20:30","city":"上海市","street":"三环线","est_lat":"31.2304","est_lon":"121.4737","reason":"sentry_aware_object_detection","camera":"0"}"#
        let info = try #require(EventInfo.parse(Data(json.utf8)))
        #expect(info.city == "上海市")
        #expect(info.street == "三环线")
        #expect(info.latitude == 31.2304)
        #expect(info.reasonDescription == "哨兵：检测到物体靠近")
        #expect(info.timestamp != nil)
    }
}

@Suite struct SegmentAlignmentTests {
    @Test func shiftsOverlongSegmentToMeetNext() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let first = ClipSegment(startDate: t0, files: [:])
        let next = ClipSegment(startDate: t0 + 52, files: [:])
        #expect(SegmentAlignment.start(of: first, duration: 57.7, next: next) == t0 + 52 - 57.7)
        #expect(SegmentAlignment.start(of: first, duration: 59.8, next: ClipSegment(startDate: t0 + 60, files: [:])) == t0)
        #expect(SegmentAlignment.start(of: first, duration: 57.7, next: nil) == t0)
    }
}

@Suite struct ScannerTests {
    @Test func groupsFoldersAndDrives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tescam-\(UUID().uuidString)/TeslaCam")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let recent = root.appendingPathComponent("RecentClips")
        let sentry = root.appendingPathComponent("SentryClips/2024-05-01_10-30-00")
        for dir in [recent, sentry] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // 两次行程：10:00–10:01 与 10:10
        for name in ["2024-05-01_10-00-00", "2024-05-01_10-01-00", "2024-05-01_10-10-00"] {
            for camera in ["front", "back"] {
                FileManager.default.createFile(atPath: recent.appendingPathComponent("\(name)-\(camera).mp4").path, contents: Data())
            }
        }
        FileManager.default.createFile(atPath: sentry.appendingPathComponent("2024-05-01_10-29-00-front.mp4").path, contents: Data())
        try Data(#"{"reason":"sentry_aware_object_detection"}"#.utf8).write(to: sentry.appendingPathComponent("event.json"))

        let library = try TeslaCamScanner().scan(root)
        #expect(library.events(of: .recent).count == 2)
        #expect(library.events(of: .recent).map(\.segments.count).sorted() == [1, 2])
        let sentryEvent = try #require(library.events(of: .sentry).first)
        #expect(sentryEvent.info?.reason == "sentry_aware_object_detection")
    }
}

/// 构造带特斯拉 SEI 的最小 MP4（ftyp + mdat + moov/mvhd）。
enum SyntheticMP4 {
    static func protobuf(speed: Float, brake: Bool, steering: Float, frame: UInt64) -> [UInt8] {
        var bytes: [UInt8] = [0x08, 0x01] // version = 1
        bytes += [0x10, 0x01] // gear = D
        bytes += [0x18] + varint(frame)
        bytes += [0x25] + withUnsafeBytes(of: speed.bitPattern.littleEndian, Array.init)
        bytes += [0x35] + withUnsafeBytes(of: steering.bitPattern.littleEndian, Array.init)
        bytes += [0x48, brake ? 1 : 0]
        bytes += [0x59] + withUnsafeBytes(of: (31.23).bitPattern.littleEndian, Array.init)
        bytes += [0x61] + withUnsafeBytes(of: (121.47).bitPattern.littleEndian, Array.init)
        return bytes
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func seiNAL(_ proto: [UInt8]) -> [UInt8] {
        let payload: [UInt8] = [0x42, 0x42, 0x42, 0x69] + proto
        var rbsp: [UInt8] = [0x06, 0x05, UInt8(payload.count)] + payload + [0x80]
        // 插入防竞争字节
        var escaped: [UInt8] = []
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2 && byte <= 3 { escaped.append(0x03); zeros = 0 }
            escaped.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        rbsp = escaped
        return rbsp
    }

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(UInt32(payload.count + 8)) + Array(type.utf8) + payload
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func make(frames: [(speed: Float, brake: Bool)], fps: UInt32 = 10) -> Data {
        var mdat: [UInt8] = []
        for (index, frame) in frames.enumerated() {
            let sei = seiNAL(protobuf(speed: frame.speed, brake: frame.brake, steering: 0, frame: UInt64(index)))
            mdat += be32(UInt32(sei.count)) + sei
            let slice: [UInt8] = [index == 0 ? 0x65 : 0x41, 0x88, 0x00, 0x11]
            mdat += be32(UInt32(slice.count)) + slice
        }
        var mvhd: [UInt8] = [0, 0, 0, 0] + be32(0) + be32(0) + be32(fps) + be32(UInt32(frames.count))
        mvhd += Array(repeating: 0, count: 80)
        let bytes = box("ftyp", Array("isom".utf8) + be32(0)) + box("mdat", mdat) + box("moov", box("mvhd", mvhd))
        return Data(bytes)
    }
}

@Suite struct SEITests {
    @Test func extractsTelemetryFromMP4() throws {
        let data = SyntheticMP4.make(frames: [(10, false), (12.5, false), (0, true)])
        let samples = try SEIExtractor.extract(mp4: data)
        #expect(samples.count == 3)
        #expect(abs(samples[1].metadata.speed - 12.5) < 0.001)
        #expect(samples[1].metadata.gear == .drive)
        #expect(samples[2].metadata.brakeApplied)
        #expect(abs(samples[0].metadata.latitude - 31.23) < 1e-9)
        #expect(abs(samples[2].time - 0.2) < 1e-6)
    }

    @Test func negativeEnumDoesNotCrash() throws {
        // proto3 负数枚举编码为 10 字节 varint
        let bytes: [UInt8] = [0x50, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x25, 0, 0, 0x20, 0x41]
        let metadata = try SEIMetadata(protobuf: bytes[...])
        #expect(metadata.autopilot == .none)
        #expect(metadata.speed == 10)
    }

    @Test func handlesEmulationPreventionInPayload() throws {
        // speed = 0 → 浮点位全 0，会产生 00 00 序列
        let data = SyntheticMP4.make(frames: [(0, false), (0, false)])
        let samples = try SEIExtractor.extract(mp4: data)
        #expect(samples.count == 2)
        #expect(samples[1].metadata.frameSequence == 1)
    }
}

@Suite struct RiskTests {
    func track(_ speeds: [Double], brakeFrom: Int = .max) -> TelemetryTrack {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return TelemetryTrack(frames: speeds.enumerated().map { index, kmh in
            var m = SEIMetadata()
            m.speed = kmh / 3.6
            m.brakeApplied = index >= brakeFrom
            return TelemetryFrame(date: start + Double(index) * 0.1, metadata: m)
        })
    }

    @Test func detectsHardBraking() {
        // 80 km/h 在 1 秒内降到 40 km/h（约 11 m/s²）
        let speeds = Array(repeating: 80.0, count: 20) + (0..<10).map { 80 - Double($0) * 4 } + Array(repeating: 40.0, count: 20)
        let points = RiskDetector().detect(telemetry: track(speeds, brakeFrom: 20))
        let braking = points.filter { $0.kind == .hardBraking }
        #expect(braking.count == 1)
        #expect(points.allSatisfy { $0.kind != .hardAcceleration })
    }

    @Test func steadyDrivingHasNoRisk() {
        #expect(RiskDetector().detect(telemetry: track(Array(repeating: 60, count: 100))).isEmpty)
    }
}

@Suite struct LayoutTests {
    @Test func gridLayoutFitsBudget() {
        let plan = LayoutPlan.make(layout: .teslaStyle, cameras: [.front, .leftRepeater, .back, .rightRepeater],
                                   cellAspect: 4 / 3, sourceCellWidth: 1280, quality: .original,
                                   topBand: true, bottomBand: true)
        #expect(plan.canvasSize.width * plan.canvasSize.height <= LayoutPlan.maxPixels + 1)
        #expect(Int(plan.canvasSize.width) % 2 == 0 && Int(plan.canvasSize.height) % 2 == 0)
        #expect(plan.cells.count == 4)
    }

    @Test func defaultCamerasRespectAvailability() {
        #expect(VideoLayout.sideBySide.defaultCameras(available: [.front, .leftRepeater]) == [.front, .leftRepeater])
        #expect(VideoLayout.grid.defaultCameras(available: [.back, .front]) == [.front, .back])
        #expect(VideoLayout.grid.defaultCameras(available: Camera.allCases)
                == [.leftPillar, .front, .rightPillar, .leftRepeater, .back, .rightRepeater])
    }
}
