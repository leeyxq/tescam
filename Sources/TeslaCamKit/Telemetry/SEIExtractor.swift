import Foundation

public enum SEIExtractorError: LocalizedError {
    case noMediaData

    public var errorDescription: String? { "视频文件中没有 mdat 数据" }
}

/// 直接扫描 MP4 的 mdat，从 H.264/HEVC 的 SEI user_data_unregistered 中取出特斯拉车辆数据。
///
/// 特斯拉写入的载荷格式：若干 0x42 填充字节 + 0x69 标记 + protobuf(SeiMetadata)。
/// 为兼容其他固件，也会尝试“16 字节 UUID + protobuf”的标准格式。
public enum SEIExtractor {
    public struct Sample: Sendable {
        /// 相对于该视频文件开头的秒数
        public var time: TimeInterval
        public var metadata: SEIMetadata
    }

    /// 优先按 sample table 只读取每帧开头的少量字节（U 盘上快一个数量级），失败时退回全量扫描。
    public static func extract(contentsOf url: URL) throws -> [Sample] {
        try extractClip(contentsOf: url).samples
    }

    /// 同时返回视频时长（秒），用于分段对齐。
    public static func extractClip(contentsOf url: URL) throws -> (samples: [Sample], duration: TimeInterval?) {
        if let file = try? RandomAccessFile(url), let table = try? MP4SampleTable.load(from: file),
           let samples = try? extract(table: table, file: file) {
            return (samples, table.duration)
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let duration = data.withUnsafeBytes { raw -> TimeInterval? in
            let bytes = raw.bindMemory(to: UInt8.self)
            return MP4Box.topLevel(in: bytes).first { $0.type == "moov" }.flatMap { MP4Box.movieDuration(in: bytes, moov: $0) }
        }
        return (try extract(mp4: data), duration)
    }

    /// 解析 moov 中视频轨的 stsz/stco/stsc/stts，逐帧读取帧首部的 SEI。
    static func extractUsingSampleTable(_ url: URL) throws -> [Sample]? {
        let file = try RandomAccessFile(url)
        guard let table = try MP4SampleTable.load(from: file) else { return nil }
        return try extract(table: table, file: file)
    }

    private static func extract(table: MP4SampleTable, file: RandomAccessFile) throws -> [Sample] {
        let headerLength = table.isHEVC ? 2 : 1
        func metadata(at index: Int) throws -> SEIMetadata? {
            let offset = table.offsets[index]
            let size = Int(table.sizes[index])
            let head = try file.read(at: offset, count: min(size, 1024))
            var position = 0
            while position + 4 <= head.count {
                let length = Int(head[position]) << 24 | Int(head[position + 1]) << 16
                    | Int(head[position + 2]) << 8 | Int(head[position + 3])
                guard length > 1, position + 4 + length <= size else { return nil }
                let type = table.isHEVC ? Int((head[position + 4] >> 1) & 0x3F) : Int(head[position + 4] & 0x1F)
                if table.isHEVC ? (type == 39 || type == 40) : type == 6 {
                    let nal = position + 4 + length <= head.count
                        ? Array(head[(position + 4)..<(position + 4 + length)])
                        : try file.read(at: offset + Int64(position + 4), count: length)
                    if let metadata = nal.withUnsafeBufferPointer({ parseSEI($0, headerLength: headerLength) }) {
                        return metadata
                    }
                } else if table.isHEVC ? type < 32 : (type == 1 || type == 5) {
                    return nil // 已到图像数据，SEI 只会出现在其前面
                }
                position += 4 + length
            }
            return nil
        }

        // 停车录像不含 SEI：先约每秒抽查一帧，全无则跳过，避免逐帧读取 U 盘
        let count = table.offsets.count
        let probeStride = max(1, Int((Double(count) / max(table.time(ofSample: count - 1), 1)).rounded()))
        guard try stride(from: 0, to: count, by: probeStride).contains(where: { try metadata(at: $0) != nil }) else {
            return []
        }
        var samples: [Sample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            if let metadata = try metadata(at: index) {
                samples.append(Sample(time: table.time(ofSample: index), metadata: metadata))
            }
        }
        return samples
    }

    public static func extract(mp4 data: Data) throws -> [Sample] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Sample] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let boxes = MP4Box.topLevel(in: bytes)
            guard let mdat = boxes.first(where: { $0.type == "mdat" }) else { throw SEIExtractorError.noMediaData }
            let moov = boxes.first { $0.type == "moov" }
            let duration = moov.flatMap { MP4Box.movieDuration(in: bytes, moov: $0) }
            let isHEVC = moov.map { MP4Box.contains(bytes, range: $0.payload, fourCC: "hvc1")
                || MP4Box.contains(bytes, range: $0.payload, fourCC: "hev1") } ?? false

