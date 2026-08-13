//
//  NodeRunner.m
//  testnode
//

#include "NodeRunner.hpp"
#include <NodeMobile/NodeMobile.h>
#include <string>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>   // chdir

// Per-launch verdict file in the app's Documents dir (host-readable via
// `simctl get_app_container`). The proxy reads the test's real exit code from
// this durable file instead of scraping the lossy `simctl --console` stream
// (which drops output intermittently on CI). Path is built from the per-launch
// token (set by main.m from --run-token via NODE_MOBILE_RUN_TOKEN); an empty
// token (e.g. a spawned child that never got --run-token) writes nothing.
static char g_result_file[1024] = {0};
static bool g_result_written = false;
static void write_result(const char* verdict) {
    if (g_result_file[0] == '\0') return;
    FILE* f = fopen(g_result_file, "w");
    if (f) { fputs(verdict, f); fclose(f); g_result_written = true; }
}
// Loaded via NODE_OPTIONS=--require, which (unlike a command-line flag) stays
// out of process.execArgv, so tests that assert on it are unaffected. Keep in
// sync with the copy in android/testnode/app/src/main/cpp/native-lib.cpp.
static const char* kExitVerdictHookJS = R"JS('use strict';
// Written at launch by the testnode harness; see NodeRunner.mm.
// process.exit() leaves through libc exit(), so node_start() never returns and
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

static bool result_file_exists(void) {
    if (g_result_file[0] == '\0') return false;
    FILE* f = fopen(g_result_file, "r");
    if (!f) return false;
    fclose(f);
    return true;
}

static void NodeRunnerAtExitHook(void) {
    // node_start did not return: a crash, an abort, or an explicit
    // process.exit() (which routes through node::Exit -> libc exit() and never
    // unwinds to us). The exit() case is now covered by the JS hook above, so
    // check the file rather than only our own flag — otherwise this would
    // overwrite the real verdict it just wrote. Anything that reaches here with
    // no file at all terminated abnormally, and FAIL is the correct verdict.
    if (!g_result_written && !result_file_exists()) write_result("FAIL\n");
}

@implementation NodeRunner

+ (void) CopyTestDir:(NSString*)srcTestsPath:(NSString*)dstTestsPath
{
    BOOL isDir;
    if ([[NSFileManager defaultManager] fileExistsAtPath:dstTestsPath isDirectory:&isDir] && isDir) {
        [[NSFileManager defaultManager] removeItemAtPath:dstTestsPath error:nil];
    }
    
    NSLog(@"Copying test files to documents...");
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:srcTestsPath toPath:dstTestsPath error:&copyError]) {
        NSLog(@"Error copying files: %@", [copyError localizedDescription]);
        exit(1);
    }
}

