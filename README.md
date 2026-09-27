# Hexeon

A small, native macOS save editor for Game Boy Advance Pokémon saves — including
**romhack saves that PKHeX refuses to open**.

![Swift 6](https://img.shields.io/badge/Swift-6.0-orange) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![MIT](https://img.shields.io/badge/license-MIT-green)

## Why this exists

PKHeX is excellent and you should use it for retail games. It assumes the
vanilla Gen 3 save layout, though, and romhacks change that layout:

| | Vanilla FR/LG/E | Pokémon Unbound |
|---|---|---|
| Footer magic | `0x08012025` | `0x01121999` |
| Section 1 summed length | 3968 bytes | ~4084 bytes |
| Pokémon payload | XOR-encrypted with `pid ^ otid` | plaintext |
| Substructure order | shuffled by `pid % 24` | fixed G/A/E/M |
| Per-Pokémon checksum | used | zeroed, unused |
| PC entry size | 80 bytes, payload at `+0x20` | 58 bytes, payload at `+0x1C` |

Every one of those is detected from the file. You don't pick a game, and a hack
Hexeon has never seen works as long as it reuses one of these shapes.

Edit such a save with a vanilla-assuming tool and it writes *correct-looking*
checksums over the *wrong* byte ranges. The game then rejects the slot as
corrupt and silently rolls back to your previous save — which is exactly how
this project started.

## The trick: measure, don't assume

Hexeon never hardcodes a per-hack table. The game already wrote a checksum over
some fixed length, so Hexeon asks **which prefix lengths could have produced
that checksum**, and intersects the answer across both save slots. The true
length is always inside the resulting window.

When writing a section back, it recomputes the checksum at every candidate
length. If they all agree, it commits. If they disagree — meaning the edit
touched bytes near a boundary Hexeon can't pin down — it **refuses and tells
you**, instead of handing your console a save it will reject.

```swift
let save = try Gen3SaveFile(contentsOf: url)
print(save.encoding)          // .plain for Unbound, .vanilla for retail
print(save.lengthWindows[1]!) // measured candidate lengths for section 1
```

## What it does today

- Opens any 128 KB Gen 3 save; picks the slot the game would actually load
- Autodetects payload encoding *and* PC entry geometry — vanilla or romhack
- Lists **party and PC** with artwork, nickname, species id, level, HP, nature
  and shiny value
- **Toggles shininess** on any of them while preserving nature, ability and
  everything else
- Shows shiny artwork for shinies, with a "preview all as shiny" switch
- Exports a new file — never overwrites your input
- Refuses to write anything whose checksums it can't compute unambiguously

Shiny editing picks a replacement PID congruent to the old one **mod 600**. That
keeps `pid % 25` (nature) and `pid % 24` (substructure order), and since 600 is
even, the ability bit too. For encrypted saves the payload is re-encrypted under
the new key and the payload checksum rewritten.

## Artwork, without a species table

A romhack numbers species however it likes: Beldum is 398 in Unbound, 374 in the
National Dex. Hexeon resolves the difference in three steps, cheapest first:

1. a mapping learned earlier and cached on disk;
2. ids ≤ 251, which equal National Dex numbers in every Gen 3 game and in
   FireRed-based hacks (Slowpoke is 79 in both);
3. **the nickname** — an un-renamed Pokémon is named after its species, so the
   save carries its own species table. One un-renamed Flabébé teaches Hexeon what
   species 840 is, for every renamed one afterwards.

Artwork is the Pokémon HOME renders from [PokeAPI/sprites](https://github.com/PokeAPI/sprites),
fetched on demand and cached under `~/Library/Caches/Hexeon`. Nothing is bundled:
it keeps the app at a few hundred KB, and an open-source repo has no business
redistributing someone else's renders. No network, no artwork — everything else
still works.

## How the PC is read

The PC is logically one buffer spread over sections 5–13, but where it splits
depends on per-section lengths a hack may change. Rather than reassemble it,
Hexeon scans each section for entries that validate as stored Pokémon and locks
onto the stride it finds. The cost: an entry whose header straddles a section
boundary is skipped, and the app tells you how many.

## Not implemented

Item/bag editing, IV/EV editing, moves, box numbers and names, legality checks,
and generations other than 3. Gen 3 romhacks were the itch; the rest can wait
until someone actually wants it.

Moves are only read from 48-byte payloads. Unbound's 58-byte PC entry packs the
last 20 bytes in a way this project hasn't decoded, so PC moves aren't shown —
species, PID, nickname and IVs all sit in the part that is understood, which is
everything shiny editing touches.

## Build

```bash
swift build             # library + app
swift test              # 10 tests, no save file required
./Scripts/bundle-app.sh # produces build/Hexeon.app
```

Validate against your own save without committing it anywhere:

```bash
HEXEON_TEST_SAVE=~/backups/mysave.sav \
HEXEON_TEST_INDEX=2 \
swift test --filter realSaveMatchesKnownGoodOutput
```

## Getting a save off a 3DS GBA VC inject

1. Launch the game, then exit to HOME so the save flushes.
2. Boot GodMode9, go to `[S:] SYSNAND VIRTUAL` → `agbsave.bin` → `A` →
   **AGBSAVE options** → **Dump GBA VC save**. It lands in `0:/gm9/out/`.
3. Edit it with Hexeon on your Mac.
4. To put it back: in GodMode9, highlight the file and press **Y** to copy it to
   the clipboard (the inject reads from there, not a file picker), then
   `agbsave.bin` → **AGBSAVE options** → **Inject GBA VC save**.

## Safety

Back up before you inject. Hexeon only ever writes to the active slot, leaving
the other slot as a rollback, and always exports to a new file. The `.gitignore`
excludes `*.sav` so you can't accidentally publish your own save.

## License

MIT. Not affiliated with Nintendo, Game Freak, or the Pokémon Company.
Pokémon Unbound is a fan project by Skeli.
