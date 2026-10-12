import Foundation

/// Incremental UTF-8 decoder: PTY reads can split a multi-byte sequence
/// (common with Persian text), so incomplete trailing bytes are kept for
/// the next chunk. Invalid input becomes U+FFFD.
public struct Utf8StreamDecoder {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func decode(_ bytes: UnsafeBufferPointer<UInt8>) -> [Unicode.Scalar] {
        var input = pending
        input.append(contentsOf: bytes)
        pending.removeAll(keepingCapacity: true)

        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            let lead = input[index]
            if lead < 0x80 {
                scalars.append(Unicode.Scalar(lead))
                index += 1
                continue
            }

            let length: Int
            var value: UInt32
            switch lead {
            case 0xc2...0xdf: length = 2; value = UInt32(lead & 0x1f)
            case 0xe0...0xef: length = 3; value = UInt32(lead & 0x0f)
            case 0xf0...0xf4: length = 4; value = UInt32(lead & 0x07)
            default:
                scalars.append(Self.replacement)
                index += 1
                continue
            }

            var consumed = 1
            var valid = true
            while consumed < length {
                guard index + consumed < input.count else {
                    // Incomplete so far: wait for the rest of the sequence.
                    pending = Array(input[index...])
                    return scalars
                }
                let byte = input[index + consumed]
                guard byte & 0xc0 == 0x80 else { valid = false; break }
                value = (value << 6) | UInt32(byte & 0x3f)
                consumed += 1
            }

            let minimum: UInt32 = length == 2 ? 0x80 : length == 3 ? 0x800 : 0x10000
            if valid, value >= minimum, let scalar = Unicode.Scalar(value) {
                scalars.append(scalar)
            } else {
                scalars.append(Self.replacement)
            }
            index += consumed
        }

        return scalars
    }

    private static let replacement = Unicode.Scalar(0xfffd)!
}
