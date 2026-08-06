# Embedding: the environment node inherits

node-as-a-library has no launcher to set up its environment, so whatever the
host app's process has is what node gets. On desktop the shell supplies a
sensible environment; on mobile there is no shell, and several things node
expects are either absent or wrong. This document is what an embedder needs to
set, and why.

For what is and isn't supported at the API level, see [FAQ.md](./FAQ.md).

## Set it before node starts

Call `setenv(name, value, 1)` before `node::Start()` — or before whatever entry
point your integration uses to create the `Environment`. Most of what follows is
read once during bootstrap:

- `NODE_OPTIONS`, `NODE_ICU_DATA` and `OPENSSL_CONF` are consumed while the
  process initializes.
- `NODE_EXTRA_CA_CERTS` is read during crypto init.
- `NODE_COMPILE_CACHE` is read when the `Environment` is created.

Assigning these from JavaScript after boot does nothing — the read has already
happened. The exceptions are `TZ`, which is re-applied whenever you assign
`process.env.TZ`, and anything your own code reads lazily.

## Two read paths, and why it matters

node reads environment variables two ways, and the difference is visible to
embedders on older releases.

**`getenv()` / `uv_os_getenv()`** — `process.env`, `HOME`, `TZ`,
`UV_THREADPOOL_SIZE`. These have always worked on both platforms.

