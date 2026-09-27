import Testing
import Foundation
@testable import Gen3Save

/// Builds a save from scratch so the tests never need a real (personal) one.
/// `sectionLengths` is the whole point: a romhack sums different amounts per
/// section than vanilla does, and Hexeon must measure rather than assume.
struct SaveBuilder {
    var bytes = [UInt8](repeating: 0, count: 131_072)
    var magic: UInt32 = 0x0112_1999
    var sectionLengths: [UInt16: Int] = [1: 4084]
    var defaultLength = 3968

    mutating func write(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }
    mutating func write(_ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8(value >> 8)
    }

    /// Sections are stored rotated in a real save; rotate here too so the tests
    /// exercise the id→offset mapping instead of assuming file order.
    func offset(slot: Int, sectionID: UInt16, rotation: Int) -> Int {
        let position = (Int(sectionID) + rotation) % 14
        return slot * 0xE000 + position * 0x1000
    }

    mutating func addMon(slot: Int, rotation: Int, pid: UInt32, otid: UInt32,
                         species: UInt16, level: UInt8, nickname: String,
                         encoding: MonEncoding) {
        let base = offset(slot: slot, sectionID: 1, rotation: rotation)
        bytes[base + 0x34] = 1
        writeMon(at: base + 0x38, pid: pid, otid: otid, species: species,
                 level: level, nickname: nickname, encoding: encoding,
                 storage: .party)
    }

    /// PC entries start 4 bytes into section 5 (after the current-box index) and
    /// repeat at the storage stride.
    mutating func addBoxMon(slot: Int, rotation: Int, index: Int, pid: UInt32,
                            otid: UInt32, species: UInt16, nickname: String,
                            encoding: MonEncoding, storage: MonStorage) {
        let base = offset(slot: slot, sectionID: 5, rotation: rotation)
        writeMon(at: base + 4 + index * storage.totalSize, pid: pid, otid: otid,
                 species: species, level: 0, nickname: nickname,
                 encoding: encoding, storage: storage)
    }

    mutating func writeMon(at mon: Int, pid: UInt32, otid: UInt32, species: UInt16,
                           level: UInt8, nickname: String, encoding: MonEncoding,
                           storage: MonStorage) {
        write(pid, at: mon)
        write(otid, at: mon + 4)
        bytes.replaceSubrange((mon + 8)..<(mon + 18),
                              with: Gen3Text.encode(nickname, length: 10))
        bytes.replaceSubrange((mon + 0x14)..<(mon + 0x1B),
                              with: Gen3Text.encode("Shin", length: 7))
        bytes[mon + 0x12] = 2   // language
        var payload = [UInt8](repeating: 0, count: storage.payloadSize)
        payload[0] = UInt8(species & 0xFF)
        payload[1] = UInt8(species >> 8)
        payload[4] = 0xA0; payload[5] = 0x0E          // experience
        payload[9] = 90                               // friendship
        if storage.payloadSize == 48 {
            payload[12] = 33                          // Tackle
            payload[24] = 13                          // an EV, so the block isn't all zero
        }
        if storage.hasStatusBlock {
            bytes[mon + 0x54] = level
            write(UInt16(45), at: mon + 0x56)
            write(UInt16(45), at: mon + 0x58)
        }

        let usesChecksum = storage.payloadOffset >= 0x20
        switch encoding {
        case .plain:
            bytes.replaceSubrange((mon + storage.payloadOffset)..<(mon + storage.payloadOffset + storage.payloadSize),
                                  with: payload)
            if usesChecksum { write(UInt16(0), at: mon + 0x1C) }
        case .vanilla:
            var sum: UInt32 = 0
            for i in stride(from: 0, to: 48, by: 2) {
                sum &+= UInt32(payload[i]) | UInt32(payload[i + 1]) << 8
            }
            write(UInt16(sum & 0xFFFF), at: mon + 0x1C)
                let order = Array(Gen3Mon.substructOrder[Int(pid % 24)])
            var shuffled = [UInt8](repeating: 0, count: 48)
            for (slotIndex, kind) in order.enumerated() {
                let source = ["G", "A", "E", "M"].firstIndex(of: String(kind))! * 12
                shuffled.replaceSubrange((slotIndex * 12)..<(slotIndex * 12 + 12),
                                         with: payload[source..<(source + 12)])
            }
            let key = pid ^ otid
            for i in stride(from: 0, to: 48, by: 4) {
                write(Gen3Checksum.load32(shuffled, i) ^ key, at: mon + storage.payloadOffset + i)
            }
        }
    }

