import Foundation

/// 关闭预读的随机读取，避免从 U 盘读入整个视频文件。
final class RandomAccessFile {
    private let descriptor: Int32
    let size: Int64

    init(_ url: URL) throws {
        descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url]) }
        _ = fcntl(descriptor, F_RDAHEAD, 0)
        size = lseek(descriptor, 0, SEEK_END)
    }

    deinit { close(descriptor) }

    func read(at offset: Int64, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        let read = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
        guard read >= 0 else { throw CocoaError(.fileReadUnknown) }
        if read < count { buffer.removeLast(count - read) }
        return buffer
    }
}

/// 视频轨的帧位置与时间表。
struct MP4SampleTable {
    var offsets: [Int64]
    var sizes: [UInt32]
    /// 每帧的解码时间（timescale 单位）
    var decodeTimes: [Int64]
    var timescale: Int64
    var isHEVC: Bool
    /// 视频轨总时长（秒）
    var duration: TimeInterval

    func time(ofSample index: Int) -> TimeInterval {
        Double(decodeTimes[index]) / Double(timescale)
    }

    static func load(from file: RandomAccessFile) throws -> MP4SampleTable? {
        // 只读 box 头定位 moov，moov 本身通常只有几百 KB
        var position: Int64 = 0
        var moov: [UInt8]?
        while position + 8 <= file.size {
            let header = try file.read(at: position, count: 16)
            guard header.count >= 8 else { break }
            var size = Int64(be32(header, 0))
            var headerLength: Int64 = 8
            if size == 1 {
                guard header.count >= 16 else { break }
                size = Int64(be32(header, 8)) << 32 | Int64(be32(header, 12))
                headerLength = 16
            } else if size == 0 {
                size = file.size - position
            }
            guard size >= headerLength else { break }
            if String(decoding: header[4..<8], as: UTF8.self) == "moov" {
                moov = try file.read(at: position + headerLength, count: Int(size - headerLength))
                break
            }
            position += size
        }
        guard let moov else { return nil }
        return moov.withUnsafeBufferPointer { parse(moov: $0) }
    }

    static func parse(moov bytes: UnsafeBufferPointer<UInt8>) -> MP4SampleTable? {
        func child(_ box: MP4Box, _ type: String) -> MP4Box? {
            MP4Box.children(in: bytes, range: box.payload).first { $0.type == type }
        }
        for trak in MP4Box.children(in: bytes, range: 0..<bytes.count) where trak.type == "trak" {
            guard let mdia = child(trak, "mdia"), let hdlr = child(mdia, "hdlr"), hdlr.payload.count >= 12,
                  String(decoding: bytes[hdlr.payload.lowerBound + 8..<hdlr.payload.lowerBound + 12], as: UTF8.self) == "vide",
                  let mdhd = child(mdia, "mdhd"), let minf = child(mdia, "minf"), let stbl = child(minf, "stbl"),
                  let stsz = child(stbl, "stsz"), let stsc = child(stbl, "stsc"), let stts = child(stbl, "stts"),
                  let chunkBox = child(stbl, "stco") ?? child(stbl, "co64")
            else { continue }

            func fits(_ box: MP4Box, _ needed: Int) -> Bool { box.payload.count >= needed }
            let m = mdhd.payload.lowerBound
            guard fits(mdhd, bytes[m] == 1 ? 32 : 24), fits(stsz, 12), fits(chunkBox, 8), fits(stsc, 8), fits(stts, 8)
            else { return nil }
            let timescale = Int64(bytes[m] == 1 ? be32(bytes, m + 20) : be32(bytes, m + 12))
            guard timescale > 0 else { return nil }

            // stsz
            let z = stsz.payload.lowerBound
            let uniformSize = be32(bytes, z + 4)
            let sampleCount = Int(be32(bytes, z + 8))
            guard uniformSize != 0 || fits(stsz, 12 + sampleCount * 4) else { return nil }
            var sizes = [UInt32]()
            sizes.reserveCapacity(sampleCount)
            for i in 0..<sampleCount {
                sizes.append(uniformSize != 0 ? uniformSize : be32(bytes, z + 12 + i * 4))
            }

            // stco / co64
            let c = chunkBox.payload.lowerBound
            let chunkCount = Int(be32(bytes, c + 4))
            let is64 = chunkBox.type == "co64"
            guard fits(chunkBox, 8 + chunkCount * (is64 ? 8 : 4)) else { return nil }
            let chunkOffsets: [Int64] = (0..<chunkCount).map { i in
                is64 ? Int64(be32(bytes, c + 8 + i * 8)) << 32 | Int64(be32(bytes, c + 12 + i * 8))
                     : Int64(be32(bytes, c + 8 + i * 4))
            }

            // stsc：每个 chunk 的帧数
            let s = stsc.payload.lowerBound
            guard fits(stsc, 8 + Int(be32(bytes, s + 4)) * 12) else { return nil }
            let entries = (0..<Int(be32(bytes, s + 4))).map { i in
                (firstChunk: Int(be32(bytes, s + 8 + i * 12)), perChunk: Int(be32(bytes, s + 12 + i * 12)))
            }
            var offsets = [Int64]()
            offsets.reserveCapacity(sampleCount)
            var sample = 0
            for (chunkIndex, chunkOffset) in chunkOffsets.enumerated() where sample < sampleCount {
                let chunkNumber = chunkIndex + 1
                let perChunk = entries.last { $0.firstChunk <= chunkNumber }?.perChunk ?? 1
                var offset = chunkOffset
                for _ in 0..<perChunk where sample < sampleCount {
                    offsets.append(offset)
                    offset += Int64(sizes[sample])
                    sample += 1
                }
            }
            guard offsets.count == sampleCount else { return nil }

            // stts
            let t = stts.payload.lowerBound
            guard fits(stts, 8 + Int(be32(bytes, t + 4)) * 8) else { return nil }
            var decodeTimes = [Int64]()
            decodeTimes.reserveCapacity(sampleCount)
            var current: Int64 = 0
            for i in 0..<Int(be32(bytes, t + 4)) {
                let count = Int(be32(bytes, t + 8 + i * 8))
                let delta = Int64(be32(bytes, t + 12 + i * 8))
                for _ in 0..<count where decodeTimes.count < sampleCount {
                    decodeTimes.append(current)
                    current += delta
                }
            }
            while decodeTimes.count < sampleCount { decodeTimes.append(current) }

            let isHEVC = child(stbl, "stsd").map {
                MP4Box.contains(bytes, range: $0.payload, fourCC: "hvc1") || MP4Box.contains(bytes, range: $0.payload, fourCC: "hev1")
            } ?? false
            return MP4SampleTable(offsets: offsets, sizes: sizes, decodeTimes: decodeTimes, timescale: timescale,
                                  isHEVC: isHEVC, duration: Double(current) / Double(timescale))
        }
        return nil
    }

    private static func be32(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