//node's libUV requires all arguments being on contiguous memory.
+ (int) startEngineWithArguments:(NSArray*)arguments
{
    //Set the builtin_modules path to NODE_PATH

    int c_arguments_size=0;
    
    //Compute byte size need for all arguments in contiguous memory.
    for (id argElement in arguments)
    {
        c_arguments_size+=strlen([argElement UTF8String]);
        c_arguments_size++; // for '\0'
    }
    
    //Stores arguments in contiguous memory.
    char* args_buffer=(char*)calloc(c_arguments_size, sizeof(char));
    
    //argv to pass into node.
    char* argv[[arguments count]];
    
    //To iterate through the expected start position of each argument in args_buffer.
    char* current_args_position=args_buffer;
    
    //Argc
    int argument_count=0;
    
    //Populate the args_buffer and argv.
    for (id argElement in arguments)
    {
        const char* current_argument=[argElement UTF8String];
        
        //Copy current argument to its expected position in args_buffer
        strncpy(current_args_position, current_argument, strlen(current_argument));
        
        //Save current argument start position in argv and increment argc.
        argv[argument_count]=current_args_position;
        argument_count++;
        
        //Increment to the next argument's expected position.
        current_args_position+=strlen(current_args_position)+1;
    }
    //Build the per-launch verdict file path (<Documents>/result-<token>.txt) from
    //the token set by main.m, before starting node, so the atexit fallback can
    //write even if node aborts.
    const char* tok_env = getenv("NODE_MOBILE_RUN_TOKEN");
    //Copy it: unsetenv() below may free the string getenv() pointed at, and the
    //token is still needed afterwards to name the stdout file.
    char tok[128] = {0};
    if (tok_env) strncpy(tok, tok_env, sizeof(tok) - 1);
    if (tok[0]) {
        NSString* docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString* rf = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"result-%s.txt", tok]];
        strncpy(g_result_file, [rf UTF8String], sizeof(g_result_file) - 1);
        //Consume the token: a child spawned via process.execPath inherits the
        //environment and re-enters main.m; with the token still set it would
        //write PASS/FAIL to the parent's verdict file while the parent is
        //still running (a false-PASS vector). Only this launch may hold it.
        unsetenv("NODE_MOBILE_RUN_TOKEN");
        atexit(NodeRunnerAtExitHook);

        //Redirect stdout/stderr into the sandbox, next to the verdict file, and
        //let the proxy read it back afterwards. The alternative is
        //`simctl launch --console`, which pipes the app's output over a FIFO
        //that simctl fails to establish on a rapid relaunch ("Unable to
        //establish FIFO ... Error 17") -- the proxy carries a retry loop purely
        //for that. Same argument the verdict file already won: a durable file in
        //the sandbox beats a shared, lossy stream.
        //
        //Unbuffered, because the JS process.on('exit') hook can write the
        //verdict and the process can then die without libc flushing whatever is
        //still sitting in stdout's buffer -- which would silently truncate the
        //output test.py compares against a .out file.
        NSString* outPath = [docs stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"stdout-%s.txt", tok]];
        if (freopen([outPath UTF8String], "w", stdout) != NULL) {
            setvbuf(stdout, NULL, _IONBF, 0);
            dup2(fileno(stdout), fileno(stderr));
            setvbuf(stderr, NULL, _IONBF, 0);
        } else {
            NSLog(@"could not redirect stdout to %@; falling back to --console", outPath);
        }

        //Drop the exit-verdict hook next to the verdict file and preload it.
        //Doing this natively (rather than shipping it in the bundled test tree)
        //keeps the upstream-owned test/ directory untouched and the hook next
        //to the code that reads what it writes.
        //
        //Unconditional: the hook require()s nothing until the process is already
        //exiting, so the only thing a test can observe is one extra listener on
        //process.on('exit'). Predicting which tests need it is not possible anyway —
        //common.skip() reaches process.exit(0) from any test, at runtime.
        {
            NSString* hook = [docs stringByAppendingPathComponent:@"exit-verdict-hook.js"];
            const char* hook_path = [hook UTF8String];
            FILE* hf = fopen(hook_path, "w");
            if (hf) {
                fputs(kExitVerdictHookJS, hf);
                fclose(hf);
                char node_options[1100];
                snprintf(node_options, sizeof(node_options), "--require=%s", hook_path);
                setenv("NODEJS_MOBILE_TEST_VERDICT_FILE", g_result_file, 1);
                setenv("NODE_OPTIONS", node_options, 1);
            } else {
                NSLog(@"could not write exit-verdict-hook.js; process.exit() tests will mis-score");
            }
        }
    }

    //Match a desktop `tools/test.py` run, which starts node with the working
    //directory at the tree root. Without this the app inherits cwd=/ and every
    //cwd-relative path in the suite resolves against the filesystem root:
    //test-fs-cp-async-file-url looks for /test/fixtures/..., --env-file misses
    //its fixture, and common.PIPE -- built relative to cwd precisely so a unix
    //socket path stays short -- expands to the full container path instead,
    //which exceeds Darwin's 104-byte sun_path cap and fails every UDS test.
    {
        NSString* root = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (chdir([root UTF8String]) != 0) {
            NSLog(@"could not chdir to the test tree root; cwd-relative tests will fail");
        }
    }

    //Native-addon gate: point NODE_MOBILE_ADDON at the .node the harness copied
    //into Documents (test-napi-addon.js dlopens it). Harmless when absent.
    //Default only (overwrite=0): the --smoke-ui device mode pre-sets this to
    //the signed copy inside the app bundle's Frameworks/, because a real
    //device's dlopen requires validly signed code and Documents copies fall
    //outside the (re)signing seal.
    {
        NSString* d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        setenv("NODE_MOBILE_ADDON", [[d stringByAppendingPathComponent:@"crcnative.node"] UTF8String], 0);
    }

    //Start node; its return is the real exit code, except after a
    //process.exit() (handled by the preloaded JS hook). Write it to the file.
    int code = node_start(argument_count, argv);
    write_result(code == 0 ? "PASS\n" : "FAIL\n");
    return code;
}

@end
