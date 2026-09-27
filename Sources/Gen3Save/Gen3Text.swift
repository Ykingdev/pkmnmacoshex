import Foundation

/// The GBA-era proprietary character encoding. Romhacks inherit it unchanged,
/// which is why nicknames are the most reliable way to identify a Pokémon in a
/// save whose species table you don't have.
public enum Gen3Text {
    public static let terminator: UInt8 = 0xFF

    private static let table: [UInt8: Character] = {
        var t: [UInt8: Character] = [0x00: " ", 0xAB: "!", 0xAC: "?", 0xAD: ".",
                                     0xAE: "-", 0xB8: ",", 0xBA: "/"]
        for n in 0..<10 { t[0xA1 + UInt8(n)] = Character(String(n)) }
        for n in 0..<26 {
            t[0xBB + UInt8(n)] = Character(UnicodeScalar(65 + n)!)
            t[0xD5 + UInt8(n)] = Character(UnicodeScalar(97 + n)!)
        }
        return t
    }()

    private static let reverse: [Character: UInt8] = {
        var r: [Character: UInt8] = [:]
        for (byte, char) in table { r[char] = byte }
        return r
    }()

    public static func decode(_ raw: some Sequence<UInt8>) -> String {
        var out = ""
        for byte in raw {
            if byte == terminator { break }
            out.append(table[byte] ?? "\u{FFFD}")
        }
        return out
    }

    /// Encodes and pads to `length` with the terminator. Characters outside the
    /// table are dropped rather than guessed at.
    public static func encode(_ text: String, length: Int) -> [UInt8] {
        var out = text.compactMap { reverse[$0] }
        if out.count > length { out = Array(out.prefix(length)) }
        out.append(contentsOf: repeatElement(terminator, count: length - out.count))
        return out
    }
}
