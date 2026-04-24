#import "macos_app.h"
#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, MZFilterMode) {
  MZFilterModeAll = 0,
  MZFilterModeText = 1,
  MZFilterModeLinks = 2,
  MZFilterModeImages = 3,
  MZFilterModeFavorites = 4,
};

static MZAppActionCallback gActionCallback = NULL;

static NSColor *mz_color(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
  return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static NSColor *mz_panel_fill(void) { return mz_color(18, 21, 24, 1.0); }
static NSColor *mz_panel_border(void) { return mz_color(62, 65, 70, 0.82); }
static NSColor *mz_card_fill(void) { return mz_color(23, 26, 29, 1.0); }
static NSColor *mz_card_border(void) { return mz_color(57, 61, 67, 0.9); }
static NSColor *mz_selected_fill(void) { return mz_color(27, 30, 34, 1.0); }
static NSColor *mz_selected_border(void) { return mz_color(74, 78, 86, 0.58); }
static NSColor *mz_action_fill(void) { return mz_color(25, 28, 31, 0.98); }
static NSColor *mz_primary_orange(void) { return mz_color(232, 119, 0, 1.0); }
static NSColor *mz_primary_orange_shadow(void) { return mz_color(255, 151, 30, 1.0); }
static NSColor *mz_text_primary(void) { return mz_color(245, 246, 249, 1.0); }
static NSColor *mz_text_secondary(void) { return mz_color(159, 163, 174, 1.0); }
static NSColor *mz_text_muted(void) { return mz_color(126, 130, 140, 1.0); }
static NSColor *mz_warning_yellow(void) { return mz_color(255, 151, 30, 1.0); }

static NSEventModifierFlags mz_app_modifier_flags(NSEvent *event) {
  return event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
}

static BOOL mz_app_is_enter_event(NSEvent *event) {
  return event.keyCode == 36 || event.keyCode == 76;
}

static NSTextField *mz_label(NSString *text, NSFont *font, NSColor *color) {
  NSTextField *label = [NSTextField labelWithString:text ?: @""];
  label.font = font;
  label.textColor = color;
  label.backgroundColor = NSColor.clearColor;
  label.bordered = NO;
  label.editable = NO;
  label.selectable = NO;
  label.lineBreakMode = NSLineBreakByTruncatingTail;
  return label;
}

static NSImage *mz_symbol_image(NSString *name, CGFloat point_size) {
  NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  if (image == nil) return nil;
  NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:point_size weight:NSFontWeightMedium];
  return [image imageWithSymbolConfiguration:config];
}

static NSImage *mz_resource_image(NSString *name, NSString *extension) {
  static NSMutableDictionary<NSString *, NSImage *> *cache = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    cache = [NSMutableDictionary dictionary];
  });

  NSString *key = [NSString stringWithFormat:@"%@.%@", name, extension];
  NSImage *cached = cache[key];
  if (cached != nil) return cached;

  NSString *bundle_path = [NSBundle.mainBundle pathForResource:name ofType:extension];
  NSImage *image = nil;
  if (bundle_path != nil) image = [[NSImage alloc] initWithContentsOfFile:bundle_path];

  if (image == nil) {
    NSString *source_path = [[NSFileManager.defaultManager currentDirectoryPath] stringByAppendingPathComponent:[@"assets" stringByAppendingPathComponent:key]];
    image = [[NSImage alloc] initWithContentsOfFile:source_path];
  }
  if (image != nil) cache[key] = image;
  return image;
}

static NSImage *mz_menubar_image(void) {
  NSString *bundlePath = [NSBundle.mainBundle pathForResource:@"MenubarTemplate" ofType:@"png"];
  if (bundlePath == nil) return nil;

  NSImage *image = [[NSImage alloc] initWithContentsOfFile:bundlePath];
  if (image == nil) return nil;
  image.template = YES;
  image.size = NSMakeSize(18.0, 18.0);
  return image;
}

static NSDateFormatter *mz_time_formatter(void) {
  static NSDateFormatter *formatter = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"h:mm a";
  });
  return formatter;
}

static NSString *mz_string_from_utf8_or_fallback(const char *value, NSString *fallback) {
  if (value == NULL) return fallback ?: @"";
  NSString *string = [NSString stringWithUTF8String:value];
  if (string != nil) return string;
  return fallback ?: @"";
}

static NSTableView *mz_enclosing_table_view(NSView *view) {
  NSView *current = view;
  while (current != nil) {
    if ([current isKindOfClass:[NSTableView class]]) {
      return (NSTableView *)current;
    }
    current = current.superview;
  }
  return nil;
}

@interface MZChamferedButton : NSButton
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL framed;
@property(nonatomic) BOOL accentCorner;
@end

@implementation MZChamferedButton
- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.bordered = NO;
    self.focusRingType = NSFocusRingTypeNone;
    self.wantsLayer = YES;
  }
  return self;
}

- (void)setActive:(BOOL)active {
  _active = active;
  self.needsDisplay = YES;
}

- (void)setFramed:(BOOL)framed {
  _framed = framed;
  self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSRect rect = NSInsetRect(self.bounds, 0.75, 0.75);
  CGFloat cut = 10.0;

  NSBezierPath *path = [NSBezierPath bezierPath];
  [path moveToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect))];
  [path lineToPoint:NSMakePoint(NSMaxX(rect) - cut, NSMinY(rect))];
  [path lineToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect) + cut)];
  [path lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect))];
  [path lineToPoint:NSMakePoint(NSMinX(rect) + cut, NSMaxY(rect))];
  [path lineToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect) - cut)];
  [path closePath];

  NSColor *fill = self.active ? mz_primary_orange() : (self.framed ? mz_card_fill() : NSColor.clearColor);
  [fill setFill];
  [path fill];

  if (self.framed || self.active) {
    [(self.active ? mz_primary_orange_shadow() : mz_card_border()) setStroke];
    path.lineWidth = 1.0;
    [path stroke];
  }

  if (self.accentCorner || self.active) {
    [mz_primary_orange_shadow() setStroke];
    NSBezierPath *corner = [NSBezierPath bezierPath];
    corner.lineWidth = 1.5;
    [corner moveToPoint:NSMakePoint(NSMinX(rect) + 2, NSMaxY(rect) - 7)];
    [corner lineToPoint:NSMakePoint(NSMinX(rect) + 8, NSMaxY(rect) - 1)];
    [corner stroke];

    NSBezierPath *bottom = [NSBezierPath bezierPath];
    bottom.lineWidth = 1.5;
    [bottom moveToPoint:NSMakePoint(NSMaxX(rect) - 12, NSMinY(rect) + 1)];
    [bottom lineToPoint:NSMakePoint(NSMaxX(rect) - 1, NSMinY(rect) + 12)];
    [bottom stroke];
  }

  NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
  style.alignment = NSTextAlignmentCenter;
  NSColor *title_color = self.active ? NSColor.whiteColor : mz_text_primary();
  NSDictionary *attributes = @{
    NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:14 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: title_color,
    NSParagraphStyleAttributeName: style,
  };
  NSSize title_size = [self.title sizeWithAttributes:attributes];
  NSRect title_rect = NSMakeRect(NSMinX(self.bounds) + 4.0,
                                NSMidY(self.bounds) - title_size.height * 0.5,
                                NSWidth(self.bounds) - 8.0,
                                title_size.height);
  [self.title drawInRect:title_rect withAttributes:attributes];
}
@end

@interface MZRow : NSObject
@property(nonatomic) int64_t rowID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, copy) NSString *app;
@property(nonatomic) int64_t copiedAt;
@property(nonatomic) int64_t pinOrder;
@property(nonatomic) NSInteger contentKind;
@property(nonatomic) BOOL pinned;
@property(nonatomic) BOOL hasImage;
@property(nonatomic) NSInteger copyCount;
@end
@implementation MZRow
@end

@interface MZRowActionButton : NSButton
@property(nonatomic) int64_t rowID;
@end
@implementation MZRowActionButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}
@end

@interface MZActionStripItemView : NSView
@property(nonatomic, strong) NSImageView *iconView;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSView *badgeView;
@property(nonatomic, strong) NSTextField *badgeLabel;
@property(nonatomic, strong) MZRowActionButton *button;
@property(nonatomic) BOOL showsSeparator;
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol shortcut:(NSString *)shortcut;
- (void)configureWithTarget:(id)target action:(SEL)action rowID:(int64_t)rowID enabled:(BOOL)enabled;
@end