    /// Stamps footers last, so checksums cover whatever the test wrote.
    mutating func finalize(counters: [UInt32] = [4, 5], rotations: [Int] = [4, 5]) -> [UInt8] {
        for slot in 0..<2 {
            for id in UInt16(0)..<14 {
                let off = offset(slot: slot, sectionID: id, rotation: rotations[slot])
                let length = sectionLengths[id] ?? defaultLength
                write(id, at: off + 0xFF4)
                write(Gen3Checksum.value(bytes, offset: off, length: length), at: off + 0xFF6)
                write(magic, at: off + 0xFF8)
                write(counters[slot], at: off + 0xFFC)
            }
        }
        return bytes
    }
}

private func unboundLikeSave(encoding: MonEncoding = .plain,
                             pid: UInt32 = 0xB8D2_A29D,
                             otid: UInt32 = 0x8DAE_A1FF) throws -> Gen3SaveFile {
    var builder = SaveBuilder()
    builder.addMon(slot: 0, rotation: 4, pid: pid, otid: otid, species: 398,
                   level: 17, nickname: "Beldum", encoding: encoding)
    builder.addMon(slot: 1, rotation: 5, pid: pid, otid: otid, species: 398,
                   level: 17, nickname: "Beldum", encoding: encoding)
    return try Gen3SaveFile(bytes: builder.finalize())
}

@Test func readsRomhackSaveWithNonVanillaSectionLengths() throws {
    let save = try unboundLikeSave()
    #expect(save.activeSlot == 1)                    // higher counter wins
    #expect(save.isVanillaMagic == false)
    #expect(save.encoding == .plain)
    #expect(save.partyCount == 1)
    // The section-1 window must contain the 4084 the builder actually summed.
    #expect(save.lengthWindows[1]?.contains(4084) == true)

    let mon = try #require(save.party.first)
    #expect(mon.nickname == "Beldum")
    #expect(mon.species == 398)
    #expect(mon.level == 17)
    #expect(mon.moves.first == 33)
    #expect(mon.isShiny == false)
}

@Test func makeShinyPreservesEverythingElse() throws {
    var save = try unboundLikeSave()
    let before = try #require(save.party.first)
    let original = save.bytes

    try save.setShiny(save.party[0], true)
    let after = try #require(save.party.first)

    #expect(after.isShiny)
    #expect(after.shinyValue < 8)
    #expect(after.nature == before.nature)           // pid % 25 held
    #expect(after.abilityBit == before.abilityBit)
    #expect(after.species == before.species)
    #expect(after.level == before.level)
    #expect(after.moves == before.moves)
    #expect(after.experience == before.experience)
    #expect(save.validatesChecksums(slot: save.activeSlot))
    #expect(save.validatesChecksums(slot: 0))        // untouched fallback slot

    // Only the PID and one section checksum may move: 4 + 2 bytes.
    let changed = zip(original, save.bytes).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
    #expect(changed.count == 6)
    #expect(changed.allSatisfy { $0 >= 0xE000 })     // active slot only
}

@Test func vanillaSavesGetReEncryptedNotCorrupted() throws {
    var save = try unboundLikeSave(encoding: .vanilla)
    #expect(save.encoding == .vanilla)
    let before = try #require(save.party.first)

    try save.setShiny(save.party[0], true)
    let after = try #require(save.party.first)

    #expect(after.isShiny)
    // Payload survived the key change: it still decrypts to the same Pokémon.
    #expect(after.species == before.species)
    #expect(after.moves == before.moves)
    #expect(after.experience == before.experience)
    #expect(after.friendship == before.friendship)
    // And the game's own payload checksum agrees with the plaintext.
    let payload = Gen3Mon.payload(bytes: save.bytes, offset: after.offset,
                                  pid: after.pid, otid: after.otid,
                                  encoding: .vanilla, storage: .party)
    var sum: UInt32 = 0
    for i in stride(from: 0, to: 48, by: 2) {
        sum &+= UInt32(payload[i]) | UInt32(payload[i + 1]) << 8
    }
    let stored = UInt16(save.bytes[after.offset + 0x1C]) | UInt16(save.bytes[after.offset + 0x1D]) << 8
    #expect(UInt16(sum & 0xFFFF) == stored)
    #expect(save.validatesChecksums(slot: save.activeSlot))
}

