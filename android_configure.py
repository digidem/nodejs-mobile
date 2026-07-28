import platform
import sys
import os
import shutil

if platform.system() != "Linux" and platform.system() != "Darwin":
    print("android-configure is currently only supported on Linux and Darwin.")
    sys.exit(1)

if len(sys.argv) != 4:
    print("Usage: ./android-configure <path to the Android NDK> <Android SDK version> <target architecture>")
    sys.exit(1)

if not os.path.exists(sys.argv[1]) or not os.listdir(sys.argv[1]):
    print("\033[91mError: \033[0m" + "Invalid path to the Android NDK")
    sys.exit(1)

if int(sys.argv[2]) < 24:
    print("\033[91mError: \033[0m" + "Android SDK version must be at least 24 (Android 7.0)")
    sys.exit(1)

android_ndk_path = sys.argv[1]
android_sdk_version = sys.argv[2]
arch = sys.argv[3]

if arch == "arm":
    DEST_CPU = "arm"
    TOOLCHAIN_PREFIX = "armv7a-linux-androideabi"
elif arch in ("aarch64", "arm64"):
    DEST_CPU = "arm64"
    TOOLCHAIN_PREFIX = "aarch64-linux-android"
    arch = "arm64"
elif arch == "x86":
    DEST_CPU = "ia32"
    TOOLCHAIN_PREFIX = "i686-linux-android"
elif arch == "x86_64":
    DEST_CPU = "x64"
    TOOLCHAIN_PREFIX = "x86_64-linux-android"
    arch = "x64"
else:
    print("\033[91mError: \033[0m" + "Invalid target architecture, must be one of: arm, arm64, aarch64, x86, x86_64")
    sys.exit(1)

print("\033[92mInfo: \033[0m" + "Configuring for " + DEST_CPU + "...")

if platform.system() == "Darwin":
    host_os = "mac"
    toolchain_path = android_ndk_path + "/toolchains/llvm/prebuilt/darwin-x86_64"

elif platform.system() == "Linux":
    host_os = "linux"
    toolchain_path = android_ndk_path + "/toolchains/llvm/prebuilt/linux-x86_64"

os.environ['PATH'] += os.pathsep + toolchain_path + "/bin"
os.environ['CC'] = toolchain_path + "/bin/" + TOOLCHAIN_PREFIX + android_sdk_version + "-" +  "clang"
os.environ['CXX'] = toolchain_path + "/bin/" + TOOLCHAIN_PREFIX + android_sdk_version + "-" + "clang++"
# nodejs-mobile patch: add host CC and CXX
os.environ['CC_host'] = os.popen('command -v clang').read().strip()
os.environ['CXX_host'] = os.popen('command -v clang++').read().strip()

# nodejs-mobile patch: route every compile through sccache, but only when the
# caller opts in (CI sets NODEJS_MOBILE_SCCACHE=1 next to the
# mozilla-actions/sccache-action setup). Opt-in rather than "wrap when
# installed": a local build must not silently change behaviour because a
# developer happens to have sccache on PATH. This lives here and not in CI env
# because this script overwrites CC/CXX with the NDK toolchain paths above —
# an externally exported CC would not survive to the make invocation.
if os.environ.get("NODEJS_MOBILE_SCCACHE"):
    sccache = shutil.which("sccache")
    if not sccache:
        print("\033[91mError: \033[0m" + "NODEJS_MOBILE_SCCACHE is set but sccache is not on PATH")
        sys.exit(1)
    for _var in ("CC", "CXX", "CC_host", "CXX_host"):
        os.environ[_var] = sccache + " " + os.environ[_var]

GYP_DEFINES = "target_arch=" + arch
GYP_DEFINES += " v8_target_arch=" + arch
GYP_DEFINES += " android_target_arch=" + arch
GYP_DEFINES += " host_os=" + host_os + " OS=android"
GYP_DEFINES += " android_ndk_path=" + android_ndk_path
GYP_DEFINES += " android_ndk_sysroot=" + toolchain_path + "/sysroot"
# Flavor switch (mobile-only, wrapper-level so configure.py stays upstream-clean):
#   full (default) — the shared build all consumers get; flags unchanged.
#   lite           — size-reduced subtractions (see "The lite variant" in
#                    docs/BUILDING.md on the recipe branch).
# Set via env NODEJS_MOBILE_FLAVOR=lite. Android lite keeps the JIT and V8's
# native WASM engine (undici uses them); it only drops features that
# size-constrained consumers don't need. Dead-code stripping applies to both
# flavors (common.gypi).
flavor = os.environ.get("NODEJS_MOBILE_FLAVOR", "full").strip().lower()
if flavor not in ("full", "lite"):
    print("\033[91mError: \033[0m" + "NODEJS_MOBILE_FLAVOR must be 'full' or 'lite'")
    sys.exit(1)
print("\033[92mInfo: \033[0m" + "Build flavor: " + flavor)

intl = "small-icu"
extra_flags = ""
if flavor == "lite":
    intl = "none"
    extra_flags = " --without-amaro --without-inspector --without-sqlite"

os.environ['GYP_DEFINES'] = GYP_DEFINES

if os.path.exists("./configure"):
    os.system("./configure --dest-cpu=" + DEST_CPU + " --dest-os=android --openssl-no-asm --with-intl=" + intl + extra_flags + " --cross-compiling --shared")
