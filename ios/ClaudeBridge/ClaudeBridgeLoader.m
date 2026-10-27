#import <Foundation/Foundation.h>

// Runs when the host app loads this framework (before its main()). The Swift side
// defers the real work to the main queue, so it starts once the app's run loop runs.
__attribute__((constructor)) static void ClaudeBridgeLoad(void) {
    Class starter = NSClassFromString(@"ClaudeBridgeStarter");
    if (starter) {
        [starter performSelector:@selector(start)];
    }
}
