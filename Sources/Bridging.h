#import "CGVirtualDisplay.h"
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDParameter.h>

// Swift's CGEventType enum cannot express the C sentinel for any input event.
static inline CFTimeInterval CaffeineSecondsSinceInput(void) {
    return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
}
