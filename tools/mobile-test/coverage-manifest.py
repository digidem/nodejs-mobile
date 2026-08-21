#!/usr/bin/env python3
"""Report what the curated device gate actually covers on each platform.

A test can be absent from a device run for two very different reasons: it is
skipped by a `[$system==android]` / `[$system==ios]` section in a `.status`
file (a recorded decision), or it is simply not in the curated allow-list (no
decision at all). Those are indistinguishable from a green run, and the second
group is by far the larger one. This prints both.

Runs entirely on the host against a stub shell — it never touches a device, so
it is safe to call from any job. Counts come from `tools/test.py --report`,
which uses the real status-file parser rather than a reimplementation of its
glob and condition semantics.

Usage (from a materialized tree):
    tools/mobile-test/coverage-manifest.py [--suite parallel] [--summary]

--summary also appends a Markdown table to $GITHUB_STEP_SUMMARY.
"""

import argparse
import contextlib
import os
import re
import stat
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CURATED = os.path.join(ROOT, 'tools', 'mobile-test', 'curated-device-tests.txt')
PLATFORMS = ('android', 'ios')


def curated_names(suite):
    """Names in the curated list belonging to `suite`, e.g. 'parallel/test-x'."""
    names = set()
    with open(CURATED, encoding='utf-8') as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            group, _, name = line.partition('/')
            if group == suite:
                names.add(name)
    return names


def write_stub(path):
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write('#!/bin/sh\nexit 0\n')
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)


@contextlib.contextmanager
def host_binary_present():
    """test.py loads every suite's config up front, and test/sea/testcfg.py
    resolves out/Release/node at config time — so even asking about `parallel`
    needs it. On an unbuilt tree, stand in a stub for the duration; a real build
    (or the symlink prepare-android-test.sh drops) is left alone."""
    path = os.path.join(ROOT, 'out', 'Release', 'node')
    if os.path.exists(path):
        yield
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_stub(path)
    try:
        yield
    finally:
        with contextlib.suppress(OSError):
            os.remove(path)


def report_counts(suite, arch, shell):
    """(total, skipped) for `suite` on `arch`, from test.py's own status parser."""
    # --run=0,1000000 selects a single case, so the report is printed and
    # essentially nothing executes; the stub shell keeps even that off-device.
    proc = subprocess.run(
        [sys.executable, 'tools/test.py', '--report', '--arch', arch,
         '--shell', shell, '--run', '0,1000000', suite],
        cwd=ROOT, capture_output=True, text=True, check=False)
    total = skipped = None
    for line in proc.stdout.splitlines():
        match = re.match(r'Total: (\d+) tests', line)
        if match:
            total = int(match.group(1))
        match = re.match(r'\s*\*\s*(\d+) tests will be skipped', line)
        if match:
            skipped = int(match.group(1))
    if total is None or skipped is None:
        sys.stderr.write(proc.stdout + proc.stderr)
        raise SystemExit(f'could not read a report for {suite} on {arch}')
    return total, skipped


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--suite', default='parallel')
    parser.add_argument('--summary', action='store_true',
                        help='also append a table to $GITHUB_STEP_SUMMARY')
    args = parser.parse_args()

    curated = curated_names(args.suite)

    with tempfile.TemporaryDirectory() as tmp, host_binary_present():
        shell = os.path.join(tmp, 'stub-node')
        write_stub(shell)

        rows = []
        for arch in PLATFORMS:
            total, skipped = report_counts(args.suite, arch, shell)
            runnable = total - skipped
            # The curated list is shared by both platforms and every entry is
            # verified to run on both, so anything status-skipped here would be
            # a contradiction; subtract defensively rather than assume.
            run = min(len(curated), runnable)
            rows.append((arch, total, skipped, runnable, run, runnable - run))

    width = max(len(r[0]) for r in rows)
    print(f'Device-test coverage manifest — test/{args.suite}')
    print()
    for arch, total, skipped, runnable, run, absent in rows:
        pct = 100.0 * run / runnable if runnable else 0.0
        print(f'  {arch:<{width}}  {total:5d} total'
              f'   {skipped:5d} skipped by .status'
              f'   {runnable:5d} runnable'
              f'   {run:5d} run on PRs ({pct:.1f}%)'
              f'   {absent:5d} never run on a device')

    if args.summary and os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as handle:
            handle.write(f'\n### Device-test coverage — `test/{args.suite}`\n\n')
            handle.write('| Platform | Total | Skipped by `.status` | Runnable | '
                         'Run on PRs (curated) | Never run on a device |\n')
            handle.write('|---|---:|---:|---:|---:|---:|\n')
            for arch, total, skipped, runnable, run, absent in rows:
                pct = 100.0 * run / runnable if runnable else 0.0
                handle.write(f'| {arch} | {total} | {skipped} | {runnable} | '
                             f'{run} ({pct:.1f}%) | **{absent}** |\n')


if __name__ == '__main__':
    main()
