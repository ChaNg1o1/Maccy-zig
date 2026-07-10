#import "macos_paste.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

int mz_ax_is_trusted(int prompt) {
  if (!prompt) return AXIsProcessTrusted() ? 1 : 0;
  NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
  return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts) ? 1 : 0;
}

static void mz_post_event_pair(CGEventTapLocation tap, CGEventRef down, CGEventRef up) {
  if (down) CGEventPost(tap, down);
  if (up) CGEventPost(tap, up);
}

static void mz_post_event_pair_to_pid(pid_t pid, CGEventRef down, CGEventRef up) {
  if (down) CGEventPostToPid(pid, down);
  if (up) CGEventPostToPid(pid, up);
}

static void mz_send_command_v_chord(pid_t fallback_pid, BOOL force_session_tap) {
  CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
  if (!source) {
    NSLog(@"[MaccyZig] mz_post_command_v: CGEventSourceCreate failed");
    return;
  }

  // Send a real modifier chord instead of only a "v" event with command
  // flags. Some apps treat the latter as synthetic key text, while the full
  // chord flows through menu command handling like a hardware shortcut.
  CGEventRef cmdDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)55, true);
  CGEventRef vDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)9, true);
  CGEventRef vUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)9, false);
  CGEventRef cmdUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)55, false);
  if (vDown) CGEventSetFlags(vDown, kCGEventFlagMaskCommand);
  if (vUp) CGEventSetFlags(vUp, kCGEventFlagMaskCommand);

  NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
  if (force_session_tap || (front != nil && front.processIdentifier == fallback_pid)) {
    mz_post_event_pair(kCGHIDEventTap, cmdDown, vDown);
    mz_post_event_pair(kCGHIDEventTap, vUp, cmdUp);
    NSLog(@"[MaccyZig] posted ⌘V via HID tap; frontmost=%@ pid=%d target=%d",
          front.bundleIdentifier ?: front.localizedName ?: @"<unknown>",
          front.processIdentifier,
          fallback_pid);
  } else if (fallback_pid > 0) {
    mz_post_event_pair_to_pid(fallback_pid, cmdDown, vDown);
    mz_post_event_pair_to_pid(fallback_pid, vUp, cmdUp);
    NSLog(@"[MaccyZig] posted ⌘V to pid=%d fallback; frontmost=%@ pid=%d",
          fallback_pid,
          front.bundleIdentifier ?: front.localizedName ?: @"<unknown>",
          front.processIdentifier);
  } else {
    mz_post_event_pair(kCGHIDEventTap, cmdDown, vDown);
    mz_post_event_pair(kCGHIDEventTap, vUp, cmdUp);
    NSLog(@"[MaccyZig] posted ⌘V via HID tap without target; frontmost=%@ pid=%d",
          front.bundleIdentifier ?: front.localizedName ?: @"<unknown>",
          front.processIdentifier);
  }

  if (cmdDown) CFRelease(cmdDown);
  if (vDown) CFRelease(vDown);
  if (vUp) CFRelease(vUp);
  if (cmdUp) CFRelease(cmdUp);
  CFRelease(source);
}

static void mz_activate_then_post_command_v(pid_t pid, NSUInteger attempt) {
  if (pid <= 0) {
    mz_send_command_v_chord(0, YES);
    return;
  }

  NSRunningApplication *target = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
  if (target == nil || target.isTerminated) {
    NSLog(@"[MaccyZig] target pid=%d missing/terminated; using pid fallback", pid);
    mz_send_command_v_chord(pid, NO);
    return;
  }

  NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
  if (front != nil && front.processIdentifier == pid) {
    mz_send_command_v_chord(pid, YES);
    return;
  }

  // Force the original app active. This is deliberately stronger than the
  // earlier activateWithOptions:0 path: after Maccy's row mouseUp, AppKit
  // often reasserts Maccy as active for a short window. We wait out that
  // bounce, activate the original process, then post a normal HID ⌘V once it
  // is actually frontmost.
  [target activateWithOptions:(NSApplicationActivateIgnoringOtherApps | NSApplicationActivateAllWindows)];

  // ~0.8s budget: full-screen and cross-Space activations routinely take
  // several hundred ms, and falling to CGEventPostToPid too early means many
  // apps silently ignore the paste.
  if (attempt >= 32) {
    NSLog(@"[MaccyZig] target pid=%d did not become frontmost after retries; using pid fallback", pid);
    mz_send_command_v_chord(pid, NO);
    return;
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.025 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    mz_activate_then_post_command_v(pid, attempt + 1);
  });
}

// Restore the previous app and send a real paste shortcut to it. We do not
// rely on CGEventPostToPid as the primary path because many macOS apps only
// run command-key menu handling for the active/key app. Instead, activate the
// original app, wait until it is frontmost, then post a normal HID-level
// command-v chord. PID posting remains as last-resort fallback.
void mz_post_command_v_to_pid(int pid) {
  // Wait until after the row mouseUp + panel orderOut churn, then start
  // polling/activation. This is still perceived as instant but avoids the
  // observed ~70ms Maccy reactivation bounce in AppKit logs.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.09 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    mz_activate_then_post_command_v((pid_t)pid, 0);
  });
}

// Backwards-compatible wrapper for the original frontmost-route variant.
// Now unused on the auto-paste happy path but kept for the keyboard ⌘⏎
// shortcut path which doesn't track a previous-frontmost PID.
void mz_post_command_v(void) {
  mz_post_command_v_to_pid(0);
}
