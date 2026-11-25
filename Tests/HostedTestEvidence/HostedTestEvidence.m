#import <AppKit/AppKit.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import "HostedTestEvidence.h"

static void evidence(const char *message) {
  (void)write(STDERR_FILENO, message, strlen(message));
}

static void atExitEvidence(void) {
  evidence("Test host evidence: atexit\n");
}

void TinyStatsHostedTestEvidenceAppKit(void) {
  NSApplication *app = NSApp;
  if (!app) {
    evidence("Test host evidence: AppKit not yet initialized\n");
    return;
  }
  static atomic_bool reported = false;
  if (atomic_exchange(&reported, true)) return;
  id<NSApplicationDelegate> delegate = app.delegate;
  // AppKit exposes the delegate callback, not a public application boolean.
  NSString *line = [NSString stringWithFormat:
      @"Test host evidence: AppKit observed; app=%@ windows=%lu delegate=%@ "
       "terminateAfterLastWindowClosed property=unavailable delegateCallback=%@\n",
      app ? @"present" : @"nil", (unsigned long)app.windows.count,
      delegate ? NSStringFromClass([delegate class]) : @"nil",
      [delegate respondsToSelector:@selector(applicationShouldTerminateAfterLastWindowClosed:)] ? @"implemented" : @"absent"];
  evidence(line.UTF8String);
}

__attribute__((constructor)) static void installHostEvidence(void) {
  evidence("Test host evidence: process start\n");
  atexit(atExitEvidence);
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                  usingBlock:^(__unused NSNotification *notification) {
    evidence("Test host evidence: NSApplication will terminate\n");
  }];
  [center addObserverForName:NSWindowWillCloseNotification object:nil queue:nil
                  usingBlock:^(__unused NSNotification *notification) {
    NSApplication *app = NSApp;
    NSUInteger visible = 0;
    for (NSWindow *window in app.windows) {
      if (window.isVisible) visible++;
    }
    NSString *line = [NSString stringWithFormat:
        @"Test host evidence: window will close; windows=%lu visible=%lu\n",
        (unsigned long)app.windows.count, (unsigned long)visible];
    evidence(line.UTF8String);
  }];
  [center addObserverForName:NSApplicationDidUpdateNotification object:nil queue:nil
                  usingBlock:^(__unused NSNotification *notification) {
    TinyStatsHostedTestEvidenceAppKit();
  }];
}
