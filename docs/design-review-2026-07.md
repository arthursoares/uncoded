# Uncoded v0.1.0 — Final Design Review

Synthesis of five review lenses (onboarding, IA/navigation, core flows, visual/a11y, trust/safety) adjudicated by two adversarial judges. 36 raw findings collapsed to 24 surviving entries; every surviving entry below was kept by **both** judges. Convergence across lenses is flagged where it occurred — it is the strongest signal in this review.

---

## 1. Executive summary

Uncoded's core engine and aesthetic are sound, but v0.1.0 has two launch-blocking classes of defect. First, the **first-run path is a dead end**: a user with no lenses defined scans a folder, sees "6 CODED / 0 MAPPED," and is offered no route to the one setup step the app requires — three separate lenses independently converged on this. Second, the **flagship trust feature is broken in practice**: the undo journal persists on disk but is unreachable after any rescan or relaunch (three lenses converged), and revert itself patches byte offsets with zero verification, so it can corrupt a raw that Lightroom has since touched. Two smaller P0s — a stale auto-suggested 6-bit code in Add Lens that ships exactly the wrong-mapping bug the app exists to fix, and a missing one-sentence Lightroom caveat — complete the pre-launch list. Everything else is v0.2 workflow/polish work; notably, both judges rejected a welcome-tutorial approach to onboarding in favor of in-context guidance.

---

## 2. Fix before going public (P0)

### P0-1. The post-scan dead end: "0 mapped" offers no path forward
*(Findings 0, 2, 9 — onboarding and ia-navigation lenses converged; both judges P0.)*

The most likely first-run: launch, drop a folder, see 9 frames / 6 coded / 0 mapped. Because `fixable` is empty, no Fix button renders (`ScanView.swift:121-128`); frames show only the passive 9pt "code not mapped" (`:417`); and the one piece of rescue copy — "add lenses under 'My Lenses' first" — is inside the `markBar`, which only appears after the user clicks a frame, an interaction nothing invites (`:179-183`). The user concludes the app detected a problem it cannot act on.

**Implementation sketch** (`ScanView.swift`, `ContentView.swift`):
- In the results header, when `!session.results.isEmpty && lenses.isEmpty && codedCount > 0`, render an amber banner where the Fix button would sit: *"6 frames wear code 011101 you haven't claimed — Add Lens…"*. Compute the most frequent detected code from `session.results` and present `AddLensSheet` directly with `CodePickerList` pre-seeded to it (add an optional `preselectedCode:` init parameter).
- Pass the sidebar `selection` binding (or an `onNavigate` closure) from `ContentView` into `ScanView` so the banner can alternatively flip to `.lenses`.
- Add a context-menu item on any coded-but-unmapped `FrameCell`: *"Map code 001100 to a lens…"*, opening the same pre-seeded sheet.
- Promote the "add lenses first" hint out of `markBar` into the header whenever `lenses.isEmpty`.

### P0-2. Revert vanishes after rescan or relaunch, though journals persist
*(Findings 10, 15, 30 — ia-navigation, core-flows, AND trust-safety independently converged; both judges P0.)*

`JournalStore` persists journals precisely so fixes survive restarts (`Fixer.swift:3-13`), and the README promises it (line 45). But the only revert affordance is gated on in-memory `session.fixState` (`ScanView.swift:150, 326`), which `scan()` wipes (`:290`). After a rescan or relaunch, FIXED seals disappear and no UI anywhere can reach `Fixer.revert`. The safety net is invisible exactly when needed — a week later, when Lightroom looks wrong.

**Implementation sketch**: In `scan()`, after `DNGScanner.scan` returns, probe `JournalStore.journal(for:)` for each URL (a cheap directory read) and seed `session.fixState[url] = .fixed` where a journal exists — the FIXED seal, fixed-count stat, and "Revert Fix" context item then survive for free. Add a durable escape hatch as a menu command (`File > Revert Fixes in Folder…`) in `UncodedApp`'s `.commands`.

