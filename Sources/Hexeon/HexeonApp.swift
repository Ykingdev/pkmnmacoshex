import SwiftUI
import UniformTypeIdentifiers
import Gen3Save

@main
struct HexeonApp: App {
    @State private var model = SaveModel()

    var body: some Scene {
        WindowGroup("Hexeon") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open Save…") { model.isImporting = true }
                    .keyboardShortcut("o")
                Button("Export Edited Save…") { model.isExporting = true }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty)
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
    var isImporting = false
    var isExporting = false
    /// Shows every Pokémon in its shiny colours without touching the save.
    var previewShiny = false
    /// Selected Pokémon, identified by file offset (stable across edits).
    var selection: Int?
    var draft: MonDraft?

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

    func load(_ url: URL) {
        do {
            let file = try Gen3SaveFile(contentsOf: url)
            save = file
            sourceName = url.lastPathComponent
            isDirty = false
            failed = false
            select(nil)
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
