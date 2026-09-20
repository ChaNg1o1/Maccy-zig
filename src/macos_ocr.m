#import "macos_ocr.h"
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Vision/Vision.h>
#import "macos_jev.h"

// Pinned, and identical everywhere: Vision loads a model per language set, and
// each unseen set pays the ~12s load again. Measured on this machine:
// ["zh-Hans","en-US"] warm = 154ms for an 800x300 box; ["en-US"] alone was a
// cold 11s because it is a different model.
static NSArray<NSString *> *mz_ocr_languages(void) {
  return @[ @"zh-Hans", @"en-US" ];
}

// A bounded box around where the paste will land rather than the whole window:
// recognition time follows the pixel count. Measured on a 1637x1084 window: an
// 800x300 box 154ms, half the window 384ms, all of it 676ms.
static const CGFloat kMZOcrBoxWidth = 900.0;
static const CGFloat kMZOcrBoxHeight = 420.0;
// The box widens to the field it follows, up to what still recognises inside
// the head start the panel gives it: 1637x420 measured at ~250ms, 900x420 at
// ~130ms.
static const CGFloat kMZOcrMaxBoxWidth = 1600.0;
// What explains a paste comes *before* the insertion point in reading order:
// the messages above a chat box, the label above a form field, the code above
// the caret. So most of the box sits above the landing line, with a sliver below.
static const CGFloat kMZOcrBelowAnchor = 40.0;
// Anything smaller is not worth a capture.
static const CGFloat kMZOcrMinWidth = 80.0;
static const CGFloat kMZOcrMinHeight = 40.0;
// Captured at 2x: recognition accuracy on small text falls off badly at 1x.
static const CGFloat kMZOcrScale = 2.0;
// Recognised text handed to the model. Enough for a form or a few lines of
// code around the caret, short enough not to swamp the question.
static const NSUInteger kMZOcrMaxChars = 600;
// Recognition time follows the number of text lines far more than the number
// of pixels: measured on one 1800x840 capture, 19 lines 266ms, the 9 nearest
// 161ms, and a dense 75-line screen 460ms -- too late to be used at all. Only
// about this many lines fit the character budget anyway, so only the ones
// nearest the landing line are recognised. Finding where the lines *are* is a
// different, cheap request (8ms on that capture).
static const NSUInteger kMZOcrMaxLines = 24;

static dispatch_queue_t mz_ocr_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("io.github.chang1o1.MaccyZig.ocr",
                                  dispatch_queue_attr_make_with_qos_class(
                                      DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}

// The result is produced on the ocr queue and read from elsewhere, so both
// sides go through this condition. `gOcrDone` is set on failure too: a caller
// waiting for a capture that will never arrive must be released immediately,
// not held for the whole deadline.
static NSCondition *mz_ocr_state(void) {
  static NSCondition *condition;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ condition = [NSCondition new]; });
  return condition;
}
static NSString *gOcrText = nil;
static NSUInteger gOcrGeneration = 0;
static BOOL gOcrDone = YES;

static void mz_ocr_store(NSUInteger generation, NSString *text) {
  NSCondition *state = mz_ocr_state();
  [state lock];
  if (generation == gOcrGeneration) {
    gOcrText = [text copy];
    gOcrDone = YES;
    [state broadcast];
  }
  [state unlock];
}

NSString *mz_ocr_latest(void) {
  NSCondition *state = mz_ocr_state();
  [state lock];
  NSString *text = gOcrText;
  [state unlock];
  return text;
}

NSString *mz_ocr_await(NSTimeInterval seconds) {
  NSCondition *state = mz_ocr_state();
  [state lock];
  NSUInteger generation = gOcrGeneration;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!gOcrDone && generation == gOcrGeneration) {
    if (![state waitUntilDate:deadline]) break;
  }
  NSString *text = (generation == gOcrGeneration) ? gOcrText : nil;
  [state unlock];
  return text;
}

void mz_ocr_cancel(void) {
  NSCondition *state = mz_ocr_state();
  [state lock];
  gOcrGeneration += 1;
  gOcrText = nil;
  gOcrDone = YES;
  [state broadcast];
  [state unlock];
}

#pragma mark - Permission

BOOL mz_ocr_permitted(void) { return CGPreflightScreenCaptureAccess(); }

void mz_ocr_request_permission(void) {
  // Returns immediately; macOS puts the app in the Screen Recording list and
  // shows its own prompt. The grant applies on next launch.
  (void)CGRequestScreenCaptureAccess();
}

#pragma mark - Recognition

