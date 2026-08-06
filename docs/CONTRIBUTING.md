# Contributing

Only changes that fall within the [project goals](../README.md#project-goals-and-license)
will be accepted. For a major feature or a semantic change, please open an
issue for discussion first; for minor fixes, open a pull request directly.

## The development loop

```sh
scripts/prepare.sh                    # → ./out, a complete verified source tree
cd out
# ... edit, build, run tests ...                # BUILDING.md / TESTING.md
git commit -am "what I changed"       # any commit shape is fine
cd ..
scripts/regenerate-patches.py out     # fold changes back into patches/ + mobile-src/
```

Commit the regenerated `patches/` and `mobile-src/`, plus the
`expected-tree.txt` hash the script prints, and open a PR against `recipe`.

What goes where is enforced by the tooling: an edit to an upstream file
updates its owning patch, a new file lands in `mobile-src/`, and an edit to
an upstream file no patch owns is an error until you assign it in
`patches/files.map`. See [PATCHES.md](./PATCHES.md) for the rules and the
reasoning.

## Documentation

All project documentation lives in `docs/` on this branch, and none of it is
overlaid into the source tree. That is deliberate: `mobile-src/` is part of
the recipe, so a doc kept there would be inside `expected-tree.txt` — a typo
fix would be a source-tree change needing a new tree hash, and could not be
made from the GitHub web editor at all. Prose churn should not move the
integrity anchor for the binaries.

The generated tree therefore carries no docs of its own. When something in
the tree needs to cite one — a comment in `mobile-src/`, or a patched
upstream file — point at `docs/<FILE>.md on the recipe branch`, or use a
full URL for anything user-facing. Say `on the recipe branch` rather than a
bare `docs/`: upstream ships its own `doc/` directory, so an unqualified
path is ambiguous to a reader inside the tree.

## Third-party code

Third-party code is **vendored**, the way upstream Node vendors `deps/`:
checked in, covered by `expected-tree.txt`, and updated by a script that
downloads and verifies rather than by hand. There is one such dependency
today — [`mobile-src/deps/polywasm`](../mobile-src/deps/polywasm/README.md),
the WebAssembly polyfill iOS needs for `fetch()`; its README records the exact
provenance (version, hashes, the single local edit) and the update procedure.

Neither the build nor `scripts/prepare.sh` may depend on a package registry:
reconstruction has to stay deterministic and offline-capable, and a dependency
fetched at build time would sit outside the tree hash that anchors it.

## Commit messages

Follow the [Node.js commit message guidelines](https://github.com/nodejs/node/blob/main/CONTRIBUTING.md#commit-message-guidelines):
a subsystem prefix, imperative mood, a body explaining *why*. Patch commits
carry the same convention — their subjects become the patch file names, and
their bodies are what a future maintainer reads when deciding whether
upstream has made a patch obsolete. Platform-specific work should say so
(`android:` / `ios:`).

## Review process

Open PRs against the `recipe` branch. Diffs are small by construction —
patch files, `mobile-src/` files, and the tree hash.

But a change to a `.patch` file is a **diff of a diff**, which is not what
anyone wants to review. So every PR gets a `tree-diff` job that materializes
both the base and the head of the PR and diffs the two reconstructed trees.
The summary lands on the job page and the full patch is attached as the
`materialized-tree-diff` artifact — read that to see the actual source change.
It is a review aid and never fails the PR; `verify` is what gates.

(On an upgrade PR — one that moves `upstream-base.txt` — that diff necessarily
contains the whole upstream delta as well. The summary says so. Review the
patch files directly in that case and use the tree diff only to confirm the
fork-owned files survived the rebase.)

The reviewer does **not** have to take the author's word for
`expected-tree.txt`: `verify` recomputes it from a fresh upstream clone on
every PR and fails with the correct hash. That's the one check no human can
substitute for.

CI escalates with the event:

- **on the PR**: byte-for-byte reconstruction (`verify`), per-patch
  `./android-configure` validation, the host build running the curated JS
  list, the full cross-compile matrix, and the boot smokes — plus the
  curated emulator/simulator tests, which run but are advisory;
- **on merge**: the same, all of it blocking, with both flavors on both
  platforms;
- **on release**: everything above plus the full device suite and the
  real-device smoke, all
  gating an automated publish (see [RELEASING.md](./RELEASING.md)).

See [TESTING.md](./TESTING.md#what-ci-runs) for the job-by-job table and why
the curated device tests are advisory rather than required.

These gates are enforced by repository rulesets, not convention: `recipe`
accepts changes only by pull request with `verify`, `patch-stack-configure`
and the aggregate `ci-required` green (never the per-job matrix names, which
change whenever the matrix does), and force pushes and branch deletion are
blocked. Release tags (`v*`, `nodejs-mobile-*`) cannot be moved or deleted,
and the `release` environment the publish job runs in deploys only from
`recipe`. Repository admins can bypass the rulesets; bypasses are logged,
and the intent is that they never become routine (see the note in
`.github/CODEOWNERS`). For reporting vulnerabilities, see
[SECURITY.md](./SECURITY.md).

A clean `git am` is not proof of correctness — when a patch touches C++ or
the build system, let the cross-compile matrix finish before assuming an
upgrade is sound. Nothing before it compiles a line of target code.

## Upgrading to a newer upstream Node.js

See [UPGRADING.md](./UPGRADING.md).

<a id="developers-certificate-of-origin"></a>

## Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

* (a) The contribution was created in whole or in part by me and I
  have the right to submit it under the open source license
  indicated in the file; or

* (b) The contribution is based upon previous work that, to the best
  of my knowledge, is covered under an appropriate open source
  license and I have the right under that license to submit that
  work with modifications, whether created in whole or in part
  by me, under the same open source license (unless I am
  permitted to submit under a different license), as indicated
  in the file; or

* (c) The contribution was provided directly to me by some other
  person who certified (a), (b) or (c) and I have not modified
  it.

* (d) I understand and agree that this project and the contribution
  are public and that a record of the contribution (including all
  personal information I submit with it, including my sign-off) is
  maintained indefinitely and may be redistributed consistent with
  this project or the open source license(s) involved.
