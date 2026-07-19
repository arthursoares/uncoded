# CLAUDE.md — Uncoded

Native macOS (SwiftUI/SwiftData, macOS 14+) app fixing lens metadata in
Leica M DNGs shot with third-party lenses coded with borrowed 6-bit codes.
Successor to the `fix_6bit_exif` CLI.

## Build & test

- Project is generated: `xcodegen generate` after adding/removing files
  (`project.yml` is the source of truth; `Uncoded.xcodeproj` is gitignored)
- Build: `xcodebuild -scheme Uncoded -configuration Debug -derivedDataPath build/DerivedData build`
- Test: `xcodebuild -scheme Uncoded -derivedDataPath build/DerivedData test`
- DMG: `scripts/make_dmg.sh <path/to/Uncoded.app> dist`
- Real-file reader test: set env `UNCODED_TEST_DNG=/path/to/file.dng`
  (pass via `TEST_RUNNER_UNCODED_TEST_DNG` with xcodebuild)

## Git flow & releases

- `develop` = default branch, day-to-day work. `main` = releases only.
- Release: bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in
  `project.yml`, merge develop → main, tag `vX.Y.Z`, push tag — the
  Release workflow builds the DMG and publishes the GitHub release.
- Keep both branches in sync after hotfixes on main.

## Architecture map

- `Uncoded/Sources/Services/TIFFReader.swift` — memory-mapped read-only
  TIFF/DNG parser (EXIF IFDs + XMP packet). Never reads image data.
- `Uncoded/Sources/Services/TIFFWriter.swift` — in-place writer: patch in
  place / append at EOF + re-point IFD entry / rebuild IFD at EOF. XMP
  rewritten within its whitespace padding when possible. Produces
  `WriteJournal`; `revert` verifies bytes/length before restoring and
  refuses if the file changed since the fix.
- `Uncoded/Sources/Services/Fixer.swift` — orchestration: optional one-time
  `.bak` copy, write, journal persistence (`JournalStore`, Application
  Support), revert lookup.
- `Uncoded/Sources/Models/SixBitCode.swift` — bundled community code table
  (`Resources/sixbit_codes.json`), identity matching, spec-ranked
  borrowed-code suggestions.
- `Uncoded/Sources/Models/LensNameParser.swift` — normalizes both Leica
  formats: camera "Noctilux-M 1:1.2/50 ASPH." vs catalog
  "Noctilux-M 50mm f/1.2 ASPH" (incl. comma decimals).
- `Uncoded/Sources/Services/LCPIndex.swift` — indexes Adobe .lcp profiles
  from `/Library/Application Support/Adobe/CameraRaw/LensProfiles/1.0`
  (M-mount only, deduped, Leitz Phone excluded).
- `Uncoded/Sources/Models/ScanSession.swift` — @Observable scan state,
  owned by ContentView so it survives sidebar tab switches. Don't move
  scan state back into ScanView @State.
- Views: instrument-panel design language in `UI/Theme.swift` (dark only,
  engraved type, pit-pattern `BitPatternView`, film-rebate amber).

## Domain constraints

- One 6-bit code maps to one lens (`Mappings.assign/set` in LensesView) —
  physical reality: the code is engraved on the lens.
- The M11 writes no numeric code tag; detection matches the `LensModel`
  string against the table via `LensNameParser` identities.
- Lightroom reads XMP develop settings at import; already-imported photos
  need Metadata → Read Metadata from File (this caveat must stay in the
  fix confirmation dialog).
- Writer must keep exiftool-clean output: validate changes against
  `exiftool -validate` and field readout on real M11 fixtures
  (`~/Downloads/uncoded_demo_dngs` — copies, safe to rewrite).

## Pending / known state

- Repo is public, GPL-3.0. Announcement drafts: `docs/announcing-uncoded.md`.
- v0.2 backlog lives in `docs/design-review-2026-07.md` (P1/P2 sections).