@Test func shinyCanBeUndone() throws {
    var save = try unboundLikeSave()
    try save.setShiny(save.party[0], true)
    #expect(try #require(save.party.first).isShiny)
    try save.setShiny(save.party[0], false)
    let mon = try #require(save.party.first)
    #expect(mon.isShiny == false)
    #expect(save.validatesChecksums(slot: save.activeSlot))
}

@Test func rejectsFilesThatAreNotSaves() {
    #expect(throws: Gen3SaveError.self) {
        _ = try Gen3SaveFile(bytes: [UInt8](repeating: 0, count: 1024))
    }
}

@Test func textCodecRoundTrips() {
    let encoded = Gen3Text.encode("Beldum", length: 10)
    #expect(encoded.count == 10)
    #expect(Gen3Text.decode(encoded) == "Beldum")
    #expect(encoded.last == Gen3Text.terminator)
}

/// Opt-in end-to-end check against a save on disk, so you can validate Hexeon
/// on your own game without that save ever entering the repo.
///
///   HEXEON_TEST_SAVE=/path/to/save.sav \
///   HEXEON_TEST_INDEX=2 \
///   HEXEON_TEST_EXPECT=/path/to/known-good-output.sav \
///   swift test
@Test(.enabled(if: ProcessInfo.processInfo.environment["HEXEON_TEST_SAVE"] != nil))
func realSaveMatchesKnownGoodOutput() throws {
    let env = ProcessInfo.processInfo.environment
    var save = try Gen3SaveFile(contentsOf: URL(fileURLWithPath: env["HEXEON_TEST_SAVE"]!))
    let index = Int(env["HEXEON_TEST_INDEX"] ?? "0") ?? 0

    print("magic \(String(format: "%08X", save.magic)) · \(save.encoding.rawValue) · slot \(save.activeSlot) · PC slots \(save.boxStorage?.totalSize ?? 0)B")
    for mon in save.allMons {
        let where_ = mon.isParty ? "party" : "PC   "
        let level = mon.level.map { " Lv\($0)" } ?? ""
        print("  \(where_) \(mon.slotNumber). \(mon.nickname) species=\(mon.species)\(level) sv=\(mon.shinyValue)\(mon.isShiny ? " SHINY" : "")")
    }

    try save.setShiny(save.party[index], true)
    #expect(save.party[index].isShiny)
    #expect(save.validatesChecksums(slot: save.activeSlot))

    if let expected = env["HEXEON_TEST_EXPECT"] {
        let reference = [UInt8](try Data(contentsOf: URL(fileURLWithPath: expected)))
        #expect(save.bytes == reference, "output differs from the known-good file")
    }
}


// MARK: - PC storage

/// Unbound stores PC entries in 58 bytes with the payload at +0x1C; vanilla uses
/// 80 bytes at +0x20. Hexeon has to work out which from the bytes alone.
private func saveWithBox(storage: MonStorage, encoding: MonEncoding,
                         count: Int = 3) throws -> Gen3SaveFile {
    var builder = SaveBuilder()
    let names = ["Flabébé", "Cutiefly", "Slowpoke"]
    let species: [UInt16] = [840, 959, 79]
    for slot in 0..<2 {
        let rotation = slot == 0 ? 4 : 5
        builder.addMon(slot: slot, rotation: rotation, pid: 0xB8D2_A29D, otid: 0x8DAE_A1FF,
                       species: 398, level: 17, nickname: "Beldum", encoding: encoding)
        for i in 0..<count {
            builder.addBoxMon(slot: slot, rotation: rotation, index: i,
                              pid: 0x5ABA_B859 &+ UInt32(i &* 7919), otid: 0x8DAE_A1FF,
                              species: species[i], nickname: names[i],
                              encoding: encoding, storage: storage)
        }
    }
    return try Gen3SaveFile(bytes: builder.finalize())
}

