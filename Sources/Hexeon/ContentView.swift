import SwiftUI
import Gen3Save

struct ContentView: View {
    @Bindable var model: SaveModel

    var body: some View {
        VStack(spacing: 0) {
            if let save = model.save {
                header(save)
                Divider()
                partyList
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { model.load(url) }
        }
        .fileExporter(isPresented: $model.isExporting,
                      document: RawSaveDocument(data: model.save?.data ?? Data()),
                      contentType: .data,
                      defaultFilename: model.exportName) { _ in
            model.status = "Exported. Inject it with GodMode9: copy the file with Y, then agbsave.bin → AGBSAVE options → Inject GBA VC save."
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("Open a 128 KB GBA save").font(.title3)
            Text("Vanilla Ruby/Sapphire/Emerald/FireRed/LeafGreen, and romhacks with\nnon-standard section lengths such as Pokémon Unbound.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Save…") { model.isImporting = true }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ save: Gen3SaveFile) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sourceName).font(.headline)
                Text("Active slot \(save.activeSlot) · counter \(save.slots[save.activeSlot].counter)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label(save.encoding == .plain ? "Plaintext payloads" : "Encrypted payloads",
                      systemImage: save.encoding == .plain ? "lock.open" : "lock")
                    .font(.caption)
                Text(String(format: "magic %08X%@", save.magic,
                            save.isVanillaMagic ? " (vanilla)" : " (romhack)"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var partyList: some View {
        List(model.party) { mon in
            HStack(spacing: 12) {
                Text("\(mon.id + 1)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(mon.nickname.isEmpty ? "#\(mon.species)" : mon.nickname)
                            .fontWeight(.medium)
                        if mon.isShiny {
                            Image(systemName: "sparkles").foregroundStyle(.yellow)
                        }
                    }
                    Text("species \(mon.species) · Lv \(mon.level) · \(mon.currentHP)/\(mon.maxHP) HP · nature \(mon.nature) · OT \(mon.otName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("shiny value \(mon.shinyValue)")
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
                Button(mon.isShiny ? "Remove Shine" : "Make Shiny") {
                    model.setShiny(mon.id, !mon.isShiny)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(model.status.isEmpty ? "Back up your save before injecting anything." : model.status)
                .font(.caption)
                .foregroundStyle(model.failed ? .primary : .secondary)
                .textSelection(.enabled)
            Spacer()
            Button("Open…") { model.isImporting = true }
            Button("Export…") { model.isExporting = true }
                .disabled(!model.isDirty)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
    }
}
