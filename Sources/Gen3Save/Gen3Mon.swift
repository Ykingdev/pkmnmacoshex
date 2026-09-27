import Foundation

/// How a save stores the 48-byte Pokémon payload.
///
/// Vanilla games XOR it with `pid ^ otid`, shuffle the four 12-byte
/// substructures by `pid % 24`, and checksum it. Several romhacks (Pokémon
/// Unbound among them) drop all three, leaving the payload in plain order with
/// the checksum field zeroed.
public enum MonEncoding: String, Sendable {
    case vanilla
    case plain

    static func detect(bytes: [UInt8], partyOffset: Int) -> MonEncoding {
        guard partyOffset + Gen3Mon.size <= bytes.count else { return .vanilla }
        let stored = UInt16(bytes[partyOffset + 0x1C]) | UInt16(bytes[partyOffset + 0x1D]) << 8
        if stored == 0 { return .plain }
        let pid = Gen3Checksum.load32(bytes, partyOffset)
        let otid = Gen3Checksum.load32(bytes, partyOffset + 4)
        let payload = Gen3Mon.payload(bytes: bytes, offset: partyOffset, pid: pid,
                                      otid: otid, encoding: .vanilla)
        var sum: UInt32 = 0
        for i in stride(from: 0, to: 48, by: 2) {
            sum &+= UInt32(payload[i]) | UInt32(payload[i + 1]) << 8
        }
        return UInt16(sum & 0xFFFF) == stored ? .vanilla : .plain
    }
}

public struct Gen3Mon: Identifiable, Sendable {
    public static let size = 100
    /// `SaveBlock1 + 0x34` is the party count, `+0x38` the first Pokémon.
    /// Romhacks that expand section lengths still keep these offsets.
    public static let partyCountOffset = 0x34
    public static let partyOffset = 0x38
    public static let maxParty = 6

    public let id: Int
    public let offset: Int
    public let pid: UInt32
    public let otid: UInt32
    public let nickname: String
    public let otName: String
    public let species: UInt16
    public let heldItem: UInt16
    public let experience: UInt32
    public let friendship: UInt8
    public let moves: [UInt16]
    public let level: UInt8
    public let currentHP: UInt16
    public let maxHP: UInt16

    public var trainerID: UInt16 { UInt16(otid & 0xFFFF) }
    public var secretID: UInt16 { UInt16(otid >> 16) }
    /// Under 8 means shiny — the same rule in every Gen 3 game and hack.
    public var shinyValue: UInt16 {
        trainerID ^ secretID ^ UInt16(pid >> 16) ^ UInt16(pid & 0xFFFF)
    }
    public var isShiny: Bool { shinyValue < 8 }
    public var nature: UInt8 { UInt8(pid % 25) }
    public var abilityBit: UInt8 { UInt8(pid & 1) }

    static let substructOrder: [String] = [
        "GAEM", "GAME", "GEAM", "GEMA", "GMAE", "GMEA",
        "AGEM", "AGME", "AEGM", "AEMG", "AMGE", "AMEG",
        "EGAM", "EGMA", "EAGM", "EAMG", "EMGA", "EMAG",
        "MGAE", "MGEA", "MAGE", "MAEG", "MEGA", "MEAG",
    ]

    /// The 48-byte payload in canonical G/A/E/M order, decrypted if need be.
    static func payload(bytes: [UInt8], offset: Int, pid: UInt32, otid: UInt32,
                        encoding: MonEncoding) -> [UInt8] {
        let raw = Array(bytes[(offset + 0x20)..<(offset + 0x50)])
        guard encoding == .vanilla else { return raw }
        let key = pid ^ otid
        var decrypted = [UInt8](repeating: 0, count: 48)
        for i in stride(from: 0, to: 48, by: 4) {
            let word = Gen3Checksum.load32(raw, i) ^ key
            decrypted[i] = UInt8(word & 0xFF)
            decrypted[i + 1] = UInt8((word >> 8) & 0xFF)
            decrypted[i + 2] = UInt8((word >> 16) & 0xFF)
            decrypted[i + 3] = UInt8((word >> 24) & 0xFF)
        }
        var ordered = [UInt8](repeating: 0, count: 48)
        let order = Array(substructOrder[Int(pid % 24)])
        for (slot, kind) in order.enumerated() {
            let target = ["G", "A", "E", "M"].firstIndex(of: String(kind))!
            let src = slot * 12
            ordered.replaceSubrange((target * 12)..<(target * 12 + 12),
                                    with: decrypted[src..<(src + 12)])
        }
        return ordered
    }

