import Foundation

public enum Gen3SaveError: Error, CustomStringConvertible {
    case tooSmall(Int)
    case noCompleteSlot
    case missingSection(UInt16)
    case ambiguousChecksum(section: UInt16, candidates: [Int])
    case noPIDFound
    case notInASection(Int)

    public var description: String {
        switch self {
        case .tooSmall(let n):
            return "Not a GBA save: expected at least 114688 bytes, got \(n)."
        case .noCompleteSlot:
            return "Neither save slot has all 14 sections — file is corrupt or not a Gen 3 save."
        case .missingSection(let id):
            return "Save slot is missing section \(id)."
        case .ambiguousChecksum(let id, let candidates):
            return """
            Can't safely re-checksum section \(id): the edit changed bytes near the \
            end of the summed region, and candidate lengths \(candidates.first ?? 0)–\
            \(candidates.last ?? 0) disagree. Refusing to guess.
            """
        case .noPIDFound:
            return "No PID found with the requested shininess that also preserves nature and ability."
        case .notInASection(let offset):
            return "Offset \(offset) is not inside the active save slot."
        }
    }
}

/// A 128 KB GBA Pokémon save: two rotating 14-section slots, plus trailing flash
/// space the game uses for Hall of Fame and friends.
///
/// Nothing here hardcodes vanilla section *lengths* or storage geometry — both
/// are measured from the file — which is what lets romhack saves round-trip.
public struct Gen3SaveFile {
    public static let sectionSize = 0x1000
    public static let sectionDataSize = 0xFF4
    public static let sectionsPerSlot = 14
    public static let slotSize = sectionSize * sectionsPerSlot

    public struct Slot {
        public var offsets: [UInt16: Int]
        public var counter: UInt32
        public var magic: UInt32
        public var isComplete: Bool { offsets.count == Gen3SaveFile.sectionsPerSlot }
    }

    public private(set) var bytes: [UInt8]
    public let slots: [Slot]
    /// The slot the game will load: the complete one with the highest counter.
    public let activeSlot: Int
    /// Candidate summed lengths per section, agreed across both game-written
    /// slots. Captured at load time, before any edit perturbs them.
    public let lengthWindows: [UInt16: [Int]]
    public let encoding: MonEncoding
    /// Detected PC entry geometry, or nil when the PC is empty.
    public let boxStorage: MonStorage?
    public let boxSlots: [Int]
    /// PC entries whose header straddles a section boundary, so we left them be.
    public let skippedBoundarySlots: Int

    public var magic: UInt32 { slots[activeSlot].magic }
    /// Vanilla Gen 3 games write this; romhacks often pick their own.
    public var isVanillaMagic: Bool { magic == 0x0801_2025 }
    public var isVanillaLayout: Bool {
        isVanillaMagic && encoding == .vanilla && (boxStorage ?? .boxVanilla) == .boxVanilla
    }

    public init(bytes input: [UInt8]) throws {
        guard input.count >= Self.slotSize * 2 else { throw Gen3SaveError.tooSmall(input.count) }
        self.bytes = input

        var parsed: [Slot] = []
        for slot in 0..<2 {
            var offsets: [UInt16: Int] = [:]
            var counter: UInt32 = 0
            var magic: UInt32 = 0
            for i in 0..<Self.sectionsPerSlot {
                let base = slot * Self.slotSize + i * Self.sectionSize
                let id = UInt16(input[base + 0xFF4]) | UInt16(input[base + 0xFF5]) << 8
                guard id < UInt16(Self.sectionsPerSlot) else { continue }
                offsets[id] = base
                magic = Gen3Checksum.load32(input, base + 0xFF8)
                counter = Gen3Checksum.load32(input, base + 0xFFC)
            }
            parsed.append(Slot(offsets: offsets, counter: counter, magic: magic))
        }
        self.slots = parsed

        let complete = parsed.indices.filter { parsed[$0].isComplete }
        guard let active = complete.max(by: { parsed[$0].counter < parsed[$1].counter }) else {
            throw Gen3SaveError.noCompleteSlot
        }
        self.activeSlot = active

        var windows: [UInt16: [Int]] = [:]
        for id in 0..<UInt16(Self.sectionsPerSlot) {
            var sets: [Set<Int>] = []
            for slot in complete {
                guard let off = parsed[slot].offsets[id] else { continue }
                let stored = UInt16(input[off + 0xFF6]) | UInt16(input[off + 0xFF7]) << 8
                sets.append(Set(Gen3Checksum.matchingLengths(input, offset: off,
                                                             stored: stored,
                                                             maxLength: Self.sectionDataSize)))
            }
            // Intersecting the slots narrows the window; a lone slot still bounds it.
            let merged = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }
            windows[id] = (merged.isEmpty ? (sets.first ?? []) : merged).sorted()
        }
        self.lengthWindows = windows

