---
name: release
description: Cut a Framewise release. Bumps the semantic version, writes changelog entries derived from the actual code diff (not just commit subjects), commits CHANGELOG.md, tags, and pushes the tag to trigger the GitHub Actions release workflow. Use when the user asks to "cut a release", "ship a release", "tag a new version", "bump the version", or "update the changelog".
---

# Framewise Release

Cut a release by reading the **actual code diff** since the last tag, distilling user-facing changes into `CHANGELOG.md`, then tagging and pushing to trigger the build/release workflow.

## Prerequisites (verify before starting)

- [ ] Working tree is clean (`git status` is empty)
- [ ] On `main` and up to date with `origin/main`
- [ ] At least one `v*` tag exists (`git describe --tags --abbrev=0` succeeds)
- [ ] `CHANGELOG.md` exists at the repo root — if not, run **Initial backfill** below first

If any check fails, stop and tell the user what's blocking.

## Workflow

Copy this checklist and tick items off as you go:

```
- [ ] 1. Confirm bump type (patch / minor / major)
- [ ] 2. Compute new version
- [ ] 3. Read the actual code diff since the last tag
- [ ] 4. Categorize changes (Added / Changed / Deprecated / Removed / Fixed / Security)
- [ ] 5. Update CHANGELOG.md
- [ ] 6. Commit CHANGELOG.md
- [ ] 7. Tag the commit
- [ ] 8. Push main + the tag (this triggers the release workflow)
```

### 1. Confirm bump type

Ask the user which bump to apply. Use `AskQuestion` if available; otherwise ask conversationally.

| Bump | When to use |
|------|-------------|
| patch | Bug fixes only, no new functionality |
| minor | New backwards-compatible features |
| major | Breaking changes |

### 2. Compute the new version

```bash
LATEST=$(git describe --tags --abbrev=0)            # e.g. v0.4.0
NUM="${LATEST#v}"
IFS='.' read -r MAJ MIN PAT <<< "$NUM"

case "$BUMP" in
  patch) NEW="v${MAJ}.${MIN}.$((PAT + 1))" ;;
  minor) NEW="v${MAJ}.$((MIN + 1)).0"      ;;
  major) NEW="v$((MAJ + 1)).0.0"           ;;
esac

echo "$LATEST -> $NEW"
```

Confirm `$NEW` with the user before continuing.

### 3. Read the actual code diff (CRITICAL)

> **Do not base changelog entries solely on commit messages.** Commit subjects are often inaccurate, incomplete, or describe internal refactors. The diff is the source of truth.

Start by scoping:

```bash
git diff --stat "$LATEST..HEAD"            # which files, how much
git log --oneline --reverse "$LATEST..HEAD" # subjects (orientation only)
```

Then read the diff itself:

```bash
git diff "$LATEST..HEAD"                   # whole diff (small releases)
# or, for large releases, file by file in --stat order:
git diff "$LATEST..HEAD" -- path/to/file.swift
```

If the cumulative diff is too large to digest in one read, walk files in the order shown by `--stat`, skipping vendored / generated files.

For each meaningful change, identify whether it is:

- **Added** — new public API, new file, new feature, new keybinding, new supported file format, new menu item, new UI surface
- **Changed** — rename, signature change, behavioral change, default-value change, performance change visible to the user
- **Deprecated** — soon-to-be-removed surface
- **Removed** — public surface deleted
- **Fixed** — bug fix (look for added `nil` checks, off-by-one corrections, error-handling additions, math corrections in shaders)
- **Security** — security-relevant fixes

Skip:

- Pure internal refactors with no user-visible effect
- Comment-only / whitespace / formatting changes
- Build-artifact or `.gitignore` churn
- Test-only changes (unless they shipped a new test command)

### 4. Categorize

Group entries under [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) sections in this order, omitting any section that is empty:

```
### Added
### Changed
### Deprecated
### Removed
### Fixed
### Security
```

### 5. Update CHANGELOG.md

