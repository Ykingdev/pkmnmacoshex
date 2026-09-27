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
    public var typeNames: [UInt8: String] = [:]
    public var moveStats: [UInt16: MoveStats] = [:]
    public var moveDescriptions: [UInt16: String] = [:]
    /// Species → level-up learnset. The only learnability source that could be
    /// located reliably; see `legality(species:move:)`.
    public var learnsets: [UInt16: [LearnedMove]] = [:]
    public var tmMoves: [UInt16] = []

    // Swift would encode [UInt16: String] as a flat array; decimal string keys
    // keep the committed data file diffable and readable.
    enum CodingKeys: String, CodingKey {
        case species, moves, romName, saveMagic, typeNames, moveStats,
             moveDescriptions, learnsets, tmMoves
    }

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
        moveDescriptions = try container.decodeIfPresent([String: String].self,
                                                        forKey: .moveDescriptions)?
            .reduce(into: [:]) { if let id = UInt16($1.key) { $0[id] = $1.value } } ?? [:]
        typeNames = try container.decodeIfPresent([String: String].self, forKey: .typeNames)?
            .reduce(into: [:]) { if let id = UInt8($1.key) { $0[id] = $1.value } } ?? [:]
        tmMoves = try container.decodeIfPresent([UInt16].self, forKey: .tmMoves) ?? []
        // "power,type,accuracy,pp,chance,category"
        moveStats = try container.decodeIfPresent([String: String].self, forKey: .moveStats)?
            .reduce(into: [:]) { result, pair in
                let parts = pair.value.split(separator: ",").compactMap { UInt8($0) }
                guard let id = UInt16(pair.key), parts.count == 6 else { return }
                result[id] = MoveStats(power: parts[0], type: parts[1], accuracy: parts[2],
                                       pp: parts[3], effectChance: parts[4], category: parts[5])
            } ?? [:]
        // "move:level,move:level"
        learnsets = try container.decodeIfPresent([String: String].self, forKey: .learnsets)?
            .reduce(into: [:]) { result, pair in
                guard let id = UInt16(pair.key) else { return }
                result[id] = pair.value.split(separator: ",").compactMap { item in
                    let halves = item.split(separator: ":")
                    guard halves.count == 2, let move = UInt16(halves[0]),
                          let level = UInt8(halves[1]) else { return nil }
                    return LearnedMove(move: move, level: level)
                }
            } ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(species.reduce(into: [String: String]()) { $0["\($1.key)"] = $1.value },
                             forKey: .species)
        try container.encode(moves.reduce(into: [String: String]()) { $0["\($1.key)"] = $1.value },
                             forKey: .moves)
        try container.encode(romName, forKey: .romName)
        try container.encodeIfPresent(saveMagic, forKey: .saveMagic)
        if !typeNames.isEmpty {
            try container.encode(typeNames.reduce(into: [String: String]()) { $0["\($1.key)"] = $1.value },
                                 forKey: .typeNames)
        }
        if !moveDescriptions.isEmpty {
            try container.encode(moveDescriptions.reduce(into: [String: String]()) { $0["\($1.key)"] = $1.value },
                                 forKey: .moveDescriptions)
        }
        if !moveStats.isEmpty {
            try container.encode(moveStats.reduce(into: [String: String]()) { result, pair in
                let s = pair.value
                result["\(pair.key)"] = "\(s.power),\(s.type),\(s.accuracy),\(s.pp),\(s.effectChance),\(s.category)"
            }, forKey: .moveStats)
        }
        if !learnsets.isEmpty {
            try container.encode(learnsets.reduce(into: [String: String]()) { result, pair in
                result["\(pair.key)"] = pair.value.map { "\($0.move):\($0.level)" }.joined(separator: ",")
            }, forKey: .learnsets)
        }
        if !tmMoves.isEmpty { try container.encode(tmMoves, forKey: .tmMoves) }
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
    public func stats(forMove id: UInt16) -> MoveStats? { moveStats[id] }
    public func description(forMove id: UInt16) -> String? { moveDescriptions[id] }
    public func typeName(_ id: UInt8) -> String { typeNames[id] ?? "Type \(id)" }
    public func learnset(species id: UInt16) -> [LearnedMove] { learnsets[id] ?? [] }
    public func isTM(move id: UInt16) -> Bool { tmMoves.contains(id) }

    /// Whether a move's own description says it changes stats. Reading the text is
    /// hack-proof: the effect byte lumps stat changes together with status moves
    /// (Growl and Toxic share one), so it cannot answer this.
    public func changesStats(move id: UInt16) -> Bool {
        guard let text = moveDescriptions[id]?.lowercased() else { return false }
        let verbs = ["raise", "lower", "boost", "sharply", "heighten", "reduce"]
        let stats = ["attack", "defense", "sp. atk", "sp. def", "speed",
                     "accuracy", "evasiveness", "evasion", "stat"]
        return verbs.contains(where: text.contains) && stats.contains(where: text.contains)
    }

    /// How defensible it is for this species to know this move.
    ///
    /// Only the level-up learnset could be located reliably — the per-species
    /// TM/HM compatibility bitfield could not be found in the ROMs tested — so a
    /// TM move is reported as unverified rather than illegal. Being wrong in that
    /// direction is much cheaper than crying foul over a legitimate TM.
    public enum Legality: Equatable, Sendable {
        case learnsAtLevel(UInt8)
        case tmOrHmMove
        case notInLearnset
        case unknown            // no learnset data for this species at all

        public var isFlagged: Bool { self == .notInLearnset }
    }

    public func legality(species: UInt16, move: UInt16) -> Legality {
        guard move != 0 else { return .unknown }
        let list = learnset(species: species)
        if let hit = list.first(where: { $0.move == move }) { return .learnsAtLevel(hit.level) }
        if isTM(move: move) { return .tmOrHmMove }
        return list.isEmpty ? .unknown : .notInLearnset
    }

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
        let moveCount = Int(tables.moves.keys.max() ?? 0)
        let speciesCount = Int(tables.species.keys.max() ?? 0)
        tables.typeNames = mineTypeNames(rom)
        if moveCount > 0 {
            tables.moveStats = mineMoveStats(rom, moveCount: moveCount)
            tables.moveDescriptions = mineMoveDescriptions(rom, moveCount: moveCount)
            tables.tmMoves = mineTMMoves(rom, moveNames: tables.moves)
        }
        if speciesCount > 0, moveCount > 0 {
            tables.learnsets = mineLearnsets(rom, speciesCount: speciesCount,
                                            moveCount: moveCount)
        }
        return tables
    }

    public static func mine(romAt url: URL) throws -> RomTables {
        let data = try Data(contentsOf: url)
        return mine(rom: [UInt8](data), romName: url.lastPathComponent)
    }
}
