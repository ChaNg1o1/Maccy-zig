#import "macos_paste.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

int mz_ax_is_trusted(int prompt) {
  if (!prompt) return AXIsProcessTrusted() ? 1 : 0;
  NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
  return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts) ? 1 : 0;
}

void mz_post_command_v(void) {
  CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
  if (!source) return;
  CGEventRef down = CGEventCreateKeyboardEvent(source, (CGKeyCode)9, true);
  CGEventRef up = CGEventCreateKeyboardEvent(source, (CGKeyCode)9, false);
  if (down) {
    CGEventSetFlags(down, kCGEventFlagMaskCommand);
    CGEventPost(kCGSessionEventTap, down);
    CFRelease(down);
  }
  if (up) {
    CGEventSetFlags(up, kCGEventFlagMaskCommand);
    CGEventPost(kCGSessionEventTap, up);
    CFRelease(up);
  }
  CFRelease(source);
}
