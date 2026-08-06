#!/usr/bin/env python3
"""Regenerate patches/ from an edited working tree (the dev loop).

After editing files in an out/ tree produced by scripts/prepare.sh (and
committing your changes there — any shape of commits is fine), this script
rewrites the patch series so that each patch again captures the final state
of the files it owns, and syncs fork-only files back into mobile-src/.

The partition is by file, recorded in patches/files.map (one "patch<TAB>path"
line per owned file):
  - a changed file owned by a patch  -> that patch is re-emitted
  - a changed fork-only file (exists in mobile-src/) -> copied back
  - a NEW file                       -> mobile-src by default; assign it to a
    patch in files.map first if it is upstream-coupled (e.g. a new file in
    deps/ that belongs with a patch concern)
  - a changed upstream file owned by nothing -> error; add a files.map line
    (to an existing patch or a new name.patch entry in series+files.map
    with a "Subject: ..." template) and re-run

Patch files are unnumbered (name.patch, not NNNN-name.patch); patches/series
alone records the apply order. Numbering was dropped because it turned every
insertion or retirement into a rename of the whole series plus a rewrite of
every [PATCH n/m] subject line, churning files whose content hadn't changed.

Patch headers (author, date, subject, body) are preserved from the existing
.patch files, and core.abbrev is pinned, so an unchanged patch regenerates
byte-identically regardless of which tree it was regenerated from.

Usage: scripts/regenerate-patches.py <out_dir>
"""
import os, re, subprocess, sys, tempfile, shutil

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCHES = os.path.join(HERE, 'patches')

