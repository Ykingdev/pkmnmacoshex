import Foundation

/// How a save stores the Pokémon payload.
///
/// Vanilla games XOR it with `pid ^ otid`, shuffle the four 12-byte
/// substructures by `pid % 24`, and checksum it. Several romhacks (Pokémon
/// Unbound among them) drop all three, leaving the payload in plain order with
/// the checksum field zeroed.
public enum MonEncoding: String, Sendable {
    case vanilla
    case plain
}

/// Where the fields of one stored Pokémon sit. Party entries follow the vanilla
/// 100-byte shape even in hacks; PC entries are where hacks economise.
public struct MonStorage: Sendable, Equatable {
    public let totalSize: Int
    public let payloadOffset: Int
    public let payloadSize: Int
    public let hasStatusBlock: Bool

    /// 80-byte core plus the 20-byte battle status block.
    public static let party = MonStorage(totalSize: 100, payloadOffset: 0x20,
                                         payloadSize: 48, hasStatusBlock: true)
    /// Vanilla PC entry: the same core, minus the status block.
    public static let boxVanilla = MonStorage(totalSize: 80, payloadOffset: 0x20,
                                              payloadSize: 48, hasStatusBlock: false)
    /// Unbound-style PC entry: no checksum field, 30-byte payload.
    public static let boxCompact = MonStorage(totalSize: 58, payloadOffset: 0x1C,
                                             payloadSize: 30, hasStatusBlock: false)
    public static let boxCandidates = [boxVanilla, boxCompact]

    /// Bytes that must be inside one section for us to read and re-PID an entry.
    var headerSize: Int { payloadOffset + 4 }
    var usesChecksum: Bool { payloadOffset >= 0x20 }
}

public struct Gen3Mon: Identifiable, Sendable {
    public enum Location: Sendable, Equatable {
        case party(Int)
        case box(Int)
    }

    public let location: Location
    public let offset: Int
    public let storage: MonStorage
    public let pid: UInt32
    public let otid: UInt32
    public let nickname: String
    public let otName: String
    public let species: UInt16
    public let heldItem: UInt16
    public let experience: UInt32
    public let friendship: UInt8
    public let moves: [UInt16]
    public let level: UInt8?
    public let currentHP: UInt16?
    public let maxHP: UInt16?

    public var id: Int { offset }
    public var isParty: Bool { if case .party = location { return true }; return false }
    public var slotNumber: Int {
        switch location {
        case .party(let i), .box(let i): return i + 1
        }
    }

    public var trainerID: UInt16 { UInt16(otid & 0xFFFF) }
    public var secretID: UInt16 { UInt16(otid >> 16) }
    /// Under 8 means shiny — the same rule in every Gen 3 game and hack.
    public var shinyValue: UInt16 {
        trainerID ^ secretID ^ UInt16(pid >> 16) ^ UInt16(pid & 0xFFFF)
    }
    public var isShiny: Bool { shinyValue < 8 }
    public var nature: UInt8 { UInt8(pid % 25) }
    public var abilityBit: UInt8 { UInt8(pid & 1) }
    public var displayName: String { nickname.isEmpty ? "#\(species)" : nickname }

    static let substructOrder: [String] = [
        "GAEM", "GAME", "GEAM", "GEMA", "GMAE", "GMEA",
        "AGEM", "AGME", "AEGM", "AEMG", "AMGE", "AMEG",
        "EGAM", "EGMA", "EAGM", "EAMG", "EMGA", "EMAG",
        "MGAE", "MGEA", "MAGE", "MAEG", "MEGA", "MEAG",
    ]

    /// The payload in canonical G/A/E/M order, decrypted if need be.
    static func payload(bytes: [UInt8], offset: Int, pid: UInt32, otid: UInt32,
                        encoding: MonEncoding, storage: MonStorage) -> [UInt8] {
        let start = offset + storage.payloadOffset
        let raw = Array(bytes[start..<(start + storage.payloadSize)])
        // Encryption and shuffling only ever apply to the 4×12 vanilla payload.
        guard encoding == .vanilla, storage.payloadSize == 48 else { return raw }
        let key = pid ^ otid
        var decrypted = [UInt8](repeating: 0, count: 48)
        for i in stride(from: 0, to: 48, by: 4) {
            let word = Gen3Checksum.load32(raw, i) ^ key
            for b in 0..<4 { decrypted[i + b] = UInt8((word >> (8 * b)) & 0xFF) }
        }
        var ordered = [UInt8](repeating: 0, count: 48)
        for (slot, kind) in Array(substructOrder[Int(pid % 24)]).enumerated() {
            let target = ["G", "A", "E", "M"].firstIndex(of: String(kind))! * 12
            ordered.replaceSubrange(target..<(target + 12),
                                    with: decrypted[(slot * 12)..<(slot * 12 + 12)])
        }
        return ordered
    }

