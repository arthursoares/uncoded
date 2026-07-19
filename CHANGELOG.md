# Changelog

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
