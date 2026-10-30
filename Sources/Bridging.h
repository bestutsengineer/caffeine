#import "CGVirtualDisplay.h"
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDParameter.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>

// Private client type used only for LED properties; it installs no event handler.
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int, CFDictionaryRef);
static inline IOHIDEventSystemClientRef CaffeineCreateLEDClient(void) {
    return IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 2, NULL);
}

// Swift's CGEventType enum cannot express the C sentinel for any input event.
static inline CFTimeInterval CaffeineSecondsSinceInput(void) {
    return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
}
