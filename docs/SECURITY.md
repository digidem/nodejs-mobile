# Security

## Reporting a vulnerability

Report vulnerabilities privately via GitHub:
[Security → Report a vulnerability](https://github.com/gmaclennan/nodejs-mobile/security/advisories/new).
Do not open a public issue for anything you believe is exploitable.

Vulnerabilities in Node.js itself belong upstream: report them through the
[Node.js security process](https://github.com/nodejs/node/blob/main/SECURITY.md),
not here. This fork inherits upstream fixes by tracking the pinned release
line in `upstream-base.txt`. In scope here is only what the fork adds: the
patches, the `mobile-src/` overlay, and the build/release pipeline.

## Supported versions

Only the latest release is supported. Fixes ship as a new
`<upstream>-<rev>` release (see [RELEASING.md](./RELEASING.md)); nothing is
backported to older releases.

## Release integrity

Releases are produced only by CI from the `recipe` branch, and only after
the full test gate — build matrix, boot smokes, curated and full device
suites, and a real-device smoke ([TESTING.md](./TESTING.md)). There is no
path that publishes a hand-built binary.

Every release tag is an annotated tag carrying a `Recipe-Commit:` trailer
naming the recipe-branch commit that generated it, and the release assets
come from the same CI run that pushed the tag. The source tree itself is
reproducible: `scripts/prepare.sh` rebuilds it from the pinned upstream tag
plus the patch series and fails unless the result hashes byte-for-byte to
`expected-tree.txt`.
