import SwiftUI
import UniformTypeIdentifiers
import Gen3Save

@main
struct PkmnMacOSHexApp: App {
    @State private var model = SaveModel()

    var body: some Scene {
        WindowGroup("pkmnmacoshex") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open Save…") { model.beginImport(.save) }
                    .keyboardShortcut("o")
                Button("Export Edited Save…") { model.isExporting = true }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty)
                Divider()
                Button("Import ROM for Names…") { model.beginImport(.rom) }
                    .keyboardShortcut("r")
            }
        }
    }
}

struct RawSaveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@Observable
@MainActor
final class SaveModel {
    var save: Gen3SaveFile?
    var sprites = SpriteLibrary()
    var sourceName = ""
    var status = ""
    var failed = false
    var isDirty = false
    /// What the single file importer is currently being used for. Two
    /// `.fileImporter` modifiers on one view shadow each other, so there is one.
    enum ImportIntent { case save, rom }
    var importIntent: ImportIntent = .save
    var isImporting = false
    var isExporting = false
    /// Shows every Pokémon in its shiny colours without touching the save.
    var previewShiny = false
    /// Selected Pokémon, identified by file offset (stable across edits).
    var selection: Int?
    var draft: MonDraft?
    /// Names from a ROM the user imported, which win over anything bundled.
    var importedTables: RomTables?
    /// Names bundled with the app, matched to the open save by footer magic.
    var bundledTables: RomTables?
    var tables: RomTables { importedTables ?? bundledTables ?? RomTables() }

    private var tablesFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
        return support.appendingPathComponent("pkmnmacoshex/rom-tables.json")
    }

    init() {
        if let data = try? Data(contentsOf: tablesFile),
           let decoded = try? JSONDecoder().decode(RomTables.self, from: data) {
            importedTables = decoded
        }
        sprites.romTables = tables
    }

    /// Mines species and move names out of a ROM once, then remembers them — so
    /// names keep working on later launches without the ROM present.
    func importROM(_ url: URL) {
        do {
            let mined = try RomTables.mine(romAt: url)
            guard !mined.isEmpty else {
                failed = true
                status = "No name tables found in \(url.lastPathComponent). Is it an unheadered GBA ROM?"
                return
            }
            importedTables = mined
            sprites.romTables = mined
            try? FileManager.default.createDirectory(at: tablesFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? JSONEncoder().encode(mined).write(to: tablesFile)
            failed = false
            status = "Mined \(mined.species.count) species and \(mined.moves.count) move names from \(url.lastPathComponent)."
        } catch {
            failed = true
            status = "\(error)"
        }
    }

    func speciesName(_ mon: Gen3Mon) -> String? { tables.speciesName(mon.species) }
    func moveName(_ id: UInt16) -> String? { id == 0 ? "—" : tables.moveName(id) }

    var party: [Gen3Mon] { save?.party ?? [] }
    var boxed: [Gen3Mon] { save?.boxes ?? [] }
    var allMons: [Gen3Mon] { save?.allMons ?? [] }
    var selectedMon: Gen3Mon? { allMons.first { $0.offset == selection } }
    var draftHasChanges: Bool {
        guard let draft, let mon = selectedMon else { return false }
        return draft != MonDraft(mon)
    }

    func select(_ mon: Gen3Mon?) {
        selection = mon?.offset
        draft = mon.map(MonDraft.init)
    }

    func revertDraft() {
        draft = selectedMon.map(MonDraft.init)
    }

    func applyDraft() {
        guard var file = save, let draft, let mon = selectedMon else { return }
        do {
            let after = try file.apply(draft, to: mon)
            guard file.validatesChecksums(slot: file.activeSlot) else {
                failed = true
                status = "Refused: checksums did not validate after the edit."
                return
            }
            save = file
            isDirty = true
            failed = false
            self.draft = MonDraft(after)
            status = "\(after.displayName) updated — \(after.natureName), IVs \(after.ivs.map(String.init).joined(separator: "/"))\(after.isShiny ? ", shiny" : "")."
        } catch {
            failed = true
            status = "\(error)"
        }
    }

    func beginImport(_ intent: ImportIntent) {
        importIntent = intent
        isImporting = true
    }

    func handleImport(_ url: URL) {
        switch importIntent {
        case .save: load(url)
        case .rom: importROM(url)
        }
    }

    func load(_ url: URL) {
        do {
            let file = try Gen3SaveFile(contentsOf: url)
            save = file
            sourceName = url.lastPathComponent
            isDirty = false
            failed = false
            select(nil)
            bundledTables = RomTables.bundled(matching: file.magic)
            sprites.romTables = tables
            var parts = ["slot \(file.activeSlot)", "\(file.partyCount) in party",
                         "\(file.boxSlots.count) in PC"]
            if file.skippedBoundarySlots > 0 {
                parts.append("\(file.skippedBoundarySlots) PC slot(s) span a section boundary and were skipped")
            }
            status = "Loaded " + parts.joined(separator: ", ") + "."
        } catch {
            save = nil
            failed = true
            status = "\(error)"
        }
    }

    func setShiny(_ mon: Gen3Mon, _ shiny: Bool) {
        guard var file = save else { return }
        do {
            try file.setShiny(mon, shiny)
            guard file.validatesChecksums(slot: file.activeSlot) else {
                failed = true
                status = "Refused: checksums did not validate after the edit."
                return
            }
            let updated = (file.party + file.boxes).first { $0.offset == mon.offset }
            save = file
            isDirty = true
            failed = false
            if selection == mon.offset { draft = updated.map(MonDraft.init) }
            status = String(format: "%@: PID %08X → %08X, shiny value %d → %d. Nature and ability unchanged.",
                            mon.displayName, mon.pid, updated?.pid ?? 0,
                            mon.shinyValue, updated?.shinyValue ?? 0)
        } catch {
            failed = true
            status = "\(error)"
        }
    }

    var exportName: String {
        let stem = (sourceName as NSString).deletingPathExtension
        return stem.isEmpty ? "edited.sav" : "\(stem)-edited.sav"
    }
}
