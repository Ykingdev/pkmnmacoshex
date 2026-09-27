import Foundation

/// An editable snapshot of one Pokémon.
///
/// Gen 3 derives nature, and part of the ability, from the PID — so those aren't
/// stored fields you can just overwrite. Setting `nature`, `abilityBit` or
/// `isShiny` makes pkmnmacoshex search for a PID that satisfies all three at once and
/// re-encrypt the payload under the new key. Everything else is a direct write.
public struct MonDraft: Equatable, Sendable {
    public var nickname: String
    public var otName: String
    public var trainerID: UInt16
    public var secretID: UInt16
    public var species: UInt16
    public var heldItem: UInt16
    public var experience: UInt32
    public var friendship: UInt8
    public var nature: UInt8
    public var abilityBit: UInt8
    public var isShiny: Bool
    public var ivs: [UInt8]
    public var evs: [UInt8]
    public var moves: [UInt16]
    public var pp: [UInt8]
    public var level: UInt8?

    /// Fields this Pokémon's storage layout can't express, for the UI to disable.
    public let editableMoves: Bool
    public let editableEVs: Bool
    public let editableLevel: Bool

    public init(_ mon: Gen3Mon) {
        nickname = mon.nickname
        otName = mon.otName
        trainerID = mon.trainerID
        secretID = mon.secretID
        species = mon.species
        heldItem = mon.heldItem
        experience = mon.experience
        friendship = mon.friendship
        nature = mon.nature
        abilityBit = mon.abilityBit
        isShiny = mon.isShiny
        ivs = mon.ivs
        evs = mon.evs.isEmpty ? [0, 0, 0, 0, 0, 0] : mon.evs
        moves = mon.moves.isEmpty ? [0, 0, 0, 0] : mon.moves
        pp = mon.pp.isEmpty ? [0, 0, 0, 0] : mon.pp
        level = mon.level
        editableMoves = mon.storage.movesOffset != nil
        editableEVs = mon.storage.evsOffset != nil
        editableLevel = mon.storage.hasStatusBlock
    }

    /// True when applying this needs a new PID rather than a plain field write.
    public func needsNewPID(comparedTo mon: Gen3Mon) -> Bool {
        nature != mon.nature || abilityBit != mon.abilityBit || isShiny != mon.isShiny
            || trainerID != mon.trainerID || secretID != mon.secretID
    }
}

extension Gen3SaveFile {
    /// Finds a PID giving exactly this nature, ability bit and shininess.
    ///
    /// Nature is `pid % 25` and the ability bit is `pid & 1`, so together they pin
    /// the PID to one residue mod 50. Shininess constrains the low half-word to
    /// eight values per high half-word, so the two cases are searched differently:
    /// shiny by walking high half-words, non-shiny by stepping the residue class.
    public static func pid(nature: UInt8, abilityBit: UInt8, shiny: Bool,
                           trainerID: UInt16, secretID: UInt16,
                           near old: UInt32) -> UInt32? {
        let ts = trainerID ^ secretID
        var best: UInt32?
        var bestDistance = UInt32.max

        func consider(_ candidate: UInt32) {
            guard candidate % 25 == UInt32(nature), candidate & 1 == UInt32(abilityBit) else { return }
            let value = ts ^ UInt16(candidate >> 16) ^ UInt16(candidate & 0xFFFF)
            guard (value < 8) == shiny else { return }
            let distance = candidate > old ? candidate - old : old - candidate
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }

        if shiny {
            for high in 0...UInt32(0xFFFF) {
                for target in UInt16(0)..<8 {
                    consider(high << 16 | UInt32(ts ^ UInt16(high & 0xFFFF) ^ target))
                }
            }
        } else {
            // Walk outwards from the current PID within the residue class; almost
            // every PID is non-shiny, so this lands within a few steps.
            var step: UInt32 = 0
            while step < 50 * 4096, best == nil {
                for candidate in [old &+ step, old &- step] {
                    let aligned = candidate &- (candidate % 50)
                    for delta in UInt32(0)..<50 { consider(aligned &+ delta) }
                }
                step += 50
            }
        }
        return best
    }

