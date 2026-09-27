import Foundation

/// Battle data for one move, as the ROM stores it.
public struct MoveStats: Sendable, Equatable {
    public var power: UInt8
    public var type: UInt8
    public var accuracy: UInt8
    public var pp: UInt8
    public var effectChance: UInt8
    /// 0 physical, 1 special, 2 status — hacks with the physical/special split
    /// keep this as its own field rather than deriving it from the type.
    public var category: UInt8

    public var isStatus: Bool { category == 2 }
    public var categoryName: String {
        switch category {
        case 0: return "Physical"
        case 1: return "Special"
        default: return "Status"
        }
    }
}

/// One entry of a species' level-up learnset.
public struct LearnedMove: Sendable, Equatable, Hashable {
    public var move: UInt16
    public var level: UInt8
}

extension RomTables {
    // MARK: - Type names

    /// `gTypeNames`: fixed-width, "Normal" first, "Fight" second. Note the ids are
    /// the vanilla ones — there is an unused slot at 9 and Fire is 10 — which a
    /// hack keeps even when it adds Fairy, so they must be read, not assumed.
    static func mineTypeNames(_ rom: [UInt8]) -> [UInt8: String] {
        let normal = Gen3Text.encode("Normal", length: 6)
        var from = 0
        while let hit = search(rom, pattern: normal, from: from) {
            from = hit + 1
            for width in 6...13 {
                guard let next = entry(rom, at: hit + width, width: width) else { continue }
                guard normalize(next).hasPrefix("fight") else { continue }
                var names: [UInt8: String] = [:]
                for index in 0..<24 {
                    guard let text = entry(rom, at: hit + index * width, width: width) else { break }
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains(where: { $0.isLetter }), !trimmed.contains("\u{FFFD}") {
                        names[UInt8(index)] = trimmed
                    }
                }
                if names.count >= 15 { return names }
            }
        }
        return [:]
    }

    // MARK: - Move battle data

    /// `gBattleMoves`. Found by anchoring on stats that hacks rarely retune —
    /// Pound (40 power, Normal, 100%, 35 PP) followed by Karate Chop (50,
    /// Fighting, 100%, 25 PP) — which also yields the entry stride.
    ///
    /// Field order is *not* vanilla's in every hack, so the anchor is the
    /// power/type/accuracy/PP run and the remaining fields are read relative to it.
    static func mineMoveStats(_ rom: [UInt8], moveCount: Int) -> [UInt16: MoveStats] {
        let first: [UInt8] = [40, 0, 100, 35]      // Pound
        let second: [UInt8] = [50, 1, 100, 25]     // Karate Chop
        var from = 0
        while let hit = search(rom, pattern: first, from: from) {
            from = hit + 1
            for stride in 8...32 where hit + stride + second.count <= rom.count {
                guard Array(rom[(hit + stride)..<(hit + stride + second.count)]) == second
                else { continue }
                let base = hit - stride     // entry 0
                guard base >= 0 else { continue }
                var stats: [UInt16: MoveStats] = [:]
                for id in 1...max(moveCount, 1) {
                    let offset = base + id * stride
                    guard offset + stride <= rom.count else { break }
                    let row = Array(rom[offset..<(offset + stride)])
                    // Unused slots are filled with 0xFF; a move can have a name
                    // without battle data, so skip rather than invent values.
                    if row.allSatisfy({ $0 == 0xFF }) { continue }
                    guard row[2] <= 100, row[3] >= 1, row[3] <= 64 else { continue }
                    stats[UInt16(id)] = MoveStats(power: row[0], type: row[1],
                                                  accuracy: row[2], pp: row[3],
                                                  effectChance: row[4],
                                                  category: stride > 9 ? row[9] : 0)
                }
                if stats.count > 100 { return stats }
            }
        }
        return [:]
    }

    // MARK: - Descriptions

    /// `gMoveDescriptions`: an array of pointers to text. Several such arrays exist
    /// (items have one too), so candidates are scored by whether the description
    /// at a known move's index actually describes that move.
    static func mineMoveDescriptions(_ rom: [UInt8], moveCount: Int) -> [UInt16: String] {
        let probes: [(UInt16, String)] = [(14, "attack"), (45, "lower"), (105, "restor"),
                                          (92, "poison"), (182, "protect")]
        var best: (score: Int, table: [UInt16: String]) = (0, [:])
        var offset = 0
        while offset + 4 <= rom.count {
            guard let target = pointer(rom, at: offset), isText(rom, at: target) else {
                offset += 4
                continue
            }
            var length = 0
            var cursor = offset
            while cursor + 4 <= rom.count, let next = pointer(rom, at: cursor),
                  isText(rom, at: next) {
                length += 1
                cursor += 4
            }
            if length >= 300 {
                let score = probes.reduce(into: 0) { total, probe in
                    guard let target = pointer(rom, at: offset + Int(probe.0) * 4),
                          let text = string(rom, at: target) else { return }
                    if text.lowercased().contains(probe.1) { total += 1 }
                }
                if score > best.score {
                    var table: [UInt16: String] = [:]
                    for id in 1...moveCount {
                        guard let target = pointer(rom, at: offset + id * 4),
                              let text = string(rom, at: target), !text.isEmpty else { continue }
                        table[UInt16(id)] = text
                    }
                    best = (score, table)
                }
            }
            offset = max(cursor, offset + 4)
        }
        return best.score >= 4 ? best.table : [:]
    }

    // MARK: - Learnsets

