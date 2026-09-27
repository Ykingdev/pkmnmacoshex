import Foundation

public enum Gen3Checksum {
    @inline(__always)
    static func load32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// The Gen 3 section checksum: sum the region as little-endian 32-bit words,
    /// then fold the halves of the result together.
    public static func value(_ bytes: [UInt8], offset: Int, length: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i < length {
            sum &+= load32(bytes, offset + i)
            i += 4
        }
        return UInt16(((sum >> 16) &+ (sum & 0xFFFF)) & 0xFFFF)
    }

    /// Every prefix length whose checksum equals `stored`.
    ///
    /// This is how Hexeon supports romhacks without a per-hack table: the game
    /// itself wrote a checksum over some fixed length we don't know, so we ask
    /// which lengths could have produced it. The true length is always in here.
    /// Trailing zero padding makes several lengths match, which is harmless —
    /// they all yield the same checksum for any edit that stays inside them.
    public static func matchingLengths(_ bytes: [UInt8], offset: Int,
                                      stored: UInt16, maxLength: Int) -> [Int] {
        var matches: [Int] = []
        var sum: UInt32 = 0
        var n = 4
        while n <= maxLength {
            sum &+= load32(bytes, offset + n - 4)
            if UInt16(((sum >> 16) &+ (sum & 0xFFFF)) & 0xFFFF) == stored {
                matches.append(n)
            }
            n += 4
        }
        return matches
    }
}
