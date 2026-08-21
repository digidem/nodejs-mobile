#include <jni.h>
#include <string>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/types.h>
#include <android/log.h>

namespace node {
    extern int Start(int argc, char *argv[]);
}

extern "C"
int startNode(int argc, char *argv[]) {
    const int exit_code = node::Start(argc,argv);
    return exit_code;
}

// Forward declaration
int start_redirecting_stdout_stderr();

const char *TAG = "TestNode";
JNIEnv* cacheEnvPointer = NULL;

// Per-launch verdict file in the app sandbox. The proxy reads the test's real
// exit code from this private file (a durable channel) instead of scraping the
// shared, lossy logcat for a marker line. Named with the per-launch token so a
// stale file or a spawned grandchild (a fresh exec, no JNI call -> empty path)
// can't be mistaken for this launch's verdict; g_launch_pid guards the writer so
// only the launching process writes.
static char g_result_file[1024] = {0};
static pid_t g_launch_pid = 0;
static bool g_result_written = false;

static void write_result(const char* verdict) {
    if (g_result_file[0] == '\0' || getpid() != g_launch_pid) return;
    FILE* f = fopen(g_result_file, "w");
    if (f) { fputs(verdict, f); fclose(f); g_result_written = true; }
}

// Loaded via NODE_OPTIONS=--require, which (unlike a command-line flag) stays
// out of process.execArgv, so tests that assert on it are unaffected. Keep in
// sync with the copy in ios/testnode/testnode/NodeRunner.mm.
static const char* kExitVerdictHookJS = R"JS('use strict';
// Written at launch by the testnode harness; see native-lib.cpp.
// process.exit() leaves through libc exit(), so node::Start() never returns and
// the native verdict write is skipped. This handler is the only place the real
// exit code is observable on that path.
// It requires nothing until the process is already exiting, so it adds no
// entries to process.moduleLoadList -- which test-bootstrap-modules asserts on.
try {
  const f = process.env.NODEJS_MOBILE_TEST_VERDICT_FILE;
  if (f) {
    process.on('exit', (code) => {
      try {
        if (!require('node:worker_threads').isMainThread) return;
        require('node:fs').writeFileSync(f, code === 0 ? 'PASS\n' : 'FAIL\n');
      } catch {}
    });
  }
} catch {}
)JS";

static bool result_file_exists() {
    if (g_result_file[0] == '\0') return false;
    FILE* f = fopen(g_result_file, "r");
    if (!f) return false;
    fclose(f);
    return true;
}

void AtExitHook()
{
    // startNode did not return: a crash, an abort, or an explicit process.exit()
    // (which routes through node::Exit -> libc exit() and never unwinds to us).
    // The exit() case is now covered by the JS hook above, so check the file
    // rather than only our own flag — otherwise this would overwrite the real
    // verdict it just wrote. Anything that reaches here with no file at all
    // terminated abnormally, and FAIL is the correct verdict.
    if (!g_result_written && !result_file_exists()) write_result("FAIL\n");
}