@Test(arguments: [(MonStorage.boxCompact, MonEncoding.plain),
                  (MonStorage.boxVanilla, MonEncoding.vanilla)])
func detectsPCLayoutFromTheBytes(storage: MonStorage, encoding: MonEncoding) throws {
    let save = try saveWithBox(storage: storage, encoding: encoding)
    #expect(save.encoding == encoding)
    #expect(save.boxStorage == storage)
    #expect(save.boxes.count == 3)
    #expect(save.boxes.map(\.species) == [840, 959, 79])
    #expect(save.boxes.map(\.nickname) == ["Flabébé", "Cutiefly", "Slowpoke"])
    #expect(save.boxes.allSatisfy { !$0.isParty })
    #expect(save.boxes.allSatisfy { $0.level == nil })   // no status block in the PC
    #expect(save.party.count == 1)                       // party still parsed separately
}

@Test(arguments: [(MonStorage.boxCompact, MonEncoding.plain),
                  (MonStorage.boxVanilla, MonEncoding.vanilla)])
func shinyWorksOnPCPokemonToo(storage: MonStorage, encoding: MonEncoding) throws {
    var save = try saveWithBox(storage: storage, encoding: encoding)
    let before = save.boxes[1]
    let neighbours = [save.boxes[0].pid, save.boxes[2].pid]
    #expect(before.isShiny == false)

    try save.setShiny(before, true)
    let after = save.boxes[1]

    #expect(after.isShiny)
    #expect(after.species == before.species)
    #expect(after.nickname == before.nickname)
    #expect(after.nature == before.nature)
    #expect(after.experience == before.experience)
    #expect(save.validatesChecksums(slot: save.activeSlot))
    #expect(save.validatesChecksums(slot: 0))
    // Its neighbours in the PC are untouched.
    #expect([save.boxes[0].pid, save.boxes[2].pid] == neighbours)
    #expect(save.boxes.count == 3)
}

@Test func emptyPCIsNotMistakenForPokemon() throws {
    var builder = SaveBuilder()
    builder.addMon(slot: 0, rotation: 4, pid: 0xB8D2_A29D, otid: 0x8DAE_A1FF,
                   species: 398, level: 17, nickname: "Beldum", encoding: .plain)
    builder.addMon(slot: 1, rotation: 5, pid: 0xB8D2_A29D, otid: 0x8DAE_A1FF,
                   species: 398, level: 17, nickname: "Beldum", encoding: .plain)
    let save = try Gen3SaveFile(bytes: builder.finalize())
    #expect(save.boxes.isEmpty)
    #expect(save.boxStorage == nil)
    #expect(save.party.count == 1)
}

// MARK: - Full field editing

@Test(arguments: [(MonStorage.boxCompact, MonEncoding.plain),
                  (MonStorage.boxVanilla, MonEncoding.vanilla)])
func everyDirectFieldRoundTrips(storage: MonStorage, encoding: MonEncoding) throws {
    var save = try saveWithBox(storage: storage, encoding: encoding)
    let mon = save.party[0]                      // party is always the 48-byte layout
    var draft = MonDraft(mon)
    draft.nickname = "Sparky"
    draft.otName = "Ash"
    draft.species = 412
    draft.heldItem = 13
    draft.experience = 125_000
    draft.friendship = 200
    draft.ivs = [31, 30, 29, 28, 27, 26]
    draft.evs = [252, 128, 4, 6, 8, 10]
    draft.moves = [33, 85, 91, 247]
    draft.pp = [35, 15, 20, 15]
    draft.level = 42

    let after = try save.apply(draft, to: mon)

    #expect(after.nickname == "Sparky")
    #expect(after.otName == "Ash")
    #expect(after.species == 412)
    #expect(after.heldItem == 13)
    #expect(after.experience == 125_000)
    #expect(after.friendship == 200)
    #expect(after.ivs == [31, 30, 29, 28, 27, 26])
    #expect(after.evs == [252, 128, 4, 6, 8, 10])
    #expect(after.moves == [33, 85, 91, 247])
    #expect(after.pp == [35, 15, 20, 15])
    #expect(after.level == 42)
    #expect(save.validatesChecksums(slot: save.activeSlot))
    // Re-reading from a fresh parse of the bytes must agree — proves it is really
    // on disk in the right encoding, not just in the returned struct.
    let reloaded = try Gen3SaveFile(bytes: save.bytes)
    #expect(reloaded.party[0].nickname == "Sparky")
    #expect(reloaded.party[0].ivs == [31, 30, 29, 28, 27, 26])
    #expect(reloaded.party[0].moves == [33, 85, 91, 247])
}