@implementation MZActionStripItemView
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol shortcut:(NSString *)shortcut {
  if ((self = [super initWithFrame:NSZeroRect])) {
    self.wantsLayer = YES;

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.image = mz_symbol_image(symbol, 15.0);
    _iconView.contentTintColor = mz_text_primary();
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_iconView];

    _titleLabel = mz_label(title, [NSFont systemFontOfSize:14 weight:NSFontWeightMedium], mz_text_primary());
    [self addSubview:_titleLabel];

    _badgeView = [[NSView alloc] initWithFrame:NSZeroRect];
    _badgeView.wantsLayer = YES;
    _badgeView.layer.cornerRadius = 7.0;
    _badgeView.layer.backgroundColor = mz_color(72, 75, 86, 1.0).CGColor;
    [self addSubview:_badgeView];

    _badgeLabel = mz_label(shortcut ?: @"", [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold], mz_text_primary());
    [_badgeView addSubview:_badgeLabel];

    _button = [[MZRowActionButton alloc] initWithFrame:NSZeroRect];
    _button.title = @"";
    _button.bordered = NO;
    _button.transparent = YES;
    _button.focusRingType = NSFocusRingTypeNone;
    [self addSubview:_button];
  }
  return self;
}

- (void)configureWithTarget:(id)target action:(SEL)action rowID:(int64_t)rowID enabled:(BOOL)enabled {
  self.button.target = target;
  self.button.action = action;
  self.button.rowID = rowID;
  self.button.enabled = enabled;

  NSColor *text_color = enabled ? mz_text_primary() : mz_text_muted();
  NSColor *icon_color = enabled ? mz_text_primary() : mz_text_muted();
  self.titleLabel.textColor = text_color;
  self.iconView.contentTintColor = icon_color;
  self.badgeView.alphaValue = enabled ? 1.0 : 0.45;
}

- (void)layout {
  [super layout];

  CGFloat width = self.bounds.size.width;
  CGFloat height = self.bounds.size.height;

  self.iconView.frame = NSMakeRect(16, (height - 18) * 0.5, 18, 18);
  self.titleLabel.frame = NSMakeRect(42, (height - 20) * 0.5, width - 96, 20);
  self.badgeView.hidden = self.badgeLabel.stringValue.length == 0;
  if (!self.badgeView.hidden) {
    self.badgeView.frame = NSMakeRect(width - 58, (height - 28) * 0.5, 40, 28);
    self.badgeLabel.frame = NSMakeRect(0, 5, 40, 18);
    self.badgeLabel.alignment = NSTextAlignmentCenter;
  }
  self.button.frame = self.bounds;

  self.layer.sublayers = nil;
  if (self.showsSeparator) {
    CALayer *separator = [CALayer layer];
    separator.backgroundColor = mz_color(79, 82, 89, 0.8).CGColor;
    separator.frame = NSMakeRect(width - 1, 12, 1, MAX(0, height - 24));
    [self.layer addSublayer:separator];
  }
}
@end

@interface MZClipboardCellView : NSTableCellView
@property(nonatomic, strong) NSView *rowContainer;
@property(nonatomic, strong) MZRowActionButton *rowButton;
@property(nonatomic, strong) NSView *iconBackdrop;
@property(nonatomic, strong) NSImageView *iconView;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *subtitleLabel;
@property(nonatomic, strong) NSTextField *timeLabel;
@property(nonatomic, strong) MZRowActionButton *favoriteButton;
@property(nonatomic, strong) NSView *actionBar;
@property(nonatomic, strong) MZActionStripItemView *pasteActionView;
@property(nonatomic, strong) MZActionStripItemView *duplicateActionView;
@property(nonatomic, strong) MZActionStripItemView *revealActionView;
@property(nonatomic, strong) MZActionStripItemView *moreActionView;
@property(nonatomic, strong) NSView *dividerView;
@property(nonatomic, strong) NSTrackingArea *previewTrackingArea;
@property(nonatomic, strong) NSPopover *previewPopover;
@property(nonatomic) BOOL previewEnabled;
@property(nonatomic, weak) id interactionTarget;
- (void)configureWithRow:(MZRow *)row
                selected:(BOOL)selected
                  target:(id)target
                    icon:(NSImage *)icon
            revealEnabled:(BOOL)revealEnabled;
@end

@implementation MZClipboardCellView
static BOOL mz_point_hits_view(NSView *container, NSView *target, NSPoint point) {
  if (target == nil || target.hidden || target.alphaValue <= 0.01) return NO;
  NSRect rect = [container convertRect:target.bounds fromView:target];
  return NSPointInRect(point, rect);
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)dismissImagePreview {
  if (self.previewPopover != nil && self.previewPopover.shown) {
    [self.previewPopover close];
  }
}

- (void)showImagePreviewIfNeeded {
  if (!self.previewEnabled || self.previewPopover.shown) return;
  MZRow *row = [self.objectValue isKindOfClass:[MZRow class]] ? self.objectValue : nil;
  if (row == nil) return;

  size_t len = 0;
  const unsigned char *bytes = mz_app_copy_image_preview(row.rowID, &len);
  if (bytes == NULL || len == 0) return;

  NSData *data = [NSData dataWithBytes:bytes length:len];
  mz_app_free_buffer(bytes, len);
  NSImage *image = [[NSImage alloc] initWithData:data];
  if (image == nil) return;

  const CGFloat max_width = 360.0;
  const CGFloat max_height = 260.0;
  NSSize image_size = image.size;
  if (image_size.width <= 0.0 || image_size.height <= 0.0) return;
  CGFloat scale = MIN(max_width / image_size.width, max_height / image_size.height);
  if (scale > 1.0) scale = 1.0;
  NSSize display_size = NSMakeSize(MAX(1.0, floor(image_size.width * scale)), MAX(1.0, floor(image_size.height * scale)));

  NSViewController *controller = [NSViewController new];
  NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, display_size.width + 16.0, display_size.height + 16.0)];
  content.wantsLayer = YES;
  content.layer.cornerRadius = 12.0;
  content.layer.masksToBounds = YES;
  content.layer.backgroundColor = mz_panel_fill().CGColor;
  content.layer.borderWidth = 1.0;
  content.layer.borderColor = mz_panel_border().CGColor;

  NSImageView *preview = [[NSImageView alloc] initWithFrame:NSMakeRect(8, 8, display_size.width, display_size.height)];
  preview.image = image;
  preview.imageScaling = NSImageScaleProportionallyUpOrDown;
  [content addSubview:preview];
  controller.view = content;

  if (self.previewPopover == nil) {
    self.previewPopover = [NSPopover new];
    self.previewPopover.behavior = NSPopoverBehaviorTransient;
    self.previewPopover.animates = YES;
  }
  self.previewPopover.contentViewController = controller;
  [self.previewPopover showRelativeToRect:self.iconBackdrop.bounds ofView:self.iconBackdrop preferredEdge:NSRectEdgeMaxX];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;

    _rowContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    _rowContainer.wantsLayer = YES;
    _rowContainer.layer.cornerRadius = 10.0;
    _rowContainer.layer.masksToBounds = YES;
    [self addSubview:_rowContainer];

    _rowButton = [[MZRowActionButton alloc] initWithFrame:NSZeroRect];
    _rowButton.title = @"";
    _rowButton.bordered = NO;
    _rowButton.transparent = YES;
    _rowButton.focusRingType = NSFocusRingTypeNone;
    [self addSubview:_rowButton];

    _iconBackdrop = [[NSView alloc] initWithFrame:NSZeroRect];
    _iconBackdrop.wantsLayer = YES;
    _iconBackdrop.layer.cornerRadius = 8.0;
    _iconBackdrop.layer.borderWidth = 1.0;
    _iconBackdrop.layer.borderColor = mz_color(61, 65, 72, 0.85).CGColor;
    _iconBackdrop.layer.backgroundColor = mz_color(24, 27, 30, 0.92).CGColor;
    [_rowContainer addSubview:_iconBackdrop];

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [_iconBackdrop addSubview:_iconView];

    _titleLabel = mz_label(@"", [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold], mz_text_primary());
    [_rowContainer addSubview:_titleLabel];

    _subtitleLabel = mz_label(@"", [NSFont systemFontOfSize:13 weight:NSFontWeightMedium], mz_text_secondary());
    [_rowContainer addSubview:_subtitleLabel];

    _timeLabel = mz_label(@"", [NSFont systemFontOfSize:13 weight:NSFontWeightMedium], mz_text_secondary());
    _timeLabel.alignment = NSTextAlignmentRight;
    [_rowContainer addSubview:_timeLabel];

    _favoriteButton = [[MZRowActionButton alloc] initWithFrame:NSZeroRect];
    _favoriteButton.title = @"";
    _favoriteButton.bordered = NO;
    _favoriteButton.imageScaling = NSImageScaleProportionallyUpOrDown;
    _favoriteButton.focusRingType = NSFocusRingTypeNone;
    [_rowContainer addSubview:_favoriteButton];

    _dividerView = [[NSView alloc] initWithFrame:NSZeroRect];
    _dividerView.wantsLayer = YES;
    _dividerView.layer.backgroundColor = mz_color(43, 47, 52, 0.92).CGColor;
    [self addSubview:_dividerView];
  }
  return self;
}

