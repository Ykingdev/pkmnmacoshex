import Foundation

/// The GBA-era proprietary character encoding. Romhacks inherit it unchanged,
/// which is why nicknames are the most reliable way to identify a Pokémon in a
/// save whose species table you don't have.
public enum Gen3Text {
    public static let terminator: UInt8 = 0xFF

    private static let table: [UInt8: Character] = {
        // Enough of the table to read names out of a ROM: "Double-Edge",
        // "Nature's Madness", "Flabébé" all need entries beyond the alphabet.
        var t: [UInt8: Character] = [0x00: " ", 0x1B: "é", 0xAB: "!", 0xAC: "?",
                                     0xAD: ".", 0xAE: "-", 0xB0: "…", 0xB1: "“",
                                     0xB2: "”", 0xB3: "‘", 0xB4: "’", 0xB5: "♂",
                                     0xB6: "♀", 0xB8: ",", 0xBA: "/", 0xF0: ":"]
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

    /// The character for one byte, or nil when the byte isn't text.
    public static func character(for byte: UInt8) -> Character? { table[byte] }

    public static func decode(_ raw: some Sequence<UInt8>) -> String {
        var out = ""
        for byte in raw {
            if byte == terminator { break }
            out.append(table[byte] ?? "\u{FFFD}")
        }
        return out
    }

    /// Whether a fixed-width name field holds real text: at least `minLength`
    /// known characters, then a terminator. Used to tell a stored Pokémon apart
    /// from arbitrary save bytes.
    public static func isPrintable(_ raw: some Sequence<UInt8>, minLength: Int) -> Bool {
        var count = 0
        for byte in raw {
            if byte == terminator { break }
            guard table[byte] != nil else { return false }
            count += 1
        }
        return count >= minLength
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
