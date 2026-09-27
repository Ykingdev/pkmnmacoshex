import SwiftUI
import Gen3Save

/// The editing pane. Fields a storage layout can't express are disabled with the
/// reason attached, rather than silently doing nothing.
struct InspectorView: View {
    @Binding var draft: MonDraft
    let mon: Gen3Mon
    let hasChanges: Bool
    let onApply: () -> Void
    let onRevert: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Identity") {
                        field("Nickname") {
                            TextField("", text: $draft.nickname).frame(width: 140)
                        }
                        field("OT name") {
                            TextField("", text: $draft.otName).frame(width: 140)
                        }
                        field("Trainer ID") {
                            number($draft.trainerID)
                        }
                        field("Secret ID") {
                            number($draft.secretID)
                        }
                        Text("Changing trainer IDs re-derives shininess for this Pokémon and can make it read as traded.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    group("Species") {
                        field("Species id") { number($draft.species) }
                        field("Held item") { number($draft.heldItem) }
                        field("Experience") { number($draft.experience) }
                        field("Friendship") { number($draft.friendship) }
                        if draft.editableLevel {
                            field("Level") {
                                number(Binding(
                                    get: { draft.level ?? 0 },
                                    set: { draft.level = $0 }
                                ))
                            }
                            Text("Gen 3 also derives level from experience using per-species growth rates, which a romhack can change. Set both consistently or the game may correct one on level-up.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    group("Derived from PID") {
                        field("Nature") {
                            Picker("", selection: $draft.nature) {
                                ForEach(0..<25, id: \.self) { index in
                                    Text(Gen3Mon.natureNames[index]).tag(UInt8(index))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }
                        field("Ability") {
                            Picker("", selection: $draft.abilityBit) {
                                Text("First").tag(UInt8(0))
                                Text("Second").tag(UInt8(1))
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 140)
                        }
                        Toggle("Shiny", isOn: $draft.isShiny)
                        Text("These three are encoded in the PID, so Hexeon searches for a PID satisfying all of them and re-encrypts the payload under the new key.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    group("IVs") {
                        ForEach(0..<6, id: \.self) { index in
                            field(Gen3Mon.statNames[index]) {
                                HStack(spacing: 8) {
                                    Slider(value: Binding(
                                        get: { Double(draft.ivs[index]) },
                                        set: { draft.ivs[index] = UInt8($0.rounded()) }
                                    ), in: 0...31, step: 1)
                                    .frame(width: 100)
                                    Text("\(draft.ivs[index])")
                                        .font(.caption.monospaced())
                                        .frame(width: 22, alignment: .trailing)
                                }
                            }
                        }
                    }

                    group("EVs") {
                        if draft.editableEVs {
                            ForEach(0..<6, id: \.self) { index in
                                field(Gen3Mon.statNames[index]) {
                                    number(Binding(
                                        get: { draft.evs[index] },
                                        set: { draft.evs[index] = $0 }
                                    ))
                                }
                            }
                        } else {
                            unavailable("This save packs PC EVs in \(mon.storage.totalSize)-byte entries using a layout Hexeon hasn't decoded.")
                        }
                    }

                    group("Moves") {
                        if draft.editableMoves {
                            ForEach(0..<4, id: \.self) { index in
                                field("Move \(index + 1)") {
                                    HStack(spacing: 6) {
                                        number(Binding(
                                            get: { draft.moves[index] },
                                            set: { draft.moves[index] = $0 }
                                        ))
                                        Text("PP").font(.caption2).foregroundStyle(.secondary)
                                        number(Binding(
                                            get: { draft.pp[index] },
                                            set: { draft.pp[index] = $0 }
                                        ), width: 40)
                                    }
                                }
                            }
                            Text("Move ids are the game's own numbering; romhacks add moves beyond the vanilla 354.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            unavailable("PC moves live in the 12 undecoded bytes of this save's \(mon.storage.totalSize)-byte entry. Hexeon preserves them byte-for-byte instead of guessing.")
                        }
                    }
                }
                .padding(14)
            }

            Divider()
            HStack {
                Text(hasChanges ? "Unsaved changes" : "No changes")
                    .font(.caption)
                    .foregroundStyle(hasChanges ? .orange : .secondary)
                Spacer()
                Button("Revert", action: onRevert).disabled(!hasChanges)
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
            }
            .padding(10)
        }
        .frame(width: 320)
    }

    // MARK: - Small builders

    private func group<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func field<Content: View>(_ label: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            content()
        }
    }

    private func number<V: BinaryInteger>(_ binding: Binding<V>,
                                         width: CGFloat = 140) -> some View {
        TextField("", value: binding, format: IntegerFormatStyle<V>())
            .multilineTextAlignment(.trailing)
            .frame(width: width)
    }

    private func unavailable(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.fill").font(.caption2)
            Text(reason).font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}
