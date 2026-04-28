#import "macos_app.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <stdarg.h>

typedef NS_ENUM(NSInteger, MZFilterMode) {
  MZFilterModeAll = 0,
  MZFilterModeText = 1,
  MZFilterModeLinks = 2,
  MZFilterModeImages = 3,
  MZFilterModeFavorites = 4,
};

typedef NS_ENUM(NSInteger, MZLang) {
  MZLangEnglish = 0,
  MZLangChinese = 1,
};

static NSString *const kMZLangDefaultsKey = @"MZLanguage";
static NSString *const kMZMaxItemsDefaultsKey = @"MZMaxItems";
static NSString *const kMZLangChangedNotification = @"MZLangChangedNotification";
static MZLang gLang = MZLangEnglish;
static int64_t gInitialMaxItems = 500;

static NSString *mz_t(NSString *en);

static MZLang mz_lang_from_string(NSString *s) {
  if ([s isEqualToString:@"zh"] || [s isEqualToString:@"zh-Hans"] || [s isEqualToString:@"zh-CN"]) return MZLangChinese;
  return MZLangEnglish;
}

static NSString *mz_lang_to_string(MZLang lang) {
  return lang == MZLangChinese ? @"zh" : @"en";
}

static void mz_lang_load(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSString *stored = [defaults stringForKey:kMZLangDefaultsKey];
  if (stored.length > 0) {
    gLang = mz_lang_from_string(stored);
    return;
  }
  // No stored preference — auto-detect from system locale once.
  NSString *langCode = NSLocale.currentLocale.languageCode ?: @"en";
  gLang = mz_lang_from_string(langCode);
}

static void mz_lang_set(MZLang lang) {
  if (gLang == lang) return;
  gLang = lang;
  [NSUserDefaults.standardUserDefaults setObject:mz_lang_to_string(lang) forKey:kMZLangDefaultsKey];
  [NSNotificationCenter.defaultCenter postNotificationName:kMZLangChangedNotification object:nil];
}

int64_t mz_app_load_max_items(int64_t fallback) {
  NSInteger stored = [NSUserDefaults.standardUserDefaults integerForKey:kMZMaxItemsDefaultsKey];
  return stored > 0 ? (int64_t)stored : fallback;
}

void mz_app_set_initial_max_items(int64_t max_items) {
  if (max_items > 0) gInitialMaxItems = max_items;
}

static NSArray<NSNumber *> *mz_max_item_choices(void) {
  return @[ @200, @500, @1000, @2000 ];
}

static NSString *mz_max_items_title(NSInteger value) {
  return [NSString stringWithFormat:@"%ld %@", (long)value, mz_t(@"items")];
}

// Translate using English source as the key. Unknown keys pass through unchanged so we
// can ship without exhaustively localizing every transient label.
static NSString *mz_t(NSString *en) {
  if (gLang == MZLangEnglish || en == nil) return en;
  static NSDictionary<NSString *, NSString *> *zh = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    zh = @{
      // Header / tooltips
      @"Maccy": @"Maccy",
      @"Keep window on top": @"窗口置顶",
      // Search
      @"Search clipboard history...": @"搜索剪贴板历史…",
      // Tabs
      @"All": @"全部",
      @"Text": @"文本",
      @"Links": @"链接",
      @"Images": @"图片",
      @"☆  Favorites": @"☆  收藏",
      // Footer
      @"Clear All": @"全部清除",
      @"item": @"项",
      @"items": @"项",
      // Menus
      @"Toggle Favorite": @"切换收藏",
      @"Paste as Plain Text": @"粘贴为纯文本",
      @"Reveal": @"显示位置",
      @"Clear Unpinned": @"清空未固定",
      @"Language": @"语言",
      @"History Limit": @"历史数量上限",
      @"English": @"English",
      @"中文": @"中文",
      // Subtitles
      @"Copied as Image": @"复制为图片",
      @"Copied as File": @"复制为文件",
      @"Copied as Link": @"复制为链接",
      @"Copied as Plain Text": @"复制为纯文本",
      @"Copied Data": @"已复制数据",
    };
  });
  NSString *v = zh[en];
  return v ?: en;
}

// MZRow lives further down the file; we use untyped `id` here so we don't need
// to forward-shuffle the @interface. KVC keys match @property names.
static NSString *mz_subtitle_for_row(id row) {
  // Mirrors the original SQL CASE in main.zig but routes labels through mz_t()
  // so the visible string follows the active language. Bundle ids (row.app)
  // are intentionally not localized since they are stable identifiers.
  NSInteger kind = [[row valueForKey:@"contentKind"] integerValue];
  NSString *app = [row valueForKey:@"app"];
  if (kind == MZ_APP_CONTENT_IMAGE) return mz_t(@"Copied as Image");
  if (kind == MZ_APP_CONTENT_FILE) return mz_t(@"Copied as File");
  if (app.length > 0) return app;
  if (kind == MZ_APP_CONTENT_LINK) return mz_t(@"Copied as Link");
  if (kind == MZ_APP_CONTENT_TEXT) return mz_t(@"Copied as Plain Text");
  return mz_t(@"Copied Data");
}

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

static BOOL mz_app_matches_command_key(NSEvent *event, unsigned short keyCode, NSString *fallback) {
  if (event.keyCode == keyCode) return YES;
  NSString *characters = event.charactersIgnoringModifiers.lowercaseString ?: @"";
  return [characters isEqualToString:(fallback ?: @"")];
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

@interface MZCenteredTextFieldCell : NSTextFieldCell
@end

@implementation MZCenteredTextFieldCell
// Hard-disable every focus-ring path AppKit might take. macOS 14+ paints a
// system keyboard-navigation accent ring on top of the cell that ignores
// NSTextField.focusRingType; covering the cell-side hooks is what actually
// stops it from drawing.
- (void)drawFocusRingMaskWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
  (void)cellFrame;
  (void)controlView;
}

- (NSRect)focusRingMaskBoundsForFrame:(NSRect)cellFrame inView:(NSView *)controlView {
  (void)cellFrame;
  (void)controlView;
  return NSZeroRect;
}

- (NSFocusRingType)focusRingType {
  return NSFocusRingTypeNone;
}

- (NSRect)mz_centeredDrawingRectForBounds:(NSRect)rect {
  NSRect drawingRect = [super drawingRectForBounds:rect];
  NSSize cellSize = [self cellSizeForBounds:rect];
  drawingRect.origin.y = rect.origin.y + floor((NSHeight(rect) - cellSize.height) * 0.5);
  drawingRect.size.height = MIN(NSHeight(rect), cellSize.height);
  return drawingRect;
}

- (NSRect)drawingRectForBounds:(NSRect)rect {
  return [self mz_centeredDrawingRectForBounds:rect];
}

- (void)editWithFrame:(NSRect)rect
               inView:(NSView *)controlView
               editor:(NSText *)textObj
             delegate:(id)delegate
                event:(NSEvent *)event {
  [super editWithFrame:[self mz_centeredDrawingRectForBounds:rect]
                inView:controlView
                editor:textObj
              delegate:delegate
                 event:event];
}

- (void)selectWithFrame:(NSRect)rect
                 inView:(NSView *)controlView
                 editor:(NSText *)textObj
               delegate:(id)delegate
                  start:(NSInteger)selStart
                 length:(NSInteger)selLength {
  [super selectWithFrame:[self mz_centeredDrawingRectForBounds:rect]
                  inView:controlView
                  editor:textObj
                delegate:delegate
                   start:selStart
                  length:selLength];
}
@end

static void mz_center_text_field_vertically(NSTextField *field) {
  MZCenteredTextFieldCell *cell = [[MZCenteredTextFieldCell alloc] initTextCell:field.stringValue ?: @""];
  cell.placeholderString = field.placeholderString;
  cell.font = field.font;
  cell.textColor = field.textColor;
  cell.backgroundColor = field.backgroundColor;
  cell.drawsBackground = field.drawsBackground;
  cell.bordered = field.bordered;
  // Mirror bezeled on the cell as well — NSTextField forwards drawing through
  // its cell, and a bezeled cell will still paint focus chrome even when the
  // owning field has bezeled=NO.
  cell.bezeled = field.isBezeled;
  cell.editable = field.editable;
  cell.selectable = field.selectable;
  cell.alignment = field.alignment;
  cell.lineBreakMode = field.lineBreakMode;
  cell.usesSingleLineMode = YES;
  cell.truncatesLastVisibleLine = YES;
  field.cell = cell;
}

static NSImage *mz_symbol_image(NSString *name, CGFloat point_size) {
  NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  if (image == nil) return nil;
  NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:point_size weight:NSFontWeightMedium];
  return [image imageWithSymbolConfiguration:config];
}

