# Contributing

## Branch model (git flow)

- **`develop`** — integration branch and the default for PRs. Day-to-day
  work lands here (directly or via `feature/*` branches).
- **`main`** — releases only. `develop` is merged into `main` when a
  version ships.
- **Tags** — pushing a `v*` tag on `main` triggers the Release workflow,
  which builds the DMG and publishes a GitHub release.

## Release checklist

1. Bump `MARKETING_VERSION` in `project.yml` on `develop`
2. Merge `develop` → `main`
3. `git tag vX.Y.Z && git push origin main vX.Y.Z`

## Development

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme Uncoded test
```

CI builds and tests every push to `main`/`develop` and every PR.