Insert the new section directly above the most recent version's section (i.e. it becomes the new top-most version). The repo intentionally does **not** keep an `## [Unreleased]` section — the entries for the upcoming release are written here at release time, generated fresh from the diff. Use today's date in `YYYY-MM-DD`.

```markdown
## [0.5.0] - 2026-05-06

### Added
- File-association support: Framewise registers as a viewer for video and
  image types and accepts multi-file "Open With" / drag-and-drop pairs.
- Hover pixel readout chip showing channel-tinted RGB(A) values, with delta
  formatted using the active error metric.

### Changed
- Renamed `VideoEngine` to `MediaEngine`; per-side state moved from
  `videoSizeA/B`, `hasVideoA/B`, `videoNameA/B` to the `media*` equivalents.
- Maximum zoom raised from 200× to 1000× so the in-shader pixel readout
  reliably triggers on high-resolution media.

### Fixed
- In-shader RGB value overlay now displays alpha when alpha differs from 1.0
  (split mode) or when the alpha delta is non-zero (error mode).
```

Each entry should be:

- One sentence, complete and readable in isolation
- Past tense, user-facing language
- Specific enough that a user can decide if the change matters to them
- Reference filenames or symbols only when it sharpens the meaning

### 6. Commit CHANGELOG.md

```bash
git add CHANGELOG.md
git commit -m "Update CHANGELOG for ${NEW}"
```

The tag in step 7 must point at this commit, so commit before tagging.

### 7. Tag

```bash
git tag -a "$NEW" -m "Release $NEW"
```

### 8. Push

```bash
git push origin main
git push origin "$NEW"
```

Pushing the `v*` tag triggers `.github/workflows/build.yml`, which:

1. Builds the universal binary and applies the version stamp via `scripts/apply-version.sh`.
2. Signs / notarizes (if secrets are configured).
3. Creates a GitHub release whose body comes from this version's CHANGELOG section, extracted by `.cursor/skills/release/scripts/extract-changelog.sh`.

After pushing, watch the workflow at `gh run watch` (or the Actions tab) to confirm the release publishes.

## Initial backfill (run once)

If `CHANGELOG.md` does not exist yet, populate it from existing tag history before cutting any new release.

1. Create `CHANGELOG.md` at the repo root using the template below.
2. For each consecutive tag pair, oldest to newest, run:

   ```bash
   git diff --stat "$PREV..$NEXT"
   git diff "$PREV..$NEXT"
   ```

   Read the diff and write that version's section using the same rules as steps 4–5.
3. For the very first tag (no previous tag), summarize the initial state from `git log --reverse "$FIRST_TAG"` plus the contents of `git show "$FIRST_TAG":README.md`.
4. Land the backfill in its own commit (don't ride it into a release commit).

### CHANGELOG.md template

```markdown
# Changelog

All notable changes to Framewise are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - YYYY-MM-DD

### Added
- ...
```

> No `## [Unreleased]` section — release entries are written at the moment of cutting the release, generated fresh from the diff.

## Utility script

`.cursor/skills/release/scripts/extract-changelog.sh <version>` prints the body of one version's section (no header), used by the GitHub Actions release step to set the release body via `body_path`.

```bash
.cursor/skills/release/scripts/extract-changelog.sh 0.5.0    # 0.5.0 or v0.5.0 both work
```

The script exits non-zero if the requested version isn't present in `CHANGELOG.md`, which is intentional — fail the release rather than ship empty notes.

## Anti-patterns

- Copying commit subjects verbatim into the changelog
- Adding entries for refactors with no user-visible effect
- Tagging before committing the CHANGELOG (the tag must include the changelog commit)
- Bumping the major version for additive changes, or the patch version for new features
- Force-pushing or moving a tag once published (tags are immutable)
- Editing `CFBundleShortVersionString` / `CFBundleVersion` in `Info.plist` directly — versioning is derived at build time by `scripts/apply-version.sh`