**`SafeGetenv()`** — `TMPDIR`, `NODE_OPTIONS`, `NODE_ICU_DATA`,
`NODE_EXTRA_CA_CERTS`, `NODE_USE_SYSTEM_CA`, `OPENSSL_CONF`, `NODE_PATH`,
`NODE_COMPILE_CACHE`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_DEBUG_NATIVE`.
Upstream declines these when the process looks privileged. An Android app
process is `fork()`ed from the zygote without `exec()`, so it inherits an
auxiliary vector describing init's exec of the zygote — `AT_SECURE=1`,
`AT_{,E}{U,G}ID=0` — while running unprivileged. The check therefore declined
**every** variable in this group inside **every** Android app, permanently.

The credentials patch (see [PATCHES.md](./PATCHES.md#the-series)) relaxes the
heuristic on `NODE_MOBILE` builds, so these work from that patch onwards. On
iOS they were never affected. If you are on an older build and one of these
appears to be ignored on Android, this is why.

## Data and temp directories

node has no notion of an application data directory; it inherits the process's
working directory and whatever paths you hand it. Query the platform for the
right location and pass it in — do not hard-code, and do not assume a desktop
layout exists.

### Android

An app process starts with no `TMPDIR`, and **there is no `/tmp`**. That matters
because `os.tmpdir()` falls back to exactly that path, so any dependency writing
to `os.tmpdir()` fails with `ENOENT` until you set the variable.

| Query | Path | Use for |
|---|---|---|
| `getCacheDir()` | `/data/user/0/<pkg>/cache` | **`TMPDIR`**, compile cache. The OS may purge it under storage pressure, which is the right semantics for scratch data. |
| `getNoBackupFilesDir()` | `…/no_backup` | Databases, keys, device-bound state. Persistent, excluded from backup/restore. |
| `getFilesDir()` | `…/files` | General app data. Persistent, but **included in auto-backup** — don't put device-bound state here, it will be restored onto a different device. |
| `getExternalFilesDir(null)` | app-scoped external storage | User-visible exports. No runtime permission needed. |

Also consider setting `HOME` to your files directory: a good deal of npm code
calls `os.homedir()` unconditionally, and on Android it is unset or useless.

### iOS

The OS already sets `TMPDIR` to `<container>/tmp` and `HOME` to the container
root, so `os.tmpdir()` works without help. Note it returns a full container
path, which is long — see the `sun_path` budget in
[TESTING.md](./TESTING.md#unix-domain-sockets) before using it for socket paths.

| Directory | Use for |
|---|---|
| `Library/Application Support` | Persistent app data. Backed up. Does not exist by default — create it. |
| `Library/Caches` | Compile cache and other regenerable data. Purgeable, not backed up. |
| `Documents` | **User-facing documents only.** Exposed in the Files app when `UIFileSharingEnabled` is set. |
| `NSTemporaryDirectory()` | Already `TMPDIR`. |

Mark large regenerable data with `NSURLIsExcludedFromBackupKey`, or it inflates
your users' iCloud backups.

## What to set, and what to leave alone

### Worth setting

**`TMPDIR`** — required on Android (see above); leave alone on iOS.

**`NODE_COMPILE_CACHE`** — an on-disk V8 code cache, and a real startup win.
Point it at a subdirectory of the cache/Caches directory. **Also set
`NODE_COMPILE_CACHE_PORTABLE=1`**: it makes cache entries keyed by relative
path, which matters on iOS because a data-container path contains a UUID that is
not stable across reinstalls — with absolute keys the cache silently misses
after an update. `NODE_DISABLE_COMPILE_CACHE` turns it off again without
changing the rest of your configuration.

**`NODE_EXTRA_CA_CERTS`** — the clean way to add a private CA. Stage the PEM in
your bundle or files directory and point at it. It is *additive* to node's
bundled Mozilla root store, and read once at startup. This is the recommended
mechanism on both platforms; see
[the FAQ on device trust](./FAQ.md#does-https-trust-the-devices-certificates)
for why reading the system store is not a substitute.

**`NODE_OPTIONS`** — the main lever when you don't control `argv`. The most
valuable setting on mobile is a heap cap: V8 sizes the old space from total
device RAM, which is frequently far more than a background runtime should claim,
and on Android exceeding the cgroup limit kills the whole app rather than
throwing an allocation error. Prefer
**`--max-old-space-size-percentage`** over the absolute
`--max-old-space-size` — device RAM ranges over an order of magnitude, and the
percentage form takes precedence when both are given. Also useful:
`--enable-source-maps`, `--require` for a preload shim, and
`--unhandled-rejections` if `throw` (the default) isn't the behaviour you want.
Only the options upstream marks `kAllowedInEnvvar` are accepted, and
`NODE_OPTIONS` never appears in `process.execArgv`.

### Situational

**`NODE_ICU_DATA`** — meaningful only on the `full` flavor, which is built
`--with-intl=small-icu` on both platforms. Ship a full `icudt*.dat` as an asset
and point at it if you need locales beyond the small set. It is a **no-op on
`lite`**, which is `--with-intl=none` and has no `Intl` at all. See
[BUILDING.md](./BUILDING.md) for the flavor split.

**`NODE_USE_SYSTEM_CA=1`** — only if you need user- or MDM-installed CAs
honoured, and understand that it buys less than it appears to: iOS has no API to
enumerate trust anchors, and on Android the OpenSSL default locations are not
populated in a sandbox. Prefer `NODE_EXTRA_CA_CERTS`.

**`SSL_CERT_FILE` / `SSL_CERT_DIR`** — consulted only under
`NODE_USE_SYSTEM_CA`. On Android you can point `SSL_CERT_DIR` at
`/system/etc/security/cacerts`.

**`TZ`** — usually leave unset; bionic and iOS both supply the system zone
without help. Set it to force a specific zone or for deterministic behaviour in
tests. Unlike the rest of this list it can be changed after startup: assigning
`process.env.TZ` calls `tzset()` and tells V8 to re-detect.

**`UV_THREADPOOL_SIZE`** — libuv's blocking-work pool, shared by `fs`, `dns` and
some crypto. Defaults to 4; consider lowering it on low-end devices. Read once,
on first use.

**`NODE_DEBUG_NATIVE` / `NODE_DEBUG`** — diagnostic logging, which lands in
logcat or the iOS log. Genuinely useful on device, where you have no console.

### Leave alone

**`OPENSSL_CONF`** — the compiled-in default path does not exist on device, and
that is harmless. Set it only for a deliberate provider or legacy-algorithm
configuration, and never at a path another app can write: a configuration file
can change crypto behaviour.

**`NODE_PATH`** — affects CommonJS resolution only; **the ESM loader ignores it
entirely**. Prefer a bundler or explicit paths.

## Gotchas

- **`os.tmpdir()` on Android returns `/tmp` unless you set `TMPDIR`.** The
  credentials patch made the variable *readable*; it does not set it. Nothing
  else will.
- **`os.homedir()` is not a writable location** you should rely on. On iOS it is
  the container root; on Android it is unset or `/`.
- **The working directory is not yours by default.** An embedded runtime
  inherits the host process's cwd, which on Android is `/`. Anything resolving a
  relative path — including `common.PIPE`-style short socket paths — resolves
  against it. `chdir()` somewhere sensible before starting node, or pass
  absolute paths.
- **Two node instances in one process are not supported.** See
  [FAQ.md](./FAQ.md#can-i-run-two-or-more-nodejs-instances).