- (void)configureWithRow:(MZRow *)row
                selected:(BOOL)selected
                  target:(id)target
                    icon:(NSImage *)icon
            revealEnabled:(BOOL)revealEnabled {
  self.objectValue = row;
  self.interactionTarget = target;
  self.titleLabel.stringValue = row.title ?: @"";
  self.subtitleLabel.stringValue = row.subtitle ?: @"";
  self.iconView.image = icon;
  self.timeLabel.stringValue = [mz_time_formatter() stringFromDate:[NSDate dateWithTimeIntervalSince1970:row.copiedAt]];

  self.favoriteButton.target = target;
  self.favoriteButton.action = @selector(togglePinFromButton:);
  self.favoriteButton.rowID = row.rowID;
  self.favoriteButton.image = mz_symbol_image(row.pinned ? @"star.fill" : @"star", 18.0);
  self.favoriteButton.contentTintColor = row.pinned ? mz_warning_yellow() : mz_text_secondary();

  self.rowButton.target = target;
  self.rowButton.action = @selector(pasteRow:);
  self.rowButton.rowID = row.rowID;

  self.rowContainer.layer.backgroundColor = (selected ? mz_selected_fill() : NSColor.clearColor).CGColor;
  self.rowContainer.layer.borderColor = (selected ? mz_selected_border() : NSColor.clearColor).CGColor;
  self.rowContainer.layer.borderWidth = selected ? 1.0 : 0.0;
  self.dividerView.hidden = NO;
  self.subtitleLabel.textColor = mz_text_secondary();
  self.timeLabel.textColor = mz_text_secondary();
  self.previewEnabled = row.hasImage || row.contentKind == MZ_APP_CONTENT_IMAGE;
  if (!self.previewEnabled) [self dismissImagePreview];

  [self setNeedsLayout:YES];
  [self updateTrackingAreas];
}

- (NSView *)hitTest:(NSPoint)point {
  if (mz_point_hits_view(self, self.favoriteButton, point)) return self.favoriteButton;
  if (self.actionBar != nil && !self.actionBar.hidden) {
    if (mz_point_hits_view(self, self.pasteActionView.button, point)) return self.pasteActionView.button;
    if (mz_point_hits_view(self, self.duplicateActionView.button, point)) return self.duplicateActionView.button;
    if (mz_point_hits_view(self, self.revealActionView.button, point)) return self.revealActionView.button;
    if (mz_point_hits_view(self, self.moreActionView.button, point)) return self.moreActionView.button;
  }
  return NSPointInRect(point, self.bounds) ? self.rowButton : nil;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.previewTrackingArea != nil) {
    [self removeTrackingArea:self.previewTrackingArea];
    self.previewTrackingArea = nil;
  }
  if (!self.previewEnabled) return;
  self.previewTrackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                          options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                            owner:self
                                                         userInfo:nil];
  [self addTrackingArea:self.previewTrackingArea];
}