    /// Writes a draft back, re-deriving the PID when nature, ability, shininess
    /// or trainer identity changed, then re-checksumming the section.
    ///
    /// Returns the Pokémon as stored afterwards, so callers can show what landed.
    @discardableResult
    public mutating func apply(_ draft: MonDraft, to mon: Gen3Mon) throws -> Gen3Mon {
        let storage = mon.storage
        let section = try sectionID(containing: mon.offset)
        let otid = UInt32(draft.secretID) << 16 | UInt32(draft.trainerID)

        var newPID = mon.pid
        if draft.needsNewPID(comparedTo: mon) {
            guard let found = Self.pid(nature: draft.nature, abilityBit: draft.abilityBit,
                                       shiny: draft.isShiny, trainerID: draft.trainerID,
                                       secretID: draft.secretID, near: mon.pid) else {
                throw Gen3SaveError.noPIDFound
            }
            newPID = found
        }

        // Start from the current plaintext so undecoded bytes survive untouched.
        var payload = Gen3Mon.payload(bytes: bytes, offset: mon.offset, pid: mon.pid,
                                      otid: mon.otid, encoding: encoding, storage: storage)
        func put16(_ value: UInt16, _ index: Int) {
            payload[index] = UInt8(value & 0xFF)
            payload[index + 1] = UInt8(value >> 8)
        }
        put16(draft.species, 0)
        put16(draft.heldItem, 2)
        for i in 0..<4 { payload[4 + i] = UInt8((draft.experience >> (8 * i)) & 0xFF) }
        payload[9] = draft.friendship
        if let movesOffset = storage.movesOffset {
            for i in 0..<4 { put16(draft.moves[i], movesOffset + i * 2) }
        }
        if let ppOffset = storage.ppOffset {
            for i in 0..<4 { payload[ppOffset + i] = draft.pp[i] }
        }
        if let evsOffset = storage.evsOffset {
            for i in 0..<6 { payload[evsOffset + i] = draft.evs[i] }
        }
        let ivWord = Gen3Mon.packIVs(draft.ivs, isEgg: mon.isEgg, abilityBit: draft.abilityBit)
        for i in 0..<4 {
            payload[storage.ivWordOffset + i] = UInt8((ivWord >> (8 * i)) & 0xFF)
        }

        // Header fields.
        write(newPID, at: mon.offset)
        write(otid, at: mon.offset + 4)
        bytes.replaceSubrange((mon.offset + 8)..<(mon.offset + 18),
                              with: Gen3Text.encode(draft.nickname, length: 10))
        bytes.replaceSubrange((mon.offset + 0x14)..<(mon.offset + 0x1B),
                              with: Gen3Text.encode(draft.otName, length: 7))
        if storage.hasStatusBlock, let level = draft.level {
            bytes[mon.offset + 0x54] = level
        }

        // Payload, re-encrypted and re-shuffled under the new key if required.
        if encoding == .vanilla, storage.payloadSize == 48 {
            var shuffled = [UInt8](repeating: 0, count: 48)
            for (slot, kind) in Array(Gen3Mon.substructOrder[Int(newPID % 24)]).enumerated() {
                let source = ["G", "A", "E", "M"].firstIndex(of: String(kind))! * 12
                shuffled.replaceSubrange((slot * 12)..<(slot * 12 + 12),
                                         with: payload[source..<(source + 12)])
            }
            let key = newPID ^ otid
            for i in stride(from: 0, to: 48, by: 4) {
                write(Gen3Checksum.load32(shuffled, i) ^ key, at: mon.offset + storage.payloadOffset + i)
            }
            var sum: UInt32 = 0
            for i in stride(from: 0, to: 48, by: 2) {
                sum &+= UInt32(payload[i]) | UInt32(payload[i + 1]) << 8
            }
            write(UInt16(sum & 0xFFFF), at: mon.offset + 0x1C)
        } else {
            bytes.replaceSubrange((mon.offset + storage.payloadOffset)..<(mon.offset + storage.payloadOffset + storage.payloadSize),
                                  with: payload)
        }

        try refreshChecksum(section: section)
        return Gen3Mon(bytes: bytes, offset: mon.offset, location: mon.location,
                       encoding: encoding, storage: storage)
    }
}