        let sectionOffsets = parsed[active].offsets
        let detectedEncoding = Self.detectEncoding(bytes: input, sectionOffsets: sectionOffsets)
        self.encoding = detectedEncoding

        // Try every known PC geometry and keep whichever explains the most
        // entries, so a hack we've never seen still works if it reuses one.
        var bestStorage: MonStorage?
        var bestSlots: [Int] = []
        var bestSkipped = 0
        for candidate in MonStorage.boxCandidates {
            let found = Self.findBoxSlots(bytes: input, sectionOffsets: sectionOffsets,
                                          encoding: detectedEncoding, storage: candidate)
            if found.slots.count > bestSlots.count {
                bestStorage = candidate
                bestSlots = found.slots
                bestSkipped = found.skipped
            }
        }
        self.boxStorage = bestSlots.isEmpty ? nil : bestStorage
        self.boxSlots = bestSlots
        self.skippedBoundarySlots = bestSlots.isEmpty ? 0 : bestSkipped
    }

    public init(contentsOf url: URL) throws {
        try self.init(bytes: [UInt8](Data(contentsOf: url)))
    }

    /// Vanilla saves checksum each Pokémon's payload; the hacks that drop
    /// encryption zero that field, which makes the two trivially separable.
    static func detectEncoding(bytes: [UInt8], sectionOffsets: [UInt16: Int]) -> MonEncoding {
        guard let base = sectionOffsets[1] else { return .vanilla }
        let mon = base + 0x38
        guard mon + MonStorage.party.totalSize <= bytes.count else { return .vanilla }
        let stored = UInt16(bytes[mon + 0x1C]) | UInt16(bytes[mon + 0x1D]) << 8
        if stored == 0 { return .plain }
        return Gen3Mon.plausible(bytes: bytes, offset: mon, encoding: .vanilla,
                                 storage: .party) ? .vanilla : .plain
    }

    public func offset(ofSection id: UInt16, slot: Int? = nil) throws -> Int {
        guard let off = slots[slot ?? activeSlot].offsets[id] else {
            throw Gen3SaveError.missingSection(id)
        }
        return off
    }

    func sectionID(containing offset: Int) throws -> UInt16 {
        for (id, base) in slots[activeSlot].offsets
        where offset >= base && offset < base + Self.sectionDataSize {
            return id
        }
        throw Gen3SaveError.notInASection(offset)
    }

    // MARK: - Writing

    mutating func write(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    mutating func write(_ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8(value >> 8)
    }

    /// Recomputes a section's checksum over every plausible length and only
    /// commits when they agree — so a bad guess fails loudly instead of handing
    /// the console a save it will silently reject.
    public mutating func refreshChecksum(section id: UInt16) throws {
        let off = try offset(ofSection: id)
        let candidates = lengthWindows[id] ?? [Self.sectionDataSize]
        let values = Set(candidates.map {
            Gen3Checksum.value(bytes, offset: off, length: $0)
        })
        guard values.count == 1, let value = values.first else {
            throw Gen3SaveError.ambiguousChecksum(section: id, candidates: candidates)
        }
        write(value, at: off + 0xFF6)
    }

    /// Every section still self-consistent? Cheap post-edit sanity check.
    public func validatesChecksums(slot: Int) -> Bool {
        guard slots[slot].isComplete else { return false }
        for (_, off) in slots[slot].offsets {
            let stored = UInt16(bytes[off + 0xFF6]) | UInt16(bytes[off + 0xFF7]) << 8
            if Gen3Checksum.matchingLengths(bytes, offset: off, stored: stored,
                                            maxLength: Self.sectionDataSize).isEmpty {
                return false
            }
        }
        return true
    }

    public var data: Data { Data(bytes) }

    // MARK: - Shininess

    /// Finds a PID with the requested shininess that keeps nature and ability.
    ///
    /// Staying congruent mod 600 preserves `pid % 25` (nature) and `pid % 24`
    /// (substructure order), and — because 600 is even — the ability bit too. So
    /// the Pokémon is untouched apart from the sparkle.
    public static func repidded(from old: UInt32, trainerID: UInt16, secretID: UInt16,
                                shiny: Bool) -> UInt32? {
        let base = old % 600
        let ts = trainerID ^ secretID
        var best: UInt32?
        var bestDistance = UInt32.max

        func consider(_ candidate: UInt32) {
            guard candidate % 600 == base else { return }
            let value = ts ^ UInt16(candidate >> 16) ^ UInt16(candidate & 0xFFFF)
            guard (value < 8) == shiny else { return }
            let distance = candidate > old ? candidate - old : old - candidate
            if distance < bestDistance { bestDistance = distance; best = candidate }
        }

        if shiny {
            for high in 0...UInt32(0xFFFF) {
                for target in UInt16(0)..<8 {
                    consider(high << 16 | UInt32(ts ^ UInt16(high & 0xFFFF) ^ target))
                }
            }
        } else {
            // Non-shiny is dense: walk outwards from the current PID in steps of 600.
            var step: UInt32 = 0
            while step < 600 * 4096, best == nil {
                consider(old &+ step)
                consider(old &- step)
                step += 600
            }
        }
        return best
    }

    /// Rewrites a Pokémon to be shiny (or deliberately not), keeping species,
    /// stats, moves and nature untouched, then re-checksums its section.
    public mutating func setShiny(_ mon: Gen3Mon, _ shiny: Bool) throws {
        guard mon.isShiny != shiny else { return }
        guard let newPID = Self.repidded(from: mon.pid, trainerID: mon.trainerID,
                                         secretID: mon.secretID, shiny: shiny) else {
            throw Gen3SaveError.noPIDFound
        }
        let section = try sectionID(containing: mon.offset)

        if encoding == .vanilla, mon.storage.payloadSize == 48 {
            // The payload is keyed on the PID, so re-encrypt under the new key.
            // Substructure order is preserved (pid % 24 is unchanged) and the
            // payload checksum covers plaintext, so it does not move.
            let plain = Gen3Mon.payload(bytes: bytes, offset: mon.offset, pid: mon.pid,
                                        otid: mon.otid, encoding: .vanilla, storage: mon.storage)
            var shuffled = [UInt8](repeating: 0, count: 48)
            for (slot, kind) in Array(Gen3Mon.substructOrder[Int(newPID % 24)]).enumerated() {
                let source = ["G", "A", "E", "M"].firstIndex(of: String(kind))! * 12
                shuffled.replaceSubrange((slot * 12)..<(slot * 12 + 12),
                                         with: plain[source..<(source + 12)])
            }
            let key = newPID ^ mon.otid
            for i in stride(from: 0, to: 48, by: 4) {
                write(Gen3Checksum.load32(shuffled, i) ^ key,
                      at: mon.offset + mon.storage.payloadOffset + i)
            }
            var sum: UInt32 = 0
            for i in stride(from: 0, to: 48, by: 2) {
                sum &+= UInt32(plain[i]) | UInt32(plain[i + 1]) << 8
            }
            write(UInt16(sum & 0xFFFF), at: mon.offset + 0x1C)
        }

        write(newPID, at: mon.offset)
        try refreshChecksum(section: section)
    }
}