- (void)mouseDown:(NSEvent *)event {
  if (self.interactionTarget != nil &&
      [self.interactionTarget respondsToSelector:@selector(selectRowForItemView:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.interactionTarget performSelector:@selector(selectRowForItemView:) withObject:self];
#pragma clang diagnostic pop
  }

  if (event.clickCount >= 1 && self.interactionTarget != nil &&
      [self.interactionTarget respondsToSelector:@selector(activateSelection:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.interactionTarget performSelector:@selector(activateSelection:) withObject:self];
#pragma clang diagnostic pop
  }
}

- (void)mouseEntered:(NSEvent *)event {
  (void)event;
  [self showImagePreviewIfNeeded];
}

- (void)mouseExited:(NSEvent *)event {
  (void)event;
  [self dismissImagePreview];
}

- (void)layout {
  [super layout];

  CGFloat inset_x = 8.0;
  CGFloat inset_y = 0.0;
  CGFloat container_width = self.bounds.size.width - inset_x * 2.0;
  CGFloat container_height = self.bounds.size.height - inset_y * 2.0;

  self.rowContainer.frame = NSMakeRect(inset_x, inset_y, container_width, container_height);
  self.rowButton.frame = self.bounds;
  BOOL expanded = NO;
  CGFloat header_height = container_height;
  CGFloat action_height = 0.0;

  self.iconBackdrop.frame = NSMakeRect(8, header_height - 59, 48, 48);
  self.iconView.frame = NSMakeRect(7, 7, 34, 34);

  CGFloat right_margin = 150.0;
  self.titleLabel.frame = NSMakeRect(76, header_height - 35, container_width - 76 - right_margin, 23);
  self.subtitleLabel.frame = NSMakeRect(76, header_height - 58, container_width - 76 - right_margin, 18);
  self.timeLabel.frame = NSMakeRect(container_width - 118, header_height - 33, 72, 20);
  self.favoriteButton.frame = NSMakeRect(container_width - 38, header_height - 42, 28, 28);

  if (expanded) {
    self.actionBar.frame = NSMakeRect(0, 0, container_width, action_height);
    CGFloat slot_width = container_width / 4.0;
    self.pasteActionView.frame = NSMakeRect(0, 0, slot_width, action_height);
    self.duplicateActionView.frame = NSMakeRect(slot_width, 0, slot_width, action_height);
    self.revealActionView.frame = NSMakeRect(slot_width * 2.0, 0, slot_width, action_height);
    self.moreActionView.frame = NSMakeRect(slot_width * 3.0, 0, container_width - slot_width * 3.0, action_height);
  }

  self.dividerView.frame = NSMakeRect(inset_x, 0, MAX(0.0, self.bounds.size.width - inset_x * 2.0), 1);
}
@end

static BOOL mz_activate_row_at_event(NSView *container, id target, NSEvent *event) {
  if (container == nil || target == nil) return NO;
  NSPoint point = [container convertPoint:event.locationInWindow fromView:nil];
  for (NSView *subview in container.subviews.reverseObjectEnumerator) {
    if (![subview isKindOfClass:[MZClipboardCellView class]] || !NSPointInRect(point, subview.frame)) continue;

    MZClipboardCellView *rowView = (MZClipboardCellView *)subview;
    NSPoint rowPoint = [rowView convertPoint:event.locationInWindow fromView:nil];
    if (mz_point_hits_view(rowView, rowView.favoriteButton, rowPoint)) return NO;

    if (rowView.actionBar != nil && !rowView.actionBar.hidden) {
      if (mz_point_hits_view(rowView, rowView.pasteActionView.button, rowPoint)) return NO;
      if (mz_point_hits_view(rowView, rowView.duplicateActionView.button, rowPoint)) return NO;
      if (mz_point_hits_view(rowView, rowView.revealActionView.button, rowPoint)) return NO;
      if (mz_point_hits_view(rowView, rowView.moreActionView.button, rowPoint)) return NO;
    }

    if ([target respondsToSelector:@selector(selectRowForItemView:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [target performSelector:@selector(selectRowForItemView:) withObject:rowView];
#pragma clang diagnostic pop
    }

    if ([target respondsToSelector:@selector(activateSelection:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [target performSelector:@selector(activateSelection:) withObject:rowView];
#pragma clang diagnostic pop
    }
    return YES;
  }
  return NO;
}

@interface MZFlippedView : NSView
@property(nonatomic, weak) id interactionTarget;
@end

@implementation MZFlippedView
- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)mouseDown:(NSEvent *)event {
  if (mz_activate_row_at_event(self, self.interactionTarget, event)) return;
  [super mouseDown:event];
}

- (void)keyDown:(NSEvent *)event {
  if (self.interactionTarget != nil &&
      [self.interactionTarget respondsToSelector:@selector(handleKeyEvent:)]) {
    SEL selector = @selector(handleKeyEvent:);
    BOOL (*send)(id, SEL, NSEvent *) = (BOOL (*)(id, SEL, NSEvent *))[self.interactionTarget methodForSelector:selector];
    if (send != NULL && send(self.interactionTarget, selector, event)) return;
  }
  [super keyDown:event];
}
@end

@interface MZListScrollView : NSScrollView
@property(nonatomic, weak) id interactionTarget;
@end

@implementation MZListScrollView
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)mouseDown:(NSEvent *)event {
  if (mz_activate_row_at_event(self.documentView, self.interactionTarget, event)) return;
  [super mouseDown:event];
}
@end

@interface MZAppController : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property(nonatomic) MZAppCallbacks callbacks;
@property(nonatomic) MZAppActionCallback actionCallback;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) NSView *rootView;
@property(nonatomic, strong) NSTextField *searchField;
@property(nonatomic, strong) MZListScrollView *listScrollView;
@property(nonatomic, strong) MZFlippedView *listContentView;
@property(nonatomic, strong) NSMenu *actionsMenu;
@property(nonatomic, strong) NSMutableArray<MZRow *> *allRows;
@property(nonatomic, strong) NSMutableArray<MZRow *> *rows;
@property(nonatomic, strong) NSMutableArray<MZClipboardCellView *> *itemViews;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *iconCache;
@property(nonatomic, strong) NSMutableArray<NSButton *> *filterButtons;
@property(nonatomic, strong) NSTextField *countLabel;
@property(nonatomic, strong) NSButton *pinButton;
@property(nonatomic, strong) NSButton *settingsButton;
@property(nonatomic, strong) id keyEventMonitor;
@property(nonatomic) MZFilterMode filterMode;
@property(nonatomic) NSInteger selectedRowIndex;
@property(nonatomic) BOOL windowPinned;
@end

static MZAppController *gController = nil;

static void mz_app_dispatch_action(MZAppController *controller, MZAppAction action, int64_t rowID) {
  if (controller.actionCallback != NULL) {
    controller.actionCallback(action, rowID);
    return;
  }

  switch (action) {
    case MZ_APP_ACTION_COPY:
      if (controller.callbacks.on_select) controller.callbacks.on_select(rowID, 0);
      return;
    case MZ_APP_ACTION_PASTE:
      if (controller.callbacks.on_select) controller.callbacks.on_select(rowID, 1);
      return;
    case MZ_APP_ACTION_CLEAR_UNPINNED:
      if (controller.callbacks.on_clear) controller.callbacks.on_clear(0);
      return;
    case MZ_APP_ACTION_CLEAR_ALL:
      if (controller.callbacks.on_clear) controller.callbacks.on_clear(1);
      return;
    case MZ_APP_ACTION_QUIT:
      if (controller.callbacks.on_quit) controller.callbacks.on_quit();
      [NSApp terminate:nil];
      return;
    default:
      return;
  }
}

@implementation MZAppController
- (instancetype)initWithCallbacks:(MZAppCallbacks)callbacks {
  if ((self = [super init])) {
    _callbacks = callbacks;
    _actionCallback = gActionCallback;
    _allRows = [NSMutableArray array];
    _rows = [NSMutableArray array];
    _itemViews = [NSMutableArray array];
    _iconCache = [NSMutableDictionary dictionary];
    _filterButtons = [NSMutableArray array];
    _filterMode = MZFilterModeAll;
    _selectedRowIndex = -1;
    _windowPinned = NO;
  }
  return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

  self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  self.statusItem.button.title = @"";
  self.statusItem.button.image = mz_menubar_image();
  self.statusItem.button.imagePosition = NSImageOnly;
  self.statusItem.button.toolTip = @"Maccy";
  self.statusItem.button.target = self;
  self.statusItem.button.action = @selector(toggle:);

  [self buildPanel];

  __weak typeof(self) weak_self = self;
  self.keyEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                               handler:^NSEvent *_Nullable(NSEvent *event) {
    MZAppController *strong_self = weak_self;
    if (strong_self == nil) return event;
    return [strong_self handleKeyEvent:event] ? nil : event;
  }];

  [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(pollTimer:) userInfo:nil repeats:YES];
  [self show];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
  (void)sender;
  (void)flag;
  [self show];
  return YES;
}

- (void)dealloc {
  if (self.keyEventMonitor != nil) [NSEvent removeMonitor:self.keyEventMonitor];
}

- (void)pollTimer:(NSTimer *)timer {
  (void)timer;
  if (self.callbacks.on_poll) self.callbacks.on_poll();
}

- (void)buildPanel {
  const CGFloat panelWidth = 561.0;
  const CGFloat panelHeight = 701.0;
  const CGFloat outerMargin = 25.0;
  const CGFloat chromeTop = 42.0;
  const CGFloat searchHeight = 47.0;
  const CGFloat tabsHeight = 42.0;
  const CGFloat sectionGap = 16.0;
  const CGFloat listBottom = 60.0;
  NSRect frame = NSMakeRect(0, 0, panelWidth, panelHeight);
  self.panel = [[NSPanel alloc] initWithContentRect:frame
                                          styleMask:(NSWindowStyleMaskTitled |
                                                     NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskMiniaturizable |
                                                     NSWindowStyleMaskResizable |
                                                     NSWindowStyleMaskFullSizeContentView |
                                                     NSWindowStyleMaskNonactivatingPanel)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
  self.panel.titleVisibility = NSWindowTitleHidden;
  self.panel.titlebarAppearsTransparent = YES;
  self.panel.movableByWindowBackground = NO;
  self.panel.hidesOnDeactivate = YES;
  self.panel.floatingPanel = NO;
  self.panel.level = NSNormalWindowLevel;
  self.panel.backgroundColor = NSColor.clearColor;
  self.panel.opaque = NO;
  self.panel.hasShadow = YES;
  self.panel.minSize = frame.size;
  self.panel.maxSize = frame.size;

  self.rootView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
  self.rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.rootView.wantsLayer = YES;
  self.rootView.layer.cornerRadius = 18.0;
  self.rootView.layer.masksToBounds = YES;
  self.rootView.layer.backgroundColor = mz_panel_fill().CGColor;
  self.rootView.layer.borderWidth = 1.0;
  self.rootView.layer.borderColor = mz_panel_border().CGColor;
  self.panel.contentView = self.rootView;

  NSButton *close = [self.panel standardWindowButton:NSWindowCloseButton];
  NSButton *mini = [self.panel standardWindowButton:NSWindowMiniaturizeButton];
  NSButton *zoom = [self.panel standardWindowButton:NSWindowZoomButton];
  close.hidden = YES;
  mini.hidden = YES;
  zoom.hidden = YES;

  NSImageView *titleMark = [[NSImageView alloc] initWithFrame:NSMakeRect((frame.size.width - 154.0) * 0.5, frame.size.height - 60.0, 26.0, 48.0)];
  titleMark.image = mz_resource_image(@"logo-mark", @"png");
  titleMark.imageScaling = NSImageScaleProportionallyUpOrDown;
  [self.rootView addSubview:titleMark];

  NSTextField *title = mz_label(@"Maccy", [NSFont systemFontOfSize:25 weight:NSFontWeightBold], mz_text_primary());
  title.frame = NSMakeRect(NSMaxX(titleMark.frame) + 12.0, frame.size.height - 50.0, 116.0, 32.0);
  title.alignment = NSTextAlignmentCenter;
  [self.rootView addSubview:title];

  self.pinButton = [self chromeButtonWithSymbol:@"pin" action:@selector(toggleWindowPin:)];
  self.pinButton.frame = NSMakeRect(frame.size.width - 98, frame.size.height - chromeTop, 28, 28);
  self.pinButton.toolTip = @"Keep window on top";
  [self.rootView addSubview:self.pinButton];

  self.settingsButton = [self chromeButtonWithSymbol:@"gearshape" action:@selector(showHeaderMenu:)];
  self.settingsButton.frame = NSMakeRect(frame.size.width - 54, frame.size.height - chromeTop, 30, 30);
  [self.rootView addSubview:self.settingsButton];

  CGFloat searchY = frame.size.height - 123.0;
  NSView *searchBox = [[NSView alloc] initWithFrame:NSMakeRect(outerMargin, searchY, frame.size.width - outerMargin * 2.0, searchHeight)];
  searchBox.wantsLayer = YES;
  searchBox.layer.cornerRadius = 8.0;
  searchBox.layer.backgroundColor = mz_card_fill().CGColor;
  searchBox.layer.borderWidth = 1.0;
  searchBox.layer.borderColor = mz_card_border().CGColor;
  [self.rootView addSubview:searchBox];

  NSImageView *searchIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(17, 12, 23, 23)];
  searchIcon.image = mz_symbol_image(@"magnifyingglass", 20.0);
  searchIcon.contentTintColor = mz_text_primary();
  [searchBox addSubview:searchIcon];

  self.searchField = [[NSTextField alloc] initWithFrame:NSMakeRect(61, 8, searchBox.bounds.size.width - 148, 32)];
  self.searchField.delegate = self;
  self.searchField.placeholderString = @"Search clipboard history...";
  self.searchField.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
  self.searchField.textColor = mz_text_primary();
  self.searchField.drawsBackground = NO;
  self.searchField.backgroundColor = NSColor.clearColor;
  self.searchField.bordered = NO;
  self.searchField.focusRingType = NSFocusRingTypeNone;
  self.searchField.autoresizingMask = NSViewWidthSizable;
  [searchBox addSubview:self.searchField];

  NSView *searchHint = [[NSView alloc] initWithFrame:NSMakeRect(searchBox.bounds.size.width - 58, 9, 43, 29)];
  searchHint.wantsLayer = YES;
  searchHint.layer.cornerRadius = 5.0;
  searchHint.layer.borderWidth = 1.0;
  searchHint.layer.borderColor = mz_card_border().CGColor;
  searchHint.layer.backgroundColor = mz_color(28, 31, 35, 1.0).CGColor;
  searchHint.autoresizingMask = NSViewMinXMargin;
  [searchBox addSubview:searchHint];

  NSTextField *searchHintLabel = mz_label(@"⌘F", [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightSemibold], mz_text_secondary());
  searchHintLabel.frame = NSMakeRect(0, 5, 43, 19);
  searchHintLabel.alignment = NSTextAlignmentCenter;
  [searchHint addSubview:searchHintLabel];

  CGFloat filtersY = searchY - sectionGap - tabsHeight;
  CGFloat filtersWidth = frame.size.width - outerMargin * 2.0;
  CGFloat favoritesWidth = 129.0;
  CGFloat tabsGap = 15.0;
  CGFloat tabsWidth = filtersWidth - favoritesWidth - tabsGap;
  NSView *tabsCard = [[NSView alloc] initWithFrame:NSMakeRect(outerMargin, filtersY, tabsWidth, tabsHeight)];
  tabsCard.wantsLayer = YES;
  tabsCard.layer.cornerRadius = 6.0;
  tabsCard.layer.backgroundColor = mz_card_fill().CGColor;
  tabsCard.layer.borderWidth = 1.0;
  tabsCard.layer.borderColor = mz_card_border().CGColor;
  [self.rootView addSubview:tabsCard];

  NSArray<NSString *> *titles = @[ @"All", @"Text", @"Links", @"Images" ];
  CGFloat slot_width = tabsCard.bounds.size.width / titles.count;
  for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
    NSButton *button = [self filterButtonWithTitle:titles[(NSUInteger)i] tag:i];
    button.frame = NSMakeRect(slot_width * i, 0, i == (NSInteger)titles.count - 1 ? tabsCard.bounds.size.width - slot_width * i : slot_width, tabsCard.bounds.size.height);
    [tabsCard addSubview:button];
    [self.filterButtons addObject:button];

    if (i > 0) {
      NSView *divider = [[NSView alloc] initWithFrame:NSMakeRect(slot_width * i, 8, 1, 26)];
      divider.wantsLayer = YES;
      divider.layer.backgroundColor = mz_color(65, 69, 76, 0.78).CGColor;
      [tabsCard addSubview:divider];
    }
  }

  NSView *favoritesCard = [[NSView alloc] initWithFrame:NSMakeRect(CGRectGetMaxX(tabsCard.frame) + tabsGap, filtersY, favoritesWidth, tabsHeight)];
  favoritesCard.wantsLayer = YES;
  favoritesCard.layer.cornerRadius = 6.0;
  favoritesCard.layer.backgroundColor = mz_card_fill().CGColor;
  favoritesCard.layer.borderWidth = 1.0;
  favoritesCard.layer.borderColor = mz_card_border().CGColor;
  [self.rootView addSubview:favoritesCard];

  NSButton *favoritesButton = [self filterButtonWithTitle:@"☆  Favorites" tag:MZFilterModeFavorites];
  favoritesButton.frame = favoritesCard.bounds;
  [favoritesCard addSubview:favoritesButton];
  [self.filterButtons addObject:favoritesButton];
  [self updateFilterButtons];

  CGFloat listTop = filtersY - sectionGap;
  CGFloat listHeight = listTop - listBottom;
  NSView *listCard = [[NSView alloc] initWithFrame:NSMakeRect(outerMargin, listBottom, frame.size.width - outerMargin * 2.0, listHeight)];
  listCard.wantsLayer = YES;
  listCard.layer.cornerRadius = 8.0;
  listCard.layer.borderWidth = 1.0;
  listCard.layer.borderColor = mz_card_border().CGColor;
  listCard.layer.backgroundColor = mz_color(21, 24, 27, 1.0).CGColor;
  [self.rootView addSubview:listCard];

  self.listScrollView = [[MZListScrollView alloc] initWithFrame:listCard.bounds];
  self.listScrollView.drawsBackground = NO;
  self.listScrollView.borderType = NSNoBorder;
  self.listScrollView.hasVerticalScroller = YES;
  self.listScrollView.autohidesScrollers = YES;
  self.listScrollView.automaticallyAdjustsContentInsets = NO;
  self.listScrollView.scrollerInsets = NSEdgeInsetsMake(4, 0, 4, 4);
  self.listScrollView.interactionTarget = self;
  [listCard addSubview:self.listScrollView];

  self.listContentView = [[MZFlippedView alloc] initWithFrame:self.listScrollView.bounds];
  self.listContentView.interactionTarget = self;
  self.listContentView.autoresizingMask = NSViewWidthSizable;
  self.listScrollView.documentView = self.listContentView;

  NSImageView *countIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(25, 27, 18, 18)];
  countIcon.image = mz_symbol_image(@"checkmark.circle", 16.0);
  countIcon.contentTintColor = mz_primary_orange_shadow();
  [self.rootView addSubview:countIcon];

  self.countLabel = mz_label(@"0 items", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], mz_text_secondary());
  self.countLabel.frame = NSMakeRect(53, 22, 120, 28);
  [self.rootView addSubview:self.countLabel];

  NSButton *clearButton = [self footerTextButtonWithTitle:@"Clear History..." action:@selector(showHeaderMenu:)];
  clearButton.frame = NSMakeRect((frame.size.width - 140) * 0.5, 19, 140, 32);
  [self.rootView addSubview:clearButton];

  NSView *clearHint = [[NSView alloc] initWithFrame:NSMakeRect(clearButton.frame.origin.x + 155, 20, 48, 29)];
  clearHint.wantsLayer = YES;
  clearHint.layer.cornerRadius = 5.0;
  clearHint.layer.borderWidth = 1.0;
  clearHint.layer.borderColor = mz_card_border().CGColor;
  clearHint.layer.backgroundColor = mz_color(28, 31, 35, 1.0).CGColor;
  [self.rootView addSubview:clearHint];

  NSTextField *clearHintLabel = mz_label(@"⌘K", [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightSemibold], mz_text_secondary());
  clearHintLabel.frame = NSMakeRect(0, 5, 48, 18);
  clearHintLabel.alignment = NSTextAlignmentCenter;
  [clearHint addSubview:clearHintLabel];

  NSButton *plusButton = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 73, 17, 50, 34)];
  plusButton.title = @"";
  plusButton.bordered = NO;
  plusButton.wantsLayer = YES;
  plusButton.layer.cornerRadius = 6.0;
  plusButton.layer.backgroundColor = mz_card_fill().CGColor;
  plusButton.layer.borderWidth = 1.0;
  plusButton.layer.borderColor = mz_primary_orange().CGColor;
  plusButton.image = mz_symbol_image(@"plus", 23.0);
  plusButton.contentTintColor = NSColor.whiteColor;
  plusButton.focusRingType = NSFocusRingTypeNone;
  plusButton.target = self;
  plusButton.action = @selector(showHeaderMenu:);
  [self.rootView addSubview:plusButton];

  self.actionsMenu = [[NSMenu alloc] initWithTitle:@"Actions"];
  NSArray<NSDictionary *> *menu_specs = @[
    @{@"title": @"Toggle Favorite", @"selector": NSStringFromSelector(@selector(toggleSelectedFavorite:))},
    @{@"title": @"Paste as Plain Text", @"selector": NSStringFromSelector(@selector(pasteSelectedAsPlainText:))},
    @{@"title": @"Reveal", @"selector": NSStringFromSelector(@selector(revealSelected:))},
  ];
  for (NSDictionary *spec in menu_specs) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:spec[@"title"] action:NSSelectorFromString(spec[@"selector"]) keyEquivalent:@""];
    item.target = self;
    [self.actionsMenu addItem:item];
  }
  [self.actionsMenu addItem:[NSMenuItem separatorItem]];
  for (NSDictionary *spec in @[
         @{@"title": @"Clear Unpinned", @"selector": NSStringFromSelector(@selector(clearUnpinned:))},
         @{@"title": @"Clear All", @"selector": NSStringFromSelector(@selector(clearAll:))},
       ]) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:spec[@"title"] action:NSSelectorFromString(spec[@"selector"]) keyEquivalent:@""];
    item.target = self;
    [self.actionsMenu addItem:item];
  }
  [self.actionsMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *quit_item = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quitApplication:) keyEquivalent:@""];
  quit_item.target = self;
  [self.actionsMenu addItem:quit_item];

  [self updateWindowPinButton];
}