@Test func editingNatureFindsAPIDThatKeepsShininessAndAbility() throws {
    var save = try unboundLikeSave()
    let mon = save.party[0]
    for nature in UInt8(0)..<25 {
        for ability in UInt8(0)...1 {
            for shiny in [false, true] {
                var draft = MonDraft(mon)
                draft.nature = nature
                draft.abilityBit = ability
                draft.isShiny = shiny
                let after = try save.apply(draft, to: mon)
                #expect(after.nature == nature)
                #expect(after.abilityBit == ability)
                #expect(after.isShiny == shiny)
                #expect(after.species == mon.species)   // untouched by the PID change
                #expect(save.validatesChecksums(slot: save.activeSlot))
            }
        }
    }
}

@Test func changingTrainerIDKeepsTheRequestedShininess() throws {
    var save = try unboundLikeSave()
    let mon = save.party[0]
    var draft = MonDraft(mon)
    draft.trainerID = 12345
    draft.secretID = 54321
    draft.isShiny = true

    let after = try save.apply(draft, to: mon)
    #expect(after.trainerID == 12345)
    #expect(after.secretID == 54321)
    #expect(after.isShiny)          // shiny relative to the NEW trainer, not the old
    #expect(after.shinyValue < 8)
    #expect(save.validatesChecksums(slot: save.activeSlot))
}

@Test func compactPCEntriesEditWhatTheyCanAndLeaveTheRestAlone() throws {
    var save = try saveWithBox(storage: .boxCompact, encoding: .plain)
    let mon = save.boxes[0]
    #expect(mon.storage.movesOffset == nil)

    let untouchedBefore = Array(save.bytes[(mon.offset + 0x1C + 10)..<(mon.offset + 0x1C + 22)])
    var draft = MonDraft(mon)
    #expect(draft.editableMoves == false)
    #expect(draft.editableEVs == false)
    draft.species = 500
    draft.ivs = [1, 2, 3, 4, 5, 6]
    draft.nickname = "Renamed"

    let after = try save.apply(draft, to: mon)
    #expect(after.species == 500)
    #expect(after.ivs == [1, 2, 3, 4, 5, 6])
    #expect(after.nickname == "Renamed")
    // The 12 bytes we cannot decode must come through byte-identical.
    let untouchedAfter = Array(save.bytes[(mon.offset + 0x1C + 10)..<(mon.offset + 0x1C + 22)])
    #expect(untouchedAfter == untouchedBefore)
    #expect(save.validatesChecksums(slot: save.activeSlot))
}

@Test func ivsClampInsteadOfOverflowingIntoNeighbouringFields() throws {
    var save = try unboundLikeSave()
    let mon = save.party[0]
    var draft = MonDraft(mon)
    draft.ivs = [99, 99, 99, 99, 99, 99]
    let after = try save.apply(draft, to: mon)
    #expect(after.ivs == [31, 31, 31, 31, 31, 31])
    #expect(after.isEgg == mon.isEgg)
    #expect(save.validatesChecksums(slot: save.activeSlot))
}

// MARK: - Mining names out of a ROM