### P0-3. Revert patches by absolute path with zero verification — it can corrupt the file it protects
*(Finding 31 — trust-safety; both judges P0.)*

`journal(for:)` matches only `filePath == file.path` (`Fixer.swift:34`), and `TIFFWriter.revert` (`TIFFWriter.swift:85-95`) blindly seeks to recorded offsets, writes original bytes, and truncates to `originalLength`. Move a fixed DNG and the undo promise silently evaporates ("No undo journal found"). Worse: if Lightroom's "Save Metadata to File" restructures the TIFF and the user then reverts, Uncoded stomps arbitrary offsets and truncates — corrupting the original raw. This is data destruction inside the flagship safety feature, for users who may have disabled .bak.

**Implementation sketch**: Extend `WriteJournal` with a post-write fingerprint: expected file length (`originalLength + appendedBytes`) plus a hash of the bytes at each patch offset (`patch.new` is already stored, so verification needs no new data for existing journals). In `revert`, verify length and current-bytes-at-offset before writing; on mismatch, refuse with plain language: *"This file changed since Uncoded fixed it — revert would damage it. Restore the .bak instead."* Fingerprint-based lookup for moved files can follow post-launch; the verification gate is the launch blocker.

### P0-4. Add Lens silently keeps a stale auto-suggested code when the user switches profiles
*(Finding 16 — core-flows; both judges P0.)*

`fill(from:)` auto-selects the best borrowed code only `if selectedCode == nil` (`LensesView.swift:259-261`). Click Zeiss Biogon 35/2 (preselects 011101), change your mind, click a Voigtländer 15mm — name/focal/aperture update but the checked code stays frozen on the Zeiss's suggestion, and nothing flags it as stale. A trusting user ships a wrong code→lens mapping — the exact error class the app exists to eliminate — and every batch Fix thereafter writes wrong metadata.

**Implementation sketch**: Add `@State private var codeWasAutoSelected = true` in `AddLensSheet`; set it `false` in `CodePickerList`'s selection callback when the user clicks a code; in `fill(from:)`, whenever `codeWasAutoSelected`, re-run `SixBitTable.ranked(for: id).first` and replace the selection. A user-clicked code is never overridden.

### P0-5. First fix appears to do nothing in Lightroom — the re-import caveat is README-only
*(Finding 4 — onboarding; both judges P0.)*

For photos already in a catalog, Lightroom shows nothing until Metadata → Read Metadata from File (README lines 73-78). The confirmation dialog (`ScanView.swift:67-71`) and post-fix UI never mention this, so the likely first validation loop — fix, check Lightroom — reads as "the fix did nothing": the worst first impression for an app selling trustworthiness.

**Implementation sketch**: Copy-only. Append to both `keepBak` branches of the dialog message: *"Photos already in a Lightroom catalog need Metadata → Read Metadata from File afterwards; photos imported after fixing just work."*

---

## 3. v0.2 (P1)

**Mapping lives in two places with different semantics and silent stealing** (finding 8). `MapCodeSheet` calls `Mappings.assign` — silently stealing codes from other lenses (which quietly revert to "uncoded") and permitting multi-code lenses — while `ChangeCodeSheet` uses `Mappings.set` with a one-code invariant. Judge 1 found `AddLensSheet.save` also uses `assign`, so merely adding a lens can strip a code from another. Fix: route every path through `Mappings.set`; when an assignment would steal, confirm explicitly ("Code 011101 is currently worn by Zeiss Biogon — move it to Voigtländer?").

**Override affordances are disjoint across view modes** (findings 13 + 19 merged). List rows: right-click `assignMenu`, no marking. Sheet frames: tap-to-mark, context menu with only Revert. Fix: add `assignMenu(for: [file.url])` to `FrameCell`'s context menu (pass a closure or `@ViewBuilder` into `ContactSheet`) and wire list-row taps to `toggleMark`.

**Tap-to-mark is invisible** (finding 17). The only sheet-mode override path is documented in a source comment; no hover state, no cursor change, `helpText` never mentions it. Fix: `.onHover`-driven accent border + corner mark on `FrameCell`, append "click to mark for assignment" to `helpText`, one-line header hint when coded-unmapped frames exist and selection is empty.

