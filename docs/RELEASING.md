# Release Instructions

Releasing is a button, a review, and (optionally) an approval:

1. **Actions → "Cut release" → Run workflow** (no inputs). It computes the
   next version — `X.Y.Z` from `upstream-base.txt`, the `-R` revision as the
   next free one derived from existing tags (nobody types a revision) —
   bumps `mobile-src/src/node_mobile_version.h`, stubs a dated CHANGELOG
   section, re-anchors `expected-tree.txt` by running `prepare.sh`, and
   opens a **release PR**.
2. **Fill in the CHANGELOG entry, review, and merge.** Merging is the
   release sign-off. (The bot's own push doesn't trigger PR checks — a
   `GITHUB_TOKEN` limitation — but your CHANGELOG commit does, and nothing
   publishes unverified either way: every gate re-runs on the merge push,
   and `release-check` is guarded off `pull_request` so the release chain
   can never fire from the unmerged PR.)

   The `release-notes` job (part of `ci-required`) checks the entry on the
   PR: it fails while the first CHANGELOG section is still the `_TODO_`
   stub, or isn't the section for the version being released. Run
   `scripts/release-notes.py` locally to see exactly what publish will
   ship. `publish` asserts the same thing, but by then the PR is merged
   and closed, and the only way out is another push to `recipe`.

   **Use squash or rebase, not a merge commit.** `release-check` reads
   `git log -1 --format=%s` to spot a `release-dryrun:` rehearsal, and a
   merge commit replaces that subject with `Merge pull request #N from …`,
   silently turning a rehearsal into a normal push. The *release* trigger
   itself is content-derived and unaffected — it's the dry run that breaks.
   Requiring linear history on `recipe` enforces this.
3. The merge push makes the version of record **untagged at HEAD**, which
   is the release trigger (`release-check` in `build.yml` — content-derived
   and idempotent; no magic commit wording). One run then carries the full
   gate chain — build matrix both flavors, boot smokes, NAPI smoke, the
   curated and full device suites, BrowserStack real devices — and the
   publish job, which `needs:` all of it.

   One of those needs is `upstream-base`, which is plumbing rather than a
   gate. The tag is pushed from a tree materialized by a depth-1 clone, so
   its history stops at the upstream base and the remote will only accept it
   if it already holds that base and everything under it. The job keeps this
   fork's `upstream-base` branch on the pinned tag, which puts those objects
   there and keeps them reachable. It no-ops in a second unless the base
   moved, so it costs nothing except on the run after an upgrade.
   → [UPGRADING.md](./UPGRADING.md)
4. **Optional human gate:** the publish job runs in the `release`
   Environment. Add required reviewers under Settings → Environments →
   release and the pipeline pauses for an approval click before tagging.
   With no reviewers configured it proceeds automatically.
5. Publish tags **`vX.Y.Z-R`** on a materialized full-source commit (the
   release stays browsable as a complete tree) and creates the GitHub
   **prerelease** with four zips: `nodejs-mobile-{android,ios}{,-lite}-X.Y.Z-R.zip`.
   Promote (untick "prerelease") when satisfied — the `full` flavor has
   already passed real devices by construction; `lite` is
   emulator/simulator-tested only.

A failed gate means no tag and no release; fix on `recipe` and the next
push retries automatically (the version is still untagged — the trigger is
self-healing). For a full rehearsal without tagging/publishing, push a
commit whose subject starts with `release-dryrun:`.

## A release run builds cold

Budget **3–4 hours** for the build matrix on a release, against well under an
hour for a typical warm push. A release run compiles with no shared compiler
cache at all: no sccache, no R2 credentials in the job, and no restore of the
prebuilt `libnode` from the Actions cache. That is deliberate, and it is the
one measure that takes cache poisoning out of the supply chain rather than
merely making it harder — the bytes that ship are compiled in the run that
ships them. [BUILDING.md](./BUILDING.md#the-ci-compiler-cache) has the model
and the wiring.

Two consequences worth knowing before you start one:

- A `release-dryrun:` rehearsal builds cold too. It has to, or it isn't
  rehearsing the release. Expect it to take as long as the real thing.
- Re-running a failed release gate re-runs the cold build. Prefer fixing on
  `recipe` and letting the next push retry (which is the self-healing path
  anyway) over "Re-run all jobs" on a run whose build matrix already
  succeeded.

This is not new cost in practice: the version bump changes `HEAD:src`, which
already invalidated the `libnode` cache key on every release. It is now
structural rather than incidental.

## Versioning and tags

- `process.version` stays upstream's (`v24.18.0`) so every tool that parses
  Node versions keeps working; the mobile release is readable at runtime as
  **`process.versions.mobile`** (`"24.18.0-0"`, `-pre`-suffixed on
  non-release builds).
- Tags are `vX.Y.Z-R` (semver reads `-R` as a prerelease qualifier — apt
  for a variant build, and irrelevant to tag/URL consumers). Releases
  before the rename used `nodejs-mobile-X.Y.Z-R`; both spellings count as
  "already released" to `release-check` and to Cut release's revision
  computation.
- The annotated tag message carries **`Recipe-Commit: <sha>`** — the exact
  recipe-branch commit whose pipeline produced the release (`git show vX.Y.Z-R`
  answers "what generated this"); the release notes repeat it as a link. The
  tag itself points at the materialized tree, which is what the release was
  *built from* — the trailer records what it was *generated by*.

## Post-release

Bump the consumer plugins (`nodejs-mobile-react-native`, `-cordova`) as
needed. No version-unflag commit: the stack keeps upstream's release-tagged
`NODE_VERSION_IS_RELEASE` as-is.
