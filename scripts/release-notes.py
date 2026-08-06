#!/usr/bin/env python3
"""Extract and validate the release notes for the version of record.

The published release notes are the first section of docs/CHANGELOG.md, and
they must belong to the version in mobile-src/src/node_mobile_version.h with
the cut-release TODO stub filled in. That invariant holds for every commit on
`recipe` — an ordinary PR inherits the released version and its already-written
section — so it is checkable on a pull request, long before the merge push
tries to publish anything.

Both callers use it (build.yml `release-notes` and `publish`) so the two can't
disagree: a stricter publish would fail on notes the PR was allowed to merge.

Usage:
  scripts/release-notes.py                       # check, print the notes
  scripts/release-notes.py --out notes.md        # check, write the notes
  scripts/release-notes.py --advisory            # report problems, exit 0

Exit status is 1 when the notes are not publishable (0 with --advisory).
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / 'docs' / 'CHANGELOG.md'
VERSION_H = ROOT / 'mobile-src' / 'src' / 'node_mobile_version.h'

FIELDS = ('MAJOR_VERSION', 'MINOR_VERSION', 'PATCH_VERSION', 'REVISION')
ANCHOR = re.compile(r'^\s*<a id="[^"]*"></a>\s*$')


def version_of_record(path):
    """X.Y.Z-R from the #defines in node_mobile_version.h."""
    src = path.read_text()
    parts = []
    for field in FIELDS:
        m = re.search(r'^#define NODE_MOBILE_%s\s+(\d+)\s*$' % field, src, re.M)
        if not m:
            sys.exit('error: NODE_MOBILE_%s not found in %s' % (field, path))
        parts.append(m.group(1))
    return '%s.%s.%s-%s' % tuple(parts)


def first_section(path):
    """The first '## ' section of the CHANGELOG, header line included.

    Each section is preceded by its own '<a id="X.Y.Z-R">' anchor, so reading
    up to the next '## ' picks up the *following* section's anchor. Trim it —
    it rendered as a stray line at the foot of every published release body,
    and it would otherwise mask a section whose body is empty.
    """
    out, seen = [], False
    for line in path.read_text().splitlines(keepends=True):
        if line.startswith('## '):
            if seen:
                break
            seen = True
        if seen:
            out.append(line)
    while out and (not out[-1].strip() or ANCHOR.match(out[-1])):
        out.pop()
    return ''.join(out)


def problems(notes, version):
    """Every reason these notes must not be published, in reading order."""
    found = []
    if not notes.strip():
        return ['docs/CHANGELOG.md has no section to publish']
    header, _, body = notes.partition('\n')
    if 'Version %s' % version not in header:
        found.append(
            'first CHANGELOG section is not for %s (it is %r) — '
            'the version of record and docs/CHANGELOG.md disagree'
            % (version, header.strip()))
    if 'TODO' in notes:
        found.append(
            'release notes still contain the cut-release TODO stub — '
            'fill in docs/CHANGELOG.md')
    elif not body.strip():
        found.append(
            'release notes for %s are empty — fill in docs/CHANGELOG.md'
            % version)
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--version', help='version to check against '
                    '(default: read from node_mobile_version.h)')
    ap.add_argument('--out', type=pathlib.Path,
                    help='write the notes here (written even when invalid, so '
                         'an advisory caller still has something to publish)')
    ap.add_argument('--advisory', action='store_true',
                    help='report problems as warnings and exit 0')
    args = ap.parse_args()

    version = args.version or version_of_record(VERSION_H)
    notes = first_section(CHANGELOG)

    if args.out:
        args.out.write_text(notes)
    else:
        sys.stdout.write(notes)

    found = problems(notes, version)
    for problem in found:
        # GitHub Actions reads these as annotations; they are plain enough
        # to be useful when the script is run by hand.
        print('::%s::%s' % ('warning' if args.advisory else 'error', problem),
              file=sys.stderr)
    if not found:
        print('release notes for %s are ready (%d lines)'
              % (version, len(notes.splitlines())), file=sys.stderr)
    return 1 if found and not args.advisory else 0


if __name__ == '__main__':
    sys.exit(main())