- (NSButton *)chromeButtonWithSymbol:(NSString *)symbol action:(SEL)action {
  NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
  button.title = @"";
  button.bordered = NO;
  button.image = mz_symbol_image(symbol, 20.0);
  button.contentTintColor = mz_text_primary();
  button.focusRingType = NSFocusRingTypeNone;
  button.target = self;
  button.action = action;
  return button;
}

- (NSButton *)filterButtonWithTitle:(NSString *)title tag:(NSInteger)tag {
  MZChamferedButton *button = [[MZChamferedButton alloc] initWithFrame:NSZeroRect];
  button.title = title;
  button.tag = tag;
  button.bordered = NO;
  button.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
  button.focusRingType = NSFocusRingTypeNone;
  button.framed = tag == MZFilterModeFavorites;
  button.accentCorner = tag == MZFilterModeAll;
  button.target = self;
  button.action = @selector(changeFilter:);
  return button;
}

- (NSButton *)footerTextButtonWithTitle:(NSString *)title action:(SEL)action {
  NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
  button.title = title;
  button.bordered = NO;
  button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  button.contentTintColor = mz_text_secondary();
  button.focusRingType = NSFocusRingTypeNone;
  button.target = self;
  button.action = action;
  return button;
}

- (void)toggle:(id)sender {
  (void)sender;
  if (self.panel.isVisible) [self hide]; else [self show];
}