// Menu items render their image alongside the title at a fixed leading slot. We
// flag the image as a template so AppKit re-tints it with the menu foreground
// color (white in dark mode, black in light) and clamp the size so each glyph
// occupies the same column regardless of intrinsic SF Symbol dimensions.
static NSImage *mz_menu_symbol_image(NSString *name) {
  NSImage *image = mz_symbol_image(name, 16.0);
  if (image == nil) return nil;
  image = [image copy];
  image.template = YES;
  image.size = NSMakeSize(18.0, 18.0);
  return image;
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

@interface MZShortcutHintView : NSView
@property(nonatomic, copy) NSString *shortcut;
- (instancetype)initWithShortcut:(NSString *)shortcut;
@end

@implementation MZShortcutHintView
- (instancetype)initWithShortcut:(NSString *)shortcut {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _shortcut = [shortcut copy];
    self.wantsLayer = NO;
  }
  return self;
}

- (BOOL)isOpaque {
  return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSString *value = self.shortcut ?: @"";
  NSDictionary<NSAttributedStringKey, id> *attrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: mz_text_secondary(),
  };
  NSSize size = [value sizeWithAttributes:attrs];
  NSPoint origin = NSMakePoint(floor((NSWidth(self.bounds) - size.width) * 0.5),
                              floor((NSHeight(self.bounds) - size.height) * 0.5));
  [value drawAtPoint:origin withAttributes:attrs];
}
@end

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
@property(nonatomic) NSInteger rowIndex;
@property(nonatomic, weak) id interactionTarget;
- (void)configureWithRow:(MZRow *)row
                selected:(BOOL)selected
                  target:(id)target
                    icon:(NSImage *)icon
            revealEnabled:(BOOL)revealEnabled;
- (void)applySelectedAppearance:(BOOL)selected;
- (void)dismissImagePreview;
@end

@implementation MZClipboardCellView
static BOOL mz_point_hits_view(NSView *container, NSView *target, NSPoint point) {
  if (target == nil || target.hidden || target.alphaValue <= 0.01) return NO;
  NSRect rect = [container convertRect:target.bounds fromView:target];
  return NSPointInRect(point, rect);
}

static BOOL mz_view_is_descendant_of(NSView *view, NSView *ancestor) {
  if (view == nil || ancestor == nil) return NO;
  for (NSView *current = view; current != nil; current = current.superview) {
    if (current == ancestor) return YES;
  }
  return NO;
}

static void mz_debug_log(NSString *format, ...) {
  if (format == nil) return;
  va_list args;
  va_start(args, format);
  NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  if (line == nil) return;

  NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
  NSData *data = [stamped dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) return;

  NSString *path = @"/tmp/maccy-debug.log";
  NSFileManager *fm = NSFileManager.defaultManager;
  if (![fm fileExistsAtPath:path]) {
    [data writeToFile:path atomically:YES];
    return;
  }

  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
  if (fh == nil) {
    [data writeToFile:path atomically:YES];
    return;
  }
  @try {
    [fh seekToEndOfFile];
    [fh writeData:data];
  } @catch (__unused NSException *e) {
  } @finally {
    [fh closeFile];
  }
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

// Decoded preview thumbnails are reusable across hovers; keep a small per-process
// LRU keyed by row id so we don't re-read from SQLite + redecode on every mouse
// move. NSCache auto-evicts under memory pressure, so we don't need a manual
// invalidation hook when rows are removed from history.
static NSCache<NSNumber *, NSImage *> *mz_preview_cache(void) {
  static NSCache<NSNumber *, NSImage *> *cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSCache new];
    cache.countLimit = 96;  // a few screens worth of hovered image rows
  });
  return cache;
}

- (NSViewController *)buildImagePreviewControllerForRow:(MZRow *)row {
  NSNumber *cacheKey = @(row.rowID);
  NSImage *image = [mz_preview_cache() objectForKey:cacheKey];
  if (image == nil) {
    size_t len = 0;
    const unsigned char *bytes = mz_app_copy_image_preview(row.rowID, &len);
    if (bytes == NULL || len == 0) return nil;

    NSData *data = [NSData dataWithBytes:bytes length:len];
    mz_app_free_buffer(bytes, len);
    image = [[NSImage alloc] initWithData:data];
    if (image == nil) return nil;
    [mz_preview_cache() setObject:image forKey:cacheKey cost:(NSUInteger)len];
  }

  const CGFloat max_width = 360.0;
  const CGFloat max_height = 260.0;
  NSSize image_size = image.size;
  if (image_size.width <= 0.0 || image_size.height <= 0.0) return nil;
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
  controller.preferredContentSize = content.frame.size;
  return controller;
}

// Read-only text preview popover for non-image rows. Sized tightly to the
// content (so a one-line title doesn't get a 600px-tall popover), capped at
// a sane max height with vertical scrolling for long bodies, and styled to
// match the surrounding panel chrome.
- (NSViewController *)buildTextPreviewControllerForRow:(MZRow *)row {
  NSString *body = row.title ?: @"";
  if (body.length == 0) return nil;

  const CGFloat width = 360.0;
  const CGFloat max_height = 200.0;
  const CGFloat horizontal_padding = 12.0;
  const CGFloat vertical_padding = 10.0;

  NSFont *font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
  NSDictionary<NSAttributedStringKey, id> *attrs = @{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : mz_text_primary(),
  };
  CGFloat textWidth = width - horizontal_padding * 2.0;
  NSRect bounding = [body boundingRectWithSize:NSMakeSize(textWidth, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin |
                                               NSStringDrawingUsesFontLeading
                                    attributes:attrs];
  CGFloat measured = ceil(NSHeight(bounding));
  CGFloat single_line = ceil(font.ascender - font.descender + font.leading);
  CGFloat text_area = MIN(max_height - vertical_padding * 2.0,
                          MAX(single_line, measured));
  CGFloat content_height = ceil(text_area + vertical_padding * 2.0);

  NSViewController *controller = [NSViewController new];
  NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, content_height)];
  content.wantsLayer = YES;
  content.layer.cornerRadius = 10.0;
  content.layer.masksToBounds = YES;

  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(horizontal_padding, vertical_padding,
                                                                        textWidth,
                                                                        text_area)];
  scroll.borderType = NSNoBorder;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.autohidesScrollers = YES;
  scroll.drawsBackground = NO;
  scroll.backgroundColor = NSColor.clearColor;
  scroll.scrollerStyle = NSScrollerStyleOverlay;

  NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, textWidth, text_area)];
  text.editable = NO;
  text.selectable = YES;
  text.drawsBackground = NO;
  text.backgroundColor = NSColor.clearColor;
  text.textContainerInset = NSMakeSize(0, 0);
  text.font = font;
  text.textColor = mz_text_primary();
  text.string = body;
  text.minSize = NSMakeSize(0, 0);
  text.maxSize = NSMakeSize(textWidth, CGFLOAT_MAX);
  text.verticallyResizable = YES;
  text.horizontallyResizable = NO;
  text.autoresizingMask = NSViewWidthSizable;
  text.textContainer.containerSize = NSMakeSize(textWidth, CGFLOAT_MAX);
  text.textContainer.widthTracksTextView = YES;
  scroll.documentView = text;
  [content addSubview:scroll];
  controller.view = content;
  // Crucial: NSPopover sizes itself from preferredContentSize. Without this
  // the inner NSTextView's intrinsic content size dictates a huge popover
  // even when the visible text is one line.
  controller.preferredContentSize = NSMakeSize(width, content_height);
  return controller;
}

- (void)showImagePreviewIfNeeded {
  if (!self.previewEnabled || self.previewPopover.shown) return;
  MZRow *row = [self.objectValue isKindOfClass:[MZRow class]] ? self.objectValue : nil;
  if (row == nil) return;

  // Image rows render the decoded thumbnail; everything else (text, link,
  // file, other) gets a scrollable text preview so users can see the full
  // title even when the cell truncates it.
  BOOL useImage = (row.contentKind == MZ_APP_CONTENT_IMAGE) || row.hasImage;
  NSViewController *controller = useImage
      ? [self buildImagePreviewControllerForRow:row]
      : [self buildTextPreviewControllerForRow:row];
  if (controller == nil) return;

  if (self.previewPopover == nil) {
    self.previewPopover = [NSPopover new];
    self.previewPopover.behavior = NSPopoverBehaviorTransient;
    self.previewPopover.animates = YES;
  }
  self.previewPopover.contentViewController = controller;
  [self.previewPopover showRelativeToRect:self.rowContainer.bounds ofView:self.rowContainer preferredEdge:NSRectEdgeMaxX];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;
    _rowIndex = -1;

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
  self.subtitleLabel.stringValue = mz_subtitle_for_row(row);
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

  [self applySelectedAppearance:selected];
  self.dividerView.hidden = NO;
  self.subtitleLabel.textColor = mz_text_secondary();
  self.timeLabel.textColor = mz_text_secondary();
  BOOL preview_was_enabled = self.previewEnabled;
  // Every row is hover-previewable: image rows show the decoded thumbnail,
  // text/link/file/other rows show a scrollable read-only text popover with
  // the full (un-truncated) title.
  self.previewEnabled = YES;

  [self setNeedsLayout:YES];
  // Force layout *now* rather than next display tick. Otherwise the
  // virtualized reuse path can serve a freshly-dequeued cell whose
  // favoriteButton.frame is still NSZeroRect (or stale from the previous
  // row), making mz_activate_row_at_event miss favorite clicks because the
  // hit-test runs in the same mouseDown turn as configureWithRow.
  [self layoutSubtreeIfNeeded];
  if (preview_was_enabled != self.previewEnabled || self.previewTrackingArea == nil) {
    [self updateTrackingAreas];
  }
}

