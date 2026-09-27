import SwiftUI
import UniformTypeIdentifiers
import Gen3Save

@main
struct HexeonApp: App {
    @State private var model = SaveModel()

    var body: some Scene {
        WindowGroup("Hexeon") {
            ContentView(model: model)
                .frame(minWidth: 640, minHeight: 420)
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
final class SaveModel {
    var save: Gen3SaveFile?
    var sourceName = ""
    var status = ""
    var failed = false
    var isDirty = false
    var isImporting = false
    var isExporting = false

    var party: [Gen3Mon] { save?.party ?? [] }

    func load(_ url: URL) {
        do {
            let file = try Gen3SaveFile(contentsOf: url)
            save = file
            sourceName = url.lastPathComponent
            isDirty = false
            failed = false
            status = "Loaded slot \(file.activeSlot) — \(file.partyCount) in party."
        } catch {
            save = nil
            failed = true
            status = "\(error)"
        }
    }

    func setShiny(_ index: Int, _ shiny: Bool) {
        guard var file = save else { return }
        do {
            let before = file.party[index]
            try file.setShiny(partyIndex: index, shiny)
            let after = file.party[index]
            guard file.validatesChecksums(slot: file.activeSlot) else {
                failed = true
                status = "Refused: checksums did not validate after the edit."
                return
            }
            save = file
            isDirty = true
            failed = false
            status = String(format: "%@: PID %08X → %08X, shiny value %d → %d. Nature and ability unchanged.",
                            after.nickname.isEmpty ? "#\(after.species)" : after.nickname,
                            before.pid, after.pid, before.shinyValue, after.shinyValue)
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