/// Builds a fake ROM with name tables at an arbitrary offset and width, so table
/// discovery is tested without shipping (or needing) a real ROM.
private func fakeROM(speciesWidth: Int, moveWidth: Int, uppercase: Bool,
                     speciesAt: Int = 0x2A_1000, movesAt: Int = 0x31_7000,
                     size: Int = 0x40_0000) -> [UInt8] {
    var rom = [UInt8](repeating: 0, count: size)
    // Deterministic filler that can't be mistaken for Gen 3 text runs.
    var state: UInt32 = 0x1234_5678
    for i in 0..<size {
        state = state &* 1_664_525 &+ 1_013_904_223
        rom[i] = UInt8(0xF0 | (state >> 24) & 0x0F)
    }
    func plant(_ names: [String], at start: Int, width: Int) {
        for (index, name) in names.enumerated() {
            let text = uppercase ? name.uppercased() : name
            let encoded = Gen3Text.encode(text, length: width)
            rom.replaceSubrange((start + index * width)..<(start + index * width + width),
                                with: encoded)
        }
    }
    plant(["??????????", "Bulbasaur", "Ivysaur", "Venusaur", "Charmander",
           "Charmeleon", "Charizard", "Squirtle", "Beldum", "Flabébé"],
          at: speciesAt, width: speciesWidth)
    plant(["-", "Pound", "Karate Chop", "Double Slap", "Comet Punch",
           "Mega Punch", "Pay Day", "Fire Punch", "Double-Edge"],
          at: movesAt, width: moveWidth)
    return rom
}

@Test(arguments: [(11, 13, false), (11, 13, true), (13, 17, false), (12, 14, true)])
func minesNameTablesAtAnyWidthOrCase(speciesWidth: Int, moveWidth: Int, uppercase: Bool) throws {
    let rom = fakeROM(speciesWidth: speciesWidth, moveWidth: moveWidth, uppercase: uppercase)
    let tables = RomTables.mine(rom: rom, romName: "test.gba")

    // Index 1 is Bulbasaur in every Gen 3 game, so ids must line up exactly.
    #expect(RomTables.normalize(tables.speciesName(1) ?? "") == "bulbasaur")
    #expect(RomTables.normalize(tables.speciesName(4) ?? "") == "charmander")
    #expect(RomTables.normalize(tables.speciesName(8) ?? "") == "beldum")
    #expect(RomTables.normalize(tables.moveName(1) ?? "") == "pound")
    #expect(RomTables.normalize(tables.moveName(2) ?? "") == "karatechop")
    #expect(RomTables.normalize(tables.moveName(8) ?? "") == "doubleedge")
    #expect(tables.romName == "test.gba")
}

@Test func minedNamesSurviveAccentsAndPunctuation() throws {
    let rom = fakeROM(speciesWidth: 11, moveWidth: 13, uppercase: false)
    let tables = RomTables.mine(rom: rom)
    #expect(tables.speciesName(9) == "Flabébé")
    #expect(tables.moveName(8) == "Double-Edge")
}

@Test func miningAFileThatIsNotAROMYieldsNothingRatherThanNonsense() throws {
    var rom = [UInt8](repeating: 0, count: 0x10_000)
    for i in 0..<rom.count { rom[i] = UInt8(i % 251) }
    let tables = RomTables.mine(rom: rom)
    #expect(tables.isEmpty)
}

@Test func tablesEncodeAndDecodeForCaching() throws {
    let tables = RomTables.mine(rom: fakeROM(speciesWidth: 11, moveWidth: 13, uppercase: false),
                                romName: "unbound.gba")
    let restored = try JSONDecoder().decode(RomTables.self,
                                            from: try JSONEncoder().encode(tables))
    #expect(restored == tables)
    #expect(restored.speciesName(1) == "Bulbasaur")
}