def sh(*a, cwd=None, check=True):
    r = subprocess.run(a, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode:
        sys.exit(f"command failed: {' '.join(a)}\n{r.stderr}")
    return r.stdout

def read_base():
    for line in open(os.path.join(HERE, 'upstream-base.txt')):
        line = line.strip()
        if line and not line.startswith('#'):
            return line
    sys.exit('no base in upstream-base.txt')

def patch_header(path):
    """Return (author, date, message) from an existing .patch file."""
    author = date = None
    subject_lines, body, in_subject, past_headers = [], [], False, False
    for line in open(path, encoding='utf-8', errors='surrogateescape'):
        line = line.rstrip('\n')
        if not past_headers:
            if line.startswith('From:'):
                author = line[5:].strip(); in_subject = False
            elif line.startswith('Date:'):
                date = line[5:].strip(); in_subject = False
            elif line.startswith('Subject:'):
                subject_lines = [re.sub(r'^\[PATCH[^\]]*\]\s*', '', line[8:].strip())]
                in_subject = True
            elif in_subject and line.startswith(' '):
                subject_lines.append(line.strip())
            elif line == '':
                past_headers = True
        else:
            if line == '---':
                break
            body.append(line)
    while body and body[-1] == '':
        body.pop()
    msg = ' '.join(subject_lines)
    if body:
        msg += '\n\n' + '\n'.join(body)
    return author, date, msg

def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = os.path.abspath(sys.argv[1])
    base = read_base()

    # Emitted patches must not depend on whoever runs this: a user-level
    # format.* or diff.* setting (format.suffix, format.coverLetter,
    # diff.srcPrefix, ...) changes format-patch's output enough to corrupt
    # series/files.map on rewrite. Repo-local config (the identity prepare.sh
    # sets in out/) still applies; provide a fallback ident for trees that
    # lack one, since the synthesized committer never reaches the patches.
    os.environ['GIT_CONFIG_GLOBAL'] = os.devnull
    os.environ['GIT_CONFIG_SYSTEM'] = os.devnull
    os.environ.setdefault('GIT_COMMITTER_NAME', 'nodejs-mobile')
    os.environ.setdefault('GIT_COMMITTER_EMAIL', 'nodejs-mobile@invalid')
    os.environ.setdefault('GIT_AUTHOR_NAME', 'nodejs-mobile')
    os.environ.setdefault('GIT_AUTHOR_EMAIL', 'nodejs-mobile@invalid')

    # Uncommitted edits in out/ would be silently left out of the regenerated
    # patches (only base..HEAD is read) while the printed tree hash looks
    # authoritative — refuse instead.
    dirty = sh('git', 'status', '--porcelain', '--untracked-files=no', cwd=out)
    if dirty.strip():
        sys.exit('error: uncommitted changes in ' + out +
                 ' — commit them there first (any shape of commits is fine):\n'
                 + dirty)

    series = [l.strip() for l in open(os.path.join(PATCHES, 'series'))
              if l.strip() and not l.startswith('#')]
    owned = {}   # path -> patch
    for line in open(os.path.join(PATCHES, 'files.map')):
        line = line.rstrip('\n')
        if not line or line.startswith('#'):
            continue
        patch, path = line.split('\t', 1)
        owned[path] = patch

    base_sha = sh('git', 'rev-parse', f'{base}^{{commit}}', cwd=out).strip()

    # Classify every difference of out's HEAD vs the upstream base.
    changed = {}
    for line in sh('git', 'diff', '--name-status', '--no-renames', base_sha, 'HEAD',
                   cwd=out).splitlines():
        st, path = line.split('\t', 1)
        changed[path] = st

    mobile_src, per_patch, unowned = [], {p: [] for p in series}, []
    for path, st in sorted(changed.items()):
        if path in owned:
            per_patch.setdefault(owned[path], []).append((path, st))
        elif st == 'A':
            mobile_src.append(path)
        else:
            unowned.append(f'{st}\t{path}')
    if unowned:
        sys.exit('error: changed upstream files owned by no patch — add them to '
                 'patches/files.map (and series, for a new patch) first:\n  '
                 + '\n  '.join(unowned))
    stray = [p for p in per_patch if p not in series]
    if stray:
        sys.exit(f'error: files.map references patches missing from series: {stray}')

    # A path both owned by a patch and present in mobile-src/ would be
    # double-processed here and silently last-writer-wins in prepare.sh's
    # overlay — the partition must stay disjoint.
    ms_tracked = {p[len('mobile-src/'):]
                  for p in sh('git', '-C', HERE, 'ls-files', '--',
                              'mobile-src').splitlines() if p}
    collide = ms_tracked & set(owned)
    if collide:
        sys.exit('error: paths owned by a patch also exist in mobile-src/ '
                 '(the partition must be disjoint): ' + ', '.join(sorted(collide)))

    # Re-synthesize one commit per patch in a throwaway worktree, preserving
    # each patch's stored author/date/message so unchanged patches regenerate
    # byte-identically under format-patch --zero-commit --no-signature.
    wt = tempfile.mkdtemp(prefix='regen-wt.')
    out_head = sh('git', 'rev-parse', 'HEAD', cwd=out).strip()
    try:
        sh('git', 'worktree', 'add', '--detach', wt, base_sha, cwd=out)
        for patch in series:
            ppath = os.path.join(PATCHES, patch)
            author, date, msg = (None, None, None)
            if os.path.exists(ppath):
                author, date, msg = patch_header(ppath)
            if not msg:
                msg = os.path.splitext(patch)[0]  # new patch: filename as subject template
            adds = [p for p, s in per_patch.get(patch, []) if s != 'D']
            dels = [p for p, s in per_patch.get(patch, []) if s == 'D']
            if adds:
                sh('git', 'checkout', out_head, '--', *adds, cwd=wt)
            if dels:
                sh('git', 'rm', '-q', '--', *dels, cwd=wt)
            env = dict(os.environ)
            if date:
                env['GIT_AUTHOR_DATE'] = env['GIT_COMMITTER_DATE'] = date
            args = ['git', 'commit', '-q', '--allow-empty', '-m', msg]
            if author:
                args += ['--author', author]
            r = subprocess.run(args, cwd=wt, env=env, capture_output=True, text=True)
            if r.returncode:
                sys.exit(f'commit failed for {patch}: {r.stderr}')
            # An empty patch either vanishes from the emission (older gits,
            # silently renumbering the series) or emits a diff-less file that
            # kills the next `git am`. It means the patch's owned files no
            # longer differ from upstream — usually a regenerate against the
            # wrong tree (partial `git am`, `am --skip`), sometimes upstream
            # absorbing the patch. Either way it needs a human: fix the tree,
            # or retire the patch by deleting its series and files.map lines.
            if subprocess.run(['git', 'diff', '--quiet', 'HEAD^', 'HEAD'],
                              cwd=wt, capture_output=True).returncode == 0:
                sys.exit(f'error: {patch} would become empty — its owned files '
                         'no longer differ from the upstream base. If the out/ '
                         'tree is correct and upstream really absorbed it, '
                         'retire the patch: remove its lines from '
                         'patches/series and patches/files.map, then re-run.')
        # Export the new series.
        for f in os.listdir(PATCHES):
            if f.endswith('.patch'):
                os.unlink(os.path.join(PATCHES, f))
        # core.abbrev is pinned because git's default auto-abbreviation scales
        # with the object count, so the "index <old>..<new>" lines would come
        # out 8 chars from prepare.sh's shallow clone and 10 from a full one —
        # rewriting all 19 patches for whoever regenerates in the other kind of
        # tree. Pinning keeps an unchanged patch byte-identical anywhere.
        # --no-renames: a rename diff would emit `diff --git a/X b/Y`, whose
        # b-path the files.map rewrite below never captures.
        # -N: plain "[PATCH]" subjects — a "[PATCH n/m]" counter rewrites every
        # patch whenever one is added or retired.
        sh('git', '-c', 'core.abbrev=10', 'format-patch', '--no-renames', '-N',
           '--output-directory', PATCHES, '--zero-commit', '--no-signature',
           f'{base_sha}..HEAD', cwd=wt)
    finally:
        subprocess.run(['git', 'worktree', 'remove', '--force', wt], cwd=out,
                       capture_output=True)
        shutil.rmtree(wt, ignore_errors=True)

    # Strip format-patch's NNNN- filename prefixes: series alone records the
    # apply order, and a numbered name renumbers the whole directory whenever
    # a patch is inserted or retired. The numeric prefix is only read here, to
    # recover the emission order before it is discarded.
    emitted = []
    for f in sorted(f for f in os.listdir(PATCHES) if re.match(r'\d{4}-.*\.patch$', f)):
        bare = re.sub(r'^\d{4}-', '', f)
        dst = os.path.join(PATCHES, bare)
        if os.path.exists(dst):
            sys.exit(f'error: two patches collapse to the same filename {bare} — '
                     'give them distinct subjects')
        os.rename(os.path.join(PATCHES, f), dst)
        emitted.append(bare)

    # Rewrite series + files.map from what was actually emitted (names can
    # change when subjects change).
    with open(os.path.join(PATCHES, 'series'), 'w') as f:
        f.write('\n'.join(emitted) + '\n')
    with open(os.path.join(PATCHES, 'files.map'), 'w') as f:
        for p in emitted:
            for line in open(os.path.join(PATCHES, p)):
                m = re.match(r'^diff --git a/(.*) b/', line)
                if m:
                    f.write(f'{p}\t{m.group(1)}\n')

    # Sync fork-only files back into mobile-src/ (adds + edits of existing).
    ms_root = os.path.join(HERE, 'mobile-src')

    # Deletions must round-trip too: a fork-only file removed (or renamed) in
    # out/ appears nowhere in base..HEAD, but leaving its old copy in
    # mobile-src/ would make prepare.sh re-overlay it and mismatch the printed
    # tree hash with no hint why.
    fork_only = {p for p, st in changed.items() if st == 'A' and p not in owned}
    stale = sorted(ms_tracked - fork_only)
    for path in stale:
        full = os.path.join(ms_root, path)
        if os.path.exists(full):
            os.unlink(full)
        print(f'removed stale mobile-src/{path} (no longer in the out tree)')

    synced = 0
    for path in sorted(set(mobile_src)
                       | {p for p in changed
                          if os.path.exists(os.path.join(ms_root, p))}):
        blob = subprocess.run(['git', 'show', f'HEAD:{path}'], cwd=out,
                              capture_output=True)
        if blob.returncode:
            continue
        dst = os.path.join(ms_root, path)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as fh:
            fh.write(blob.stdout)
        mode = sh('git', 'ls-tree', 'HEAD', '--', path, cwd=out).split()[0]
        os.chmod(dst, 0o755 if mode == '100755' else 0o644)
        synced += 1

    tree = sh('git', 'rev-parse', 'HEAD^{tree}', cwd=out).strip()
    print(f'Regenerated {len(emitted)} patches; synced {synced} mobile-src files.')
    print(f'out/ HEAD tree is {tree} — update expected-tree.txt if this change is intentional.')

if __name__ == '__main__':
    main()