    /// `gLevelUpLearnsets`: one pointer per species to a list of (move, level).
    ///
    /// Vanilla packs both into a u16 (9 bits of move), which cannot address the
    /// 900+ moves a hack adds, so the encoding is tried rather than assumed:
    /// 3-byte `{u16 move; u8 level}` first, then the vanilla packed form. A
    /// candidate is accepted only if levels ascend and lists terminate, across
    /// many species.
    static func mineLearnsets(_ rom: [UInt8], speciesCount: Int,
                              moveCount: Int) -> [UInt16: [LearnedMove]] {
        var best: (score: Int, table: [UInt16: [LearnedMove]]) = (0, [:])
        var offset = 0
        while offset + 4 <= rom.count {
            guard pointer(rom, at: offset) != nil else { offset += 4; continue }
            var length = 0
            var cursor = offset
            while cursor + 4 <= rom.count, pointer(rom, at: cursor) != nil {
                length += 1
                cursor += 4
            }
            if length >= max(speciesCount / 2, 300) {
                for packed in [false, true] {
                    var table: [UInt16: [LearnedMove]] = [:]
                    var valid = 0
                    for id in 1...min(speciesCount, length - 1) {
                        guard let target = pointer(rom, at: offset + id * 4),
                              let list = learnset(rom, at: target, packed: packed,
                                                  moveCount: moveCount)
                        else { continue }
                        if !list.isEmpty {
                            table[UInt16(id)] = list
                            valid += 1
                        }
                    }
                    if valid > best.score { best = (valid, table) }
                }
            }
            offset = max(cursor, offset + 4)
        }
        return best.score >= 200 ? best.table : [:]
    }

    static func learnset(_ rom: [UInt8], at offset: Int, packed: Bool,
                         moveCount: Int) -> [LearnedMove]? {
        var result: [LearnedMove] = []
        var cursor = offset
        var lastLevel: UInt8 = 0
        let step = packed ? 2 : 3
        while cursor + step <= rom.count, result.count < 100 {
            let word = UInt16(rom[cursor]) | UInt16(rom[cursor + 1]) << 8
            // Terminators seen in the wild: 0xFFFF packed, or move 0 (with level
            // 0xFF) in the 3-byte form.
            if word == 0xFFFF || word == 0 { return result.isEmpty ? nil : result }
            let move: UInt16
            let level: UInt8
            if packed {
                move = word & 0x1FF
                level = UInt8((word >> 9) & 0x7F)
            } else {
                move = word
                level = rom[cursor + 2]
            }
            guard move >= 1, Int(move) <= moveCount, level <= 100, level >= lastLevel
            else { return nil }
            result.append(LearnedMove(move: move, level: level))
            lastLevel = level
            cursor += step
        }
        return nil      // ran off the end without a terminator
    }

    // MARK: - TM/HM list

    /// `gTMHMMoves`: the move each TM and HM teaches. The per-species
    /// compatibility bitfield could not be located in the ROMs tested, so this is
    /// used only to soften the legality verdict — a TM move is "unverified"
    /// rather than "illegal".
    static func mineTMMoves(_ rom: [UInt8], moveNames: [UInt16: String]) -> [UInt16] {
        let byName = moveNames.reduce(into: [String: UInt16]()) {
            $0[normalize($1.value)] = $1.key
        }
        let classics = ["toxic", "thunderbolt", "icebeam", "earthquake", "flamethrower",
                        "protect", "rest", "shadowball"].compactMap { byName[$0] }
        guard classics.count >= 6 else { return [] }
        var offset = 0
        var best: [UInt16] = []
        while offset + 2 <= rom.count {
            var values: [UInt16] = []
            var cursor = offset
            while cursor + 2 <= rom.count {
                let value = UInt16(rom[cursor]) | UInt16(rom[cursor + 1]) << 8
                guard moveNames[value] != nil else { break }
                values.append(value)
                cursor += 2
            }
            if (40...200).contains(values.count),
               classics.allSatisfy({ values.contains($0) }),
               best.isEmpty || values.count < best.count {
                best = values      // the tightest matching run is the TM list itself
            }
            offset = max(cursor, offset) + 2
        }
        return best
    }

    // MARK: - Byte helpers

    static func pointer(_ rom: [UInt8], at offset: Int) -> Int? {
        guard offset + 4 <= rom.count else { return nil }
        let value = Gen3Checksum.load32(rom, offset)
        guard value >= 0x0800_0000, value < 0x0800_0000 + UInt32(rom.count) else { return nil }
        return Int(value - 0x0800_0000)
    }

    static func isText(_ rom: [UInt8], at offset: Int, minLength: Int = 12) -> Bool {
        guard offset + minLength <= rom.count else { return false }
        for byte in rom[offset..<(offset + minLength)] {
            if byte == Gen3Text.terminator { return false }
            if byte == 0xFE { continue }                 // line break
            if Gen3Text.character(for: byte) == nil { return false }
        }
        return true
    }

    static func string(_ rom: [UInt8], at offset: Int, limit: Int = 300) -> String? {
        guard offset < rom.count else { return nil }
        var out = ""
        var cursor = offset
        while cursor < rom.count, cursor - offset < limit {
            let byte = rom[cursor]
            if byte == Gen3Text.terminator { return out }
            if byte == 0xFE { out.append("\n") }
            else if let character = Gen3Text.character(for: byte) { out.append(character) }
            else { return out.isEmpty ? nil : out }
            cursor += 1
        }
        return out.isEmpty ? nil : out
    }
}