// Fast-path used by selection switches: only the rowContainer layer attrs
// change, so we skip the full configureWithRow rebuild (title/subtitle/icon/
// time/buttons/trackingArea) and avoid the surrounding layout pass.
- (void)applySelectedAppearance:(BOOL)selected {
  CGColorRef fill = (selected ? mz_selected_fill() : NSColor.clearColor).CGColor;
  CGColorRef border = (selected ? mz_selected_border() : NSColor.clearColor).CGColor;
  CGFloat border_width = selected ? 1.0 : 0.0;
  CALayer *layer = self.rowContainer.layer;
  if (layer == nil) return;
  if (!CGColorEqualToColor(layer.backgroundColor, fill)) layer.backgroundColor = fill;
  if (!CGColorEqualToColor(layer.borderColor, border)) layer.borderColor = border;
  if (layer.borderWidth != border_width) layer.borderWidth = border_width;
}

- (NSView *)hitTest:(NSPoint)point {
  if (!NSPointInRect(point, self.frame)) return nil;

  NSPoint local = [self convertPoint:point fromView:self.superview];
  if (mz_point_hits_view(self, self.favoriteButton, local)) return self.favoriteButton;
  if (self.actionBar != nil && !self.actionBar.hidden) {
    if (mz_point_hits_view(self, self.pasteActionView.button, local)) return self.pasteActionView.button;
    if (mz_point_hits_view(self, self.duplicateActionView.button, local)) return self.duplicateActionView.button;
    if (mz_point_hits_view(self, self.revealActionView.button, local)) return self.revealActionView.button;
    if (mz_point_hits_view(self, self.moreActionView.button, local)) return self.moreActionView.button;
  }
  return self.rowButton;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.previewTrackingArea != nil) {
    [self removeTrackingArea:self.previewTrackingArea];
    self.previewTrackingArea = nil;
  }
  if (!self.previewEnabled) return;
  self.previewTrackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                          options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
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

