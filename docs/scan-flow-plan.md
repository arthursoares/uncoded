# Scan and assignment flow improvements

## Scope and cleanup plan

Keep the existing metadata engine, persistent model, and visual language. Fix the five reviewed workflow gaps with no new dependencies. Preserve existing untracked documentation and screenshots.

Tracking: [assignment scope #9](https://github.com/arthursoares/uncoded/issues/9), [bulk selection #10](https://github.com/arthursoares/uncoded/issues/10), [assignment wording #11](https://github.com/arthursoares/uncoded/issues/11), [code transfers #12](https://github.com/arthursoares/uncoded/issues/12), and [rescan retention #13](https://github.com/arthursoares/uncoded/issues/13).

1. Add state-transition regression tests before changing scan-session behavior. Keep the existing stale-scan and lens-deletion protections.
2. Centralize photo selection and override operations in ScanSession so grid/list UI share behavior. Preserve assignment scope; expose visible/unresolved selection and clear actions.
3. Retain pending overrides and selected URLs when rescanning the same folder, pruning missing files. Isolate different folders and stale scans; handle lens deletion during rescans.
4. Clarify per-photo overrides versus saved code mappings in the scan UI and mapping sheet. Make selection visible and accessible.
5. Show code ownership and confirm transfers in Add Lens, Change Code, and Map Code before any mutations. Preserve multiple codes per lens. Add meaningful regression coverage for mapping transitions.
6. Run the macOS build and test suite, then obtain independent review and fix reproducible issues. Record runtime/UI verification limits honestly.

No release, version bump, or raw-file mutations are required. Prefer existing controls and state over new abstractions; keep changes scoped to scan/session and mapping UI.

## Verification

- Final native Debug build and permanent suite: 203 tests, six fixture-dependent skips, zero failures.
- New coverage: assignment scope, selected photos with no pending write, failures-only scope, same-folder rescans, overlapping scans, deletion during rescan, mapping transfers, stale confirmations, and preservation of other codes.
- Synthetic in-memory native grid/list renders inspected at 1000 × 650 points. Live list selection and Cmd-A/Shift-Cmd-A checked through accessibility; unresolved selection kept the primary Fix action disabled while other writes remained available through explicit Fix All.
- Temporary rendering harness removed before delivery. Existing untracked docs/screenshots were preserved.
- Independent source review found no remaining blockers after fixing fail-open mapping reads and adding direct scope regression coverage.
- Not verified: forced SwiftData store-read failure injection, rare native error/transfer-alert layouts, or the six real-file fixture tests without their input DNGs.
