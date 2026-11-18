#import <UIKit/UIKit.h>
#import "AppDelegate.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        freopen("/tmp/navigatoreosm.log", "a", stderr);
        freopen("/tmp/navigatoreosm.log", "a", stdout);
        NSLog(@"=== NavigatoreOSM started (main) ===");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