- (void)applyWindowPinState {
  self.panel.hidesOnDeactivate = !self.windowPinned;
  self.panel.floatingPanel = self.windowPinned;
  self.panel.level = self.windowPinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
  [self updateWindowPinButton];
}

- (void)updateWindowPinButton {
  self.pinButton.image = mz_symbol_image(self.windowPinned ? @"pin.fill" : @"pin", 20.0);
  self.pinButton.contentTintColor = self.windowPinned ? mz_warning_yellow() : mz_text_secondary();
}

- (void)show {
  NSScreen *screen = NSScreen.mainScreen;
  NSRect sf = screen.visibleFrame;
  NSRect pf = self.panel.frame;
  pf.origin.x = NSMidX(sf) - pf.size.width * 0.5;
  pf.origin.y = NSMaxY(sf) - pf.size.height - 34;
  [self.panel setFrame:pf display:NO];
  [NSApp activateIgnoringOtherApps:YES];
  [self.panel orderFrontRegardless];
  [self.panel makeKeyAndOrderFront:nil];
  if (self.rows.count > 0 && self.selectedRowIndex < 0) {
    [self selectRowAtIndex:0 focusList:NO];
  }
  [self.searchField becomeFirstResponder];
  if (self.callbacks.on_toggle) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self.callbacks.on_toggle) self.callbacks.on_toggle();
    });
  }
}

- (void)hide {
  [self.panel orderOut:nil];
}

- (MZRow *)selectedItem {
  if (self.selectedRowIndex < 0 || self.selectedRowIndex >= (NSInteger)self.rows.count) return nil;
  return self.rows[(NSUInteger)self.selectedRowIndex];
}

- (NSInteger)indexOfRowID:(int64_t)rowID inRows:(NSArray<MZRow *> *)rows {
  for (NSUInteger i = 0; i < rows.count; i++) {
    if (rows[i].rowID == rowID) return (NSInteger)i;
  }
  return NSNotFound;
}

- (void)selectRowID:(int64_t)rowID {
  NSInteger index = [self indexOfRowID:rowID inRows:self.rows];
  if (index == NSNotFound) return;
  [self selectRowAtIndex:index focusList:YES];
}

- (BOOL)performRowAction:(MZAppAction)action rowID:(int64_t)rowID hidesPanel:(BOOL)hidesPanel {
  if (rowID == 0) return NO;
  if (action == MZ_APP_ACTION_TOGGLE_PIN) {
    [self optimisticallyTogglePinForRowID:rowID];
  }
  if (hidesPanel) [self hide];
  mz_app_dispatch_action(self, action, rowID);
  return YES;
}

- (BOOL)performSelectedAction:(MZAppAction)action hidesPanel:(BOOL)hidesPanel {
  MZRow *item = [self selectedItem];
  return item ? [self performRowAction:action rowID:item.rowID hidesPanel:hidesPanel] : NO;
}

- (CGFloat)rowHeightAtIndex:(NSInteger)index {
  (void)index;
  return 74.0;
}

- (void)relayoutItemViews {
  CGFloat width = self.listScrollView.contentSize.width;
  CGFloat y = 0.0;
  for (NSUInteger i = 0; i < self.itemViews.count; i++) {
    MZClipboardCellView *view = self.itemViews[i];
    CGFloat height = [self rowHeightAtIndex:(NSInteger)i];
    view.frame = NSMakeRect(0, y, width, height);
    y += height;
  }
  self.listContentView.frame = NSMakeRect(0, 0, width, MAX(y, self.listScrollView.contentSize.height));
}

- (void)reloadItemViews {
  for (MZClipboardCellView *view in self.itemViews) {
    [view removeFromSuperview];
  }
  [self.itemViews removeAllObjects];

  CGFloat width = self.listScrollView.contentSize.width;
  CGFloat y = 0.0;
  for (NSUInteger i = 0; i < self.rows.count; i++) {
    MZRow *item = self.rows[i];
    CGFloat height = [self rowHeightAtIndex:(NSInteger)i];
    MZClipboardCellView *view = [[MZClipboardCellView alloc] initWithFrame:NSMakeRect(0, y, width, height)];
    view.identifier = [NSString stringWithFormat:@"clipboard-item-%lu", (unsigned long)i];
    [view configureWithRow:item
                  selected:((NSInteger)i == self.selectedRowIndex)
                    target:self
                      icon:[self iconForRow:item]
              revealEnabled:[self rowSupportsReveal:item]];
    [self.listContentView addSubview:view];
    [self.itemViews addObject:view];
    y += height;
  }
  self.listContentView.frame = NSMakeRect(0, 0, width, MAX(y, self.listScrollView.contentSize.height));
}

- (void)refreshVisibleSelectionState {
  for (NSUInteger i = 0; i < self.itemViews.count; i++) {
    MZClipboardCellView *view = self.itemViews[i];
    MZRow *item = self.rows[i];
    [view configureWithRow:item
                  selected:((NSInteger)i == self.selectedRowIndex)
                    target:self
                      icon:[self iconForRow:item]
              revealEnabled:[self rowSupportsReveal:item]];
  }
  [self relayoutItemViews];
}

- (void)updateItemViewAtIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)self.itemViews.count) return;
  MZClipboardCellView *view = self.itemViews[(NSUInteger)index];
  MZRow *item = self.rows[(NSUInteger)index];
  [view configureWithRow:item
                selected:(index == self.selectedRowIndex)
                  target:self
                    icon:[self iconForRow:item]
            revealEnabled:[self rowSupportsReveal:item]];
}

- (void)scrollSelectedRowToVisible {
  if (self.selectedRowIndex < 0 || self.selectedRowIndex >= (NSInteger)self.itemViews.count) return;
  NSRect targetRect = self.itemViews[(NSUInteger)self.selectedRowIndex].frame;
  [self.listContentView scrollRectToVisible:targetRect];
}

- (void)selectRowAtIndex:(NSInteger)index focusList:(BOOL)focusList {
  if (self.rows.count == 0) return;
  NSInteger bounded = MAX(0, MIN(index, (NSInteger)self.rows.count - 1));
  if (bounded == self.selectedRowIndex && !focusList) return;
  NSInteger previous = self.selectedRowIndex;
  self.selectedRowIndex = bounded;
  [self updateItemViewAtIndex:previous];
  [self updateItemViewAtIndex:bounded];
  [self relayoutItemViews];
  [self scrollSelectedRowToVisible];
  if (focusList) [self.panel makeFirstResponder:self.listContentView];
  [self updateFilterButtons];
}