    init(bytes: [UInt8], offset: Int, index: Int, encoding: MonEncoding) {
        let pid = Gen3Checksum.load32(bytes, offset)
        let otid = Gen3Checksum.load32(bytes, offset + 4)
        let payload = Self.payload(bytes: bytes, offset: offset, pid: pid,
                                   otid: otid, encoding: encoding)
        func u16(_ i: Int) -> UInt16 { UInt16(payload[i]) | UInt16(payload[i + 1]) << 8 }

        self.id = index
        self.offset = offset
        self.pid = pid
        self.otid = otid
        self.nickname = Gen3Text.decode(bytes[(offset + 8)..<(offset + 18)])
        self.otName = Gen3Text.decode(bytes[(offset + 0x14)..<(offset + 0x1B)])
        self.species = u16(0)
        self.heldItem = u16(2)
        self.experience = Gen3Checksum.load32(payload, 4)
        self.friendship = payload[9]
        self.moves = (0..<4).map { u16(12 + $0 * 2) }
        self.level = bytes[offset + 0x54]
        self.currentHP = UInt16(bytes[offset + 0x56]) | UInt16(bytes[offset + 0x57]) << 8
        self.maxHP = UInt16(bytes[offset + 0x58]) | UInt16(bytes[offset + 0x59]) << 8
    }
}

extension Gen3SaveFile {
    /// Section 1 holds the head of SaveBlock1, where the party lives.
    public var partyCount: Int {
        guard let base = try? offset(ofSection: 1) else { return 0 }
        return min(Int(bytes[base + Gen3Mon.partyCountOffset]), Gen3Mon.maxParty)
    }

    public var party: [Gen3Mon] {
        guard let base = try? offset(ofSection: 1) else { return [] }
        return (0..<partyCount).map {
            Gen3Mon(bytes: bytes, offset: base + Gen3Mon.partyOffset + $0 * Gen3Mon.size,
                    index: $0, encoding: encoding)
        }
    }

    /// Finds a PID that flips shininess while keeping nature and ability.
    ///
    /// Staying congruent mod 600 preserves `pid % 25` (nature) and `pid % 24`
    /// (substructure order), and — because 600 is even — the ability bit too.
    /// So the Pokémon is untouched apart from the sparkle.
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
                    let low = ts ^ UInt16(high & 0xFFFF) ^ target
                    consider(high << 16 | UInt32(low))
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

    /// Rewrites party member `index` to be shiny (or deliberately not), keeping
    /// species, stats, moves and nature untouched, then re-checksums section 1.
    public mutating func setShiny(partyIndex index: Int, _ shiny: Bool) throws {
        let mon = party[index]
        guard mon.isShiny != shiny else { return }
        guard let newPID = Self.repidded(from: mon.pid, trainerID: mon.trainerID,
                                         secretID: mon.secretID, shiny: shiny) else {
            throw Gen3SaveError.noShinyPIDFound
        }

        if encoding == .vanilla {
            // The payload is keyed on the PID, so re-encrypt under the new key.
            // Substructure order is preserved (pid % 24 is unchanged), and the
            // payload checksum covers plaintext, so it does not move.
            let plain = Gen3Mon.payload(bytes: bytes, offset: mon.offset, pid: mon.pid,
                                        otid: mon.otid, encoding: .vanilla)
            let order = Array(Gen3Mon.substructOrder[Int(newPID % 24)])
            var shuffled = [UInt8](repeating: 0, count: 48)
            for (slot, kind) in order.enumerated() {
                let source = ["G", "A", "E", "M"].firstIndex(of: String(kind))! * 12
                shuffled.replaceSubrange((slot * 12)..<(slot * 12 + 12),
                                         with: plain[source..<(source + 12)])
            }
            let key = newPID ^ mon.otid
            for i in stride(from: 0, to: 48, by: 4) {
                write(Gen3Checksum.load32(shuffled, i) ^ key, at: mon.offset + 0x20 + i)
            }
            var sum: UInt32 = 0
            for i in stride(from: 0, to: 48, by: 2) {
                sum &+= UInt32(plain[i]) | UInt32(plain[i + 1]) << 8
            }
            write(UInt16(sum & 0xFFFF), at: mon.offset + 0x1C)
        }

        write(newPID, at: mon.offset)
        try refreshChecksum(section: 1)
    }
}
