# Changelog

## v0.2.0 — 2026-07-26

Deep-review round: every service and view audited (code smells + UX traps),
fixed across six PRs, each independently reviewed. 158 tests (was 40).

### Detection

- **14 lenses no longer detect the wrong 6-bit code.** The table lookup
  collapsed ASPH/generation markers, so e.g. a frame from a lens coded
  011110 (Summicron 35 ASPH) resolved to 000110 and was rewritten as
  whatever lens claimed that code. Matching is now by full normalized name,
  and never guesses: a name that legitimately means two codes (Summicron-M
  1:2/50 III vs IV/V) resolves through the code you actually mapped, or is
  shown as ambiguous with both candidates — including in the banner.
- f/0.95 no longer rounds onto f/1 (Noctilux generations wear different
  codes); "N/A" placeholder slots are no longer offered as codes.

### Fixing & undo

- **The undo journal is written before the file is touched**, survives every
  crash point (verified per-region: appendix landed / patches half-applied /
  interrupted mid-loop), and recovery restores the pristine bytes from the
  journal itself. A fix that lands never reports failure.
- **Reverting a re-fixed frame now unwinds all the way** to the camera
  original instead of one layer.
- **Renamed or moved fixed files are recognized by content**: the FIXED seal
  follows them, revert follows them, and re-fixing a renamed copy can no
  longer create a `.bak` of already-fixed bytes.
- The writer refuses instead of guessing: every offset bounds-checked,
  commits ordered and fsynced (value bytes before pointers), corrupt or
  non-UTF-8 XMP refused rather than silently replaced with an empty packet,
  malformed files throw instead of crashing, and the bytes are re-verified
  immediately before writing so a concurrent Lightroom edit can't be
  clobbered. Pulling the SD card mid-scan no longer kills the app.
- Batch fixes show determinate progress with a Stop button; failed frames
  are retryable; marks scope the Fix button; reverts ask for confirmation.

### Lightroom

- **`crs:LensProfileDigest` is finally written** (MD5 of the installed
  `.lcp`) — every previous fix carried an empty digest next to
  `LensProfileSetup="Custom"`. Existing lenses are repaired at launch, and
  files fixed by v0.1.x are re-detected and repairable.
- **`aux:LensInfo` is written** alongside `aux:Lens`, so the XMP no longer
  keeps the borrowed Leica lens's spec (usually the wrong aperture).
- The XMP packet is rewritten as XML, not by regex: develop settings,
  ratings, and multi-line values survive byte-meaning-identically
  (entity-escaped whitespace included), and only the right
  `rdf:Description` is touched. Packets carry padding so re-fixes patch
  in place instead of growing the file.

### Scanning

- Unreadable folders, denied subfolders, and unreadable files are each
  reported distinctly (with an Open Privacy Settings shortcut) instead of
  rendering as an empty folder.
- Deleting a lens no longer leaves it live in the current scan.

## v0.1.1 — 2026-07-19

Design-review P0 round (see `docs/design-review-2026-07.md`):

- **Unclaimed-code banner**: scans that find frames wearing a code no lens
  claims now offer a direct route — Add Lens (pre-seeded with that code) or
  Map to a Lens — instead of a dead end. Also on each frame's context menu.
- **Revert survives rescans and relaunches**: FIXED seals are restored from
  the persisted undo journals, so Revert Fix stays reachable.
- **Revert verification**: if anything modified a file after Uncoded fixed
  it (e.g. Lightroom saving metadata), revert refuses with an explanation
  instead of corrupting the file.
- Add Lens no longer keeps a stale auto-suggested code when switching
  profiles; a user-clicked code is never overridden.
- The fix confirmation dialog now carries the Lightroom
  read-metadata-from-file caveat.
- Scan state (folder, results, marks, overrides) survives switching
  sidebar tabs.

## v0.1.0 — 2026-07-19

First release.

- Contact-sheet scan view with embedded-preview thumbnails, detected 6-bit
  codes drawn as flange pit patterns, grid/list toggle
- One-step lens setup: pick from locally installed Adobe lens-correction
  profiles, pick the borrowed code (spec-ranked suggestions)
- Bundled community 6-bit code table (76 entries) with a lens-name
  normalizer matching camera strings ("1:2/35") to catalog names ("35mm f/2")
- Manual overrides: mark frames, assign any lens
- Native in-place metadata engine (no exiftool): ~3 ms per fix, image data
  untouched, byte-perfect undo journal, optional .bak copies
- Fixes EXIF lens fields + XMP aux/crs including the Adobe lens-correction
  profile assignment