- (void)moveSelectionByDelta:(NSInteger)delta focusList:(BOOL)focusList {
  if (self.rows.count == 0) return;
  NSInteger selected = self.selectedRowIndex;
  if (selected < 0) selected = 0;
  [self selectRowAtIndex:selected + delta focusList:focusList];
}

- (void)moveSelectionByPageDelta:(NSInteger)delta focusList:(BOOL)focusList {
  if (self.rows.count == 0) return;
  NSInteger step = MAX(1, (NSInteger)floor(self.listScrollView.contentView.bounds.size.height / 74.0) - 1);
  [self moveSelectionByDelta:delta * step focusList:focusList];
}

- (void)moveSelectionToBoundary:(BOOL)toEnd focusList:(BOOL)focusList {
  if (self.rows.count == 0) return;
  [self selectRowAtIndex:(toEnd ? (NSInteger)self.rows.count - 1 : 0) focusList:focusList];
}

- (void)applyCurrentFilterPreservingSelection:(int64_t)selectedRowID {
  [self.rows removeAllObjects];
  for (MZRow *row in self.allRows) {
    BOOL include = NO;
    switch (self.filterMode) {
      case MZFilterModeAll:
        include = YES;
        break;
      case MZFilterModeText:
        include = row.contentKind == MZ_APP_CONTENT_TEXT || row.contentKind == MZ_APP_CONTENT_OTHER;
        break;
      case MZFilterModeLinks:
        include = row.contentKind == MZ_APP_CONTENT_LINK;
        break;
      case MZFilterModeImages:
        include = row.contentKind == MZ_APP_CONTENT_IMAGE;
        break;
      case MZFilterModeFavorites:
        include = row.pinned;
        break;
    }
    if (include) [self.rows addObject:row];
  }

  NSInteger match = -1;
  if (self.rows.count > 0) {
    match = [self indexOfRowID:selectedRowID inRows:self.rows];
    if (match == NSNotFound) match = 0;
  }
  self.selectedRowIndex = match;
  [self reloadItemViews];
  [self updateCountLabel];
  [self updateFilterButtons];
  [self scrollSelectedRowToVisible];
}

- (void)updateFilterButtons {
  for (NSButton *button in self.filterButtons) {
    BOOL active = button.tag == self.filterMode;
    if ([button isKindOfClass:[MZChamferedButton class]]) {
      ((MZChamferedButton *)button).active = active;
    }
    button.contentTintColor = active ? NSColor.whiteColor : mz_text_primary();
  }

  [self updateWindowPinButton];
}

- (void)updateCountLabel {
  NSUInteger count = self.rows.count;
  self.countLabel.stringValue = [NSString stringWithFormat:@"%lu %@", (unsigned long)count, count == 1 ? @"item" : @"items"];
}

- (NSComparisonResult)compareRow:(MZRow *)lhs withRow:(MZRow *)rhs {
  if (lhs.pinned != rhs.pinned) return lhs.pinned ? NSOrderedAscending : NSOrderedDescending;
  if (lhs.pinOrder != rhs.pinOrder) return lhs.pinOrder > rhs.pinOrder ? NSOrderedAscending : NSOrderedDescending;
  if (lhs.copiedAt != rhs.copiedAt) return lhs.copiedAt > rhs.copiedAt ? NSOrderedAscending : NSOrderedDescending;
  if (lhs.rowID != rhs.rowID) return lhs.rowID > rhs.rowID ? NSOrderedAscending : NSOrderedDescending;
  return NSOrderedSame;
}

- (void)optimisticallyTogglePinForRowID:(int64_t)rowID {
  NSInteger index = [self indexOfRowID:rowID inRows:self.allRows];
  if (index == NSNotFound) return;

  MZRow *row = self.allRows[(NSUInteger)index];
  if (row.pinned) {
    row.pinned = NO;
    row.pinOrder = 0;
  } else {
    row.pinned = YES;
    int64_t maxPinOrder = 0;
    for (MZRow *candidate in self.allRows) {
      if (candidate.pinOrder > maxPinOrder) maxPinOrder = candidate.pinOrder;
    }
    row.pinOrder = maxPinOrder + 1;
  }

  [self.allRows sortUsingComparator:^NSComparisonResult(MZRow *lhs, MZRow *rhs) {
    return [self compareRow:lhs withRow:rhs];
  }];

  [self applyCurrentFilterPreservingSelection:rowID];
}

- (void)changeFilter:(NSButton *)sender {
  self.filterMode = (MZFilterMode)sender.tag;
  int64_t selectedRowID = [self selectedItem] ? [self selectedItem].rowID : 0;
  [self applyCurrentFilterPreservingSelection:selectedRowID];
}

- (void)selectRowForItemView:(MZClipboardCellView *)sender {
  MZRow *row = [sender.objectValue isKindOfClass:[MZRow class]] ? sender.objectValue : nil;
  if (row == nil) return;
  [self selectRowID:row.rowID];
}

- (void)showMenuFromView:(NSView *)view {
  if (view == nil) return;
  [self.actionsMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(view.bounds)) inView:view];
}

- (void)showHeaderMenu:(id)sender {
  [self showMenuFromView:sender];
}

- (void)showRowMenuFromButton:(MZRowActionButton *)sender {
  [self selectRowID:sender.rowID];
  [self showMenuFromView:sender];
}

- (void)toggleSelectedFavorite:(id)sender {
  (void)sender;
  [self performSelectedAction:MZ_APP_ACTION_TOGGLE_PIN hidesPanel:NO];
}

- (void)toggleWindowPin:(id)sender {
  (void)sender;
  self.windowPinned = !self.windowPinned;
  [self applyWindowPinState];
  if (self.panel.isVisible) {
    [NSApp activateIgnoringOtherApps:YES];
    [self.panel orderFrontRegardless];
    [self.panel makeKeyAndOrderFront:nil];
  }
}

- (void)togglePinFromButton:(MZRowActionButton *)sender {
  [self selectRowID:sender.rowID];
  [self performRowAction:MZ_APP_ACTION_TOGGLE_PIN rowID:sender.rowID hidesPanel:NO];
}

- (void)pasteRow:(MZRowActionButton *)sender {
  [self selectRowID:sender.rowID];
  [self performRowAction:MZ_APP_ACTION_PASTE rowID:sender.rowID hidesPanel:YES];
}

- (void)copyRow:(MZRowActionButton *)sender {
  [self selectRowID:sender.rowID];
  [self performRowAction:MZ_APP_ACTION_COPY rowID:sender.rowID hidesPanel:YES];
}

- (void)revealRow:(MZRowActionButton *)sender {
  [self selectRowID:sender.rowID];
  [self performRowAction:MZ_APP_ACTION_REVEAL rowID:sender.rowID hidesPanel:NO];
}

- (void)pasteSelectedAsPlainText:(id)sender {
  (void)sender;
  [self performSelectedAction:MZ_APP_ACTION_PASTE_PLAIN hidesPanel:YES];
}

- (void)revealSelected:(id)sender {
  (void)sender;
  [self performSelectedAction:MZ_APP_ACTION_REVEAL hidesPanel:NO];
}

- (void)clearUnpinned:(id)sender {
  (void)sender;
  mz_app_dispatch_action(self, MZ_APP_ACTION_CLEAR_UNPINNED, 0);
}

- (void)clearAll:(id)sender {
  (void)sender;
  mz_app_dispatch_action(self, MZ_APP_ACTION_CLEAR_ALL, 0);
}

- (void)quitApplication:(id)sender {
  (void)sender;
  mz_app_dispatch_action(self, MZ_APP_ACTION_QUIT, 0);
}

- (void)clearSearch:(id)sender {
  (void)sender;
  if (self.searchField.stringValue.length == 0) return;
  self.searchField.stringValue = @"";
  if (self.callbacks.on_search) self.callbacks.on_search("");
}