// The inspector shows the last capture, so "why did it read that?" is
// answered by looking at the pixels. Kept in memory: a PNG on disk is one more
// thing to go and find.
static NSLock *mz_ocr_image_lock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSLock new]; });
  return lock;
}
static CGImageRef gLastCapture = NULL;

static void mz_ocr_keep_capture(CGImageRef image) {
  NSLock *lock = mz_ocr_image_lock();
  [lock lock];
  CGImageRef previous = gLastCapture;
  gLastCapture = mz_jev_debug() ? CGImageRetain(image) : NULL;
  [lock unlock];
  if (previous != NULL) CGImageRelease(previous);
  if (mz_jev_debug()) {
    mz_jev_log(@"ocr: captured %zux%zu", CGImageGetWidth(image), CGImageGetHeight(image));
  }
}

CGImageRef mz_ocr_copy_last_capture(void) {
  NSLock *lock = mz_ocr_image_lock();
  [lock lock];
  CGImageRef copy = gLastCapture != NULL ? CGImageRetain(gLastCapture) : NULL;
  [lock unlock];
  return copy;
}

// `landing` is where in the image the paste will land, as a fraction of its
// height measured from the top.
static NSString *mz_ocr_recognise(CGImageRef image, CGFloat landing) {
  if (image == NULL) return nil;
  NSDate *started = NSDate.date;
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];

  // Vision's boxes are normalised with the origin at the bottom-left; `landing`
  // and everything compared with it is measured from the top.
  CGRect band = CGRectMake(0.0, 0.0, 1.0, 1.0);
  VNDetectTextRectanglesRequest *detect = [[VNDetectTextRectanglesRequest alloc] init];
  if ([handler performRequests:@[ detect ] error:NULL] && detect.results.count > kMZOcrMaxLines) {
    NSArray<VNTextObservation *> *nearest = [detect.results sortedArrayUsingComparator:
        ^NSComparisonResult(VNTextObservation *a, VNTextObservation *b) {
      CGFloat da = fabs(1.0 - CGRectGetMidY(a.boundingBox) - landing);
      CGFloat db = fabs(1.0 - CGRectGetMidY(b.boundingBox) - landing);
      return da < db ? NSOrderedAscending : da > db ? NSOrderedDescending : NSOrderedSame;
    }];
    CGFloat low = 1.0, high = 0.0;
    for (NSUInteger i = 0; i < kMZOcrMaxLines; i++) {
      low = MIN(low, CGRectGetMinY(nearest[i].boundingBox));
      high = MAX(high, CGRectGetMaxY(nearest[i].boundingBox));
    }
    // A little slack, so a line is not cut through the middle of its glyphs.
    low = MAX(low - 0.01, 0.0);
    high = MIN(high + 0.01, 1.0);
    band = CGRectMake(0.0, low, 1.0, high - low);
  }

  VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
  // .accurate is not optional: at .fast this box recognised in 14ms but every
  // CJK line came back as noise, and half this user's clipboard is Chinese.
  request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
  request.recognitionLanguages = mz_ocr_languages();
  request.usesLanguageCorrection = YES;
  request.regionOfInterest = band;
  if (![handler performRequests:@[ request ] error:NULL]) return nil;

  NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
  for (VNRecognizedTextObservation *observation in request.results) {
    NSString *string = [observation topCandidates:1].firstObject.string;
    if (string.length == 0) continue;
    // Reported relative to the region of interest, not to the image.
    CGFloat from_top = 1.0 - (band.origin.y + CGRectGetMidY(observation.boundingBox) * band.size.height);
    [lines addObject:@{@"text": string, @"y": @(from_top), @"far": @(fabs(from_top - landing))}];
  }
  mz_jev_log(@"ocr: %lu text line(s) found, %lu nearest recognised in %.0fms", (unsigned long)detect.results.count,
             (unsigned long)lines.count, -started.timeIntervalSinceNow * 1000.0);

  // When there is more text than the budget, it is the lines farthest from the
  // landing line that go -- wherever in the box that line ended up -- and what
  // is kept is handed over top to bottom.
  NSSortDescriptor *nearest = [NSSortDescriptor sortDescriptorWithKey:@"far" ascending:YES];
  NSMutableArray<NSDictionary *> *kept = [NSMutableArray array];
  NSUInteger used = 0;
  for (NSDictionary *line in [lines sortedArrayUsingDescriptors:@[ nearest ]]) {
    NSUInteger cost = [line[@"text"] length] + 1;
    if (used + cost > kMZOcrMaxChars) break;
    used += cost;
    [kept addObject:line];
  }
  if (kept.count == 0) return nil;
  [kept sortUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"y" ascending:YES] ]];
  return [[kept valueForKey:@"text"] componentsJoinedByString:@"\n"];
}