**No bulk marking or keyboard support** (finding 18). "Whole roll on one lens" costs 40 clicks. Fix: "Mark All Unmapped" header button, `.keyboardShortcut("a", modifiers: .command)`, `.onKeyPress(.escape)` to clear. Defer shift-range selection.

**Drag-and-drop dies after the first scan** (finding 20). `.dropDestination` is scoped to `dropZone`, which never re-renders once results exist; `fileImporter` is folder-only though `DNGScanner` handles single DNGs. Fix: move `.dropDestination(for: URL.self)` to the outer `VStack` with an `isTargeted` highlight; add `.dng`'s UTType to `allowedContentTypes`.

**Scanning a no-DNG folder silently bounces to the pristine drop zone** (finding 3). Fix: when `session.folder != nil && results.isEmpty && !scanning`, render a distinct state: "No DNGs found in ~/… — Uncoded scans .dng files; JPG and other raw formats aren't supported."

**Theme.faint fails contrast and carries the most actionable state** (finding 23). White 0.35 measures ~2.6:1 on bg, ~3.0:1 on the rebate black — far below AA — and the hierarchy is inverted: "code not mapped" (the state demanding action) is the dimmest text on screen. Fix: render "code not mapped" in `Theme.rebate` amber (6.45:1, semantically "attention" in the film language); raise `Theme.faint` to `Color(white: 0.46)`.

**System blue leaks into every sheet** (finding 27). No root tint, so default buttons and focus rings render macOS blue inches from Leica red. Fix: `.tint(Theme.accent)` once on the `NavigationSplitView` (or `WindowGroup`), delete ad-hoc per-button tints. Highest polish-per-line-changed in the review.

**Failed fixes are illegible dead ends** (finding 33). 9pt `lineLimit(1)` error text, `helpText` omits `.failed`, and `fixable` requires `fixState == nil` so a failed frame can never be retried without a full rescan. Fix: add `.failed` to `helpText`, popover with full error + "Retry Fix" (clears `session.fixState[url]`), same item in the context menu.

**Cards are invisible to VoiceOver and the keyboard** (finding 24 — *priority contested, see section 5*). `FrameCell`/`LensCard`/`CodeCard` are `.onTapGesture`-only; all state lives in `.help()`. Fix is mechanical: wrap each in `Button { } label: { }` with `.buttonStyle(.plain)`, `.accessibilityElement(children: .ignore)`, `.accessibilityLabel(helpText)` (string already exists), `.isSelected` trait; give the view-mode Picker `Label` + `.labelStyle(.iconOnly)`.

---

## 4. Later (P2)

- **Drop-zone copy** (5): when `lenses.isEmpty`, add "First time? Set Up My Lenses" under Choose Folder — belt-and-braces once P0-1's banner exists.
- **Codes tab reframe** (6 + 11 merged; two lenses converged): rename to "Code Table," drop the "unmapped" badge wall, make tapping an unowned code route to the lens-side flow.
- **Manual Add Lens without Adobe profiles** (7): copy explaining the no-correction-profile consequence and the code-less-lens trade-off.
- **No folder memory** (12): recent-folder security-scoped bookmarks + differential rescan that preserves overrides/fixState.
- **Vocabulary drift** (14): "coded/mapped/uncoded/unmapped/coded as" — converge on one axis (e.g. coded/claimed); partly free if the Codes-tab badge dies.
- **No determinate progress or cancel** (21): plumb `(done, total)` through `ScanSession`, hold the Task for cancellation.
- **Un-confirmed lens deletion** (22): `confirmationDialog` spelling out the mapping-cascade consequence.
- **Red overload** (25): keep red for selection/attention and errors only; neutral raised treatment for the healthy "coded" card border.
- **9pt floor** (26): raise the rebate row to 10-11pt; skip the scale slider (scope creep per both judges).
- **Sheet conventions** (29): `.keyboardShortcut(.cancelAction)` on every Cancel, a real Cancel in `MapCodeSheet`, `.isHeader` traits on engraved titles.
- **Before/after preview using the existing dryRun engine** (32 — *priority contested, see section 5*): per-file diff sheet via `TIFFWriter.apply(dryRun: true)`.
- **Failed revert strands the file** (34): distinct `revertFailed` state keeping Revert retryable + "Show .bak in Finder"; fold into the P0-2/P0-3 revert rework.
- **Settings/journal housekeeping** (35): first slice is a `SettingsLink` from the "per Settings" dialog text; journal dashboard and .bak cleanup later (.baks are full DNG copies — real gigabytes).