/// Opt-in: mine a real ROM and optionally dump the tables as JSON, which is how
/// the bundled name data in this repo was produced.
///
///   HEXEON_ROM=/path/to/rom.gba HEXEON_ROM_OUT=Sources/Hexeon/Names/game.json \
///   HEXEON_ROM_MAGIC=01121999 swift test --filter minesRealROM
@Test(.enabled(if: ProcessInfo.processInfo.environment["HEXEON_ROM"] != nil))
func minesRealROM() throws {
    let env = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: env["HEXEON_ROM"]!)
    var tables = try RomTables.mine(romAt: url)
    if let magic = env["HEXEON_ROM_MAGIC"], let value = UInt32(magic, radix: 16) {
        tables.saveMagic = value
    }
    print("\(tables.romName): \(tables.species.count) species, \(tables.moves.count) moves")
    for id in [UInt16(1), 79, 398, 777, 840, 959] {
        print("  species \(id) = \(tables.speciesName(id) ?? "—")")
    }
    for id in [UInt16(1), 33, 499] {
        print("  move \(id) = \(tables.moveName(id) ?? "—")")
    }
    #expect(!tables.isEmpty)
    if let out = env["HEXEON_ROM_OUT"] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(tables).write(to: URL(fileURLWithPath: out))
    }
}

