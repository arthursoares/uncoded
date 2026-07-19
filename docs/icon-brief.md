# Uncoded — App Icon Design Brief

## Project snapshot

**Product:** Uncoded, a native macOS app for Leica M photographers.
**Platform:** macOS 14+ (icon must follow current macOS squircle conventions).
**Working aesthetic:** dark instrument panel — think camera top plate, not web app.

## What the app does (context, not content)

Leica M cameras identify lenses by a **6-bit code**: six painted fields —
black or white — in a shallow arc on the lens's bayonet flange, read
optically by the camera. Third-party lenses have no official code, so
photographers "borrow" a Leica code, and every photo then lies about which
lens shot it. Uncoded detects those lies and rewrites the metadata with the
truth.

The app's entire visual identity hangs on that one artifact: **the 6-bit
pit pattern**. Inside the app, every code is drawn as six dots — filled
(black paint) or hollow (bare metal). The icon should be the purest
expression of this mark.

## Audience

Leica M shooters: design-literate, detail-obsessed, allergic to kitsch.
They own deliberately minimal, mechanical objects. They will recognize the
6-bit arc instantly — it's engraved on hardware they handle daily. The icon
should feel like it was made by someone who owns the same hardware.

## The mandatory motif

Six circular fields in a row or shallow arc, mixed filled/hollow, e.g.:

```
● ○ ● ● ○ ●      or on an arc, as on the flange:   ●
                                                  ● ○
                                                 ○   ●
```

Reference: photograph the rear mount of any 6-bit-coded M lens (or search
"Leica 6-bit code flange"). The fields sit in a recessed arc segment near
the bayonet's edge.

Optional deliberate touch: the app is called **Uncoded** — a pattern where
some pits are conspicuously empty (hollow) tells the product story: the
lens without a code is the one this app serves.

## Concept territories (in order of our preference)

1. **The mount, straight on.** A circle reading as a lens bayonet seen from
   the rear — flange segments implied, with the 6-bit pit arc as the only
   detailed element. Metallic charcoal, engraved feel. At 16 px it
   collapses gracefully to "dark circle with dots" — still legible.
2. **The pits alone.** Six dots on a dark squircle, nothing else. Brutally
   minimal; lives or dies on spacing, size and materiality (engraved,
   slightly recessed — not flat UI dots).
3. **Contact-sheet frame.** A dark film-rebate frame with the pit dots as
   edge markings. Ties to the app's scan view, but weakest at small sizes.

## Palette & materiality

- Ground: near-black charcoal `#161618`, subtle vertical brushed or
  anodized texture acceptable — restrained, no skeuomorphic leather/glass.
- Marks: warm off-white `#EBE8DE` (engraved paint, not pure white).
- Accent: signal red `#E01B24` — **at most one small element** (a single
  pit, an index dot). May also be omitted entirely.
- Optional secondary: film-rebate amber `#EDA340` — only if territory 3.

## Trademark caution (hard requirement)

No Leica trademarks: no red roundel with type, no "Leica"/"Leitz"
lettering, no script logo, nothing that reads as the Leica red-dot badge.
A single small red *pit* among six is fine; a lone red circle centered on
the icon is not. When in doubt, drop the red.

## Technical constraints

- Master at **1024×1024** on the Apple squircle grid; test at 512, 256,
  128, 64, 32, and **16 px** — the pit pattern must survive at 16 px (at
  that size, dots may merge into 6 alternating ticks; design for it).
- Deliver as layered **Icon Composer** project if possible (macOS 26
  Liquid Glass: separate background / motif layers), plus flat PNG
  fallbacks. Provide light, dark, and tinted/clear variants — the dark
  variant is the canonical one for this app.
- No text anywhere in the icon. No gradients steeper than a gentle
  vignette. No drop shadows outside the squircle.

## Deliverables

1. Icon Composer project (or layered source: Figma/Sketch/PSD)
2. 1024 master PNG, light + dark + tinted variants
3. 16/32 px hand-checked versions (pixel-hinted if needed)
4. One-line usage note: which code (if a real one) the pits spell, so we
   never accidentally ship a pattern meaning a specific Leica lens we'd
   rather not imply. Safe choices: a deliberately non-assigned pattern, or
   the "partially uncoded" motif from above.

## References available on request

- App screenshots (contact sheet, code grid, lens cards) — the icon should
  feel like their sibling.
- The in-app pit glyph: 6 circles, 1 pt stroke, filled vs hollow.
- Photos of a real coded flange.
