import Foundation

public enum Gen3SaveError: Error, CustomStringConvertible {
    case tooSmall(Int)
    case noCompleteSlot
    case missingSection(UInt16)
    case ambiguousChecksum(section: UInt16, candidates: [Int])
    case noShinyPIDFound

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
            end of the summed region, and candidate lengths \(candidates.first!)–\
            \(candidates.last!) disagree. Refusing to guess.
            """
        case .noShinyPIDFound:
            return "No PID found that is shiny while preserving nature and ability."
        }
    }
}

/// A 128 KB GBA Pokémon save: two rotating 14-section slots, plus trailing
/// flash space the game uses for Hall of Fame and friends.
///
/// Nothing here assumes vanilla section *lengths* — those are measured from the
/// file — which is what lets romhack saves round-trip intact.
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

    public var magic: UInt32 { slots[activeSlot].magic }
    /// Vanilla Gen 3 games write this; romhacks often pick their own.
    public var isVanillaMagic: Bool { magic == 0x0801_2025 }

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
        self.encoding = MonEncoding.detect(bytes: input,
                                           partyOffset: (parsed[active].offsets[1] ?? 0) + Gen3Mon.partyOffset)
    }

    public init(contentsOf url: URL) throws {
        try self.init(bytes: [UInt8](Data(contentsOf: url)))
    }

    public func offset(ofSection id: UInt16, slot: Int? = nil) throws -> Int {
        guard let off = slots[slot ?? activeSlot].offsets[id] else {
            throw Gen3SaveError.missingSection(id)
        }
        return off
    }

    // MARK: - Writing

    mutating func write(_ value: UInt32, at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    mutating func write(_ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
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
}
