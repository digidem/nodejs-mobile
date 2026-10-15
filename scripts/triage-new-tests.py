#!/usr/bin/env python3
"""List the tests an upstream bump adds or changes that likely need a .status
skip on mobile, one line per suspect.

Usage:
  scripts/triage-new-tests.py <out_dir> <old-tag> <new-tag> [--all]

Scans test/parallel and test/sequential. Added tests are checked whole;
modified tests only on their added lines, since an existing test can gain a
child-process subtest or a new // Flags: entry. A test already matched (by
name or glob) in the platform's .status block is dropped for that platform
unless --all is given. Categories, in the order they are reported:

  SPAWN-NODE      spawns a child node: cannot pass on Android, flaky on the
                  iOS simulator -- skip both
  PERMISSION      --permission without --allow-fs-write, or drops fs/fs.write:
                  the harness's verdict write is denied -- skip both
  IOS-FLAGS       V8 wasm flags iOS lite mode doesn't know ("bad option") --
                  skip iOS
  SPAWN-EXTERNAL  execs a non-node binary (mkfifo, sh, ...) -- judgement call

A trailing [skips: ...] shows a top-level common.skip() guard; if it always
fires on mobile the test scores PASS and needs no entry.
See docs/UPGRADING.md, "New upstream tests".
"""
import fnmatch
import os
import re
import subprocess
import sys

DIRS = ("test/parallel", "test/sequential")
PLATFORMS = ("android", "ios")
TEST_RE = re.compile(r"^test/(parallel|sequential)/(test-[^/]+)\.(js|mjs|cjs)$")

SPAWN_NODE = re.compile(
    r"process\.execPath|spawnPromisified|isolation:\s*['\"]process|\bfork\(|"
    r"buildSnapshot\(|spawnSyncAnd\w+\(|startCLI\(")
SPAWN_EXTERNAL = re.compile(
    r"(?<![\w.])(execFileSync|execFile|execSync|exec|spawnSync|spawn)\(\s*['\"`]")
FLAGS = re.compile(r"^//\s*Flags:(.*)")
DROP_FS = re.compile(r"permission\.drop\(\s*['\"]fs(\.write)?['\"]")
IOS_FLAG = re.compile(r"--(experimental-)?wasm-[\w-]+")
SKIP_GUARD = re.compile(r"^if\s*\((.*)\)")


def git(out, *args):
    return subprocess.run(["git", "-C", out, *args], check=True,
                          capture_output=True, text=True).stdout


def ensure_tag(out, tag):
    if subprocess.run(["git", "-C", out, "rev-parse", "-q", "--verify",
                       f"refs/tags/{tag}"], capture_output=True).returncode:
        print(f"fetching {tag}...", file=sys.stderr)
        git(out, "fetch", "-q", "--depth", "1", "origin", "tag", tag)


def status_entries(out):
    """(suite, platform) -> skip patterns; each suite's .status covers only its own dir."""
    entries = {}
    for d in DIRS:
        suite = os.path.basename(d)
        path = os.path.join(out, d, os.path.basename(d) + ".status")
        if not os.path.exists(path):
            continue
        applies = ()
        for line in open(path, encoding="utf-8"):
            line = line.split("#", 1)[0].strip()
            if line.startswith("["):
                applies = tuple(p for p in PLATFORMS
                                if line == "[true]" or f"$system=={p}" in line)
            elif ":" in line:
                for p in applies:
                    entries.setdefault((suite, p), []).append(line.split(":", 1)[0].strip())
    return entries


def classify(lines, flags_lines):
    """[(category, line)] for lines (iterable of source lines)."""
    hits = {}
    for raw in flags_lines:
        m = FLAGS.match(raw)
        if not m:
            continue
        flags = m.group(1)
        if "--permission" in flags and "--allow-fs-write" not in flags:
            hits.setdefault("PERMISSION", raw)
        if IOS_FLAG.search(flags):
            hits.setdefault("IOS-FLAGS", raw)
    for raw in lines:
        s = raw.strip()
        if s.startswith("//"):
            continue
        if SPAWN_NODE.search(s):
            hits.setdefault("SPAWN-NODE", s)
        elif SPAWN_EXTERNAL.search(s):
            hits.setdefault("SPAWN-EXTERNAL", s)
        if DROP_FS.search(s):
            hits.setdefault("PERMISSION", s)
    order = ("SPAWN-NODE", "PERMISSION", "IOS-FLAGS", "SPAWN-EXTERNAL")
    return [(c, hits[c]) for c in order if c in hits]


def skip_guards(lines):
    guards = []
    for i, raw in enumerate(lines):
        if raw.startswith("common.skip(") or raw.startswith("  common.skip("):
            cond = next((SKIP_GUARD.match(lines[j]).group(1)
                         for j in range(i, max(i - 3, -1), -1)
                         if SKIP_GUARD.match(lines[j])), None)
            guards.append(cond or "?")
    return guards


def main(argv):
    show_all = "--all" in argv
    args = [a for a in argv if a != "--all"]
    if len(args) != 3:
        sys.exit(__doc__)
    out, old, new = args
    for t in (old, new):
        ensure_tag(out, t)
    covered = {} if show_all else status_entries(out)

    changed = git(out, "diff", "--name-status", old, new, "--", *DIRS)
    rows = []
    for line in changed.splitlines():
        kind, *paths = line.split("\t")
        path = paths[-1]
        m = TEST_RE.match(path)
        if not m or kind[0] not in "AMR":
            continue
        name = m.group(2)
        src = git(out, "show", f"{new}:{path}").splitlines()
        if kind[0] == "A":
            hits = classify(src, src[:5])
        else:
            added = [l[1:] for l in git(out, "diff", old, new, "--", path).splitlines()
                     if l.startswith("+") and not l.startswith("+++")]
            hits = classify(added, [l for l in added if FLAGS.match(l)])
        if not hits:
            continue
        category, evidence = hits[0]
        targets = ("ios",) if category == "IOS-FLAGS" else PLATFORMS
        open_on = [p for p in targets
                   if not any(fnmatch.fnmatchcase(name, pat)
                              for pat in covered.get((m.group(1), p), []))]
        if not open_on:
            continue
        extra = "+" + ",".join(c for c, _ in hits[1:]) if hits[1:] else ""
        guards = skip_guards(src)
        note = f"  [skips: {'; '.join(guards)}]" if guards else ""
        rows.append(f"{category + extra:<16} {kind[0]} {name} ({','.join(open_on)})"
                    f"  {evidence[:100]}{note}")
    print("\n".join(sorted(rows)) or "no suspects")


if __name__ == "__main__":
    main(sys.argv[1:])
