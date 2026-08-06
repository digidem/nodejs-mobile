//
//  ViewController.m
//  testnode
//

#import "ViewController.h"
#import "NodeRunner.hpp"

@interface ViewController ()
@property (nonatomic, strong) UILabel *verdictLabel;
@property (nonatomic, assign) BOOL smokeStarted;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // --smoke-ui mode (see main.m): show a verdict label the XCUITest smoke
    // asserts on. Outside smoke mode the app has no UI behaviour.
    if (getenv("NODE_MOBILE_SMOKE_UI") == NULL) return;

    self.verdictLabel = [[UILabel alloc] init];
    self.verdictLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.verdictLabel.textAlignment = NSTextAlignmentCenter;
    self.verdictLabel.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightBold];
    self.verdictLabel.accessibilityIdentifier = @"smokeVerdict";
    self.verdictLabel.text = @"SMOKE:RUNNING";
    [self.view addSubview:self.verdictLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.verdictLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.verdictLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (getenv("NODE_MOBILE_SMOKE_UI") == NULL || self.smokeStarted) return;
    self.smokeStarted = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *verdict = [ViewController runSmoke];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.verdictLabel.text = verdict;
        });
    });
}

// Stage the smoke scripts from the app bundle into Documents and run node on
// the smoke script. The CI workflow copies bs-smoke.js + test-napi-addon.js
// into the bundle root and crcnative.node into Frameworks/ after building
// (the build is unsigned; BrowserStack re-signs on upload). The addon is
// dlopen'd IN PLACE from Frameworks/ — a real device's loader requires
// validly signed code, and Frameworks/ is what (re)signing covers; a copy in
// Documents would not launch on hardened iOS.
+ (NSString *)runSmoke {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *bundle = [[NSBundle mainBundle] bundlePath];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *name in @[@"bs-smoke.js", @"test-napi-addon.js"]) {
        NSString *src = [bundle stringByAppendingPathComponent:name];
        NSString *dst = [docs stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:src]) {
            NSLog(@"SMOKE: missing bundle resource %@", name);
            return @"SMOKE:FAIL";
        }
        [fm removeItemAtPath:dst error:nil];
        NSError *err = nil;
        if (![fm copyItemAtPath:src toPath:dst error:&err]) {
            NSLog(@"SMOKE: staging %@ failed: %@", name, err.localizedDescription);
            return @"SMOKE:FAIL";
        }
    }

    NSString *addon = [bundle stringByAppendingPathComponent:@"Frameworks/crcnative.node"];
    if (![fm fileExistsAtPath:addon]) {
        NSLog(@"SMOKE: missing bundle resource Frameworks/crcnative.node");
        return @"SMOKE:FAIL";
    }
    setenv("NODE_MOBILE_ADDON", [addon UTF8String], 1);

    NSString *script = [docs stringByAppendingPathComponent:@"bs-smoke.js"];
    int code = [NodeRunner startEngineWithArguments:@[@"node", script]];
    NSLog(@"SMOKE: node exited with code %d", code);
    return code == 0 ? @"SMOKE:PASS" : @"SMOKE:FAIL";
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