/// The committed name data must stay loadable and correct — it ships to users, so
/// a bad regeneration should fail CI rather than quietly break names in the app.
@Test func bundledUnboundNamesAreValid() throws {
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let file = repo.appendingPathComponent("Sources/Hexeon/Names/unbound-v2.1.1.1.json")
    let tables = try JSONDecoder().decode(RomTables.self, from: try Data(contentsOf: file))

    #expect(tables.saveMagic == 0x0112_1999)          // Unbound's footer magic
    #expect(tables.species.count > 1200)
    #expect(tables.moves.count > 900)
    // Spot-check ids taken from a real Unbound save's party and PC.
    #expect(tables.speciesName(398) == "Beldum")
    #expect(tables.speciesName(820) == "Bergmite")
    #expect(tables.speciesName(959) == "Cutiefly")
    #expect(tables.speciesName(840) == "Flabébé")
    #expect(tables.speciesName(989) == "Type: Null")
    #expect(tables.moveName(33) == "Tackle")
    #expect(tables.moveName(499) == "Metal Bash")
    // Tables must stop where the game's data stops, not run into dialogue.
    #expect(tables.moveName(923) == nil)
    #expect(tables.species.values.allSatisfy { $0.first?.isUppercase == true })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HEXEON_ROM"] != nil))
func minesBattleDataAndLearnsets() throws {
    let tables = try RomTables.mine(romAt: URL(fileURLWithPath: ProcessInfo.processInfo.environment["HEXEON_ROM"]!))
    print("types \(tables.typeNames.count) · stats \(tables.moveStats.count) · descriptions \(tables.moveDescriptions.count) · learnsets \(tables.learnsets.count) · TMs \(tables.tmMoves.count)")
    for id in [UInt16(1), 33, 52, 86, 347] {
        if let s = tables.stats(forMove: id) {
            print("  \(tables.moveName(id) ?? "?"): \(s.power) power, \(tables.typeName(s.type)), \(s.accuracy)%, \(s.pp) PP, \(s.categoryName), changesStats=\(tables.changesStats(move: id))")
        }
    }
    print("  Bulbasaur learnset: \(tables.learnset(species: 1).prefix(5).map { "\(tables.moveName($0.move) ?? "?")@\($0.level)" })")
    print("  Beldum learnset: \(tables.learnset(species: 398).map { "\(tables.moveName($0.move) ?? "?")@\($0.level)" })")
    print("  Beldum knows Tackle? \(tables.legality(species: 398, move: 33))")
    print("  Beldum knows Surf? \(tables.legality(species: 398, move: 57))")
    #expect(!tables.moveStats.isEmpty)
    #expect(!tables.learnsets.isEmpty)
}

// MARK: - Move browsing data

/// Small hand-built tables, so filter and legality behaviour is tested without a ROM.
private func handMadeTables() -> RomTables {
    var tables = RomTables(species: [1: "Bulbasaur", 398: "Beldum"],
                           moves: [33: "Tackle", 14: "Swords Dance", 86: "Thunder Wave",
                                   57: "Surf", 499: "Metal Bash"],
                           romName: "hand.gba")
    tables.typeNames = [0: "Normal", 8: "Steel", 13: "Electric", 11: "Water"]
    tables.moveStats = [
        33: MoveStats(power: 40, type: 0, accuracy: 100, pp: 35, effectChance: 0, category: 0),
        14: MoveStats(power: 0, type: 0, accuracy: 0, pp: 30, effectChance: 0, category: 2),
        86: MoveStats(power: 0, type: 13, accuracy: 100, pp: 20, effectChance: 0, category: 2),
        57: MoveStats(power: 95, type: 11, accuracy: 100, pp: 15, effectChance: 0, category: 1),
    ]
    tables.moveDescriptions = [
        33: "A physical attack in which the user charges into the foe.",
        14: "A frenetic dance. It sharply raises the Attack stat.",
        86: "A weak jolt of electricity that paralyzes the foe.",
        57: "The user swamps the battlefield with a giant wave.",
    ]
    tables.learnsets = [398: [LearnedMove(move: 33, level: 1), LearnedMove(move: 499, level: 10)]]
    tables.tmMoves = [57]
    return tables
}

@Test func statChangingMovesComeFromDescriptionsNotEffectBytes() {
    let tables = handMadeTables()
    // Swords Dance raises a stat; Thunder Wave is a status move that does not.
    #expect(tables.changesStats(move: 14))
    #expect(tables.changesStats(move: 86) == false)
    #expect(tables.changesStats(move: 33) == false)
    // Both are category 2, so category alone could not have told them apart.
    #expect(tables.stats(forMove: 14)?.category == tables.stats(forMove: 86)?.category)
}

@Test func legalityNeverCallsATMMoveIllegal() {
    let tables = handMadeTables()
    #expect(tables.legality(species: 398, move: 33) == .learnsAtLevel(1))
    #expect(tables.legality(species: 398, move: 499) == .learnsAtLevel(10))
    // Surf is a TM: unverifiable, so it must not be flagged.
    #expect(tables.legality(species: 398, move: 57) == .tmOrHmMove)
    #expect(tables.legality(species: 398, move: 57).isFlagged == false)
    // Swords Dance is neither in the learnset nor a TM — that is worth flagging.
    #expect(tables.legality(species: 398, move: 14) == .notInLearnset)
    #expect(tables.legality(species: 398, move: 14).isFlagged)
    // A species with no learnset data must never be flagged on no evidence.
    #expect(tables.legality(species: 1, move: 14) == .unknown)
    #expect(tables.legality(species: 1, move: 14).isFlagged == false)
    #expect(tables.legality(species: 398, move: 0) == .unknown)
}

@Test func battleDataSurvivesTheRoundTripToJSON() throws {
    let restored = try JSONDecoder().decode(RomTables.self,
                                            from: try JSONEncoder().encode(handMadeTables()))
    #expect(restored.stats(forMove: 57)?.power == 95)
    #expect(restored.stats(forMove: 57)?.category == 1)
    #expect(restored.typeName(11) == "Water")
    #expect(restored.learnset(species: 398) == [LearnedMove(move: 33, level: 1),
                                                LearnedMove(move: 499, level: 10)])
    #expect(restored.tmMoves == [57])
    #expect(restored.changesStats(move: 14))
}

@Test func bundledUnboundBattleDataIsValid() throws {
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let file = repo.appendingPathComponent("Sources/Hexeon/Names/unbound-v2.1.1.1.json")
    let tables = try JSONDecoder().decode(RomTables.self, from: try Data(contentsOf: file))

    #expect(tables.moveStats.count > 600)
    #expect(tables.learnsets.count > 1200)
    #expect(tables.tmMoves.count == 58)
    #expect(tables.typeName(0) == "Normal")
    #expect(tables.typeName(10) == "Fire")          // vanilla ids: 9 is unused
    #expect(tables.stats(forMove: 33)?.power == 40) // Tackle
    #expect(tables.stats(forMove: 52)?.category == 1) // Ember is special
    #expect(tables.changesStats(move: 347))         // Calm Mind
    #expect(tables.changesStats(move: 33) == false) // Tackle
    // Beldum's level-up learnset must match the moves a real Unbound Beldum has.
    let beldum = tables.learnset(species: 398).map(\.move)
    #expect(beldum.contains(33) && beldum.contains(148) && beldum.contains(499))
    #expect(tables.legality(species: 398, move: 33) == .learnsAtLevel(1))
}
