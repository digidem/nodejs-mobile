// Minimal Node.js embedder for the Android boot smoke
// (docs/TESTING.md on the recipe branch).
// Links the cross-compiled libnode.so and hands argv straight to node::Start, so
// the smoke can run a JS file via `adb shell` on the emulator without the
// Gradle/testnode app (Gradle 6.7.1 predates JDK 17 and jcenter is sunset).
// This exercises libnode directly; the JNI/app integration path is covered by
// the heavier device suites.
namespace node {
int Start(int argc, char* argv[]);
}

int main(int argc, char* argv[]) {
  return node::Start(argc, argv);
}