    init(bytes: [UInt8], offset: Int, location: Location,
         encoding: MonEncoding, storage: MonStorage) {
        let pid = Gen3Checksum.load32(bytes, offset)
        let otid = Gen3Checksum.load32(bytes, offset + 4)
        let payload = Self.payload(bytes: bytes, offset: offset, pid: pid,
                                   otid: otid, encoding: encoding, storage: storage)
        func u16(_ i: Int) -> UInt16 {
            i + 1 < payload.count ? UInt16(payload[i]) | UInt16(payload[i + 1]) << 8 : 0
        }

        self.location = location
        self.offset = offset
        self.storage = storage
        self.pid = pid
        self.otid = otid
        self.nickname = Gen3Text.decode(bytes[(offset + 8)..<(offset + 18)])
        self.otName = Gen3Text.decode(bytes[(offset + 0x14)..<(offset + 0x1B)])
        self.species = u16(0)
        self.heldItem = u16(2)
        self.experience = payload.count >= 8 ? Gen3Checksum.load32(payload, 4) : 0
        self.friendship = payload.count > 9 ? payload[9] : 0
        // Compact payloads reorder everything after friendship; only read moves
        // from the layout we actually understand.
        self.moves = storage.payloadSize == 48 ? (0..<4).map { u16(12 + $0 * 2) } : []
        if storage.hasStatusBlock {
            self.level = bytes[offset + 0x54]
            self.currentHP = UInt16(bytes[offset + 0x56]) | UInt16(bytes[offset + 0x57]) << 8
            self.maxHP = UInt16(bytes[offset + 0x58]) | UInt16(bytes[offset + 0x59]) << 8
        } else {
            self.level = nil
            self.currentHP = nil
            self.maxHP = nil
        }
    }

    /// Does this look like a real stored Pokémon rather than noise?
    ///
    /// Used to find PC entries without knowing a hack's storage geometry, so it
    /// errs strict: a false positive would mean editing arbitrary save bytes.
    static func plausible(bytes: [UInt8], offset: Int,
                          encoding: MonEncoding, storage: MonStorage) -> Bool {
        guard offset >= 0, offset + storage.headerSize <= bytes.count else { return false }
        let pid = Gen3Checksum.load32(bytes, offset)
        let otid = Gen3Checksum.load32(bytes, offset + 4)
        guard pid != 0, otid != 0, pid != 0xFFFF_FFFF, otid != 0xFFFF_FFFF else { return false }
        guard (1...7).contains(bytes[offset + 0x12]) else { return false }       // language
        guard Gen3Text.isPrintable(bytes[(offset + 8)..<(offset + 18)], minLength: 1),
              Gen3Text.isPrintable(bytes[(offset + 0x14)..<(offset + 0x1B)], minLength: 1)
        else { return false }

        let payload = payload(bytes: bytes, offset: offset, pid: pid, otid: otid,
                              encoding: encoding, storage: storage)
        let species = UInt16(payload[0]) | UInt16(payload[1]) << 8
        let item = UInt16(payload[2]) | UInt16(payload[3]) << 8
        guard (1...1500).contains(species), item <= 1500 else { return false }
        guard Gen3Checksum.load32(payload, 4) <= 2_000_000 else { return false }  // experience

        if storage.usesChecksum {
            // The strongest signal available: the game's own payload checksum.
            var sum: UInt32 = 0
            for i in stride(from: 0, to: payload.count - 1, by: 2) {
                sum &+= UInt32(payload[i]) | UInt32(payload[i + 1]) << 8
            }
            let stored = UInt16(bytes[offset + 0x1C]) | UInt16(bytes[offset + 0x1D]) << 8
            return UInt16(sum & 0xFFFF) == stored
        }
        return true
    }
}
