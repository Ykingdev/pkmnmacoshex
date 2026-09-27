import Foundation

/// Species and move names mined out of a GBA ROM.
///
/// The save only stores numbers, and the numbering is the ROM's own — Beldum is
/// 398 in Unbound and 374 in the National Dex — so the names have to come from
/// the ROM. Rather than hardcode table addresses per game (which is what breaks
/// on every romhack), find the tables by looking for what they must contain.
public struct RomTables: Sendable, Codable, Equatable {
    public var species: [UInt16: String]
    public var moves: [UInt16: String]
    public var romName: String
    /// The save footer magic of the game this came from, so bundled tables can be
    /// matched to a save automatically.
    public var saveMagic: UInt32?

    // Swift would encode [UInt16: String] as a flat array; decimal string keys
    // keep the committed data file diffable and readable.
    enum CodingKeys: String, CodingKey { case species, moves, romName, saveMagic }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func table(_ key: CodingKeys) throws -> [UInt16: String] {
            try container.decode([String: String].self, forKey: key)
                .reduce(into: [:]) { result, pair in
                    if let id = UInt16(pair.key) { result[id] = pair.value }
                }
        }
        species = try table(.species)
        moves = try table(.moves)
        romName = try container.decode(String.self, forKey: .romName)
        saveMagic = try container.decodeIfPresent(UInt32.self, forKey: .saveMagic)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(species.reduce(into: [String: String]()) { $0["\($1.key)"] = $1.value },
                             forKey: .species)
        try container.encode(moves.reduce(into: [String: String]()) { $0["\($1.key)"] = $1.value },
                             forKey: .moves)
        try container.encode(romName, forKey: .romName)
        try container.encodeIfPresent(saveMagic, forKey: .saveMagic)
    }

    public init(species: [UInt16: String] = [:], moves: [UInt16: String] = [:],
                romName: String = "", saveMagic: UInt32? = nil) {
        self.species = species
        self.moves = moves
        self.romName = romName
        self.saveMagic = saveMagic
    }

    public var isEmpty: Bool { species.isEmpty && moves.isEmpty }
    public func speciesName(_ id: UInt16) -> String? { species[id] }
    public func moveName(_ id: UInt16) -> String? { moves[id] }

    /// The first few entries of each table, which every Gen 3 game and hack keeps
    /// in the same order. Compared after normalisation, so "DoubleSlap",
    /// "Double Slap" and "DOUBLE SLAP" all match.
    static let speciesAnchors = ["bulbasaur", "ivysaur", "venusaur", "charmander"]
    static let moveAnchors = ["pound", "karatechop", "doubleslap", "cometpunch"]

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Reads one fixed-width, terminator-padded entry.
    static func entry(_ rom: [UInt8], at offset: Int, width: Int) -> String? {
        guard offset >= 0, offset + width <= rom.count else { return nil }
        return Gen3Text.decode(rom[offset..<(offset + width)])
    }

    /// Locates a table by finding its first anchor, deriving the entry width from
    /// where the second anchor lands, then confirming with the rest.
    ///
    /// Entry widths differ per game and per table (FireRed uses 11 for species and
    /// 13 for moves; hacks change both), so the width is measured, never assumed.
    static func findTable(in rom: [UInt8], anchors: [String],
                          widths: ClosedRange<Int> = 7...24) -> (start: Int, width: Int)? {
        let first = anchors[0]
        // Anchor bytes depend on capitalisation, so try the two conventions used.
        let candidates = [Gen3Text.encode(first.capitalized, length: first.count),
                          Gen3Text.encode(first.uppercased(), length: first.count)]
        for pattern in Set(candidates) {
            var searchFrom = 0
            while let hit = search(rom, pattern: pattern, from: searchFrom) {
                searchFrom = hit + 1
                for width in widths {
                    guard width > first.count else { continue }
                    // Entry must be terminated inside its own width.
                    guard rom.count > hit + width, rom[hit + first.count] == Gen3Text.terminator
                    else { continue }
                    let matchesRest = anchors.dropFirst().enumerated().allSatisfy { index, expected in
                        guard let text = entry(rom, at: hit + width * (index + 1), width: width)
                        else { return false }
                        return normalize(text) == expected
                    }
                    if matchesRest {
                        // Anchor is index 1; index 0 is the game's placeholder entry.
                        return (hit - width, width)
                    }
                }
            }
        }
        return nil
    }

    static func search(_ haystack: [UInt8], pattern: [UInt8], from: Int) -> Int? {
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return nil }
        let limit = haystack.count - pattern.count
        var i = max(0, from)
        while i <= limit {
            if haystack[i] == pattern[0],
               Array(haystack[i..<(i + pattern.count)]) == pattern {
                return i
            }
            i += 1
        }
        return nil
    }

    /// Walks a table from its start until the entries stop being table entries.
    ///
    /// Two things must not be confused with the end of a table:
    ///
    /// - **Placeholders.** Vanilla FireRed has 25 consecutive "?????" rows at
    ///   species 252–276 before the Gen 3 species resume at 277, so a run of rows
    ///   without letters is normal and must be skipped, not treated as the end.
    /// - **Adjacent text.** Right after the move table sits ordinary game
    ///   dialogue, which decodes perfectly well and is terminated too — "must be
    ///   acqu", "100 Team". What actually separates a table entry from running
    ///   text is padding: a fixed-width entry fills everything after its
    ///   terminator with 0xFF, whereas the next dialogue string starts straight
    ///   after. Verified against Unbound, where the move table ends at 922
    ///   ("Rapid Flow") and entry 923 is the first with text after its
    ///   terminator.
    ///
    /// So the stop condition is one properly-unpadded row.
    static func readTable(_ rom: [UInt8], start: Int, width: Int, limit: Int = 1600) -> [UInt16: String] {
        var result: [UInt16: String] = [:]
        for index in 0..<limit {
            let offset = start + index * width
            guard offset + width <= rom.count,
                  let text = entry(rom, at: offset, width: width) else { break }
            guard isWellFormedEntry(rom, at: offset, width: width),
                  !text.contains("\u{FFFD}") else { break }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            // Keep real names; skip the game's own placeholder rows.
            if !trimmed.isEmpty, trimmed.contains(where: { $0.isLetter }) {
                result[UInt16(index)] = trimmed
            }
        }
        return result
    }

    /// A fixed-width entry either terminates within its width and pads the rest,
    /// or fills the width exactly with no room for a terminator — a name as long
    /// as the column allows. Anything else (a terminator with more text after it)
    /// is the adjacent data, not a table row.
    static func isWellFormedEntry(_ rom: [UInt8], at offset: Int, width: Int) -> Bool {
        guard offset + width <= rom.count else { return false }
        guard let terminator = rom[offset..<(offset + width)].firstIndex(of: Gen3Text.terminator)
        else { return true }   // full-width name; the decode check still applies
        return rom[(terminator + 1)..<(offset + width)].allSatisfy {
            $0 == Gen3Text.terminator || $0 == 0
        }
    }

    public static func mine(rom: [UInt8], romName: String = "") -> RomTables {
        var tables = RomTables(romName: romName)
        if let found = findTable(in: rom, anchors: speciesAnchors) {
            tables.species = readTable(rom, start: found.start, width: found.width)
        }
        if let found = findTable(in: rom, anchors: moveAnchors) {
            tables.moves = readTable(rom, start: found.start, width: found.width)
        }
        return tables
    }

    public static func mine(romAt url: URL) throws -> RomTables {
        let data = try Data(contentsOf: url)
        return mine(rom: [UInt8](data), romName: url.lastPathComponent)
    }
}
