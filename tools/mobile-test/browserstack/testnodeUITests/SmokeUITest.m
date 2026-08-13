//
//  SmokeUITest.m
//
//  Real-device smoke for BrowserStack XCUITest: launch the testnode app
//  in --smoke-ui mode (ViewController runs node + the N-API addon gate on a
//  background thread) and assert the verdict label lands on SMOKE:PASS.
//  The target that compiles this file is generated at build time by
//  add-uitest-target.rb — it is not checked into the Xcode project.
//

#import <XCTest/XCTest.h>

@interface SmokeUITest : XCTestCase
@end

@implementation SmokeUITest

- (void)testNodeBootsAndLoadsNapiAddon {
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[ @"--smoke-ui" ];
    [app launch];

    XCUIElement *label = [app.staticTexts elementMatchingType:XCUIElementTypeStaticText
                                                   identifier:@"smokeVerdict"];
    XCTAssertTrue([label waitForExistenceWithTimeout:30],
                  @"smoke verdict label never appeared — app failed to start");

    // Node boot + addon is seconds on-device; a generous ceiling for cold
    // starts. If node crashes the app dies and the wait fails, which is the
    // correct verdict.
    NSPredicate *passed = [NSPredicate predicateWithFormat:@"label == 'SMOKE:PASS'"];
    XCTestExpectation *e = [self expectationForPredicate:passed
                                     evaluatedWithObject:label
                                                 handler:nil];
    XCTWaiterResult r = [XCTWaiter waitForExpectations:@[ e ] timeout:240];
    XCTAssertEqual(r, XCTWaiterResultCompleted,
                   @"verdict label reads '%@' (want SMOKE:PASS) — see device syslog for SMOKE:/node output",
                   label.label);
}

@end
