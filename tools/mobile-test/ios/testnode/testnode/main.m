//
//  main.m
//  testnode
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "NodeRunner.hpp"
int main(int argc, char * argv[]) {

    //--smoke-ui: self-driving real-device smoke mode for BrowserStack XCUITest,
    //where there is no simctl/proxy harness. Start the normal UI app; the
    //ViewController runs node on a background thread (bs-smoke.js + the
    //N-API addon gate, staged in the app bundle by the CI workflow) and
    //surfaces the verdict in a label the UI test asserts on.
    if(argc>=2 && strcmp(argv[1],"--smoke-ui")==0) {
        setenv("NODE_MOBILE_SMOKE_UI", "1", 1);
        @autoreleasepool {
            return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
        }
    }

    if(argc<2)
    {
        //This application needs some arguments to pass to node.
        return 0;
    } else {
        //If we receive arguments we are probably running tests.

        NSString* srcTestsPath = [[NSBundle mainBundle] pathForResource:@"test" ofType:nil];
        NSString* dstTestsPath = [NSString stringWithFormat:@"%@/test", [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]];

        //--copy-path-for-testing indicates that we should copy the test folder to Documents.
        if(strncmp(argv[1],"--copy-path-for-testing",strlen("--copy-path-for-testing"))==0) {
            [NodeRunner CopyTestDir:srcTestsPath:dstTestsPath];
            return 0;
        }

        //NSArray to manipulate the arguments in, to use the NodeRunner startEngineWithArguments interface.
        NSMutableArray *arguments=[NSMutableArray array];
        [arguments addObject:@"node"]; //first argument.
        int i=1;
        NSString* file_replace_prefix=NULL;

        //--run-token <token>: per-launch token. Expose it via the environment,
        //never as an argv element, so it can't appear in a test's process.argv.
        //NodeRunner uses it to name the per-launch verdict file
        //(Documents/result-<token>.txt); a spawned child never receives
        //--run-token, so it can't write a neighbouring test's verdict.
        if(argc>=i+2 && strcmp(argv[i],"--run-token")==0) {
            setenv("NODE_MOBILE_RUN_TOKEN", argv[i+1], 1);
            i+=2;
        }

        //--substitute-dir indicates a path prefix that should be replaced with the test path in Documents.
        if(argc>=i+2 && strcmp(argv[i],"--substitute-dir")==0) {
            file_replace_prefix=[[NSString alloc] initWithCString:argv[i+1] encoding:NSUTF8StringEncoding];
            i+=2;
        }

        //Add following arguments to the node invocation. Rewrite test paths to
        //the Documents copy. Use substring replacement (not a prefix check) so
        //paths embedded in a flag are also translated, e.g.
        //--test-reporter=./test/common/test-error-reporter.js (matches the
        //Android harness, which uses String.replace).
        for(; i < argc; i++) {
            NSString *str = [[NSString alloc] initWithCString:argv[i] encoding:NSUTF8StringEncoding];
            if(file_replace_prefix!=NULL) {
                str = [str stringByReplacingOccurrencesOfString:file_replace_prefix withString:dstTestsPath];
            }
            str = [str stringByReplacingOccurrencesOfString:@"./test/" withString:[NSString stringWithFormat:@"%@/", dstTestsPath]];
            [arguments addObject:str];
        }

        //start Node
        return [NodeRunner startEngineWithArguments:arguments] ;
    }
}
