import Foundation

enum ProtobufError: Error, Equatable {
    /// A value runs past the end of the data.
    case truncated
    /// Not valid protobuf: a varint over 10 bytes, field number 0, or a group or unknown wire type.
    case malformed
}

/// Reads the protobuf wire format one field at a time, enough for Google Authenticator's export
/// (https://protobuf.dev/programming-guides/encoding/). Nested messages are `.bytes` that the
/// caller reads with another reader.
struct ProtobufReader {
    enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// The next field, or nil at the end of the data.
    mutating func next() throws -> (field: Int, value: Value)? {
        guard offset < bytes.count else { return nil }
        let key = try readVarint()
        let field = key >> 3
        guard field >= 1, field <= 0x1FFF_FFFF else { throw ProtobufError.malformed }
        switch key & 7 {
        case 0:
            return (Int(field), .varint(try readVarint()))
        case 1:
            return (Int(field), .fixed64(try readFixed(byteCount: 8)))
        case 2:
            let length = try readVarint()
            guard length <= UInt64(bytes.count - offset) else { throw ProtobufError.truncated }
            let value = Data(bytes[offset..<offset + Int(length)])
            offset += Int(length)
            return (Int(field), .bytes(value))
        case 5:
            return (Int(field), .fixed32(UInt32(try readFixed(byteCount: 4))))
        default:
            // 3 and 4 are the long-deprecated groups; 6 and 7 don't exist.
            throw ProtobufError.malformed
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard offset < bytes.count else { throw ProtobufError.truncated }
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << UInt64(7 * index)
            if byte & 0x80 == 0 { return result }
        }
        throw ProtobufError.malformed
    }

    /// Little-endian.
    private mutating func readFixed(byteCount: Int) throws -> UInt64 {
        guard bytes.count - offset >= byteCount else { throw ProtobufError.truncated }
        var value: UInt64 = 0
        for index in 0..<byteCount {
            value |= UInt64(bytes[offset + index]) << UInt64(8 * index)
        }
        offset += byteCount
        return value
    }
}