- (void)mouseMoved:(NSEvent *)event {
  (void)event;
  if (self.previewPopover.shown) return;
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
  mz_debug_log(@"activate_row container=%@ point=(%.1f,%.1f)",
               NSStringFromClass(container.class),
               point.x,
               point.y);

  for (NSView *subview in container.subviews.reverseObjectEnumerator) {
    if (![subview isKindOfClass:[MZClipboardCellView class]]) continue;
    if (!NSPointInRect(point, subview.frame)) continue;

    MZClipboardCellView *rowView = (MZClipboardCellView *)subview;
    MZRow *row = [rowView.objectValue isKindOfClass:[MZRow class]] ? rowView.objectValue : nil;
    // Make absolutely sure subview frames (favoriteButton, action bar, etc.)
    // are up-to-date before we hit-test against them. Cheap when nothing is
    // pending, critical when this is the same turn the cell was reused.
    [rowView layoutSubtreeIfNeeded];
    NSPoint rowPoint = [rowView convertPoint:event.locationInWindow fromView:nil];
    mz_debug_log(@"activate_row matched rowID=%lld title=%@ rowPoint=(%.1f,%.1f) favFrame=(%.1f,%.1f,%.1f,%.1f)",
                 row ? row.rowID : 0,
                 row ? row.title : @"<nil>",
                 rowPoint.x,
                 rowPoint.y,
                 rowView.favoriteButton.frame.origin.x,
                 rowView.favoriteButton.frame.origin.y,
                 rowView.favoriteButton.frame.size.width,
                 rowView.favoriteButton.frame.size.height);

    if (mz_point_hits_view(rowView, rowView.favoriteButton, rowPoint)) {
      [rowView.favoriteButton performClick:nil];
      return YES;
    }

    if (rowView.actionBar != nil && !rowView.actionBar.hidden) {
      if (mz_point_hits_view(rowView, rowView.pasteActionView.button, rowPoint)) {
        [rowView.pasteActionView.button performClick:nil];
        return YES;
      }
      if (mz_point_hits_view(rowView, rowView.duplicateActionView.button, rowPoint)) {
        [rowView.duplicateActionView.button performClick:nil];
        return YES;
      }
      if (mz_point_hits_view(rowView, rowView.revealActionView.button, rowPoint)) {
        [rowView.revealActionView.button performClick:nil];
        return YES;
      }
      if (mz_point_hits_view(rowView, rowView.moreActionView.button, rowPoint)) {
        [rowView.moreActionView.button performClick:nil];
        return YES;
      }
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
      return YES;
    }
    return NO;
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

// Persisted window size keys. We only remember size — position keeps the
// "drop-from-menubar / centered" behavior so the user always finds the panel in
// the same spot on the screen.
static NSString *const kMZWindowWidthKey = @"MZWindowWidth";
static NSString *const kMZWindowHeightKey = @"MZWindowHeight";
static const CGFloat kMZPanelDefaultWidth = 561.0;
static const CGFloat kMZPanelDefaultHeight = 701.0;
static const CGFloat kMZPanelMinWidth = 561.0;
static const CGFloat kMZPanelMinHeight = 460.0;

@interface MZAppController : NSObject <NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate>
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
@property(nonatomic, strong) NSMutableArray<MZClipboardCellView *> *reusableItemViews;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *iconCache;
@property(nonatomic, strong) NSMutableArray<NSButton *> *filterButtons;
@property(nonatomic, strong) NSTextField *countLabel;
@property(nonatomic, strong) NSButton *clearButton;
@property(nonatomic, strong) NSButton *pinButton;
@property(nonatomic, strong) NSButton *settingsButton;
@property(nonatomic, strong) id keyEventMonitor;
@property(nonatomic, strong) NSRunningApplication *previousFrontmostApp;
@property(nonatomic, strong) NSMenuItem *languageMenuItem;
@property(nonatomic, strong) NSMenuItem *historyLimitMenuItem;
// Chrome views referenced from -relayoutPanelChrome so the layout stays
// pixel-correct after the user resizes the window.
@property(nonatomic, strong) NSImageView *titleMark;
@property(nonatomic, strong) NSTextField *appTitleLabel;
@property(nonatomic, strong) NSView *searchBox;
@property(nonatomic, strong) NSView *searchHint;
@property(nonatomic, strong) NSView *tabsCard;
@property(nonatomic, strong) NSMutableArray<NSView *> *tabDividers;
@property(nonatomic, strong) NSView *favoritesCard;
@property(nonatomic, strong) NSView *listCard;
@property(nonatomic, strong) NSView *clearHint;
@property(nonatomic) MZFilterMode filterMode;
@property(nonatomic) NSUInteger filterChangeGeneration;
@property(nonatomic) NSInteger selectedRowIndex;
@property(nonatomic) NSInteger maxItemsLimit;
@property(nonatomic) BOOL windowPinned;
@end

static MZAppController *gController = nil;
static const CGFloat kMZListTopPadding = 8.0;
static const CGFloat kMZListBottomPadding = 8.0;

static int mz_app_target_pid_for_action(MZAppController *controller, MZAppAction action) {
  switch (action) {
    case MZ_APP_ACTION_PASTE:
    case MZ_APP_ACTION_PASTE_PLAIN:
      return controller.previousFrontmostApp != nil ? (int)controller.previousFrontmostApp.processIdentifier : 0;
    default:
      return 0;
  }
}

static void mz_app_dispatch_action(MZAppController *controller, MZAppAction action, int64_t rowID) {
  int target_pid = mz_app_target_pid_for_action(controller, action);
  if (controller.actionCallback != NULL) {
    controller.actionCallback(action, rowID, target_pid);
    return;
  }

  switch (action) {
    case MZ_APP_ACTION_COPY:
      if (controller.callbacks.on_select) controller.callbacks.on_select(rowID, 0, 0);
      return;
    case MZ_APP_ACTION_PASTE: {
      // The previous frontmost app was captured in -show; passing its pid
      // through to the paste path lets us route ⌘V directly to that process
      // and bypass the frontmost-app race entirely.
      if (controller.callbacks.on_select) controller.callbacks.on_select(rowID, 1, target_pid);
      return;
    }
    case MZ_APP_ACTION_PASTE_PLAIN: {
      if (controller.callbacks.on_select) controller.callbacks.on_select(rowID, 1, target_pid);
      return;
    }
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
    _reusableItemViews = [NSMutableArray array];
    _iconCache = [NSMutableDictionary dictionary];
    _filterButtons = [NSMutableArray array];
    _tabDividers = [NSMutableArray array];
    _filterMode = MZFilterModeAll;
    _selectedRowIndex = -1;
    _maxItemsLimit = gInitialMaxItems > 0 ? (NSInteger)gInitialMaxItems : 500;
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
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)pollTimer:(NSTimer *)timer {
  (void)timer;
  if (self.callbacks.on_poll) self.callbacks.on_poll();
}

- (void)buildPanel {
  const CGFloat outerMargin = 25.0;
  const CGFloat contentInset = 16.0;
  const CGFloat contentTextX = 84.0;
  const CGFloat chromeTop = 42.0;
  const CGFloat searchHeight = 47.0;
  const CGFloat tabsHeight = 42.0;
  const CGFloat sectionGap = 16.0;
  const CGFloat listBottom = 60.0;
  NSRect frame = NSMakeRect(0, 0, kMZPanelDefaultWidth, kMZPanelDefaultHeight);
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
  // Allow full two-axis resizing while preserving the original 561px layout as
  // the minimum width. Wider windows reflow the search field, tabs, rows, and
  // footer; narrower windows are blocked to avoid clipped chrome.
  self.panel.minSize = NSMakeSize(kMZPanelMinWidth, kMZPanelMinHeight);

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

  self.titleMark = [[NSImageView alloc] initWithFrame:NSZeroRect];
  self.titleMark.image = mz_resource_image(@"logo-mark", @"png");
  self.titleMark.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.titleMark.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
  [self.rootView addSubview:self.titleMark];

  self.appTitleLabel = mz_label(@"Maccy", [NSFont systemFontOfSize:25 weight:NSFontWeightBold], mz_text_primary());
  self.appTitleLabel.alignment = NSTextAlignmentCenter;
  self.appTitleLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
  [self.rootView addSubview:self.appTitleLabel];

  self.pinButton = [self chromeButtonWithSymbol:@"pin" action:@selector(toggleWindowPin:)];
  self.pinButton.toolTip = mz_t(@"Keep window on top");
  self.pinButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  [self.rootView addSubview:self.pinButton];

  self.settingsButton = [self chromeButtonWithSymbol:@"gearshape" action:@selector(showHeaderMenu:)];
  self.settingsButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  [self.rootView addSubview:self.settingsButton];

  self.searchBox = [[NSView alloc] initWithFrame:NSZeroRect];
  self.searchBox.wantsLayer = YES;
  self.searchBox.layer.cornerRadius = 8.0;
  self.searchBox.layer.backgroundColor = mz_card_fill().CGColor;
  self.searchBox.layer.borderWidth = 1.0;
  self.searchBox.layer.borderColor = mz_card_border().CGColor;
  self.searchBox.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [self.rootView addSubview:self.searchBox];

  NSImageView *searchIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(17, 12, 23, 23)];
  searchIcon.image = mz_symbol_image(@"magnifyingglass", 20.0);
  searchIcon.contentTintColor = mz_text_primary();
  [self.searchBox addSubview:searchIcon];

  self.searchField = [[NSTextField alloc] initWithFrame:NSZeroRect];
  self.searchField.delegate = self;
  self.searchField.placeholderString = mz_t(@"Search clipboard history...");
  self.searchField.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
  self.searchField.textColor = mz_text_primary();
  self.searchField.drawsBackground = NO;
  self.searchField.backgroundColor = NSColor.clearColor;
  // bordered + bezeled both off: prevents AppKit from painting both the
  // legacy bezel chrome AND the macOS 14+ system keyboard-navigation accent
  // ring, neither of which lines up with our custom searchBox container.
  // focusRingType is honored only when bezeled=NO.
  self.searchField.bordered = NO;
  self.searchField.bezeled = NO;
  self.searchField.focusRingType = NSFocusRingTypeNone;
  self.searchField.autoresizingMask = NSViewWidthSizable;
  // Explicitly editable + selectable so ⌘A / ⌘C / ⌘V / drag-select all work
  // inside the search box. NSTextField defaults flip depending on which
  // initialiser path is used and silently break text selection otherwise.
  self.searchField.editable = YES;
  self.searchField.selectable = YES;
  self.searchField.allowsEditingTextAttributes = NO;
  mz_center_text_field_vertically(self.searchField);
  // Re-assert on the freshly installed cell — the helper copies whatever the
  // field happened to have at that moment, so this guarantees the cell ends
  // up editable/selectable too.
  self.searchField.cell.editable = YES;
  self.searchField.cell.selectable = YES;
  [self.searchBox addSubview:self.searchField];

  self.searchHint = [[NSView alloc] initWithFrame:NSZeroRect];
  self.searchHint.wantsLayer = YES;
  self.searchHint.layer.cornerRadius = 5.0;
  self.searchHint.layer.borderWidth = 1.0;
  self.searchHint.layer.borderColor = mz_card_border().CGColor;
  self.searchHint.layer.backgroundColor = mz_color(28, 31, 35, 1.0).CGColor;
  self.searchHint.autoresizingMask = NSViewMinXMargin;
  [self.searchBox addSubview:self.searchHint];

  MZShortcutHintView *searchHintLabel = [[MZShortcutHintView alloc] initWithShortcut:@"⌘F"];
  searchHintLabel.frame = self.searchHint.bounds;
  searchHintLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self.searchHint addSubview:searchHintLabel];

  self.tabsCard = [[NSView alloc] initWithFrame:NSZeroRect];
  self.tabsCard.wantsLayer = YES;
  self.tabsCard.layer.cornerRadius = 6.0;
  self.tabsCard.layer.backgroundColor = mz_card_fill().CGColor;
  self.tabsCard.layer.borderWidth = 1.0;
  self.tabsCard.layer.borderColor = mz_card_border().CGColor;
  self.tabsCard.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [self.rootView addSubview:self.tabsCard];

  NSArray<NSString *> *titles = @[ mz_t(@"All"), mz_t(@"Text"), mz_t(@"Links"), mz_t(@"Images") ];
  for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
    NSButton *button = [self filterButtonWithTitle:titles[(NSUInteger)i] tag:i];
    [self.tabsCard addSubview:button];
    [self.filterButtons addObject:button];
    if (i > 0) {
      NSView *divider = [[NSView alloc] initWithFrame:NSZeroRect];
      divider.wantsLayer = YES;
      divider.layer.backgroundColor = mz_color(65, 69, 76, 0.78).CGColor;
      [self.tabsCard addSubview:divider];
      [self.tabDividers addObject:divider];
    }
  }

  self.favoritesCard = [[NSView alloc] initWithFrame:NSZeroRect];
  self.favoritesCard.wantsLayer = YES;
  self.favoritesCard.layer.cornerRadius = 6.0;
  self.favoritesCard.layer.backgroundColor = mz_card_fill().CGColor;
  self.favoritesCard.layer.borderWidth = 1.0;
  self.favoritesCard.layer.borderColor = mz_card_border().CGColor;
  self.favoritesCard.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  [self.rootView addSubview:self.favoritesCard];

  NSButton *favoritesButton = [self filterButtonWithTitle:mz_t(@"☆  Favorites") tag:MZFilterModeFavorites];
  favoritesButton.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self.favoritesCard addSubview:favoritesButton];
  [self.filterButtons addObject:favoritesButton];
  [self updateFilterButtons];

  self.listCard = [[NSView alloc] initWithFrame:NSZeroRect];
  self.listCard.wantsLayer = YES;
  self.listCard.layer.cornerRadius = 8.0;
  self.listCard.layer.borderWidth = 1.0;
  self.listCard.layer.borderColor = mz_card_border().CGColor;
  self.listCard.layer.backgroundColor = mz_color(21, 24, 27, 1.0).CGColor;
  self.listCard.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self.rootView addSubview:self.listCard];

  self.listScrollView = [[MZListScrollView alloc] initWithFrame:NSZeroRect];
  self.listScrollView.drawsBackground = NO;
  self.listScrollView.borderType = NSNoBorder;
  self.listScrollView.hasVerticalScroller = YES;
  self.listScrollView.autohidesScrollers = YES;
  self.listScrollView.automaticallyAdjustsContentInsets = NO;
  self.listScrollView.scrollerInsets = NSEdgeInsetsMake(4, 0, 4, 4);
  self.listScrollView.interactionTarget = self;
  self.listScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self.listCard addSubview:self.listScrollView];

  self.listContentView = [[MZFlippedView alloc] initWithFrame:NSZeroRect];
  self.listContentView.interactionTarget = self;
  self.listContentView.autoresizingMask = NSViewWidthSizable;
  self.listScrollView.documentView = self.listContentView;
  self.listScrollView.contentView.postsBoundsChangedNotifications = YES;
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(listScrollViewDidScroll:)
                                             name:NSViewBoundsDidChangeNotification
                                           object:self.listScrollView.contentView];

  NSImageView *countIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(outerMargin + contentInset, 25.5, 18, 18)];
  countIcon.image = mz_symbol_image(@"checkmark.circle", 16.0);
  countIcon.contentTintColor = mz_primary_orange_shadow();
  [self.rootView addSubview:countIcon];

  self.countLabel = mz_label(@"0 items", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], mz_text_secondary());
  self.countLabel.frame = NSMakeRect(outerMargin + contentInset + 28, 20.0, 120, 29.0);
  mz_center_text_field_vertically(self.countLabel);
  [self.rootView addSubview:self.countLabel];

  self.clearButton = [self footerTextButtonWithTitle:mz_t(@"Clear All") action:@selector(clearAll:)];
  self.clearButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
  [self.rootView addSubview:self.clearButton];

  self.clearHint = [[NSView alloc] initWithFrame:NSZeroRect];
  self.clearHint.wantsLayer = YES;
  self.clearHint.layer.cornerRadius = 5.0;
  self.clearHint.layer.borderWidth = 1.0;
  self.clearHint.layer.borderColor = mz_card_border().CGColor;
  self.clearHint.layer.backgroundColor = mz_color(28, 31, 35, 1.0).CGColor;
  self.clearHint.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
  [self.rootView addSubview:self.clearHint];

  MZShortcutHintView *clearHintLabel = [[MZShortcutHintView alloc] initWithShortcut:@"⌘K"];
  clearHintLabel.frame = self.clearHint.bounds;
  clearHintLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self.clearHint addSubview:clearHintLabel];

  // Suppress unused-variable warnings for layout constants only consumed by
  // -relayoutPanelChrome below — keeping them named here documents intent.
  (void)contentInset;
  (void)contentTextX;
  (void)chromeTop;
  (void)searchHeight;
  (void)tabsHeight;
  (void)sectionGap;
  (void)listBottom;
  (void)outerMargin;

  self.actionsMenu = [[NSMenu alloc] initWithTitle:@"Actions"];
  // Icons mirror the reference design: outlined SF Symbols rendered as templates so
  // they pick up the menu's foreground color and stay aligned with the title text.
  NSArray<NSDictionary *> *menu_specs = @[
    @{@"title": mz_t(@"Toggle Favorite"), @"selector": NSStringFromSelector(@selector(toggleSelectedFavorite:)), @"symbol": @"star"},
    @{@"title": mz_t(@"Paste as Plain Text"), @"selector": NSStringFromSelector(@selector(pasteSelectedAsPlainText:)), @"symbol": @"doc.on.doc"},
    @{@"title": mz_t(@"Reveal"), @"selector": NSStringFromSelector(@selector(revealSelected:)), @"symbol": @"magnifyingglass"},
  ];
  for (NSDictionary *spec in menu_specs) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:spec[@"title"] action:NSSelectorFromString(spec[@"selector"]) keyEquivalent:@""];
    item.target = self;
    item.image = mz_menu_symbol_image(spec[@"symbol"]);
    [self.actionsMenu addItem:item];
  }
  [self.actionsMenu addItem:[NSMenuItem separatorItem]];
  for (NSDictionary *spec in @[
         @{@"title": mz_t(@"Clear Unpinned"), @"selector": NSStringFromSelector(@selector(clearUnpinned:)), @"symbol": @"trash"},
         @{@"title": mz_t(@"Clear All"), @"selector": NSStringFromSelector(@selector(clearAll:)), @"symbol": @"trash"},
       ]) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:spec[@"title"] action:NSSelectorFromString(spec[@"selector"]) keyEquivalent:@""];
    item.target = self;
    item.image = mz_menu_symbol_image(spec[@"symbol"]);
    [self.actionsMenu addItem:item];
  }
  // Language submenu — toggles between English and 中文 in-place.
  [self.actionsMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *langRoot = [[NSMenuItem alloc] initWithTitle:mz_t(@"Language") action:NULL keyEquivalent:@""];
  langRoot.image = mz_menu_symbol_image(@"command");
  NSMenu *langMenu = [[NSMenu alloc] initWithTitle:@"Language"];
  NSMenuItem *enItem = [[NSMenuItem alloc] initWithTitle:@"English" action:@selector(switchLanguageToEnglish:) keyEquivalent:@""];
  enItem.target = self;
  enItem.state = (gLang == MZLangEnglish) ? NSControlStateValueOn : NSControlStateValueOff;
  [langMenu addItem:enItem];
  NSMenuItem *zhItem = [[NSMenuItem alloc] initWithTitle:@"中文" action:@selector(switchLanguageToChinese:) keyEquivalent:@""];
  zhItem.target = self;
  zhItem.state = (gLang == MZLangChinese) ? NSControlStateValueOn : NSControlStateValueOff;
  [langMenu addItem:zhItem];
  langRoot.submenu = langMenu;
  [self.actionsMenu addItem:langRoot];
  self.languageMenuItem = langRoot;

  NSMenuItem *historyRoot = [[NSMenuItem alloc] initWithTitle:mz_t(@"History Limit") action:NULL keyEquivalent:@""];
  historyRoot.image = mz_menu_symbol_image(@"clock.arrow.circlepath");
  NSMenu *historyMenu = [[NSMenu alloc] initWithTitle:@"History Limit"];
  for (NSNumber *choice in mz_max_item_choices()) {
    NSInteger value = choice.integerValue;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:mz_max_items_title(value) action:@selector(changeHistoryLimit:) keyEquivalent:@""];
    item.target = self;
    item.tag = value;
    item.state = (value == self.maxItemsLimit) ? NSControlStateValueOn : NSControlStateValueOff;
    [historyMenu addItem:item];
  }
  historyRoot.submenu = historyMenu;
  [self.actionsMenu addItem:historyRoot];
  self.historyLimitMenuItem = historyRoot;

  [self.actionsMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *quit_item = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quitApplication:) keyEquivalent:@""];
  quit_item.target = self;
  quit_item.image = mz_menu_symbol_image(@"xmark");
  [self.actionsMenu addItem:quit_item];

  [self updateWindowPinButton];

  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(handleLanguageChange:)
                                             name:kMZLangChangedNotification
                                           object:nil];

  [self restoreSavedPanelSize];
  [self relayoutPanelChrome];
  // Install the window delegate AFTER initial layout so we don't bounce
  // through -windowDidResize: while we're still constructing subviews.
  self.panel.delegate = self;
}

