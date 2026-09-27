import AppKit
import Foundation
import Observation
import Gen3Save

extension RomTables {
    /// Name tables mined from ROMs and shipped with the app, so a game we have
    /// data for shows names without the user supplying anything. Only names are
    /// bundled — never a ROM.
    static func bundled() -> [RomTables] {
        guard let directory = Bundle.module.url(forResource: "Names", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RomTables.self, from: data)
        }
    }

    /// Picks the bundled table whose game matches this save's footer magic.
    static func bundled(matching magic: UInt32) -> RomTables? {
        bundled().first { $0.saveMagic == magic }
    }
}

/// Supplies artwork for a Pokémon whose species number belongs to a romhack's
/// own table rather than the National Dex.
///
/// Three-step resolution, cheapest first:
///  1. a mapping learned earlier and saved to disk,
///  2. species ids ≤ 251, which equal National Dex numbers in every Gen 3 game
///     and in the FireRed-based hacks (verified: Slowpoke is 79 in both),
///  3. the nickname — an un-renamed Pokémon is named after its species, so the
///     save effectively carries its own species table. Matches are remembered,
///     so one un-renamed Flabébé teaches pkmnmacoshex what species 840 is for every
///     renamed one after it.
///
/// Artwork is fetched on demand and cached under ~/Library/Caches, never bundled
/// — partly to keep the app small, mostly so an open-source repo isn't
/// redistributing someone else's renders.
@Observable
@MainActor
final class SpriteLibrary {
    static let spriteBase = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/home"
    static let speciesIndexURL = "https://pokeapi.co/api/v2/pokemon-species?limit=1400"

    /// Names mined from a ROM, when one has been imported. Far better than the
    /// nickname heuristic: it resolves renamed Pokémon and every species at once.
    var romTables = RomTables()
    private(set) var learned: [UInt16: Int] = [:]
    private var nameToDex: [String: Int] = [:]
    private var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    /// Set when the network is unavailable, so the UI can say so once.
    private(set) var offline = false

    private let cacheDirectory: URL
    private let stateFile: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("pkmnmacoshex/sprites", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        stateFile = support.appendingPathComponent("pkmnmacoshex/species-map.json")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        loadState()
    }

    // MARK: - Species → National Dex

    /// Normalises "Flabébé" and "Mr. Mime" onto PokeAPI's "flabebe" / "mr-mime".
    static func normalize(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    func dexNumber(for mon: Gen3Mon) -> Int? {
        if let known = learned[mon.species] { return known }
        // A mined ROM name is authoritative; the nickname is only a fallback for
        // when no ROM has been imported.
        if let romName = romTables.speciesName(mon.species),
           let dex = nameToDex[Self.normalize(romName)] {
            learned[mon.species] = dex
            saveState()
            return dex
        }
        if mon.species >= 1, mon.species <= 251 { return Int(mon.species) }
        guard !nameToDex.isEmpty else { return nil }
        if let dex = nameToDex[Self.normalize(mon.nickname)] {
            learned[mon.species] = dex
            saveState()
            return dex
        }
        return nil
    }

    /// Teaches the library a species number by hand, for a renamed Pokémon whose
    /// species nothing else identifies.
    func assign(species: UInt16, dex: Int) {
        learned[species] = dex
        saveState()
    }

    func loadSpeciesIndex() async {
        guard nameToDex.isEmpty else { return }
        let indexFile = cacheDirectory.appendingPathComponent("species-index.json")
        if let data = try? Data(contentsOf: indexFile),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data),
           !decoded.isEmpty {
            nameToDex = decoded
            return
        }
        struct Response: Decodable {
            struct Entry: Decodable { let name: String; let url: String }
            let results: [Entry]
        }
        guard let url = URL(string: Self.speciesIndexURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            offline = true
            return
        }
        var map: [String: Int] = [:]
        for entry in response.results {
            let digits = entry.url.split(separator: "/").last { Int($0) != nil }
            if let id = digits.flatMap({ Int($0) }) { map[Self.normalize(entry.name)] = id }
        }
        nameToDex = map
        try? JSONEncoder().encode(map).write(to: indexFile)
    }

    // MARK: - Artwork

    private func key(_ dex: Int, _ shiny: Bool) -> String { "\(dex)\(shiny ? "-shiny" : "")" }

    func cachedSprite(for mon: Gen3Mon, shiny: Bool) -> NSImage? {
        guard let dex = dexNumber(for: mon) else { return nil }
        return images[key(dex, shiny)]
    }

    func sprite(for mon: Gen3Mon, shiny: Bool) async -> NSImage? {
        await loadSpeciesIndex()
        guard let dex = dexNumber(for: mon) else { return nil }
        let name = key(dex, shiny)
        if let image = images[name] { return image }
        guard !inFlight.contains(name) else { return nil }
        inFlight.insert(name)
        defer { inFlight.remove(name) }

        let file = cacheDirectory.appendingPathComponent("\(name).png")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            images[name] = image
            return image
        }
        let path = shiny ? "\(Self.spriteBase)/shiny/\(dex).png" : "\(Self.spriteBase)/\(dex).png"
        guard let url = URL(string: path),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data) else {
            offline = true
            return nil
        }
        try? data.write(to: file)
        images[name] = image
        return image
    }

    // MARK: - Persistence

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFile),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        learned = decoded.reduce(into: [:]) { result, pair in
            if let species = UInt16(pair.key) { result[species] = pair.value }
        }
    }

    private func saveState() {
        let encodable = learned.reduce(into: [String: Int]()) { $0["\($1.key)"] = $1.value }
        try? JSONEncoder().encode(encodable).write(to: stateFile)
    }
}
