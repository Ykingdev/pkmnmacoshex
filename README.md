# Hexeon

<img src="docs/icon.png" width="128" align="right" alt="Hexeon icon">

A small, **native macOS** save editor for Game Boy Advance Pokémon saves —
including **romhack saves that PKHeX can't open**.

![Swift 6](https://img.shields.io/badge/Swift-6.0-orange) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![MIT](https://img.shields.io/badge/license-MIT-green)

## Install

**Download** — get `Hexeon.zip` from
[Releases](https://github.com/Ykingdev/pkmnmacoshex/releases/latest), unzip, and
drag `Hexeon.app` into Applications. Requires macOS 14 or later, Apple silicon or
Intel.

macOS will refuse to open it the first time. The app is ad-hoc signed but not
notarized — that needs a paid Apple Developer account — so Gatekeeper treats it
as unidentified. Once, either:

- right-click `Hexeon.app` → **Open** → **Open** in the dialog, or
- `xattr -dr com.apple.quarantine /Applications/Hexeon.app`

After that it launches normally.

**Or build it** — no dependencies beyond Xcode:

```bash
git clone https://github.com/Ykingdev/pkmnmacoshex.git
cd pkmnmacoshex
./Scripts/bundle-app.sh     # writes build/Hexeon.app, icon and all
open build/Hexeon.app
```

## Why this exists

**There is no macOS build of PKHeX.** It's a .NET Windows Forms application, so
on a Mac the options are Wine, CrossOver, or a Windows VM — a lot of scaffolding
to flip one byte in a save file. Hexeon is a normal Mac app: double-click, open a
save, export it.

The second reason is romhacks. PKHeX is excellent and you should use it for
retail games, but it assumes the vanilla Gen 3 save layout, and romhacks change
that layout:

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
checksums over the *wrong* byte ranges. The game then rejects the slot as corrupt
and silently rolls back to your previous save — which is exactly how this project
started: a Pokémon Unbound save, edited on a Mac, that the 3DS quietly refused.

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
- Lists **party and PC** with artwork, nickname, species and move **names**,
  level, nature and IVs
- **Edits every field it can decode**: nickname, OT name, trainer and secret ID,
  species, held item, experience, friendship, level, IVs, EVs, moves and PP
- **Nature, ability and shininess** — all three are encoded in the PID, so
  Hexeon searches for a PID satisfying the combination you asked for and
  re-encrypts the payload under the new key
- A **move browser**: search by name, filter by type, category or "changes
  stats", or narrow to what this species can actually learn — with each move's
  power, accuracy, PP and description from the ROM
- **Legality warnings** when a move isn't in the species' level-up learnset
- Shows shiny artwork for shinies, with a "preview all as shiny" switch
- Exports a new file — never overwrites your input
- Refuses to write anything whose checksums it can't compute unambiguously

Shiny editing picks a replacement PID congruent to the old one **mod 600**. That
keeps `pid % 25` (nature) and `pid % 24` (substructure order), and since 600 is
even, the ability bit too. For encrypted saves the payload is re-encrypted under
the new key and the payload checksum rewritten.

## Names: mined from the ROM

A save stores only numbers, in the ROM's own numbering — Beldum is 398 in
Unbound, 374 in the National Dex — so names have to come from the ROM. **Import
ROM for Names…** (⌘R) mines them once and remembers them, so names keep working
afterwards without the ROM present.

Table addresses are never hardcoded, because that is exactly what breaks on every
hack. Instead Hexeon finds each table by what it must contain: the encoded bytes
of "Bulbasaur" (or "Pound"), then the entry width measured from where "Ivysaur"
lands, then confirmation from the next anchors. Widths and capitalisation differ
per game and are both derived.

Knowing where a table *ends* turned out to be the subtle part, and two things
must not be mistaken for it:

- **Placeholders.** Vanilla FireRed has 25 consecutive "?????" rows at species
  252–276 before the Gen 3 species resume at 277.
- **Adjacent text.** Straight after the move table sits ordinary game dialogue,
  which decodes perfectly well and is terminated too. What separates a row from
  running text is *padding*: an entry fills everything after its terminator with
  `0xFF`. On Unbound this ends the move table at exactly 922 ("Rapid Flow"),
  where a naive scan ran 40 rows into item descriptions.

Unbound v2.1.1.1 ships pre-mined (`Sources/Hexeon/Names/`, 271 KB): 1270 species
and 922 move names, 677 move stat blocks, 922 descriptions, 1268 learnsets and
the TM list — matched to a save by its footer magic, so it works with no ROM at
all. **Only names are bundled, never a ROM.** Regenerate with:

```bash
HEXEON_ROM=/path/to/rom.gba \
HEXEON_ROM_OUT=Sources/Hexeon/Names/game.json \
HEXEON_ROM_MAGIC=01121999 \
swift test --filter minesRealROM
```

## Move browsing and legality

Importing a ROM mines more than names. Each table is found by content, never by
address:

| Table | How it's found |
|---|---|
| Species / move names | encoded "Bulbasaur"/"Pound", width measured from the next anchor |
| Type names | "Normal" followed by "Fight" |
| Move battle data | Pound (40 power, Normal, 100%, 35 PP) then Karate Chop, which also gives the stride |
| Move descriptions | the pointer-to-text array whose entries actually describe the moves at those ids |
| Level-up learnsets | the pointer array whose targets decode as (move, level) with ascending levels and a terminator |
| TM/HM move list | the shortest valid move-id array containing the classic TM moves |

Two findings worth recording, both from reading Unbound's bytes:

- **Field order isn't vanilla's.** Unbound's move entry starts at power, not
  effect, and carries a physical/special/status byte vanilla doesn't have. So the
  anchor is the power/type/accuracy/PP run and everything else is read relative
  to it.
- **The effect byte can't identify stat moves.** Growl and Toxic share effect 22,
  and both are category "status", so neither field separates "changes stats" from
  "inflicts a status". The move's own *description* can — so the filter reads the
  text, which also works for moves a hack invented.

### What legality does and doesn't claim

Only the level-up learnset could be located reliably; the per-species TM/HM
compatibility bitfield was not found in the ROMs tested (candidates gave Bulbasaur
zero TMs and Beldum Dragon Claw, so they were rejected rather than shipped). So:

- in the learnset → shown with the level it's learned at
- a TM/HM move → shown as **unverifiable**, never flagged
- neither → flagged as *not in the level-up learnset*, worded as a warning
- no learnset data for that species → nothing claimed

Crying foul over a legitimate TM move would be worse than staying quiet, so the
uncertainty is in the labels rather than hidden.

## Artwork, without a species table

With no ROM imported, species numbers are resolved to National Dex numbers for
artwork in three steps, cheapest first:

1. a mapping learned earlier and cached on disk;
2. ids ≤ 251, which equal National Dex numbers in every Gen 3 game and in
   FireRed-based hacks (Slowpoke is 79 in both);
3. **the nickname** — an un-renamed Pokémon is named after its species, so the
   save carries its own species table. One un-renamed Flabébé teaches Hexeon what
   species 840 is, for every renamed one afterwards.

A mined ROM supersedes all three, since it names every species including renamed
ones.

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

## What editing can and can't reach

Party Pokémon use the vanilla 48-byte payload in every game tested, so every
field is editable there. Unbound's 58-byte PC entry packs moves, PP and EVs into
12 bytes whose layout this project hasn't decoded — those controls are disabled
for PC Pokémon on such saves, and **the undecoded bytes are copied through
byte-for-byte** on every write. A test asserts exactly that.

Level is editable but worth understanding: Gen 3 also derives level from
experience via per-species growth-rate tables a romhack can change, so set level
and experience consistently or the game may correct one of them.

## Not implemented

Item/bag editing, box numbers and names, legality checks, species and move
*names* (those tables live in the ROM, not the save), and generations other than
3. Gen 3 romhacks were the itch; the rest can wait until someone wants it.

## Build

```bash
swift build             # library + app
swift test              # 26 tests, no save file or ROM required
./Scripts/bundle-app.sh # produces build/Hexeon.app, icon included
swift Scripts/make-icon.swift   # redraw the icon on its own
```

The icon is drawn in code with CoreGraphics (`Scripts/make-icon.swift`) rather
than checked in as an image — a fan rendition of a Master Ball, not artwork taken
from the games.

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
