import AVFoundation
import CryptoKit
import Foundation

public enum ExportError: LocalizedError {
    case sessionUnavailable

    public var errorDescription: String? { "当前设备不支持该导出设置" }
}

public struct ExportResult: Sendable {
    public var videoURL: URL
    public var manifestURL: URL?
    public var interval: DateInterval
}

/// 证据清单：记录源文件哈希与导出参数，便于举报或纠纷时说明视频来源与完整性。
public struct EvidenceManifest: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public var camera: String
        public var fileName: String
        public var segmentStart: Date
        public var byteCount: Int64
        public var sha256: String
    }

    public var generator = "TesCam"
    public var exportedAt: Date
    public var outputFile: String
    public var outputSHA256: String
    public var intervalStart: Date
    public var intervalEnd: Date
    public var eventKind: String
    public var eventReason: String?
    public var city: String?
    public var street: String?
    public var latitude: Double?
    public var longitude: Double?
    public var layout: String
    public var cameras: [String]
    public var sources: [Source]
}

public enum DashcamExporter {
    public static func export(_ request: ExportRequest, to url: URL, writeManifest: Bool = true,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> ExportResult {
        let built = try await CompositionBuilder.build(request)
        let preset = request.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.asset, presetName: preset) else {
            throw ExportError.sessionUnavailable
        }
        session.videoComposition = built.videoComposition
        session.metadata = metadata(for: request, interval: built.interval)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let monitor = Task {
            guard let progress else { return }
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: .mp4)
        progress?(1)

        var manifestURL: URL?
        if writeManifest {
            let target = url.deletingPathExtension().appendingPathExtension("manifest.json")
            try await Task.detached(priority: .utility) {
                try makeManifest(request: request, built: built, output: url).write(to: target)
            }.value
            manifestURL = target
        }
        return ExportResult(videoURL: url, manifestURL: manifestURL, interval: built.interval)
    }

    /// 批量导出风险点前后的片段，返回成功导出的结果。
    public static func exportRiskClips(_ points: [RiskPoint], base: ExportRequest, eventInterval: DateInterval,
                                       before: TimeInterval, after: TimeInterval, to directory: URL,
                                       progress: (@Sendable (Int, Double) -> Void)? = nil) async throws -> [ExportResult] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var results: [ExportResult] = []
        for (index, point) in points.enumerated() {
            let start = max(point.date - before, eventInterval.start)
            let end = min(point.date + after, eventInterval.end)
            guard end > start else { continue }
            var request = base
            request.interval = DateInterval(start: start, end: end)
            let name = ExportNaming.fileName(start: start, label: point.kind.displayName)
            results.append(try await export(request, to: directory.appendingPathComponent(name)) { fraction in
                progress?(index, fraction)
            })
        }
        return results
    }

    private static func metadata(for request: ExportRequest, interval: DateInterval) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var description = "特斯拉行车记录 \(request.event.kind.displayName) \(iso.string(from: interval.start)) — \(iso.string(from: interval.end))"
        if let reason = request.event.info?.reasonDescription { description += " · \(reason)" }
        var items = [
            item(.commonIdentifierCreationDate, iso.string(from: interval.start)),
            item(.commonIdentifierDescription, description),
            item(.commonIdentifierSoftware, "TesCam"),
        ]
        if let lat = request.event.info?.latitude, let lon = request.event.info?.longitude {
            items.append(item(.quickTimeMetadataLocationISO6709, String(format: "%+09.5f%+010.5f/", lat, lon)))
        }
        return items
    }

    private static func makeManifest(request: ExportRequest, built: DashcamComposition, output: URL) throws -> Data {
        var seen = Set<URL>()
        let sources = try built.sources.compactMap { camera, start, url -> EvidenceManifest.Source? in
            guard seen.insert(url).inserted else { return nil }
            let (hash, size) = try sha256(of: url)
            return .init(camera: camera.rawValue, fileName: url.lastPathComponent, segmentStart: start,
                         byteCount: size, sha256: hash)
        }
        let info = request.event.info
        let manifest = EvidenceManifest(
            exportedAt: Date(), outputFile: output.lastPathComponent, outputSHA256: try sha256(of: output).hash,
            intervalStart: built.interval.start, intervalEnd: built.interval.end,
            eventKind: request.event.kind.rawValue, eventReason: info?.reason, city: info?.city, street: info?.street,
            latitude: info?.latitude, longitude: info?.longitude, layout: request.layout.rawValue,
            cameras: request.cameras.map(\.rawValue), sources: sources)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    static func sha256(of url: URL) throws -> (hash: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}

public enum ExportNaming {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    public static func fileName(start: Date, label: String) -> String {
        let safe = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "TesCam_\(formatter.string(from: start))_\(safe).mp4"
    }
}
