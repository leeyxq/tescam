import Foundation

enum ProtobufError: Error {
    case truncated
    case unsupportedWireType(Int)
}

/// 仅支持解码所需子集的 protobuf 读取器（varint / fixed32 / fixed64 / length-delimited）。
struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(ArraySlice<UInt8>)

        var doubleValue: Double {
            switch self {
            case .varint(let v): Double(v)
            case .fixed64(let v): Double(bitPattern: v)
            case .fixed32(let v): Double(Float(bitPattern: v))
            case .bytes: 0
            }
        }

        var uint64Value: UInt64 {
            switch self {
            case .varint(let v), .fixed64(let v): v
            case .fixed32(let v): UInt64(v)
            case .bytes: 0
            }
        }

        var boolValue: Bool { uint64Value != 0 }
    }

    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    var isAtEnd: Bool { index >= bytes.endIndex }

    mutating func nextField() throws -> (number: Int, value: Value)? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let number = Int(key >> 3)
        let wireType = Int(key & 0x7)
        guard number > 0 else { throw ProtobufError.unsupportedWireType(wireType) }
        switch wireType {
        case 0:
            return (number, .varint(try readVarint()))
        case 1:
            return (number, .fixed64(try readFixed(8)))
        case 2:
            guard let length = Int(exactly: try readVarint()), index + length <= bytes.endIndex else {
                throw ProtobufError.truncated
            }
            defer { index += length }
            return (number, .bytes(bytes[index..<index + length]))
        case 5:
            return (number, .fixed32(UInt32(try readFixed(4))))
        default:
            throw ProtobufError.unsupportedWireType(wireType)
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.endIndex, shift < 64 else { throw ProtobufError.truncated }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func readFixed(_ count: Int) throws -> UInt64 {
        guard index + count <= bytes.endIndex else { throw ProtobufError.truncated }
        var result: UInt64 = 0
        for offset in 0..<count {
            result |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
        }
        index += count
        return result
    }
}