- (void)restoreSavedPanelSize {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  if ([defaults objectForKey:kMZWindowWidthKey] == nil ||
      [defaults objectForKey:kMZWindowHeightKey] == nil) {
    return;
  }
  CGFloat width = [defaults doubleForKey:kMZWindowWidthKey];
  CGFloat height = [defaults doubleForKey:kMZWindowHeightKey];
  if (width < kMZPanelMinWidth) width = kMZPanelMinWidth;
  if (height < kMZPanelMinHeight) height = kMZPanelMinHeight;

  // Don't allow restoring a size larger than the current screen — users may
  // have moved between displays since the last save.
  NSScreen *screen = NSScreen.mainScreen;
  if (screen != nil) {
    NSSize visible = screen.visibleFrame.size;
    if (width > visible.width) width = visible.width;
    if (height > visible.height) height = visible.height;
  }

  NSRect frame = self.panel.frame;
  frame.size = NSMakeSize(width, height);
  [self.panel setFrame:frame display:NO];
}

- (void)persistPanelSize {
  if (self.panel == nil) return;
  NSSize size = self.panel.frame.size;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  [defaults setDouble:size.width forKey:kMZWindowWidthKey];
  [defaults setDouble:size.height forKey:kMZWindowHeightKey];
}

// Recompute every chrome subview's frame from the current rootView size. Called
// on first layout, every -windowDidResize: tick, and after the saved size is
// restored on launch. Children inside resizable parents (search field inside
// searchBox, tab buttons inside tabsCard) are positioned here too so the layout
// stays consistent regardless of intermediate autoresizing behavior.
- (void)relayoutPanelChrome {
  if (self.rootView == nil) return;
  CGFloat W = self.rootView.bounds.size.width;
  CGFloat H = self.rootView.bounds.size.height;
  const CGFloat outerMargin = 25.0;
  const CGFloat contentInset = 16.0;
  const CGFloat contentTextX = 84.0;
  const CGFloat chromeTop = 42.0;
  const CGFloat searchHeight = 47.0;
  const CGFloat tabsHeight = 42.0;
  const CGFloat sectionGap = 16.0;
  const CGFloat listBottom = 60.0;

  // Header — logo + wordmark stay center-anchored, window-pin/settings buttons
  // hug the top-right corner.
  self.titleMark.frame = NSMakeRect(floor((W - 154.0) * 0.5), H - 60.0, 26.0, 48.0);
  self.appTitleLabel.frame = NSMakeRect(NSMaxX(self.titleMark.frame) + 12.0, H - 50.0, 116.0, 32.0);
  self.pinButton.frame = NSMakeRect(W - 98.0, H - chromeTop, 28.0, 28.0);
  self.settingsButton.frame = NSMakeRect(W - 54.0, H - chromeTop, 30.0, 30.0);

  // Search row — full width minus side margins.
  CGFloat searchY = H - 123.0;
  self.searchBox.frame = NSMakeRect(outerMargin, searchY, W - outerMargin * 2.0, searchHeight);
  CGFloat searchInner = self.searchBox.bounds.size.width;
  self.searchField.frame = NSMakeRect(contentTextX, 7.5, MAX(0.0, searchInner - contentTextX - 87.0), 32.0);
  self.searchHint.frame = NSMakeRect(searchInner - 58.0, 9.0, 43.0, 29.0);
  for (NSView *subview in self.searchHint.subviews) subview.frame = self.searchHint.bounds;

  // Filter row — tabsCard takes the leading area, favorites card hugs the
  // trailing edge with a fixed gap so its width never changes.
  CGFloat filtersY = searchY - sectionGap - tabsHeight;
  CGFloat filtersWidth = W - outerMargin * 2.0;
  CGFloat favoritesWidth = 129.0;
  CGFloat tabsGap = 15.0;
  CGFloat tabsWidth = MAX(0.0, filtersWidth - favoritesWidth - tabsGap);
  self.tabsCard.frame = NSMakeRect(outerMargin, filtersY, tabsWidth, tabsHeight);
  self.favoritesCard.frame = NSMakeRect(NSMaxX(self.tabsCard.frame) + tabsGap, filtersY, favoritesWidth, tabsHeight);

  CGFloat tabsCardWidth = self.tabsCard.bounds.size.width;
  CGFloat tabsCardHeight = self.tabsCard.bounds.size.height;
  CGFloat slot_width = tabsCardWidth / 4.0;
  for (NSInteger i = 0; i < 4 && i < (NSInteger)self.filterButtons.count; i++) {
    NSButton *button = self.filterButtons[(NSUInteger)i];
    CGFloat width = (i == 3) ? (tabsCardWidth - slot_width * 3.0) : slot_width;
    button.frame = NSMakeRect(slot_width * (CGFloat)i, 0.0, width, tabsCardHeight);
  }
  for (NSInteger i = 0; i < (NSInteger)self.tabDividers.count; i++) {
    NSView *divider = self.tabDividers[(NSUInteger)i];
    divider.frame = NSMakeRect(slot_width * (CGFloat)(i + 1), 8.0, 1.0, 26.0);
  }
  if (self.filterButtons.count >= 5) {
    self.filterButtons[4].frame = self.favoritesCard.bounds;
  }

  // History list grows with the window.
  CGFloat listTop = filtersY - sectionGap;
  CGFloat listHeight = MAX(0.0, listTop - listBottom);
  self.listCard.frame = NSMakeRect(outerMargin, listBottom, W - outerMargin * 2.0, listHeight);
  self.listScrollView.frame = self.listCard.bounds;

  // Footer count anchors bottom-left; the "Clear All" + ⌘K group stays centered.
  // (countIcon/countLabel use fixed bottom-left coordinates that don't depend on W.)
  const CGFloat clearGroupWidth = 108.0 + 15.0 + 48.0;
  CGFloat clearGroupX = floor((W - clearGroupWidth) * 0.5);
  self.clearButton.frame = NSMakeRect(clearGroupX, 20.0, 108.0, 29.0);
  self.clearHint.frame = NSMakeRect(clearGroupX + 123.0, 20.0, 48.0, 29.0);
  for (NSView *subview in self.clearHint.subviews) subview.frame = self.clearHint.bounds;

  // Reflow visible rows to the list's new width.
  [self relayoutItemViews];
}