void mz_ocr_prewarm(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Utility QoS: this is a one-off 12s model load that must not compete with
    // anything the user is waiting on.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
          initWithBitmapDataPlanes:NULL pixelsWide:240 pixelsHigh:60 bitsPerSample:8
                   samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
      if (rep == nil) return;
      [NSGraphicsContext saveGraphicsState];
      NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
      [NSColor.whiteColor setFill];
      NSRectFill(NSMakeRect(0, 0, 240, 60));
      // Both scripts, so both halves of the model are touched.
      [@"预热 warm up" drawAtPoint:NSMakePoint(6, 16)
                   withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:22],
                                    NSForegroundColorAttributeName: NSColor.blackColor}];
      [NSGraphicsContext restoreGraphicsState];
      (void)mz_ocr_recognise(rep.CGImage, 1.0);
    });
  });
}

#pragma mark - Capture

// Which part of `window` to read. Pure geometry, so the self-check can hold it
// to its rules.
//
// The box ends just below the line the paste lands on, and that line is taken
// from the most exact source that can name it: the caret; a focused element
// small enough that the box still reaches well above it (one as tall as the
// box says nothing about where inside it the paste goes); the pointer if it is
// in the area the paste goes into, since a click is how a caret gets placed;
// the middle of that area. Sideways the box follows the field, which is the
// column the person is writing in -- a conversation, a form, a document --
// rather than whatever sits beside it.
CGRect mz_ocr_box(CGRect window, MZJevPasteTarget paste, CGPoint pointer,
                  CGFloat *landing_out, NSString **source_out) {
  BOOL has_field = !CGRectIsNull(paste.field) && CGRectIntersectsRect(paste.field, window);
  CGRect area = has_field ? CGRectIntersection(paste.field, window) : window;
  CGRect line;
  if (has_field && !CGRectIsNull(paste.caret) && CGRectIntersectsRect(paste.caret, window)) {
    line = paste.caret;
    *source_out = @"the caret";
  } else if (has_field && paste.field.size.height <= kMZOcrBoxHeight * 0.5) {
    line = paste.field;
    *source_out = @"the focused element";
  } else if (CGRectContainsPoint(area, pointer)) {
    line = CGRectMake(pointer.x, pointer.y, 0.0, 0.0);
    *source_out = @"the pointer";
  } else {
    line = CGRectMake(CGRectGetMidX(area), CGRectGetMidY(area), 0.0, 0.0);
    *source_out = has_field ? @"the middle of the focused element" : @"the middle of the window";
  }
  CGRect column = has_field ? paste.field : line;

  CGFloat width = MIN(MIN(MAX(kMZOcrBoxWidth, column.size.width), kMZOcrMaxBoxWidth), window.size.width);
  CGFloat height = MIN(kMZOcrBoxHeight, window.size.height);
  // A column wider than the box is read around the landing line; a narrower
  // one sits in the middle of the box.
  CGFloat centre_x = column.size.width > width
      ? MIN(MAX(CGRectGetMidX(line), CGRectGetMinX(column) + width * 0.5), CGRectGetMaxX(column) - width * 0.5)
      : CGRectGetMidX(column);
  CGRect box = CGRectMake(centre_x - width * 0.5, CGRectGetMaxY(line) + kMZOcrBelowAnchor - height, width, height);
  // Slide the box back inside the window rather than clipping it away.
  if (CGRectGetMaxX(box) > CGRectGetMaxX(window)) box.origin.x = CGRectGetMaxX(window) - box.size.width;
  if (CGRectGetMinX(box) < CGRectGetMinX(window)) box.origin.x = CGRectGetMinX(window);
  if (CGRectGetMaxY(box) > CGRectGetMaxY(window)) box.origin.y = CGRectGetMaxY(window) - box.size.height;
  if (CGRectGetMinY(box) < CGRectGetMinY(window)) box.origin.y = CGRectGetMinY(window);
  *landing_out = MIN(MAX((CGRectGetMidY(line) - CGRectGetMinY(box)) / box.size.height, 0.0), 1.0);
  return box;
}

// Frontmost first, a window with a title before one without. Apps keep
// untitled helper windows around -- overlays the exact size of the real window,
// strips along the menu bar -- and a title is the platform's own mark of a
// window meant for the person: it is what Mission Control and the Window menu
// show. Untitled is still accepted, because launcher panels have no title.
static SCWindow *mz_ocr_frontmost(NSArray<SCWindow *> *front_to_back, BOOL (^eligible)(SCWindow *)) {
  SCWindow *untitled = nil;
  for (SCWindow *window in front_to_back) {
    if (!eligible(window)) continue;
    if (window.title.length > 0) return window;
    if (untitled == nil) untitled = window;
  }
  return untitled;
}

