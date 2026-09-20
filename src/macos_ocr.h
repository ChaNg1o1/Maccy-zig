#pragma once
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <sys/types.h>
#import "macos_jev.h"

/// The screen is the one account of "what is the user pasting into" that every
/// app gives, whatever it is built with; Accessibility is the other, and the
/// two are always used together (see mz_jev_focus_context). Reading it is never
/// on the panel's path: the capture starts when the panel opens, runs on
/// background queues, and the suggestion request gives it a short bounded wait.

/// Load the text recogniser. The first recognition in a process costs ~12s
/// while the model loads, and that cost is paid per language set, so this must
/// run at launch with the exact languages production uses. Returns
/// immediately; the work happens on a utility queue.
void mz_ocr_prewarm(void);

/// Whether the user has granted Screen Recording. Does not prompt.
BOOL mz_ocr_permitted(void);

/// Ask for Screen Recording. macOS shows its own prompt and the answer only
/// takes effect after a relaunch, which is the system's behaviour, not ours.
void mz_ocr_request_permission(void);

/// Start capturing and recognising the screen around where the paste is going
/// to land in `pid`, as located by mz_jev_paste_target -- so call
/// mz_jev_capture_focus first. Cancels any capture already running. Cheap to
/// call: everything past the first few microseconds is on background queues.
void mz_ocr_begin(pid_t pid);

/// The part of `window` that mz_ocr_begin reads, given what is known about
/// where the paste lands. All rectangles in global top-left coordinates.
/// `landing_out` receives where in the box the landing line is, as a fraction
/// of its height from the top; `source_out` what the line was taken from.
/// Exposed for the self-check.
CGRect mz_ocr_box(CGRect window, MZJevPasteTarget paste, CGPoint pointer,
                  CGFloat *landing_out, NSString **source_out);

/// Text from the most recent mz_ocr_begin, or nil when it is not finished,
/// failed, or was never started. Never blocks, never waits.
NSString *mz_ocr_latest(void);

/// Wait up to `seconds` for the capture started by mz_ocr_begin, then return
/// its text or nil. Returns at once when no capture is in flight. Never call it
/// on the main thread.
NSString *mz_ocr_await(NSTimeInterval seconds);

/// The most recent captured frame while tracing is on, or NULL. Caller owns
/// the returned image.
CGImageRef mz_ocr_copy_last_capture(void);

/// Drop any pending capture and its result.
void mz_ocr_cancel(void);

/// Times the real capture + recognition path against the frontmost window and
/// prints the result. Backs `maccy-zig ocr-check`. Returns 0 when a capture
/// produced text.
int mz_ocr_self_check(void);