- (void)windowDidResize:(NSNotification *)notification {
  if (notification.object != self.panel) return;
  [self relayoutPanelChrome];
  [self persistPanelSize];
}

- (void)windowDidMove:(NSNotification *)notification {
  // Position is intentionally not persisted — see kMZWindowWidthKey docs above.
  (void)notification;
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
  [button sendActionOn:NSEventMaskLeftMouseDown];
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

  NSRunningApplication *current = NSRunningApplication.currentApplication;
  NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
  if (frontmost != nil && frontmost.processIdentifier != current.processIdentifier) {
    self.previousFrontmostApp = frontmost;
  }

  // Reset interaction state every time the panel is summoned. Users expect a
  // fresh "top of history, ready to type" view -- not whatever row/search was
  // left over from the previous session.
  if (self.searchField.stringValue.length > 0) {
    self.searchField.stringValue = @"";
    if (self.callbacks.on_search) self.callbacks.on_search("");
  }
  // Force a visual refresh of the selection even if the controller already had
  // row 0 marked selected (selectRowAtIndex early-returns when nothing changes).
  // Resetting to -1 first guarantees `updateItemViewAtIndex` repaints the cell's
  // selected border every time the panel pops open.
  self.selectedRowIndex = -1;
  if (self.rows.count > 0) {
    [self selectRowAtIndex:0 focusList:NO];
  }

  // We need the app active so the search field's NSText field-editor can
  // receive keystrokes (NSEvent local monitors only fire while the app is
  // active). The frontmost-snap-back issue this *used* to cause for
  // auto-paste is now addressed by routing the ⌘V keystroke directly to
  // the previous app's PID via CGEventPostToPid — see mz_post_command_v_to_pid.
  [NSApp activateIgnoringOtherApps:YES];
  [self.panel orderFrontRegardless];
  [self.panel makeKeyAndOrderFront:nil];
  [self focusSearchFieldSelectingText:NO];

  // makeKeyAndOrderFront restores any scroll position AppKit autosaved, so the
  // pin-to-top reset must happen after the panel is on screen. The async
  // refresh that follows will then call scrollSelectedRowToVisible against
  // row 0, keeping the document at origin if rows arrived in the meantime.
  NSClipView *clipView = self.listScrollView.contentView;
  if (clipView != nil) {
    [clipView scrollToPoint:NSZeroPoint];
    [self.listScrollView reflectScrolledClipView:clipView];
  }

  if (self.callbacks.on_toggle) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self.callbacks.on_toggle) self.callbacks.on_toggle();
    });
  }
}

- (void)hide {
  [self.panel orderOut:nil];
  [self restorePreviousFrontmostApp];
}

- (void)restorePreviousFrontmostApp {
  NSRunningApplication *target = self.previousFrontmostApp;
  self.previousFrontmostApp = nil;
  if (target == nil || target.isTerminated) return;
  if (target.processIdentifier == NSRunningApplication.currentApplication.processIdentifier) return;
  // ignoringOtherApps is deprecated on macOS 14+; passing 0 still re-activates the app
  // with the standard semantics (front of the activation order, restores key window).
  [target activateWithOptions:0];
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
  mz_debug_log(@"selectRowID rowID=%lld index=%ld", rowID, (long)index);
  if (index == NSNotFound) return;
  [self selectRowAtIndex:index focusList:YES];
}

