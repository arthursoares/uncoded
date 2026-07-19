# Uncoded

**Truthful lens metadata for Leica M shooters using third-party glass.**

Leica M cameras identify lenses by a 6-bit code on the bayonet mount. Third-party
lenses (Voigtländer, Zeiss, TTArtisan, 7Artisans, …) have no official code, so
photographers borrow a Leica code — and every DNG then claims it was shot with a
Leica lens, and Lightroom applies the wrong correction profile.

Uncoded is a native macOS app that:

1. **Scans** your DNGs and detects which borrowed 6-bit code / Leica lens name
   each file claims — reading only the few KB of metadata it needs, not the
   whole file.
2. **Maps** codes to your real lenses. The app ships the community 6-bit code
   table and indexes the Adobe lens-correction profiles (`.lcp`) already
   installed with Lightroom / Camera Raw on your Mac, so you pick your actual
   lens from a list instead of typing digests by hand.
3. **Rewrites** the EXIF/XMP lens metadata in place — lens make, model, focal
   length, and the Adobe lens-correction profile — so Lightroom and everything
   downstream sees the truth. *(Write support is in progress; the current build
   is a read-only preview.)*

Uncoded is the native successor of the
[fix_6bit_exif](https://github.com/arthursoares/fix_6bit_exif) CLI tool.

## Status

Early development. Currently implemented:

- Bundled 6-bit code table (75+ codes, from the community spreadsheet)
- Lens-name normalizer that matches camera strings like
  `Noctilux-M 1:1.2/50 ASPH.` to catalog names like `Noctilux-M 50mm f/1.2 ASPH`
- Native TIFF/DNG metadata reader (EXIF IFD + XMP packet, no exiftool)
- Adobe `.lcp` lens-profile indexer (M-mount profiles installed by Lightroom)
- SwiftUI shell: scan a folder, browse codes, manage your lens list

## Requirements

- macOS 14+
- For the lens-profile picker: Adobe Lightroom / Camera Raw installed (the app
  reads `/Library/Application Support/Adobe/CameraRaw/LensProfiles`)

## Building

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme Uncoded -configuration Release build
```

Unsigned developer builds for now — right-click → Open on first launch.

## Credits

- 6-bit code table based on the community-maintained
  [Leica M 6-bit code spreadsheet](https://docs.google.com/spreadsheets/d/1Bx9L8IqhiQOc-jbGNaWn4rV-HRmf_zMHyHuLRkiO_FY/edit).
