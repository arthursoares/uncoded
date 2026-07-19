# Announcing Uncoded — honest lens metadata for M shooters

*Draft for blog + communities. Adjust links once the repo/releases are public.*

---

## Blog version

If you shoot a Leica M with third-party glass, your files are lying to you.

M bodies identify lenses by the 6-bit code on the bayonet — six painted
fields the camera reads optically. My Voigtländer 35/2 Ultron doesn't have
an official code, so like everyone else I coded it as a Summicron. The
camera is happy. But every DNG now says *Summicron-M 1:2/35 ASPH.*, and
Lightroom dutifully applies Summicron corrections to a lens that isn't one.
Ten years from now I won't remember which "Summicron" was actually the
Ultron and which was really a Summicron.

A while ago I wrote a command-line tool
([fix_6bit_exif](https://github.com/arthursoares/fix_6bit_exif)) that
rewrote the metadata with exiftool. It worked, but it was a programmer's
answer. **Uncoded** is the photographer's one: a native macOS app.

**How it works.** Drop a folder of DNGs and you get a contact sheet —
thumbnails from the embedded previews, each frame stamped with the 6-bit
code it claims, drawn as the actual pit pattern from the flange. Tell the
app which codes your real lenses wear (it ships the community 6-bit code
table, and picks lens-correction profiles straight from your Lightroom
install, so there's nothing to type). Frames that resolve to a real lens
light up; one click rewrites the truth into the files — lens make, model,
focal length, and the Adobe lens-correction profile, so Lightroom's Lens
Corrections panel shows your actual lens. For adapted glass with no code at
all, mark frames like a contact sheet and assign a lens manually.

**Why I trust it with my raws** (and you should demand this from anything
that touches yours): Uncoded doesn't rewrite files. Its native DNG engine
reads a few KB of metadata per file and patches values in place — the image
data is never touched, a fix takes ~3 milliseconds. Every fix records a
byte-level undo journal, so *Revert Fix* restores the file byte-for-byte —
that's verified by hash in the test suite, and validated against ExifTool
on real M11 files. If you want belt and suspenders, a preference keeps a
one-time `.bak` copy of every file too.

**Get it:** download the DMG from the GitHub releases page
(github.com/arthursoares/uncoded). It's v0.1 and unsigned for now —
right-click → Open on first launch. macOS 14+. Free.

Credits where due: the code table is based on the community-maintained
Leica M 6-bit lens code spreadsheet, and the engine is validated against
Phil Harvey's ExifTool. Not affiliated with Leica or Adobe.

I'd love to hear what breaks and what's missing — issues and lens-table
corrections especially welcome.

---

## Short version (forums / Reddit)

I built **Uncoded**, a free native macOS app for a very Leica problem:
third-party lenses coded with borrowed 6-bit codes, so every DNG claims
Summicron and Lightroom applies the wrong correction profile.

Uncoded scans your DNGs into a contact sheet showing which borrowed code
each frame claims (drawn as the actual flange pit pattern), lets you map
codes to the lenses you really own — profiles picked straight from your
Lightroom install — and rewrites the truth in place: EXIF lens fields plus
the Adobe lens-correction profile. Native engine, no exiftool, ~3 ms per
file, image data untouched, byte-perfect undo journal, optional `.bak`
copies.

v0.1, unsigned (right-click → Open), macOS 14+:
github.com/arthursoares/uncoded — feedback and lens-table corrections very
welcome.