---

## 5. Contested

No finding split on keep/drop — both judges agreed on every survival decision. Two findings split on **priority**:

- **Finding 24 (accessibility)** — Judge 1: P1 ("basic operability, not scope creep; the fix is bounded because helpText already exists"). Judge 2: P2 ("niche visual tool, no user has asked yet, but should not stay unfixed forever"). **Placed in v0.2**: the fix is mechanical and the label strings already exist.
- **Finding 32 (dry-run preview)** — Judge 2: P1 ("the right trust move for the first-fix moment; the engine already supports it"). Judge 1: P2 ("a per-file preview sheet is real design and engineering for a solo maintainer; the launch-critical trust gaps are P0-2/P0-3"). **Placed in Later**: the P0 trust fixes carry the launch; revisit for v0.2 if capacity allows.

Unanimously rejected (recorded for completeness): **finding 1** (three-panel welcome tour — the audience physically coded their lenses and owns the mental model; in-context routing fixes the actual gap at a fraction of the cost) and **finding 28** (pit-glyph illegibility at dotSize 5 — contradicted by its own screenshot evidence; patterns are legible and the tooltip supplies the numeric fallback).

---

## 6. Onboarding plan

A minimal first-run design assembled from the surviving onboarding findings. Deliberately **no welcome sheet, no tutorial** (rejected by both judges): every intervention is in-context, conditional, and disappears once the user has lenses. Four moments:

**Moment 1 — the empty drop zone.** Keep the existing safety copy. When `lenses.isEmpty` (already `@Query`-able in `ScanView`), add one secondary line under Choose Folder: *"First time? Add your lenses and the codes they wear, so scans can resolve every frame."* with a "Set Up My Lenses" link routed through the sidebar binding. Users who go lenses-first skip every later intervention; users who drop a folder first are caught at Moment 3.

**Moment 2 — the scan that finds nothing.** A dropped folder with no DNGs renders the "No DNGs found in *path*" state (P1, finding 3), never the pristine drop zone. First interaction can fail loudly or succeed — never silently.

**Moment 3 — the contact sheet with unclaimed codes.** This is the load-bearing moment (P0-1). The amber banner sits exactly where the Fix button will eventually live — *"6 frames wear code 011101 you haven't claimed — Add Lens…"* — teaching the causal chain (claim codes → frames resolve → Fix appears) by spatial substitution rather than explanation. The Add Lens sheet opens pre-seeded with the scan's most frequent code, so the happy path is: click banner, click your lens profile, confirm the suggested code, save. Returning to Scan, frames resolve live and the banner is replaced by the red Fix button — the payoff frame of the whole onboarding.

**Moment 4 — the first Fix.** The confirmation dialog carries the .bak/journal sentence it already has, plus the Lightroom read-metadata sentence (P0-5). After the first completed scan, a one-time dismissible caption under the header (gated by `@AppStorage("hasSeenMarkHint")`) teaches the only non-obvious gesture: *"Click frames to mark them grease-pencil style, then assign a lens to the marked set."* — paired with the hover affordance from finding 17 so the hint confirms what the cursor already suggests.

Total new surface: two conditional lines of copy, one banner, one pre-seed parameter, one sentence in an existing dialog, one dismissible caption. Nothing to skip, nothing to re-show, and every element self-retires once the user has lenses mapped.