- (BOOL)performRowAction:(MZAppAction)action rowID:(int64_t)rowID hidesPanel:(BOOL)hidesPanel {
  if (rowID == 0) return NO;
  // Snapshot the previous-frontmost PID *before* hide() runs, since hide()
  // clears that property on its way out. Stash it back temporarily so the
  // PASTE branch in mz_app_dispatch_action can read it.
  NSRunningApplication *snapshot = self.previousFrontmostApp;
  mz_debug_log(@"performRowAction action=%d rowID=%lld hides=%d selected=%ld scrollY=%.1f prevPid=%d",
               (int)action,
               rowID,
               hidesPanel ? 1 : 0,
               (long)self.selectedRowIndex,
               self.listScrollView.contentView.documentVisibleRect.origin.y,
               snapshot ? snapshot.processIdentifier : 0);
  if (action == MZ_APP_ACTION_TOGGLE_PIN) {
    [self optimisticallyTogglePinForRowID:rowID];
  }
  if (hidesPanel) [self hide];
  // Re-pin the snapshot for the duration of dispatch so PASTE can read it.
  self.previousFrontmostApp = snapshot;
  mz_app_dispatch_action(self, action, rowID);
  self.previousFrontmostApp = nil;
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

- (CGFloat)totalListContentHeight {
  CGFloat rowHeight = [self rowHeightAtIndex:0];
  CGFloat contentHeight = kMZListTopPadding + (CGFloat)self.rows.count * rowHeight + kMZListBottomPadding;
  return MAX(contentHeight, self.listScrollView.contentSize.height);
}

- (NSRect)frameForRowAtIndex:(NSInteger)index {
  CGFloat width = self.listScrollView.contentSize.width;
  CGFloat rowHeight = [self rowHeightAtIndex:index];
  CGFloat y = kMZListTopPadding + (CGFloat)index * rowHeight;
  return NSMakeRect(0, y, width, rowHeight);
}

- (MZClipboardCellView *)visibleItemViewForRowIndex:(NSInteger)index {
  for (MZClipboardCellView *view in self.itemViews) {
    if (view.rowIndex == index) return view;
  }
  return nil;
}

- (MZClipboardCellView *)dequeueItemView {
  MZClipboardCellView *view = self.reusableItemViews.lastObject;
  if (view != nil) {
    [self.reusableItemViews removeLastObject];
  } else {
    view = [[MZClipboardCellView alloc] initWithFrame:NSZeroRect];
    view.identifier = @"clipboard-item-visible";
  }
  if (view.superview != self.listContentView) {
    [self.listContentView addSubview:view];
  }
  [self.itemViews addObject:view];
  return view;
}

- (void)recycleVisibleItemAtArrayIndex:(NSUInteger)index {
  MZClipboardCellView *view = self.itemViews[index];
  [view dismissImagePreview];
  view.rowIndex = -1;
  view.objectValue = nil;
  view.interactionTarget = nil;
  [view removeFromSuperview];
  [self.itemViews removeObjectAtIndex:index];
  // Keep a small pool: enough for one tall window + overscan, without holding
  // onto stale view graphs forever after aggressive resizing.
  if (self.reusableItemViews.count < 64) [self.reusableItemViews addObject:view];
}

- (void)visibleRowStart:(NSInteger *)start end:(NSInteger *)end {
  if (self.rows.count == 0 || self.listScrollView == nil) {
    *start = 0;
    *end = 0;
    return;
  }
  NSRect visible = self.listScrollView.contentView.documentVisibleRect;
  CGFloat rowHeight = [self rowHeightAtIndex:0];
  static const NSInteger kOverscanRows = 4;
  NSInteger first = (NSInteger)floor((NSMinY(visible) - kMZListTopPadding) / rowHeight) - kOverscanRows;
  NSInteger last = (NSInteger)ceil((NSMaxY(visible) - kMZListTopPadding) / rowHeight) + kOverscanRows;
  if (first < 0) first = 0;
  if (last > (NSInteger)self.rows.count) last = (NSInteger)self.rows.count;
  if (last < first) last = first;
  *start = first;
  *end = last;
}

- (void)updateVisibleItemViews {
  uint64_t t0 = mach_absolute_time();
  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  CGFloat width = self.listScrollView.contentSize.width;
  CGFloat height = [self totalListContentHeight];
  self.listContentView.frame = NSMakeRect(0, 0, width, height);

  NSInteger start = 0;
  NSInteger end = 0;
  [self visibleRowStart:&start end:&end];

  for (NSInteger i = (NSInteger)self.itemViews.count - 1; i >= 0; i--) {
    MZClipboardCellView *view = self.itemViews[(NSUInteger)i];
    if (view.rowIndex < start || view.rowIndex >= end) {
      [self recycleVisibleItemAtArrayIndex:(NSUInteger)i];
    }
  }

  for (NSInteger index = start; index < end; index++) {
    MZClipboardCellView *view = [self visibleItemViewForRowIndex:index];
    if (view == nil) {
      view = [self dequeueItemView];
      view.rowIndex = index;
    }

    NSRect frame = [self frameForRowAtIndex:index];
    if (!NSEqualRects(view.frame, frame)) view.frame = frame;
    MZRow *item = self.rows[(NSUInteger)index];
    [view configureWithRow:item
                  selected:(index == self.selectedRowIndex)
                    target:self
                      icon:[self iconForRow:item]
              revealEnabled:[self rowSupportsReveal:item]];
  }

  [CATransaction commit];
  static mach_timebase_info_data_t tb = {0, 0};
  if (tb.denom == 0) mach_timebase_info(&tb);
  uint64_t ns = (mach_absolute_time() - t0) * tb.numer / tb.denom;
  mz_debug_log(@"visible_item_views_ns=%llu rows=%lu visible=%ld-%ld views=%lu reuse=%lu",
               (unsigned long long)ns,
               (unsigned long)self.rows.count,
               (long)start,
               (long)end,
               (unsigned long)self.itemViews.count,
               (unsigned long)self.reusableItemViews.count);
}

- (void)listScrollViewDidScroll:(NSNotification *)notification {
  (void)notification;
  [self updateVisibleItemViews];
}

- (void)relayoutItemViews {
  [self updateVisibleItemViews];
}

- (void)reloadItemViews {
  // Tab/filter switches funnel through here and historically triggered an
  // O(N) configureWithRow per cell with implicit Core Animation transactions,
  // which on N≈200 rows pushed visible repaint into 50–200ms territory.
  // Wrap the rebuild in a single transaction with disabled actions to skip
  // CALayer animation queueing, and batch the timing in a debug log so we
  // can sanity-check the path on a real device.
  uint64_t t0 = mach_absolute_time();
  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  [self updateVisibleItemViews];

  [CATransaction commit];
  static mach_timebase_info_data_t tb = {0, 0};
  if (tb.denom == 0) mach_timebase_info(&tb);
  uint64_t ns = (mach_absolute_time() - t0) * tb.numer / tb.denom;
  mz_debug_log(@"reload_item_views_ns=%llu rows=%lu",
               (unsigned long long)ns, (unsigned long)self.rows.count);
}

- (void)refreshVisibleSelectionState {
  for (NSUInteger i = 0; i < self.itemViews.count; i++) {
    MZClipboardCellView *view = self.itemViews[i];
    if (view.rowIndex < 0 || view.rowIndex >= (NSInteger)self.rows.count) continue;
    MZRow *item = self.rows[(NSUInteger)view.rowIndex];
    [view configureWithRow:item
                  selected:(view.rowIndex == self.selectedRowIndex)
                    target:self
                      icon:[self iconForRow:item]
              revealEnabled:[self rowSupportsReveal:item]];
  }
}

- (void)updateItemViewAtIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)self.rows.count) return;
  MZClipboardCellView *view = [self visibleItemViewForRowIndex:index];
  if (view == nil) return;
  MZRow *item = self.rows[(NSUInteger)index];
  [view configureWithRow:item
                selected:(index == self.selectedRowIndex)
                  target:self
                    icon:[self iconForRow:item]
            revealEnabled:[self rowSupportsReveal:item]];
}

- (void)scrollSelectedRowToVisible {
  if (self.selectedRowIndex < 0 || self.selectedRowIndex >= (NSInteger)self.rows.count) return;
  NSClipView *clipView = self.listScrollView.contentView;
  if (clipView == nil) return;

  NSRect targetRect = [self frameForRowAtIndex:self.selectedRowIndex];
  NSRect visibleRect = clipView.documentVisibleRect;
  if (NSContainsRect(visibleRect, targetRect) || NSIntersectsRect(visibleRect, targetRect)) {
    if (NSMinY(targetRect) >= NSMinY(visibleRect) && NSMaxY(targetRect) <= NSMaxY(visibleRect)) return;
  }

  NSPoint newOrigin = visibleRect.origin;
  if (NSMinY(targetRect) < NSMinY(visibleRect)) {
    newOrigin.y = NSMinY(targetRect);
  } else if (NSMaxY(targetRect) > NSMaxY(visibleRect)) {
    newOrigin.y = NSMaxY(targetRect) - NSHeight(visibleRect);
  } else {
    return;
  }

  CGFloat maxOffset = MAX(0.0, NSHeight(self.listContentView.bounds) - NSHeight(visibleRect));
  newOrigin.y = MIN(MAX(0.0, newOrigin.y), maxOffset);
  [clipView scrollToPoint:newOrigin];
  [self.listScrollView reflectScrolledClipView:clipView];
  [self updateVisibleItemViews];
}

- (void)selectRowAtIndex:(NSInteger)index focusList:(BOOL)focusList {
  if (self.rows.count == 0) return;
  NSInteger bounded = MAX(0, MIN(index, (NSInteger)self.rows.count - 1));
  mz_debug_log(@"selectRowAtIndex requested=%ld bounded=%ld previous=%ld focusList=%d scrollY=%.1f",
               (long)index,
               (long)bounded,
               (long)self.selectedRowIndex,
               focusList ? 1 : 0,
               self.listScrollView.contentView.documentVisibleRect.origin.y);
  if (bounded == self.selectedRowIndex && !focusList) return;
  NSInteger previous = self.selectedRowIndex;
  self.selectedRowIndex = bounded;
  // Fast path: only the selection chrome changes, so flip layer attrs on the
  // two affected cells. No full reconfigure, no relayout (row height is a
  // constant; frames don't move).
  uint64_t t0 = mach_absolute_time();
  MZClipboardCellView *previousView = [self visibleItemViewForRowIndex:previous];
  MZClipboardCellView *boundedView = [self visibleItemViewForRowIndex:bounded];
  if (previousView != nil) [previousView applySelectedAppearance:NO];
  if (boundedView != nil) [boundedView applySelectedAppearance:YES];
  static mach_timebase_info_data_t tb = {0, 0};
  if (tb.denom == 0) mach_timebase_info(&tb);
  uint64_t ns = (mach_absolute_time() - t0) * tb.numer / tb.denom;
  mz_debug_log(@"selection_repaint_ns=%llu rows=%lu", (unsigned long long)ns,
               (unsigned long)self.itemViews.count);
  [self scrollSelectedRowToVisible];
  boundedView = [self visibleItemViewForRowIndex:bounded];
  if (boundedView != nil) [boundedView applySelectedAppearance:YES];
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

- (void)repaintFilterChromeImmediately {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self updateFilterButtons];
  for (NSButton *button in self.filterButtons) {
    button.needsDisplay = YES;
    [button displayIfNeeded];
  }
  [self.tabsCard displayIfNeeded];
  [self.favoritesCard displayIfNeeded];
  [CATransaction commit];
}

