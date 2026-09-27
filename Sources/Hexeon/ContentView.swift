import SwiftUI
import Gen3Save

struct ContentView: View {
    @Bindable var model: SaveModel

    var body: some View {
        VStack(spacing: 0) {
            if let save = model.save {
                header(save)
                Divider()
                monList
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
            model.status = "Exported. In GodMode9: highlight the file, press Y to copy, then agbsave.bin → AGBSAVE options → Inject GBA VC save."
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("Open a 128 KB GBA save").font(.title3)
            Text("Ruby, Sapphire, Emerald, FireRed and LeafGreen, plus romhacks with\ntheir own section lengths and storage layout — detected automatically.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Save…") { model.isImporting = true }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ save: Gen3SaveFile) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.sourceName).font(.headline)
                HStack(spacing: 6) {
                    Badge(save.isVanillaMagic ? "vanilla" : "romhack",
                          tint: save.isVanillaMagic ? .green : .purple)
                    Badge(save.encoding == .plain ? "plaintext" : "encrypted", tint: .blue)
                    if let storage = save.boxStorage {
                        Badge("PC \(storage.totalSize)B/slot", tint: .teal)
                    }
                    Text("slot \(save.activeSlot) · counter \(save.slots[save.activeSlot].counter) · magic \(String(format: "%08X", save.magic))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Preview all as shiny", isOn: $model.previewShiny)
                .toggleStyle(.switch)
                .font(.caption)
        }
        .padding(12)
    }

    private var monList: some View {
        List {
            Section("Party (\(model.party.count))") {
                ForEach(model.party) { row($0) }
            }
            if !model.boxed.isEmpty {
                Section("PC (\(model.boxed.count))") {
                    ForEach(model.boxed) { row($0) }
                }
            }
        }
    }

    private func row(_ mon: Gen3Mon) -> some View {
        HStack(spacing: 12) {
            Text("\(mon.slotNumber)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            SpriteThumbnail(mon: mon, shiny: mon.isShiny || model.previewShiny,
                            library: model.sprites)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(mon.displayName).fontWeight(.medium)
                    if mon.isShiny {
                        Image(systemName: "sparkles").foregroundStyle(.yellow)
                    }
                }
                Text(detail(mon)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("sv \(mon.shinyValue)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Button(mon.isShiny ? "Remove Shine" : "Make Shiny") {
                model.setShiny(mon, !mon.isShiny)
            }
        }
        .padding(.vertical, 3)
    }

    private func detail(_ mon: Gen3Mon) -> String {
        var parts = ["species \(mon.species)"]
        if let level = mon.level { parts.append("Lv \(level)") }
        if let hp = mon.currentHP, let max = mon.maxHP { parts.append("\(hp)/\(max) HP") }
        parts.append("nature \(mon.nature)")
        if !mon.otName.isEmpty { parts.append("OT \(mon.otName)") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(model.status.isEmpty ? "Back up your save before injecting anything." : model.status)
                .font(.caption)
                .foregroundStyle(model.failed ? .primary : .secondary)
                .lineLimit(2)
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

struct Badge: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