// The window the paste goes into, which bounds the read: the frontmost window
// of the app that contains the landing place, or -- when the app says nothing
// about where that is -- its frontmost ordinary window, which leaves out the
// palettes, tooltips and picture-in-picture players that float above.
// Front-to-back order comes from CGWindowList, which documents it;
// SCShareableContent does not.
static SCWindow *mz_ocr_target_window(NSArray<SCWindow *> *windows, pid_t pid, CGRect landing) {
  NSMutableDictionary<NSNumber *, SCWindow *> *capturable = [NSMutableDictionary dictionary];
  for (SCWindow *window in windows) {
    if (window.owningApplication.processID != pid || !window.onScreen) continue;
    if (window.frame.size.width < kMZOcrMinWidth || window.frame.size.height < kMZOcrMinHeight) continue;
    capturable[@(window.windowID)] = window;
  }
  NSArray<NSDictionary *> *stack = CFBridgingRelease(CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  NSMutableArray<SCWindow *> *front_to_back = [NSMutableArray array];
  for (NSDictionary *info in stack) {
    SCWindow *window = capturable[info[(__bridge NSString *)kCGWindowNumber]];
    // Fully transparent is not something anyone is looking at.
    if (window != nil && [info[(__bridge NSString *)kCGWindowAlpha] doubleValue] > 0.0) [front_to_back addObject:window];
  }

  SCWindow *target = nil;
  if (!CGRectIsNull(landing)) {
    CGPoint centre = CGPointMake(CGRectGetMidX(landing), CGRectGetMidY(landing));
    target = mz_ocr_frontmost(front_to_back, ^BOOL(SCWindow *window) {
      return CGRectContainsPoint(window.frame, centre);
    });
  }
  return target ?: mz_ocr_frontmost(front_to_back, ^BOOL(SCWindow *window) { return window.windowLayer == 0; });
}

void mz_ocr_begin(pid_t pid) {
  mz_ocr_cancel();
  if (pid <= 0) { mz_jev_log(@"ocr: skipped, no target pid"); return; }
  if (!mz_ocr_permitted()) {
    mz_jev_log(@"ocr: skipped, Screen Recording not granted");
    return;
  }
  mz_jev_log(@"ocr: starting for pid %d", pid);
  NSCondition *state = mz_ocr_state();
  [state lock];
  gOcrDone = NO;  // a capture is now in flight; mz_ocr_await may wait for it
  NSUInteger generation = gOcrGeneration;
  [state unlock];

  // NSEvent reports the pointer with the origin at the bottom-left of the
  // primary screen; SCWindow frames and Accessibility put it at the top-left.
  NSPoint mouse = NSEvent.mouseLocation;
  CGPoint pointer = CGPointMake(mouse.x, NSMaxY(NSScreen.screens.firstObject.frame) - mouse.y);

  // Asking the app where the field and caret are, and asking the window server
  // what is on screen, are independent; neither waits for the other.
  __block MZJevPasteTarget paste = {CGRectNull, CGRectNull};
  dispatch_group_t located = dispatch_group_create();
  dispatch_group_async(located, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    paste = mz_jev_paste_target(pid);
  });

  [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                             onScreenWindowsOnly:YES
                                               completionHandler:^(SCShareableContent *content, NSError *error) {
    // Bounded by the Accessibility messaging timeout.
    dispatch_group_wait(located, DISPATCH_TIME_FOREVER);
    if (content == nil) { mz_ocr_store(generation, nil); return; }
    CGRect landing = !CGRectIsNull(paste.caret) ? paste.caret : paste.field;
    SCWindow *target = mz_ocr_target_window(content.windows, pid, landing);
    if (target == nil) {
      mz_jev_log(@"ocr: no capturable window for pid %d", pid);
      mz_ocr_store(generation, nil);
      return;
    }
    CGRect frame = target.frame;

    CGFloat landing_in_box = 1.0;
    NSString *source = nil;
    CGRect box = mz_ocr_box(frame, paste, pointer, &landing_in_box, &source);
    mz_jev_log(@"ocr: reading %.0fx%.0f around %@", box.size.width, box.size.height, source);

    // What is captured is that part of the display with every window of the
    // app composited as the person sees it, and nothing of any other app --
    // this panel included. Not one window: apps split what looks like a single
    // window across several (a web view in a child window, an untitled
    // overlay the size of the real window in front of it), and which of them
    // holds the pixels is not something to guess at.
    SCDisplay *display = nil;
    for (SCDisplay *candidate in content.displays) {
      if (CGRectContainsPoint(candidate.frame, CGPointMake(CGRectGetMidX(box), CGRectGetMidY(box)))) display = candidate;
    }
    SCRunningApplication *application = target.owningApplication;
    // A window can hang off the edge of its display; the landing line keeps
    // its place on screen while the box around it shrinks.
    CGFloat landing_y = CGRectGetMinY(box) + landing_in_box * box.size.height;
    box = display != nil ? CGRectIntersection(box, display.frame) : CGRectNull;
    if (application == nil || CGRectIsNull(box) || box.size.width < kMZOcrMinWidth || box.size.height < kMZOcrMinHeight) {
      mz_jev_log(@"ocr: the window is not on a display that can be read");
      mz_ocr_store(generation, nil);
      return;
    }
    landing_in_box = MIN(MAX((landing_y - CGRectGetMinY(box)) / box.size.height, 0.0), 1.0);

    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.sourceRect = CGRectMake(box.origin.x - display.frame.origin.x, box.origin.y - display.frame.origin.y,
                                   box.size.width, box.size.height);
    config.width = (size_t)(box.size.width * kMZOcrScale);
    config.height = (size_t)(box.size.height * kMZOcrScale);
    config.captureResolution = SCCaptureResolutionBest;
    config.showsCursor = NO;

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                includingApplications:@[ application ]
                                                     exceptingWindows:@[]];
    [SCScreenshotManager captureImageWithFilter:filter
                                  configuration:config
                              completionHandler:^(CGImageRef image, NSError *shotError) {
      if (image == NULL) {
        mz_jev_log(@"ocr: capture failed: %@", shotError.localizedDescription ?: @"no image");
        mz_ocr_store(generation, nil);
        return;
      }
      mz_ocr_keep_capture(image);
      CGImageRef retained = CGImageRetain(image);
      dispatch_async(mz_ocr_queue(), ^{
        mz_ocr_store(generation, mz_ocr_recognise(retained, landing_in_box));
        CGImageRelease(retained);
      });
    }];
  }];
}