extern "C"
JNIEXPORT jint JNICALL
Java_nodejsmobile_test_testnode_MainActivity_startNodeWithArguments(
        JNIEnv *env,
        jobject /* this */,
        jobjectArray arguments,
        jstring nodePath,
        jboolean redirectOutputToLogcat,
        jstring runToken) {


    // Node's libuv requires all arguments being on contiguous memory.
    cacheEnvPointer = env;
    const char* path_path = env->GetStringUTFChars(nodePath, 0);
    setenv("NODE_PATH", path_path, 1);

    // Build the per-launch verdict file path (<filesDir>/result-<token>.txt) and
    // record the launching pid, before registering atexit (which runs after the
    // JNI frame is gone, so it can't touch JNIEnv).
    const char* tok = env->GetStringUTFChars(runToken, 0);
    g_launch_pid = getpid();
    snprintf(g_result_file, sizeof(g_result_file), "%s/result-%s.txt", path_path, tok);

    // Match a desktop `tools/test.py` run, which starts node with the working
    // directory at the tree root. Without this the app inherits cwd=/ and every
    // cwd-relative path in the suite resolves against the filesystem root:
    // test-fs-cp-async-file-url looks for /test/fixtures/..., --env-file misses
    // its fixture, and common.PIPE -- which is deliberately built relative to
    // cwd so a unix socket path stays short -- expands to the full container
    // path instead, blowing Darwin's 104-byte sun_path cap on iOS.
    if (chdir(path_path) != 0) {
        __android_log_write(ANDROID_LOG_ERROR, TAG,
                            "could not chdir to the test tree root; cwd-relative tests will fail");
    }

    // Native-addon gate: point NODE_MOBILE_ADDON at the .so the harness pushed
    // into the app's files dir (test-napi-addon.js dlopens it). Harmless absent.
    char addon_path[1024];
    snprintf(addon_path, sizeof(addon_path), "%s/crcnative.node", path_path);
    setenv("NODE_MOBILE_ADDON", addon_path, 1);

    // Drop the exit-verdict hook next to the verdict file and preload it. Doing
    // this natively (rather than shipping it in the bundled test tree) keeps the
    // upstream-owned test/ directory untouched and the hook next to the code
    // that reads what it writes.
    if (tok && tok[0]) {
        char hook_path[1024];
        snprintf(hook_path, sizeof(hook_path), "%s/exit-verdict-hook.js", path_path);
        FILE* hf = fopen(hook_path, "w");
        if (hf) {
            fputs(kExitVerdictHookJS, hf);
            fclose(hf);
            char node_options[1100];
            snprintf(node_options, sizeof(node_options), "--require=%s", hook_path);
            setenv("NODEJS_MOBILE_TEST_VERDICT_FILE", g_result_file, 1);
            setenv("NODE_OPTIONS", node_options, 1);
        } else {
            __android_log_write(ANDROID_LOG_ERROR, TAG,
                                "could not write exit-verdict-hook.js; process.exit() tests will mis-score");
        }
    }

    env->ReleaseStringUTFChars(runToken, tok);
    env->ReleaseStringUTFChars(nodePath, path_path);

    // argc to pass to Node.
    jsize argc = env->GetArrayLength(arguments);

    // Compute byte size need for all arguments in contiguous memory.
    int c_arguments_size = 0;
    for (int i = 0; i < argc ; i++) {
        c_arguments_size += strlen(env->GetStringUTFChars((jstring)env->GetObjectArrayElement(arguments, i), 0));
        c_arguments_size++; // for '\0'
    }

    // Stores arguments in contiguous memory.
    char* args_buffer = (char*)calloc(c_arguments_size, sizeof(char));

    // argv to pass to Node.
    char* argv[argc];

    // To iterate through the expected start position of each argument in args_buffer.
    char* current_args_position = args_buffer;

    // Populate the args_buffer and argv.
    for (int i = 0; i < argc ; i++) {
        const char* current_argument = env->GetStringUTFChars((jstring)env->GetObjectArrayElement(arguments, i), 0);

        // Copy current argument to its expected position in args_buffer
        strncpy(current_args_position, current_argument, strlen(current_argument));

        // Save current argument start position in argv
        argv[i] = current_args_position;

        // Increment to the next argument's expected position.
        current_args_position += strlen(current_args_position)+1;
    }

    if (redirectOutputToLogcat == true) {
        // Start threads to show stdout and stderr in logcat.
        if (start_redirecting_stdout_stderr() == -1) {
            __android_log_write(ANDROID_LOG_ERROR, TAG, "Couldn't start redirecting stdout and stderr to logcat.");
        }
    }

    // Registers atExitHook
    atexit(AtExitHook);

    int result = 0;

    result = startNode(argc, argv);

    // startNode returns the real exit code only when the event loop drains
    // normally. An explicit process.exit() leaves via libc exit() and never
    // reaches here -> the preloaded JS hook wrote the verdict instead.
    write_result(result == 0 ? "PASS\n" : "FAIL\n");

    return jint(result);
}

/**
 * Redirect stdout and staderr to Android's logcat
 */

int pipe_stdout[2];
int pipe_stderr[2];
pthread_t thread_stdout;
pthread_t thread_stderr;

void redirect(int pipe, int log_level) {
    ssize_t redirect_size;
    // Big enough buffer to not get logcat linebreaks in the middle of message tests output.
    char buf[10240];
    while ((redirect_size = read(pipe, buf, sizeof buf - 1)) > 0) {
        // __android_log_write will add a new line anyway.
        if (buf[redirect_size - 1] == '\n')
            --redirect_size;
        buf[redirect_size] = 0;
        __android_log_write(log_level, TAG, buf);
    }
}

void* thread_stderr_func(void*) {
    redirect(pipe_stderr[0], ANDROID_LOG_ERROR);
    return 0;
}

void* thread_stdout_func(void*) {
    redirect(pipe_stdout[0], ANDROID_LOG_INFO);
    return 0;
}

int start_redirecting_stdout_stderr() {
    // Unbuffered (not line-buffered): a line-buffered libc stream can strand a
    // partial final line (e.g. the RESULT marker) in its buffer on teardown.
    // Unbuffered writes go straight to the pipe.
    setvbuf(stdout, 0, _IONBF, 0);
    pipe(pipe_stdout);
    dup2(pipe_stdout[1], STDOUT_FILENO);

    setvbuf(stderr, 0, _IONBF, 0);
    pipe(pipe_stderr);
    dup2(pipe_stderr[1], STDERR_FILENO);

    if (pthread_create(&thread_stdout, 0, thread_stdout_func, 0) == -1) {
        return -1;
    }
    pthread_detach(thread_stdout);

    if(pthread_create(&thread_stderr, 0, thread_stderr_func, 0) == -1) {
        return -1;
    }
    pthread_detach(thread_stderr);

    return 0;
}