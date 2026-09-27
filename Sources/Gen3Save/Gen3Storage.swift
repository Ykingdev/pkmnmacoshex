import Foundation

// MARK: - Reading Pokémon out of a save

extension Gen3SaveFile {
    /// Section 1 holds the head of SaveBlock1, where the party lives. Romhacks
    /// that resize sections still keep these two offsets.
    public var partyCount: Int {
        guard let base = try? offset(ofSection: 1) else { return 0 }
        return min(Int(bytes[base + 0x34]), 6)
    }

    public var party: [Gen3Mon] {
        guard let base = try? offset(ofSection: 1) else { return [] }
        return (0..<partyCount).map { index in
            Gen3Mon(bytes: bytes, offset: base + 0x38 + index * MonStorage.party.totalSize,
                    location: .party(index), encoding: encoding, storage: .party)
        }
    }

    public var boxes: [Gen3Mon] {
        guard let storage = boxStorage else { return [] }
        return boxSlots.enumerated().map { index, offset in
            Gen3Mon(bytes: bytes, offset: offset, location: .box(index),
                    encoding: encoding, storage: storage)
        }
    }

    public var allMons: [Gen3Mon] { party + boxes }

    /// Finds PC entries by scanning sections 5–13 for anything that validates as
    /// a stored Pokémon, then locking onto that stride.
    ///
    /// The PC is logically one buffer spread over those sections, but where it
    /// splits depends on per-section lengths a romhack is free to change — so
    /// rather than reassemble it, scan each section independently. The cost is
    /// that an entry whose header straddles a section boundary is skipped, and
    /// `skippedBoundarySlots` reports how many.
    static func findBoxSlots(bytes: [UInt8], sectionOffsets: [UInt16: Int],
                             encoding: MonEncoding,
                             storage: MonStorage) -> (slots: [Int], skipped: Int) {
        var slots: [Int] = []
        var skipped = 0
        for id in UInt16(5)...13 {
            guard let base = sectionOffsets[id] else { continue }
            let limit = base + sectionDataSize
            var anchor: Int?
            var probe = base
            while probe + storage.headerSize <= limit {
                if Gen3Mon.plausible(bytes: bytes, offset: probe,
                                     encoding: encoding, storage: storage) {
                    anchor = probe
                    break
                }
                probe += 2   // entry sizes are even, so half-word steps suffice
            }
            guard let start = anchor else { continue }
            var cursor = start
            while cursor + storage.headerSize <= limit {
                if Gen3Mon.plausible(bytes: bytes, offset: cursor,
                                     encoding: encoding, storage: storage) {
                    if cursor + storage.totalSize > limit {
                        skipped += 1
                    } else {
                        slots.append(cursor)
                    }
                }
                cursor += storage.totalSize
            }
        }
        return (slots, skipped)
    }
}