#pragma mark - Self-check

// `maccy-zig ocr-check`. Reports the two numbers that decide whether this
// feature is usable at all: the one-off model load, and the per-capture cost
// that has to fit inside the panel's budget.
int mz_ocr_self_check(void) {
  @autoreleasepool {
    // ScreenCaptureKit needs a window-server connection, which a bare CLI
    // process does not have until AppKit is initialised.
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    printf("screen recording permitted: %s\n", mz_ocr_permitted() ? "yes" : "NO");
    if (!mz_ocr_permitted()) {
      printf("  grant it in System Settings -> Privacy & Security -> Screen Recording\n");
      return 1;
    }

    mz_jev_debug_this_process();
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    printf("frontmost app: %s (pid %d)\n",
           front.localizedName.UTF8String ?: "?", front.processIdentifier);

    // First pass includes whatever of the model load is still outstanding.
    for (int pass = 1; pass <= 3; pass++) {
      NSDate *t0 = NSDate.date;
      // Exactly as the panel does it: on whatever has focus now.
      mz_jev_capture_focus(front.processIdentifier);
      mz_ocr_begin(front.processIdentifier);
      NSString *text = mz_ocr_await(30.0);
      double ms = -t0.timeIntervalSinceNow * 1000.0;
      printf("  pass %d: %6.0fms  %lu characters%s\n", pass, ms,
             (unsigned long)text.length, pass == 1 ? "   (includes model load)" : "");
      if (pass == 3 && text.length > 0) {
        NSString *head = text.length > 360 ? [text substringToIndex:360] : text;
        printf("  sample: %s…\n", [head stringByReplacingOccurrencesOfString:@"\n" withString:@" / "].UTF8String);
      }
    }
    // Where the read was aimed and why, for the last pass.
    NSArray<NSString *> *trace = mz_jev_log_lines();
    for (NSString *line in [trace subarrayWithRange:NSMakeRange(trace.count - MIN(trace.count, 5), MIN(trace.count, 5))]) {
      printf("  %s\n", line.UTF8String);
    }
    NSString *final_text = mz_ocr_latest();
    printf("ocr-check %s\n", final_text.length > 0 ? "ok" : "FAILED (no text recognised)");
    return final_text.length > 0 ? 0 : 1;
  }
}
