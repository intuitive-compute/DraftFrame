---
name: release
description: Cut a DraftFrame release. Commits pending changes, pushes a version tag that triggers the release workflow (build, sign, notarize, GitHub Release), then polls for that release and rewrites its notes into a curated Highlights section. Use when the user asks to cut, ship, publish, or tag a release (patch by default; minor/major or an explicit vX.Y.Z on request).
allowed-tools: Bash(git add:*), Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git commit:*), Bash(git tag:*), Bash(git push:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(swift build:*), Bash(swift test:*), Bash(swift-format:*), Bash(gh release view:*), Bash(gh release edit:*), Bash(gh run list:*), Bash(gh run view:*)
---

# Release

Cut a release of DraftFrame. The app version is derived entirely from the git
tag (there is no version file to bump). Pushing a `v*` tag triggers
`.github/workflows/release.yml`, which builds, signs, and notarizes the DMGs on
GitHub-hosted runners and then creates the GitHub Release with auto-generated
notes. **Never run `scripts/package.sh` locally** to make a release; the tag
push is the only trigger.

## Version bump

Read the requested bump from the argument; default to **patch**.

- `patch` (default): `v1.17.0` -> `v1.17.1`
- `minor`: `v1.17.0` -> `v1.18.0`
- `major`: `v1.17.0` -> `v2.0.0`
- An explicit `vX.Y.Z`: use it verbatim.

```bash
latest=$(git tag --sort=-v:refname | head -1)          # e.g. v1.17.0
IFS=. read -r major minor patch <<< "${latest#v}"
next="v$major.$minor.$((patch+1))"                      # patch bump
```

## Steps

1. **Preflight.** Confirm the current branch is `main` and `git status` shows
   only the changes that belong in this release. If unrelated/stray files are
   present (e.g. scratch files), do **not** stage them; stage only the files
   that are part of the change. Run the same checks CI runs and fix or stop on
   any failure (do not tag a broken tree):
   ```bash
   swift-format lint --strict --recursive Sources/ Tests/
   swift build
   swift test
   ```
   (If `swift-format` is not installed locally, note it and rely on CI's lint;
   never skip build and test.)

2. **Commit.** Stage the relevant files and write a single concise, imperative
   one-line subject describing what the change does. **No co-author / "Generated
   with Claude" line. No em dashes.** Commit with exactly one `-m`.

3. **Tag and push.** Compute `next` (see above). Push the commit first, then the
   tag (the tag push is what starts the release workflow):
   ```bash
   git push origin main
   git tag "$next"
   git push origin "$next"
   ```

4. **Poll for the release.** The workflow builds, signs, and notarizes both
   arches before creating the release, so this takes several minutes. Poll in
   the background so you're notified when it lands:
   ```bash
   until gh release view "$next" >/dev/null 2>&1; do sleep 20; done
   ```
   If it has not appeared after ~25 minutes, check the run with
   `gh run list --workflow=release.yml` / `gh run view` and report any failure
   instead of continuing.

5. **Rewrite the notes into Highlights.** The release is created with
   auto-generated notes. Replace them with a curated `## Highlights` section in
   the house style, preserving the `**Full Changelog**` link:
   - Derive the highlights from the commits in this release:
     `git log "$latest..$next" --pretty=format:'%s'`.
   - Match the established style (see any recent release, e.g. `v1.17.0`):
     a `## Highlights` heading, then one bullet per user-visible change, each
     led by a **bold short phrase.** followed by a plain-language sentence.
     User-facing wording, not commit subjects. **No em dashes.**
   - Keep the `**Full Changelog**: ...compare/<prev>...<new>` line that the
     auto-generated notes already contain (read it from the existing body so
     the URL is exact).
   - Write the final markdown to a temp file and apply it:
     ```bash
     gh release view "$next" --json body -q .body   # grab the Full Changelog line
     gh release edit "$next" --notes-file <path-to-notes>
     ```

6. **Report.** Print the release URL (`gh release view "$next" --json url -q .url`)
   and a one-line summary of the highlights.

## Notes

- Releases are immutable artifacts but the notes are editable; editing notes
  after creation is expected and safe.
- Do not create the GitHub Release yourself with `gh release create`; let the
  workflow create it so the signed/notarized DMGs are attached.