- (BOOL)handleKeyEvent:(NSEvent *)event {
  if (!self.panel.isVisible) return NO;

  NSEventModifierFlags modifiers = mz_app_modifier_flags(event);
  BOOL hasCommand = (modifiers & NSEventModifierFlagCommand) != 0;
  BOOL hasOption = (modifiers & NSEventModifierFlagOption) != 0;
  BOOL hasShift = (modifiers & NSEventModifierFlagShift) != 0;
  NSString *characters = event.charactersIgnoringModifiers.lowercaseString ?: @"";

  if (event.keyCode == 53) {
    [self hide];
    return YES;
  }

  if (hasCommand && [characters isEqualToString:@"f"]) {
    [self.searchField becomeFirstResponder];
    return YES;
  }
  if (hasCommand && [characters isEqualToString:@"k"]) {
    [self clearSearch:nil];
    [self.searchField becomeFirstResponder];
    return YES;
  }
  if (hasCommand && [characters isEqualToString:@"v"]) {
    if (hasOption) return [self performSelectedAction:MZ_APP_ACTION_PASTE_PLAIN hidesPanel:YES];
    return [self performSelectedAction:MZ_APP_ACTION_PASTE hidesPanel:YES];
  }
  if (hasCommand && [characters isEqualToString:@"p"]) {
    return [self performSelectedAction:MZ_APP_ACTION_TOGGLE_PIN hidesPanel:NO];
  }
  if (hasCommand && [characters isEqualToString:@"r"]) {
    return [self performSelectedAction:MZ_APP_ACTION_REVEAL hidesPanel:NO];
  }

  if (!hasCommand && !hasOption) {
    switch (event.keyCode) {
      case 126:
        [self moveSelectionByDelta:-1 focusList:YES];
        return YES;
      case 125:
        [self moveSelectionByDelta:1 focusList:YES];
        return YES;
      case 116:
        [self moveSelectionByPageDelta:-1 focusList:YES];
        return YES;
      case 121:
        [self moveSelectionByPageDelta:1 focusList:YES];
        return YES;
      case 115:
        [self moveSelectionToBoundary:NO focusList:YES];
        return YES;
      case 119:
        [self moveSelectionToBoundary:YES focusList:YES];
        return YES;
      default:
        break;
    }
  }

  if (!mz_app_is_enter_event(event) || hasCommand) return NO;
  if (hasOption) return [self performSelectedAction:MZ_APP_ACTION_PASTE_PLAIN hidesPanel:YES];
  if (hasShift) return [self performSelectedAction:MZ_APP_ACTION_COPY hidesPanel:YES];
  return [self performSelectedAction:MZ_APP_ACTION_PASTE hidesPanel:YES];
}

- (NSImage *)iconForRow:(MZRow *)row {
  if (row.app.length > 0) {
    NSImage *cached = self.iconCache[row.app];
    if (cached != nil) return cached;

    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    NSURL *app_url = [workspace URLForApplicationWithBundleIdentifier:row.app];
    if (app_url != nil) {
      NSImage *image = [workspace iconForFile:app_url.path];
      if (image != nil) {
        self.iconCache[row.app] = image;
        return image;
      }
    }
  }

  if (row.contentKind == MZ_APP_CONTENT_IMAGE || row.hasImage) {
    NSImage *image = mz_resource_image(@"logo-thumb", @"png");
    if (image != nil) return image;
  }

  NSString *symbol = @"doc.text";
  switch (row.contentKind) {
    case MZ_APP_CONTENT_LINK:
      symbol = @"link";
      break;
    case MZ_APP_CONTENT_IMAGE:
      symbol = @"photo";
      break;
    case MZ_APP_CONTENT_FILE:
      symbol = @"doc";
      break;
    case MZ_APP_CONTENT_OTHER:
      symbol = @"chevron.left.forwardslash.chevron.right";
      break;
    case MZ_APP_CONTENT_TEXT:
    default:
      symbol = @"text.alignleft";
      break;
  }

  NSImage *image = mz_symbol_image(symbol, 21.0);
  if (image != nil) {
    image = [image copy];
  }
  return image;
}

- (BOOL)rowSupportsReveal:(MZRow *)row {
  return row.contentKind == MZ_APP_CONTENT_FILE || row.contentKind == MZ_APP_CONTENT_LINK || row.app.length > 0;
}

- (void)activateSelection:(id)sender {
  (void)sender;
  [self performSelectedAction:MZ_APP_ACTION_PASTE hidesPanel:YES];
}

- (void)controlTextDidChange:(NSNotification *)obj {
  if (obj.object != self.searchField) return;
  if (self.callbacks.on_search) self.callbacks.on_search(self.searchField.stringValue.UTF8String);
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
  (void)textView;
  if (control != self.searchField) return NO;
  if (commandSelector == @selector(moveUp:)) {
    [self moveSelectionByDelta:-1 focusList:NO];
    return YES;
  }
  if (commandSelector == @selector(moveDown:)) {
    [self moveSelectionByDelta:1 focusList:NO];
    return YES;
  }
  if (commandSelector == @selector(pageUp:)) {
    [self moveSelectionByPageDelta:-1 focusList:NO];
    return YES;
  }
  if (commandSelector == @selector(pageDown:)) {
    [self moveSelectionByPageDelta:1 focusList:NO];
    return YES;
  }
  if (commandSelector == @selector(moveToBeginningOfDocument:)) {
    [self moveSelectionToBoundary:NO focusList:NO];
    return YES;
  }
  if (commandSelector == @selector(moveToEndOfDocument:)) {
    [self moveSelectionToBoundary:YES focusList:NO];
    return YES;
  }
  if (commandSelector != @selector(insertNewline:) && commandSelector != @selector(insertNewlineIgnoringFieldEditor:)) return NO;

  NSEvent *event = NSApp.currentEvent;
  NSEventModifierFlags modifiers = event ? mz_app_modifier_flags(event) : 0;
  if ((modifiers & NSEventModifierFlagCommand) != 0) return NO;
  if ((modifiers & NSEventModifierFlagOption) != 0) return [self performSelectedAction:MZ_APP_ACTION_PASTE_PLAIN hidesPanel:YES];
  if ((modifiers & NSEventModifierFlagShift) != 0) return [self performSelectedAction:MZ_APP_ACTION_COPY hidesPanel:YES];
  return [self performSelectedAction:MZ_APP_ACTION_PASTE hidesPanel:YES];
}
@end

void mz_app_run(MZAppCallbacks callbacks) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    gController = [[MZAppController alloc] initWithCallbacks:callbacks];
    app.delegate = gController;
    [app run];
  }
}

void mz_app_set_action_callback(MZAppActionCallback callback) {
  gActionCallback = callback;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gController != nil) gController.actionCallback = callback;
  });
}

void mz_app_toggle(void) {
  dispatch_async(dispatch_get_main_queue(), ^{ [gController toggle:nil]; });
}

void mz_app_show(void) {
  dispatch_async(dispatch_get_main_queue(), ^{ [gController show]; });
}

void mz_app_hide(void) {
  dispatch_async(dispatch_get_main_queue(), ^{ [gController hide]; });
}

void mz_app_set_status_text(const char *text) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *value = text ? [NSString stringWithUTF8String:text] : @"M";
    if (gController.statusItem.button.image != nil) {
      gController.statusItem.button.toolTip = value.length ? value : @"Maccy";
    } else {
      gController.statusItem.button.title = value.length ? value : @"M";
    }
  });
}

void mz_app_set_rows(const MZAppRow *rows, size_t count) {
  NSMutableArray<MZRow *> *copy = [NSMutableArray arrayWithCapacity:count];
  for (size_t i = 0; i < count; i++) {
    MZRow *row = [MZRow new];
    row.rowID = rows[i].id;
    row.title = mz_string_from_utf8_or_fallback(rows[i].title, @"[text]");
    row.subtitle = mz_string_from_utf8_or_fallback(rows[i].subtitle, @"");
    row.app = mz_string_from_utf8_or_fallback(rows[i].app, @"");
    row.copiedAt = rows[i].copied_at;
    row.pinOrder = rows[i].pin_order;
    row.contentKind = rows[i].content_kind;
    row.pinned = rows[i].pinned != 0;
    row.hasImage = rows[i].has_image != 0;
    row.copyCount = rows[i].copy_count;
    [copy addObject:row];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    int64_t selectedRowID = 0;
    MZRow *selected = [gController selectedItem];
    if (selected != nil) selectedRowID = selected.rowID;

    gController.allRows = copy;
    [gController applyCurrentFilterPreservingSelection:selectedRowID];
  });
}

void mz_app_reveal_target(const char *target) {
  if (target == NULL) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *value = [NSString stringWithUTF8String:target];
    if (value.length == 0) return;

    NSURL *url = [NSURL URLWithString:value];
    if (url != nil && url.isFileURL) {
      [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ url ]];
      return;
    }
    if (url != nil) {
      [NSWorkspace.sharedWorkspace openURL:url];
    }
  });
}