- (void)updateCountLabel {
  // Pull every label fresh through mz_t so it tracks language changes as well.
  NSUInteger count = self.rows.count;
  NSString *unit = mz_t(count == 1 ? @"item" : @"items");
  self.countLabel.stringValue = [NSString stringWithFormat:@"%lu %@", (unsigned long)count, unit];
}

- (NSComparisonResult)compareRow:(MZRow *)lhs withRow:(MZRow *)rhs {
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
  MZFilterMode next = (MZFilterMode)sender.tag;
  if (next == self.filterMode) return;
  int64_t selectedRowID = [self selectedItem] ? [self selectedItem].rowID : 0;
  self.filterMode = next;
  self.filterChangeGeneration += 1;
  NSUInteger generation = self.filterChangeGeneration;

  // Make the tab chrome react in the same event turn. The list rebuild below
  // can still touch hundreds of rows, but the user's click should get visual
  // acknowledgement immediately instead of waiting behind that work.
  [self repaintFilterChromeImmediately];

  dispatch_async(dispatch_get_main_queue(), ^{
    if (generation != self.filterChangeGeneration) return;
    [self applyCurrentFilterPreservingSelection:selectedRowID];
  });
}

- (void)selectRowForItemView:(MZClipboardCellView *)sender {
  MZRow *row = [sender.objectValue isKindOfClass:[MZRow class]] ? sender.objectValue : nil;
  if (row == nil) return;
  mz_debug_log(@"selectRowForItemView rowID=%lld title=%@", row.rowID, row.title);
  [self selectRowID:row.rowID];
}

- (void)showMenuFromView:(NSView *)view {
  if (view == nil) return;
  [self.actionsMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(view.bounds)) inView:view];
}

- (void)focusSearchFieldSelectingText:(BOOL)selectAll {
  if (self.searchField == nil) return;
  [self.panel makeFirstResponder:self.searchField];
  if (selectAll) [self.searchField selectText:nil];
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
  mz_debug_log(@"pasteRow button rowID=%lld", sender.rowID);
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

- (void)switchLanguageToEnglish:(id)sender {
  (void)sender;
  mz_lang_set(MZLangEnglish);
}

- (void)switchLanguageToChinese:(id)sender {
  (void)sender;
  mz_lang_set(MZLangChinese);
}

- (void)changeHistoryLimit:(NSMenuItem *)sender {
  NSInteger value = sender.tag;
  if (value <= 0) return;
  self.maxItemsLimit = value;
  [NSUserDefaults.standardUserDefaults setInteger:value forKey:kMZMaxItemsDefaultsKey];
  [self updateHistoryLimitMenu];
  if (self.callbacks.on_max_items_change != NULL) {
    self.callbacks.on_max_items_change((int64_t)value);
  }
}

- (void)handleLanguageChange:(NSNotification *)note {
  (void)note;
  [self applyLocalization];
}

- (void)updateHistoryLimitMenu {
  if (self.historyLimitMenuItem == nil) return;
  self.historyLimitMenuItem.title = mz_t(@"History Limit");
  for (NSMenuItem *item in self.historyLimitMenuItem.submenu.itemArray) {
    item.title = mz_max_items_title(item.tag);
    item.state = (item.tag == self.maxItemsLimit) ? NSControlStateValueOn : NSControlStateValueOff;
  }
}

- (void)applyLocalization {
  // Re-translate every static string we can reach. Per-row subtitles are reset
  // through reloadItemViews below, which calls mz_subtitle_for_row again.
  if (self.statusItem != nil) self.statusItem.button.toolTip = mz_t(@"Maccy");
  if (self.pinButton != nil) self.pinButton.toolTip = mz_t(@"Keep window on top");
  if (self.searchField != nil) self.searchField.placeholderString = mz_t(@"Search clipboard history...");

  // Filter tabs (4 main + favorites). Order in self.filterButtons matches insertion.
  if (self.filterButtons.count >= 5) {
    NSArray<NSString *> *tabs = @[ mz_t(@"All"), mz_t(@"Text"), mz_t(@"Links"), mz_t(@"Images") ];
    for (NSUInteger i = 0; i < tabs.count; i++) self.filterButtons[i].title = tabs[i];
    self.filterButtons[4].title = mz_t(@"☆  Favorites");
    [self updateFilterButtons];
  }

  // Footer button.
  if (self.clearButton != nil) self.clearButton.title = mz_t(@"Clear All");

  // Actions menu items (preserve our well-known order).
  if (self.actionsMenu.itemArray.count >= 9) {
    self.actionsMenu.itemArray[0].title = mz_t(@"Toggle Favorite");
    self.actionsMenu.itemArray[1].title = mz_t(@"Paste as Plain Text");
    self.actionsMenu.itemArray[2].title = mz_t(@"Reveal");
    // index 3 is a separator
    self.actionsMenu.itemArray[4].title = mz_t(@"Clear Unpinned");
    self.actionsMenu.itemArray[5].title = mz_t(@"Clear All");
    // index 6 is a separator
    self.actionsMenu.itemArray[7].title = mz_t(@"Language");
  }
  [self updateHistoryLimitMenu];
  // Sync the radio-style state on the language submenu.
  if (self.languageMenuItem.submenu.itemArray.count >= 2) {
    NSMenuItem *enItem = self.languageMenuItem.submenu.itemArray[0];
    NSMenuItem *zhItem = self.languageMenuItem.submenu.itemArray[1];
    enItem.state = (gLang == MZLangEnglish) ? NSControlStateValueOn : NSControlStateValueOff;
    zhItem.state = (gLang == MZLangChinese) ? NSControlStateValueOn : NSControlStateValueOff;
  }

  // Re-render rows so subtitles + count label refresh.
  [self updateCountLabel];
  [self reloadItemViews];
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

  if (event.keyCode == 53) {
    [self hide];
    return YES;
  }

  if (hasCommand && mz_app_matches_command_key(event, 3, @"f")) {
    [self focusSearchFieldSelectingText:YES];
    return YES;
  }
  // ⌘A / ⌘C / ⌘X / ⌘V inside the search field: we don't ship an Edit menu,
  // so AppKit never dispatches the standard responder-chain action. Forward
  // them to the focused field editor manually so text selection / clipboard
  // round-tripping works as users expect.
  if (hasCommand && !hasOption && !hasShift) {
    NSResponder *first = self.panel.firstResponder;
    NSText *editor = [first isKindOfClass:[NSText class]] ? (NSText *)first : nil;
    if (editor != nil) {
      if (mz_app_matches_command_key(event, 0, @"a")) { [editor selectAll:nil]; return YES; }
      if (mz_app_matches_command_key(event, 8, @"c")) { [editor copy:nil]; return YES; }
      if (mz_app_matches_command_key(event, 7, @"x")) { [editor cut:nil]; return YES; }
    }
  }
  if (hasCommand && mz_app_matches_command_key(event, 40, @"k")) {
    [self clearAll:nil];
    return YES;
  }
  if (hasCommand && mz_app_matches_command_key(event, 9, @"v")) {
    if (hasOption) return [self performSelectedAction:MZ_APP_ACTION_PASTE_PLAIN hidesPanel:YES];
    return [self performSelectedAction:MZ_APP_ACTION_PASTE hidesPanel:YES];
  }
  if (hasCommand && mz_app_matches_command_key(event, 35, @"p")) {
    return [self performSelectedAction:MZ_APP_ACTION_TOGGLE_PIN hidesPanel:NO];
  }
  if (hasCommand && mz_app_matches_command_key(event, 15, @"r")) {
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
  if (self.callbacks.on_search == NULL) return;
  // Coalesce rapid keystrokes; only the last query within the debounce window runs the
  // DB refresh. Schedule on common modes so we still fire while AppKit is in the
  // event-tracking run loop mode during typing.
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dispatchPendingSearch:) object:nil];
  [self performSelector:@selector(dispatchPendingSearch:)
             withObject:nil
             afterDelay:0.03
                inModes:@[ NSRunLoopCommonModes ]];
}

- (void)dispatchPendingSearch:(id)sender {
  (void)sender;
  if (self.callbacks.on_search == NULL || self.searchField == nil) return;
  self.callbacks.on_search(self.searchField.stringValue.UTF8String);
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
    mz_lang_load();
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

  // Tracing this single boundary lets us tell from `/tmp/maccy-debug.log` whether
  // a "stale panel" report is upstream (Zig never pushed) or downstream (push
  // happened but the apply block never ran).
  mz_debug_log(@"set_rows count=%zu", count);

  dispatch_async(dispatch_get_main_queue(), ^{
    int64_t selectedRowID = 0;
    MZRow *selected = [gController selectedItem];
    if (selected != nil) selectedRowID = selected.rowID;

    gController.allRows = copy;
    [gController applyCurrentFilterPreservingSelection:selectedRowID];
    mz_debug_log(@"set_rows applied count=%lu selected=%lld",
                 (unsigned long)copy.count, selectedRowID);
  });
}

void mz_app_invalidate_preview_cache(void) {
  [mz_preview_cache() removeAllObjects];
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
