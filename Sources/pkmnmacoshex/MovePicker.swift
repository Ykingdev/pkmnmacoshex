import SwiftUI
import Gen3Save

/// Move browser: search by name, narrow by type, category or "changes stats", and
/// see at a glance whether this species can actually learn each one.
struct MovePicker: View {
    let tables: RomTables
    let species: UInt16
    let speciesName: String
    let onPick: (UInt16, UInt8) -> Void      // move id, suggested PP
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var type: UInt8?
    @State private var category: UInt8?
    @State private var statChangersOnly = false
    @State private var learnableOnly = false
    @State private var selection: UInt16?

    private var learnset: [UInt16: UInt8] {
        tables.learnset(species: species).reduce(into: [:]) { $0[$1.move] = $1.level }
    }

    private var results: [UInt16] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let learnable = learnset
        return tables.moves.keys.filter { id in
            guard let name = tables.moveName(id) else { return false }
            if !trimmed.isEmpty, !name.lowercased().contains(trimmed) { return false }
            if learnableOnly, learnable[id] == nil { return false }
            if statChangersOnly, !tables.changesStats(move: id) { return false }
            if let type, tables.stats(forMove: id)?.type != type { return false }
            if let category, tables.stats(forMove: id)?.category != category { return false }
            return true
        }
        .sorted { (tables.moveName($0) ?? "") < (tables.moveName($1) ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            if results.isEmpty {
                ContentUnavailableView("No moves match", systemImage: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                List(results, id: \.self, selection: $selection) { id in
                    row(id).tag(id)
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    private var filters: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search moves by name", text: $query)
                    .textFieldStyle(.plain)
            }
            HStack(spacing: 8) {
                Picker("Type", selection: $type) {
                    Text("Any type").tag(UInt8?.none)
                    ForEach(tables.typeNames.keys.sorted(), id: \.self) { id in
                        Text(tables.typeName(id)).tag(UInt8?.some(id))
                    }
                }
                .frame(width: 130)
                Picker("Category", selection: $category) {
                    Text("Any category").tag(UInt8?.none)
                    Text("Physical").tag(UInt8?.some(0))
                    Text("Special").tag(UInt8?.some(1))
                    Text("Status").tag(UInt8?.some(2))
                }
                .frame(width: 140)
                Toggle("Changes stats", isOn: $statChangersOnly)
                Toggle("\(speciesName) can learn", isOn: $learnableOnly)
                Spacer()
            }
            .labelsHidden()
            .font(.caption)
        }
        .padding(10)
    }

    private func row(_ id: UInt16) -> some View {
        let stats = tables.stats(forMove: id)
        let legality = tables.legality(species: species, move: id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(tables.moveName(id) ?? "#\(id)").fontWeight(.medium)
                if let stats {
                    Badge(tables.typeName(stats.type), tint: .blue)
                    Badge(stats.categoryName, tint: stats.isStatus ? .gray : .orange)
                }
                LegalityBadge(legality: legality)
                Spacer()
                if let stats {
                    Text(stats.power > 0 ? "\(stats.power) pow · \(stats.accuracy)% · \(stats.pp) PP"
                                         : "\(stats.accuracy)% · \(stats.pp) PP")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text("no battle data").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if let text = tables.description(forMove: id) {
                Text(text.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pick(id) }
    }

    private var footer: some View {
        HStack {
            Text("\(results.count) of \(tables.moves.count) moves")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Use Move") { if let selection { pick(selection) } }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
        }
        .padding(10)
    }

    private func pick(_ id: UInt16) {
        onPick(id, tables.stats(forMove: id)?.pp ?? 0)
        dismiss()
    }
}

/// How defensible a move is for this species. Never says "illegal" on evidence
/// that only covers level-up learnsets.
struct LegalityBadge: View {
    let legality: RomTables.Legality

    var body: some View {
        switch legality {
        case .learnsAtLevel(let level):
            Badge(level == 0 ? "learns" : "Lv \(level)", tint: .green)
        case .tmOrHmMove:
            Badge("TM/HM", tint: .teal)
        case .notInLearnset:
            Badge("not in learnset", tint: .orange)
        case .unknown:
            EmptyView()
        }
    }
}