            var found: [(frameIndex: Int, metadata: SEIMetadata)] = []
            var frameCount = 0
            var position = mdat.payload.lowerBound
            let end = mdat.payload.upperBound
            while position + 4 <= end {
                let length = Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16
                    | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
                position += 4
                guard length > 1, position + length <= end else { break }
                let nal = UnsafeBufferPointer(rebasing: bytes[position..<position + length])
                if isHEVC {
                    let type = Int((nal[0] >> 1) & 0x3F)
                    if type == 39 || type == 40 {
                        if let metadata = parseSEI(nal, headerLength: 2) { found.append((frameCount, metadata)) }
                    } else if type < 32, nal.count > 2, nal[2] & 0x80 != 0 {
                        frameCount += 1 // first_slice_segment_in_pic_flag
                    }
                } else {
                    let type = Int(nal[0] & 0x1F)
                    if type == 6 {
                        if let metadata = parseSEI(nal, headerLength: 1) { found.append((frameCount, metadata)) }
                    } else if type == 1 || type == 5, nal[1] & 0x80 != 0 {
                        frameCount += 1 // first_mb_in_slice == 0
                    }
                }
                position += length
            }

            let frameDuration: TimeInterval
            if let duration, duration > 0, frameCount > 0 {
                frameDuration = duration / Double(frameCount)
            } else {
                frameDuration = 1.0 / 30.0
            }
            return found.map { Sample(time: Double($0.frameIndex) * frameDuration, metadata: $0.metadata) }
        }
    }

    static func parseSEI(_ nal: UnsafeBufferPointer<UInt8>, headerLength: Int) -> SEIMetadata? {
        let rbsp = removeEmulationPrevention(nal)
        let trailingEnd = rbsp.last == 0x80 ? rbsp.count - 1 : rbsp.count
        var index = headerLength
        while index < trailingEnd {
            var payloadType = 0
            while index < trailingEnd, rbsp[index] == 0xFF { payloadType += 255; index += 1 }
            guard index < trailingEnd else { break }
            payloadType += Int(rbsp[index]); index += 1
            var payloadSize = 0
            while index < trailingEnd, rbsp[index] == 0xFF { payloadSize += 255; index += 1 }
            guard index < trailingEnd else { break }
            payloadSize += Int(rbsp[index]); index += 1

            let start = index
            let end = min(start + payloadSize, trailingEnd)
            if payloadType == 5 {
                if let metadata = decodeUserData(rbsp[start..<end]) ?? decodeUserData(rbsp[start..<trailingEnd]) {
                    return metadata
                }
            }
            index = end
        }
        return nil
    }

    static func decodeUserData(_ payload: ArraySlice<UInt8>) -> SEIMetadata? {
        var index = payload.startIndex
        while index < payload.endIndex, payload[index] == 0x42 { index += 1 }
        if index > payload.startIndex, index < payload.endIndex, payload[index] == 0x69,
           let metadata = try? SEIMetadata(protobuf: payload[(index + 1)...]), metadata.isPlausible {
            return metadata
        }
        if payload.count > 16,
           let metadata = try? SEIMetadata(protobuf: payload.dropFirst(16)), metadata.isPlausible {
            return metadata
        }
        return nil
    }

    static func removeEmulationPrevention(_ nal: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(nal.count)
        var zeros = 0
        for byte in nal {
            if zeros >= 2 && byte == 0x03 {
                zeros = 0
                continue
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }
}

/// 最小化的 ISO BMFF box 解析。
struct MP4Box {
    let type: String
    let payload: Range<Int>

    static func topLevel(in bytes: UnsafeBufferPointer<UInt8>) -> [MP4Box] {
        children(in: bytes, range: 0..<bytes.count)
    }

    static func children(in bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> [MP4Box] {
        var boxes: [MP4Box] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound {
            var size = Int(readUInt32(bytes, position))
            let type = String(decoding: bytes[position + 4..<position + 8], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard position + 16 <= range.upperBound else { break }
                size = Int(readUInt32(bytes, position + 8)) << 32 | Int(readUInt32(bytes, position + 12))
                header = 16
            } else if size == 0 {
                size = range.upperBound - position
            }
            guard size >= header else { break }
            let end = min(position + size, range.upperBound)
            boxes.append(MP4Box(type: type, payload: position + header..<end))
            position += size
        }
        return boxes
    }

    /// 读取 moov/mvhd 中的影片时长（秒）。
    static func movieDuration(in bytes: UnsafeBufferPointer<UInt8>, moov: MP4Box) -> TimeInterval? {
        guard let mvhd = children(in: bytes, range: moov.payload).first(where: { $0.type == "mvhd" }) else { return nil }
        let p = mvhd.payload.lowerBound
        guard mvhd.payload.count >= 32 else { return nil }
        let version = bytes[p]
        let timescale: UInt32
        let duration: UInt64
        if version == 1 {
            timescale = readUInt32(bytes, p + 20)
            duration = UInt64(readUInt32(bytes, p + 24)) << 32 | UInt64(readUInt32(bytes, p + 28))
        } else {
            timescale = readUInt32(bytes, p + 12)
            duration = UInt64(readUInt32(bytes, p + 16))
        }
        guard timescale > 0 else { return nil }
        return Double(duration) / Double(timescale)
    }

    static func contains(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, fourCC: String) -> Bool {
        let needle = Array(fourCC.utf8)
        guard range.count >= needle.count else { return false }
        for i in range.lowerBound...(range.upperBound - needle.count)
        where bytes[i] == needle[0] && bytes[i + 1] == needle[1] && bytes[i + 2] == needle[2] && bytes[i + 3] == needle[3] {
            return true
        }
        return false
    }

    private static func readUInt32(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
