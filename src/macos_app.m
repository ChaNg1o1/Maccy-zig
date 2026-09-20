#import "macos_app.h"
#import "macos_hotkey.h"
#import "macos_paste.h"
#import "macos_jev.h"
#import "macos_ocr.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <stdarg.h>

// Serial queue for every Zig callback that touches SQLite. Keeps multi-MB
// capture work (snapshot copy + SHA-256 + insert) and cascading DELETEs off
// the main thread, and serializes all database access on one queue.
static dispatch_queue_t mz_db_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Utility QoS keeps the idle poll tick (and capture/prune work) on
    // E-cores instead of inheriting the main thread's user-interactive QoS
    // through the timer's dispatch_async. User-blocking waits still get
    // priority donation, so paste latency is unaffected.
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    queue = dispatch_queue_create("io.github.chang1o1.MaccyZig.db", attr);
  });
  return queue;
}

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
      @"Settings": @"设置",
      @"Close": @"关闭",
      @"Actions": @"操作",
      @"Actions…": @"操作…",
      // Search
      @"Search clipboard history...": @"搜索剪贴板历史…",
      @"Search Clipboard History": @"搜索剪贴板历史",
      @"Search": @"搜索",
      @"Clear Search": @"清空搜索",
      // Empty states
      @"No Matches": @"没有匹配项",
      @"Try another search or clear the query.": @"请尝试其他关键词，或清空当前搜索。",
      @"No Items in This Filter": @"此筛选中没有条目",
      @"Switch to All to see your clipboard history.": @"切换到「全部」查看剪贴板历史。",
      @"Clipboard History Is Empty": @"剪贴板历史为空",
      @"Copy something and it will appear here.": @"复制内容后，它会显示在这里。",
      @"Show All": @"显示全部",
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
      @"Hotkey": @"全局快捷键",
      @"Global Hotkey": @"全局快捷键",
      @"General": @"通用",
      @"History": @"历史",
      @"Shortcuts & Permissions": @"快捷键与权限",
      @"Direct paste requires Accessibility permission.": @"自动粘贴需要「辅助功能」权限。",
      @"Disabled": @"禁用",
      @"English": @"English",
      @"中文": @"中文",
      @"Quit": @"退出",
      @"Paste": @"粘贴",
      @"Select": @"选择",
      @"Press Return to paste": @"按回车键粘贴",
      @"Add to Favorites": @"添加到收藏",
      @"Remove from Favorites": @"从收藏中移除",
      // Clear-all confirmation
      @"Clear all clipboard history?": @"清空全部剪贴板历史？",
      @"This removes every item, including favorites. This cannot be undone.":
        @"这将删除所有条目（包括收藏），且无法撤销。",
      @"Hotkey registration failed. Another app may already be using this shortcut.":
        @"快捷键注册失败，可能已被其他应用占用。",
      // Accessibility permission alert
      @"Grant Permission…": @"申请辅助功能权限…",
      @"Accessibility permission required": @"需要辅助功能权限",
      @"Accessibility permission already granted": @"辅助功能权限已授予",
      @"MaccyZig needs Accessibility permission so it can paste a clipboard "
       "item into the app you were using. Click \"Open Settings\", enable "
       "MaccyZig under Privacy & Security → Accessibility, then come back "
       "and try again.":
        @"MaccyZig 需要「辅助功能」权限才能把剪贴板内容自动粘贴到你正在使用的应用里。"
        @"请点击「打开设置」，在「隐私与安全性 → 辅助功能」中勾选 MaccyZig，然后回来重试。",
      @"MaccyZig already has the permission it needs to paste into other apps.":
        @"MaccyZig 已经具备粘贴到其他应用所需的权限，无需重复授权。",
      @"Open Settings": @"打开设置",
      @"Cancel": @"取消",
      @"OK": @"好",
      // Jev suggestions
      @"Jev picked": @"Jev 选中",
      @"Suggestions": @"智能推荐",
      @"API Key": @"API Key",
      @"API key": @"API key",
      @"Jev Service": @"Jev 服务",
      @"Custom": @"自定义",
      @"Custom endpoint…": @"自定义地址…",
      @"Custom Jev endpoint": @"自定义 Jev 地址",
      @"Any address that speaks TypeSafe's API — a Cloudflare AI Gateway custom provider in front of "
       "api.typesafe.ai, for one. The base URL is everything before /v1/systemone. The extra header is only "
       "for gateways that authenticate separately; leave it empty otherwise. The API key is set in Settings "
       "as usual.":
        @"任何兼容 TypeSafe 接口的地址都可以，例如架在 api.typesafe.ai 前面的 Cloudflare AI Gateway 自定义 "
        @"provider。Base URL 是 /v1/systemone 之前的部分。附加请求头只给需要单独鉴权的网关用，不需要就留空。"
        @"API key 仍然在设置里填写。",
      @"Base URL": @"Base URL",
      @"Model": @"模型",
      @"Extra header": @"附加请求头",
      @"Header value": @"请求头的值",
      @"Save": @"保存",
      @"Enter the service's base URL": @"请填写服务的 Base URL",
      @"The base URL has to start with https://": @"Base URL 必须以 https:// 开头",
      @"The base URL cannot carry a query, a fragment or credentials": @"Base URL 里不能带查询参数、片段或账号密码",
      @"That is not a valid header name": @"这不是合法的请求头名称",
      @"That header is set by MaccyZig itself": @"这个请求头由 MaccyZig 自己设置，不能覆盖",
      @"Enter a value for the header": @"请填写请求头的值",
      @"The header value cannot span lines": @"请求头的值不能换行",
      @"Could not save the header value to the keychain": @"无法把请求头的值保存到钥匙串",
      @"Set up the custom endpoint first": @"请先配置自定义地址",
      @"Save & Check": @"保存并验证",
      @"Checking the key…": @"正在验证 API key…",
      @"API key works — suggestions are on.": @"API key 可用 — 已开启智能推荐。",
      @"Enter an API key first": @"请先填写 API key",
      @"The keychain refused to store the key": @"钥匙串拒绝保存该 API key",
      @"Add an API key to start getting suggestions.": @"填写 API key 后即可开始获得推荐。",
      @"Off — nothing leaves this Mac.": @"已关闭 — 没有任何内容离开这台 Mac。",
      @"On — sends previews, the field and the screen around it. Never credentials.":
        @"已开启 — 会发送预览、输入框及其周围的屏幕文字；凭证永不发送。",
      @"Jev timed out": @"Jev 响应超时",
      @"Log Jev Decisions": @"查看 Jev 判断过程",
      @"Jev Inspector": @"Jev 判断过程",
      @"Nothing traced yet. Open the clipboard panel over another app.":
        @"还没有记录。在其他应用上唤出剪贴板面板即可。",
      @"Last screen read: %.0f×%.0f px": @"最近一次屏幕读取：%.0f×%.0f 像素",
      @"No screen read yet — apps that report a text field never need one.":
        @"还没有屏幕读取 —— 能提供输入框信息的应用不需要。",
      @"Allow Screen Reading…": @"开启屏幕读取…",
      // Edit menu — never shown (LSUIElement), but VoiceOver reads the titles.
      @"Edit": @"编辑",
      @"Undo": @"撤销",
      @"Redo": @"重做",
      @"Cut": @"剪切",
      @"Copy": @"拷贝",
      @"Select All": @"全选",
      @"Open Screen Recording…": @"打开屏幕录制设置…",
      @"Open Accessibility…": @"打开辅助功能设置…",
      @"Allowed. MaccyZig pastes straight into the app you were using.":
        @"已开启。MaccyZig 可以直接粘贴到你刚才使用的应用。",
      @"Lets Jev read the screen just above where you paste.": @"让 Jev 读取你粘贴位置正上方的屏幕内容。",
      @"Allowed. Jev reads the screen just above where you paste.":
        @"已开启。Jev 会读取你粘贴位置正上方的屏幕内容。",
      @"Needs an API key below.": @"还需要在下方填写 API key。",
      @"Needs Accessibility to see what you are pasting into.":
        @"还需要「辅助功能」权限才能知道你要粘贴到哪里。",
      @"Needs Screen Recording to read the screen just above where you paste.":
        @"还需要「屏幕录制」权限，用于读取你粘贴位置正上方的屏幕内容。",
      @"Allow screen reading": @"开启屏幕读取",
      @"Enable MaccyZig under Privacy & Security → Screen Recording, then quit and reopen "
       "MaccyZig. Each time the panel opens, Jev will then read the part of the window just "
       "above where you paste — never the whole screen.":
        @"请在「隐私与安全性 → 屏幕录制」中勾选 MaccyZig，然后退出并重新打开 MaccyZig。"
        @"之后每次打开面板时，Jev 会读取你粘贴位置正上方的那一块窗口内容，不会读取整个屏幕。",
      @"Suggest what to paste (Jev)": @"用 Jev 推荐要粘贴的内容",
      @"Sends item previews, the focused field and the text on screen around it to the Jev service "
       "chosen in Settings. Off by default.":
        @"会把条目预览、当前输入框及其周围的屏幕文字发送给设置里选定的 Jev 服务，默认关闭。",
      @"Jev is unreachable": @"Jev 无法连接",
      @"Jev is rate limited": @"Jev 请求过于频繁",
      @"Jev rejected the API key": @"Jev 拒绝了该 API key",
      @"Jev returned no answer": @"Jev 没有返回结果",
      @"Jev returned an unreadable response": @"Jev 返回了无法解析的结果",
      @"Jev request could not be encoded": @"Jev 请求构造失败",
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
  // so the visible string follows the active language. Bundle ids remain the
  // stable storage/search key; the UI resolves them to the installed app name.
  NSInteger kind = [[row valueForKey:@"contentKind"] integerValue];
  NSString *app = [row valueForKey:@"app"];
  if (kind == MZ_APP_CONTENT_IMAGE) return mz_t(@"Copied as Image");
  if (kind == MZ_APP_CONTENT_FILE) return mz_t(@"Copied as File");
  if (app.length > 0) {
    static NSCache<NSString *, NSString *> *display_name_cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      display_name_cache = [NSCache new];
      display_name_cache.countLimit = 128;
    });

    NSString *cached = [display_name_cache objectForKey:app];
    if (cached != nil) return cached;

    NSURL *app_url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:app];
    NSString *display_name = nil;
    if (app_url != nil) {
      [app_url getResourceValue:&display_name forKey:NSURLLocalizedNameKey error:nil];
      if (display_name.length == 0) display_name = app_url.lastPathComponent.stringByDeletingPathExtension;
    }
    if (display_name.length == 0) display_name = app;
    [display_name_cache setObject:display_name forKey:app];
    return display_name;
  }
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

static BOOL mz_handle_tab_key(NSView *view, NSEvent *event) {
  if (event.keyCode != 48 || view.window == nil) return NO;
  BOOL backwards = (mz_app_modifier_flags(event) & NSEventModifierFlagShift) != 0;
  NSView *target = backwards ? view.previousKeyView : view.nextKeyView;
  if (target != nil) [view.window makeFirstResponder:target];
  return YES;
}

static BOOL mz_app_is_enter_event(NSEvent *event) {
  return event.keyCode == 36 || event.keyCode == 76;
}

static BOOL mz_activate_button_for_key(NSButton *button, NSEvent *event) {
  if (!mz_app_is_enter_event(event) && event.keyCode != 49) return NO;
  [button performClick:nil];
  return YES;
}

// Match by the layout-resolved character first: hardware keyCodes name
// different characters on non-QWERTY layouts, and an OR of both means e.g.
// Dvorak's ⌘T could trigger the destructive Clear All bound to keyCode 40.
// The keyCode is only a fallback for events that carry no characters.
static BOOL mz_app_matches_command_key(NSEvent *event, unsigned short keyCode, NSString *fallback) {
  NSString *characters = event.charactersIgnoringModifiers.lowercaseString ?: @"";
  if (characters.length > 0) return [characters isEqualToString:(fallback ?: @"")];
  return event.keyCode == keyCode;
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

// The two star glyphs are requested for every row configure; building a fresh
// NSImage + symbol configuration each time is measurable on the scroll path.
static NSImage *mz_star_image(BOOL filled) {
  static NSImage *star = nil;
  static NSImage *starFill = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    star = mz_symbol_image(@"star", 18.0);
    starFill = mz_symbol_image(@"star.fill", 18.0);
  });
  return filled ? starFill : star;
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

- (void)setEnabled:(BOOL)enabled {
  [super setEnabled:enabled];
  self.needsDisplay = YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)becomeFirstResponder {
  BOOL accepted = [super becomeFirstResponder];
  if (accepted) self.needsDisplay = YES;
  return accepted;
}

- (BOOL)resignFirstResponder {
  BOOL resigned = [super resignFirstResponder];
  if (resigned) self.needsDisplay = YES;
  return resigned;
}

- (void)keyDown:(NSEvent *)event {
  if (mz_handle_tab_key(self, event)) return;
  if (mz_activate_button_for_key(self, event)) return;
  [super keyDown:event];
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
  NSColor *title_color = !self.enabled ? mz_text_muted() : (self.active ? NSColor.whiteColor : mz_text_primary());
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

  if (self.window.firstResponder == self) {
    [mz_primary_orange_shadow() setStroke];
    NSBezierPath *focus = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2.0, 2.0)
                                                          xRadius:5.0
                                                          yRadius:5.0];
    focus.lineWidth = 2.0;
    [focus stroke];
  }
}
@end

@interface MZSettingsChoiceButton : NSButton
@property(nonatomic, strong) NSTextField *valueLabel;
@property(nonatomic, strong) NSImageView *chevronView;
- (void)setDisplayTitle:(NSString *)title;
@end

@implementation MZSettingsChoiceButton
- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.title = @"";
    self.bordered = NO;
    self.focusRingType = NSFocusRingTypeNone;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 8.0;
    self.layer.backgroundColor = mz_color(28, 31, 35, 1.0).CGColor;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = mz_card_border().CGColor;

    _valueLabel = mz_label(@"", [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], mz_text_primary());
    [self addSubview:_valueLabel];

    _chevronView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _chevronView.image = mz_symbol_image(@"chevron.up.chevron.down", 12.0);
    _chevronView.contentTintColor = mz_text_secondary();
    _chevronView.accessibilityElement = NO;
    [self addSubview:_chevronView];
  }
  return self;
}

- (void)setDisplayTitle:(NSString *)title {
  self.valueLabel.stringValue = title ?: @"";
  self.accessibilityValue = self.valueLabel.stringValue;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)layout {
  [super layout];
  self.valueLabel.frame = NSMakeRect(14.0, floor((NSHeight(self.bounds) - 22.0) * 0.5), MAX(0.0, NSWidth(self.bounds) - 52.0), 22.0);
  self.chevronView.frame = NSMakeRect(NSWidth(self.bounds) - 30.0, floor((NSHeight(self.bounds) - 18.0) * 0.5), 18.0, 18.0);
}

// The label and chevron inside are decoration: a click on them is a click on
// the button. Whether the point is in the button at all is left to AppKit --
// `point` arrives in the superview's coordinates, and an earlier version here
// compared it with `bounds`, which made every one of these buttons dead except
// where the two coordinate spaces happened to overlap.
- (NSView *)hitTest:(NSPoint)point {
  return [super hitTest:point] != nil ? self : nil;
}

- (BOOL)becomeFirstResponder {
  BOOL accepted = [super becomeFirstResponder];
  if (accepted) {
    self.layer.borderWidth = 2.0;
    self.layer.borderColor = mz_primary_orange_shadow().CGColor;
  }
  return accepted;
}

- (BOOL)resignFirstResponder {
  BOOL resigned = [super resignFirstResponder];
  if (resigned) {
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = mz_card_border().CGColor;
  }
  return resigned;
}

- (void)keyDown:(NSEvent *)event {
  if (mz_handle_tab_key(self, event)) return;
  if (mz_activate_button_for_key(self, event)) return;
  [super keyDown:event];
}
@end

// While a text field is being edited the first responder is the shared field
// editor, not the field; resolve back to the field the user sees.
static NSView *mz_focused_view(NSWindow *window) {
  NSResponder *responder = window.firstResponder;
  if ([responder isKindOfClass:[NSText class]] && ((NSText *)responder).isFieldEditor) {
    id delegate = ((NSText *)responder).delegate;
    if ([delegate isKindOfClass:[NSView class]]) return delegate;
  }
  return [responder isKindOfClass:[NSView class]] ? (NSView *)responder : nil;
}

@interface MZSettingsWindow : NSWindow
// Styled container around a borderless text field; it carries the focus
// border the field itself cannot draw in this design.
@property(nonatomic, weak) NSView *textWell;
@end

@implementation MZSettingsWindow
- (BOOL)makeFirstResponder:(NSResponder *)responder {
  BOOL changed = [super makeFirstResponder:responder];
  NSView *well = self.textWell;
  if (well != nil) {
    BOOL focused = [mz_focused_view(self) isDescendantOf:well];
    well.layer.borderWidth = focused ? 2.0 : 1.0;
    well.layer.borderColor = (focused ? mz_primary_orange_shadow() : mz_card_border()).CGColor;
  }
  return changed;
}

- (void)sendEvent:(NSEvent *)event {
  if (event.type == NSEventTypeKeyDown && event.keyCode == 48) {
    NSView *current = mz_focused_view(self) ?: self.initialFirstResponder;
    BOOL backwards = (mz_app_modifier_flags(event) & NSEventModifierFlagShift) != 0;
    NSView *target = backwards ? current.previousKeyView : current.nextKeyView;
    if (target != nil) [self makeFirstResponder:target];
    return;
  }
  [super sendEvent:event];
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
@property(nonatomic, copy) NSString *sourceContext;
// Jev rated this entry plausible but did not pick it. Marked, never
// auto-selected -- a second highlight would just be a second selection.
@property(nonatomic) BOOL jevRunnerUp;
// Jev's pick for this panel open, with its probability for the row's label.
// A pick has to be unmistakable: it used to look exactly like any selected
// row, with the only trace a line of small text in the footer.
@property(nonatomic) BOOL jevPicked;
@property(nonatomic) double jevConfidence;
@end
@implementation MZRow
@end

@interface MZRowActionButton : NSButton
@property(nonatomic) int64_t rowID;
@end
@implementation MZRowActionButton
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

- (void)keyDown:(NSEvent *)event {
  if (mz_handle_tab_key(self, event)) return;
  if (mz_activate_button_for_key(self, event)) return;
  [super keyDown:event];
}
@end

// A key cap that can be pressed. It has neither an image nor a title for
// AppKit to dim, so it shows the press itself.
@interface MZKeyCapButton : MZRowActionButton
@end
@implementation MZKeyCapButton
- (void)mouseDown:(NSEvent *)event {
  CGColorRef resting = CGColorRetain(self.layer.backgroundColor);
  self.layer.backgroundColor = mz_color(58, 63, 70, 1.0).CGColor;
  [super mouseDown:event];  // tracks the mouse; returns when it comes back up
  self.layer.backgroundColor = resting;
  CGColorRelease(resting);
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
@property(nonatomic, strong) NSTimer *previewTimer;
@property(nonatomic) BOOL previewEnabled;
@property(nonatomic) NSInteger rowIndex;
@property(nonatomic) NSUInteger configuredGeneration;
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

// Interaction tracing for development only. The log records clipboard item
// titles, so in release builds it must not exist: shipping a world-readable
// /tmp file with clipboard contents is a privacy leak. The macro form also
// keeps release builds from evaluating the format arguments.
#if MZ_ENABLE_DEBUG_LOG
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
#else
#define mz_debug_log(...) ((void)0)
#endif

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

// Text previews need a dwell: without it a bubble fired on every pass of the
// mouse across the list on the way to the gear or a star. Image rows show
// nothing useful until hovered, so they open at once.
static const NSTimeInterval kMZTextPreviewHoverDelay = 0.45;

- (void)dismissImagePreview {
  [self.previewTimer invalidate];
  self.previewTimer = nil;
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
    // Entries are stored with their encoded byte size as cost; without a
    // ceiling, 96 multi-MB decoded screenshots pin hundreds of MB of memory.
    cache.totalCostLimit = 64 * 1024 * 1024;
  });
  return cache;
}

- (NSViewController *)buildImagePreviewControllerForRow:(MZRow *)row {
  NSNumber *cacheKey = @(row.rowID);
  NSImage *image = [mz_preview_cache() objectForKey:cacheKey];
  if (image == nil) {
    // Database reads are serialized on the db queue; hop over synchronously
    // so this hover path can't interleave with a capture in progress.
    __block const unsigned char *bytes = NULL;
    __block size_t len = 0;
    dispatch_sync(mz_db_queue(), ^{
      bytes = mz_app_copy_image_preview(row.rowID, &len);
    });
    if (bytes == NULL || len == 0) return nil;

    // Decode straight to a popover-sized bitmap: NSImage initWithData would
    // defer a full-resolution decode of a multi-MB screenshot to first draw,
    // which is the visible lag between hover and preview.
    NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:len freeWhenDone:NO];
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    CGImageRef thumb = NULL;
    if (source != NULL) {
      NSDictionary *options = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge id)kCGImageSourceShouldCacheImmediately: @YES,
        // 2x the popover's 360pt max edge, for Retina.
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @720,
      };
      thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
      CFRelease(source);
    }
    mz_app_free_buffer(bytes, len);
    if (thumb == NULL) return nil;
    size_t px_w = CGImageGetWidth(thumb);
    size_t px_h = CGImageGetHeight(thumb);
    // Point size at 2x, but never upscale a small original past its pixels.
    CGFloat pt_scale = (px_w >= 720 || px_h >= 720) ? 2.0 : 1.0;
    image = [[NSImage alloc] initWithCGImage:thumb size:NSMakeSize(px_w / pt_scale, px_h / pt_scale)];
    NSUInteger cost = CGImageGetBytesPerRow(thumb) * px_h;
    CGImageRelease(thumb);
    [mz_preview_cache() setObject:image forKey:cacheKey cost:cost];
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
  // Without a surface of its own the bubble inherits NSPopover's vibrancy and
  // you read the clipboard entry through whatever window is behind it.
  content.layer.backgroundColor = mz_panel_fill().CGColor;
  content.layer.borderWidth = 1.0;
  content.layer.borderColor = mz_panel_border().CGColor;

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
  text.selectable = NO;
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

// A preview is only worth covering the screen for when it shows something the
// row itself cannot: a thumbnail, or text the cell had to truncate. Popping a
// bubble over "2026-09-19" -- already fully visible -- is pure obstruction.
- (BOOL)previewWouldRevealMore {
  MZRow *row = [self.objectValue isKindOfClass:[MZRow class]] ? self.objectValue : nil;
  if (row == nil) return NO;
  if ((row.contentKind == MZ_APP_CONTENT_IMAGE) || row.hasImage) return YES;

  NSString *body = row.title ?: @"";
  if (body.length == 0) return NO;
  if ([body rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return YES;

  CGFloat available = self.titleLabel.frame.size.width;
  if (available <= 0.0) return YES;  // pre-layout: let the popover decide
  NSFont *font = self.titleLabel.font ?: [NSFont systemFontOfSize:13];
  CGFloat needed = [body sizeWithAttributes:@{NSFontAttributeName : font}].width;
  return needed > available;
}

- (void)scheduleImagePreview {
  if (!self.previewEnabled || self.previewPopover.shown) return;
  [self.previewTimer invalidate];
  if (![self previewWouldRevealMore]) {
    self.previewTimer = nil;
    return;
  }
  MZRow *row = [self.objectValue isKindOfClass:[MZRow class]] ? self.objectValue : nil;
  if (row != nil && (row.contentKind == MZ_APP_CONTENT_IMAGE || row.hasImage)) {
    self.previewTimer = nil;
    [self showImagePreviewIfNeeded];
    return;
  }
  __weak typeof(self) weakSelf = self;
  self.previewTimer = [NSTimer scheduledTimerWithTimeInterval:kMZTextPreviewHoverDelay
                                                      repeats:NO
                                                        block:^(NSTimer *timer) {
    (void)timer;
    [weakSelf showImagePreviewIfNeeded];
  }];
}

- (void)showImagePreviewIfNeeded {
  self.previewTimer = nil;
  if (!self.previewEnabled || self.previewPopover.shown) return;
  MZRow *row = [self.objectValue isKindOfClass:[MZRow class]] ? self.objectValue : nil;
  if (row == nil) return;
  if (![self previewWouldRevealMore]) return;

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
    // Transient closes itself on the next click anywhere -- and swallows that
    // click, so the row the user was aiming for never got selected. We already
    // close on exit, scroll and mouse-down, so own the lifetime outright.
    self.previewPopover.behavior = NSPopoverBehaviorApplicationDefined;
  }
  // The fade-in is another ~0.2s of waiting on the one preview meant to be instant.
  self.previewPopover.animates = !useImage;
  self.previewPopover.contentViewController = controller;
  // Anchored to the whole cell, not the inner container: from the container's
  // edge the bubble sat on top of the list's scroller.
  [self.previewPopover showRelativeToRect:self.bounds ofView:self preferredEdge:NSRectEdgeMaxX];
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
    _iconView.accessibilityElement = NO;
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
    _favoriteButton.focusRingType = NSFocusRingTypeDefault;
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
  NSString *subtitle = mz_subtitle_for_row(row);
  if (row.jevPicked) {
    subtitle = [NSString stringWithFormat:@"✦ %@ · %.0f%% · %@", mz_t(@"Jev picked"), row.jevConfidence * 100.0, subtitle];
  } else if (row.jevRunnerUp) {
    subtitle = [@"✦ " stringByAppendingString:subtitle];
  }
  self.subtitleLabel.stringValue = subtitle;
  self.iconView.image = icon;
  self.timeLabel.stringValue = [mz_time_formatter() stringFromDate:[NSDate dateWithTimeIntervalSince1970:row.copiedAt]];

  self.favoriteButton.target = target;
  self.favoriteButton.action = @selector(togglePinFromButton:);
  self.favoriteButton.rowID = row.rowID;
  self.favoriteButton.image = mz_star_image(row.pinned);
  self.favoriteButton.contentTintColor = row.pinned ? mz_warning_yellow() : mz_text_secondary();
  self.favoriteButton.toolTip = mz_t(row.pinned ? @"Remove from Favorites" : @"Add to Favorites");
  self.favoriteButton.accessibilityLabel = self.favoriteButton.toolTip;

  self.rowButton.target = target;
  self.rowButton.action = @selector(selectRowFromButton:);
  self.rowButton.rowID = row.rowID;
  NSString *select_label = row.title.length > 0
      ? [NSString stringWithFormat:@"%@: %@", mz_t(@"Select"), row.title]
      : mz_t(@"Select");
  self.rowButton.accessibilityLabel = select_label;
  self.rowButton.accessibilityHelp = mz_t(@"Press Return to paste");

  [self applySelectedAppearance:selected];
  self.dividerView.hidden = NO;
  self.subtitleLabel.textColor = row.jevPicked ? mz_primary_orange_shadow() : mz_text_secondary();
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
  MZRow *row = [self.objectValue isKindOfClass:[MZRow class]] ? self.objectValue : nil;
  // Jev's pick keeps its accent whether or not it is still the selected row:
  // arrowing away should not erase the suggestion the user is weighing.
  BOOL picked = row.jevPicked;
  NSColor *fill_color = picked ? [mz_primary_orange() colorWithAlphaComponent:selected ? 0.16 : 0.07]
                               : (selected ? mz_selected_fill() : NSColor.clearColor);
  NSColor *border_color = picked ? [mz_primary_orange_shadow() colorWithAlphaComponent:selected ? 0.95 : 0.45]
                                 : (selected ? mz_selected_border() : NSColor.clearColor);
  CGColorRef fill = fill_color.CGColor;
  CGColorRef border = border_color.CGColor;
  CGFloat border_width = picked ? 1.5 : (selected ? 1.0 : 0.0);
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
  // No NSTrackingMouseMoved: the dwell timer is armed once on entry, so
  // re-arming on every drift inside the row would only keep pushing the
  // preview away, and the move events cost CPU on every pass over the list.
  self.previewTrackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                          options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                            owner:self
                                                         userInfo:nil];
  [self addTrackingArea:self.previewTrackingArea];
}

- (void)mouseDown:(NSEvent *)event {
  // The user is acting on the row, not reading it.
  [self dismissImagePreview];
  if (self.interactionTarget != nil &&
      [self.interactionTarget respondsToSelector:@selector(selectRowForItemView:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.interactionTarget performSelector:@selector(selectRowForItemView:) withObject:self];
#pragma clang diagnostic pop
  }

  if (event.clickCount >= 2 && self.interactionTarget != nil &&
      [self.interactionTarget respondsToSelector:@selector(activateSelection:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.interactionTarget performSelector:@selector(activateSelection:) withObject:self];
#pragma clang diagnostic pop
  }
}

- (void)mouseEntered:(NSEvent *)event {
  (void)event;
  [self scheduleImagePreview];
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

  // right_margin reserves the timestamp + star column. It used to be 150,
  // which left a 32pt hole between the truncated title and the timestamp;
  // 134 keeps a 16pt gutter and hands the rest back to the title.
  CGFloat right_margin = 134.0;
  self.titleLabel.frame = NSMakeRect(76, header_height - 35, container_width - 76 - right_margin, 23);
  self.subtitleLabel.frame = NSMakeRect(76, header_height - 58, container_width - 76 - right_margin, 18);
  self.timeLabel.frame = NSMakeRect(container_width - 118, header_height - 33, 72, 20);
  self.favoriteButton.frame = NSMakeRect(container_width - 40, header_height - 44, 32, 32);

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

    if (event.clickCount >= 2 && [target respondsToSelector:@selector(activateSelection:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [target performSelector:@selector(activateSelection:) withObject:rowView];
#pragma clang diagnostic pop
      return YES;
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
  if (mz_handle_tab_key(self, event)) return;
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
@property(nonatomic, strong) NSButton *footerActionsButton;
// Bottom-right footer strip: which entry Jev picked, or why it has none.
@property(nonatomic, strong) NSTextField *jevBadge;
@property(nonatomic, strong) NSMenuItem *jevMenuItem;
@property(nonatomic, strong) NSMenuItem *jevScreenMenuItem;
// Row Jev proposed this time the panel was opened, 0 when it proposed
// nothing. Recorded with the paste so the log shows overrides too.
@property(nonatomic) int64_t jevSuggestedRowID;
@property(nonatomic) double jevSuggestedConfidence;
// Rows Jev ranked second and third; marked, never auto-selected.
@property(nonatomic, strong) NSSet<NSNumber *> *jevRunnerUpRowIDs;
// Bumped for every suggestion attempt so a late database hop can tell it
// has been superseded.
@property(nonatomic) NSUInteger jevRequestGeneration;
// Set as soon as the user moves the selection, types, or clicks. A
// suggestion that lands afterwards must not yank what they chose.
@property(nonatomic) BOOL userDroveSelection;
// Frame of the element that had focus when the panel was summoned, so the
// screen reader looks at where the paste will land rather than at a corner.
@property(nonatomic, strong) NSButton *pinButton;
@property(nonatomic, strong) NSButton *settingsButton;
@property(nonatomic, strong) NSButton *searchClearButton;
@property(nonatomic, strong) id keyEventMonitor;
@property(nonatomic, strong) NSRunningApplication *previousFrontmostApp;
@property(nonatomic, strong) NSWindow *settingsWindow;
@property(nonatomic, strong) MZSettingsChoiceButton *settingsLanguageButton;
@property(nonatomic, strong) MZSettingsChoiceButton *settingsHistoryButton;
@property(nonatomic, strong) MZSettingsChoiceButton *settingsHotkeyButton;
@property(nonatomic, strong) NSSwitch *settingsJevSwitch;
@property(nonatomic, strong) NSSecureTextField *settingsJevKeyField;
@property(nonatomic, strong) NSTextField *settingsJevStatus;
@property(nonatomic, copy) NSArray *clickTraceMonitors;
@property(nonatomic, strong) MZSettingsChoiceButton *settingsJevServiceButton;
@property(nonatomic, strong) NSTextField *settingsAccessNote;
@property(nonatomic, strong) MZChamferedButton *settingsAccessButton;
@property(nonatomic, strong) NSTextField *settingsScreenNote;
@property(nonatomic, strong) MZChamferedButton *settingsScreenButton;
@property(nonatomic, strong) NSWindow *inspectorWindow;
@property(nonatomic, strong) NSTextView *inspectorText;
@property(nonatomic, strong) NSImageView *inspectorImage;
@property(nonatomic, strong) NSTextField *inspectorCaption;
@property(nonatomic, strong) NSButton *settingsJevSave;
// Chrome views referenced from -relayoutPanelChrome so the layout stays
// pixel-correct after the user resizes the window.
@property(nonatomic, strong) NSImageView *titleMark;
@property(nonatomic, strong) NSTextField *appTitleLabel;
@property(nonatomic, strong) NSView *searchBox;
@property(nonatomic, strong) NSButton *searchHint;
@property(nonatomic, strong) NSView *tabsCard;
@property(nonatomic, strong) NSMutableArray<NSView *> *tabDividers;
@property(nonatomic, strong) NSView *favoritesCard;
@property(nonatomic, strong) NSView *listCard;
@property(nonatomic, strong) NSView *emptyStateView;
@property(nonatomic, strong) NSTextField *emptyStateTitleLabel;
@property(nonatomic, strong) NSTextField *emptyStateBodyLabel;
@property(nonatomic, strong) NSButton *emptyStateActionButton;
@property(nonatomic) MZFilterMode filterMode;
@property(nonatomic) NSUInteger filterChangeGeneration;
// Bumped whenever self.rows is rebuilt; visible cells remember the generation
// they were configured against so the scroll path can skip reconfiguration.
@property(nonatomic) NSUInteger rowsGeneration;
@property(nonatomic) NSInteger selectedRowIndex;
@property(nonatomic) NSInteger maxItemsLimit;
@property(nonatomic) BOOL windowPinned;
// Declared for the C helpers above the implementation.
- (NSInteger)indexOfRowID:(int64_t)rowID inRows:(NSArray<MZRow *> *)rows;
- (void)stampJevMarksOnRows:(NSArray<MZRow *> *)rows;
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

// Every paste is logged against the app it landed in. That log is the only
// part of the suggestion that remembers this particular user.
static void mz_app_log_paste(MZAppController *controller, MZAppAction action, int64_t rowID) {
  if (action != MZ_APP_ACTION_PASTE && action != MZ_APP_ACTION_PASTE_PLAIN) return;
  NSString *bundle = controller.previousFrontmostApp.bundleIdentifier;
  if (bundle.length == 0) return;
  int64_t suggested = controller.jevSuggestedRowID;
  int was_suggested = (suggested == rowID) ? 1 : 0;
  // Position in the list the user was looking at. Opening the panel at all
  // suggests the newest entry is not what they came for; this is how we find
  // out how true that is for this user.
  int rank = (int)[controller indexOfRowID:rowID inRows:controller.rows];
  // What Jev was asked for this panel open, if it got as far as asking. Taken
  // (not copied) so one question can never be attributed to two pastes.
  NSString *sample = mz_jev_take_last_sample();
  dispatch_async(mz_db_queue(), ^{
    mz_app_record_paste(rowID, bundle.UTF8String, was_suggested, rank, suggested, sample.UTF8String);
  });
}

static void mz_app_dispatch_action(MZAppController *controller, MZAppAction action, int64_t rowID) {
  int target_pid = mz_app_target_pid_for_action(controller, action);
  mz_app_log_paste(controller, action, rowID);
  // All action callbacks touch SQLite on the Zig side — run them on the db
  // queue so clears and writes never block the UI thread.
  if (controller.actionCallback != NULL) {
    MZAppActionCallback callback = controller.actionCallback;
    dispatch_async(mz_db_queue(), ^{ callback(action, rowID, target_pid); });
    return;
  }

  void (*on_select)(int64_t, int, int) = controller.callbacks.on_select;
  void (*on_clear)(int) = controller.callbacks.on_clear;
  switch (action) {
    case MZ_APP_ACTION_COPY:
      if (on_select) dispatch_async(mz_db_queue(), ^{ on_select(rowID, 0, 0); });
      return;
    case MZ_APP_ACTION_PASTE:
    case MZ_APP_ACTION_PASTE_PLAIN: {
      // The previous frontmost app was captured in -show; passing its pid
      // through to the paste path lets us route ⌘V directly to that process
      // and bypass the frontmost-app race entirely.
      if (on_select) dispatch_async(mz_db_queue(), ^{ on_select(rowID, 1, target_pid); });
      return;
    }
    case MZ_APP_ACTION_CLEAR_UNPINNED:
      if (on_clear) dispatch_async(mz_db_queue(), ^{ on_clear(0); });
      return;
    case MZ_APP_ACTION_CLEAR_ALL:
      if (on_clear) dispatch_async(mz_db_queue(), ^{ on_clear(1); });
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

// An LSUIElement app shows no menu bar, but NSApp.mainMenu is still what makes
// AppKit dispatch ⌘X/⌘C/⌘V/⌘A/⌘Z down the responder chain. Without one, no
// text field anywhere in the app can be pasted into -- which is why the search
// field used to forward these by hand, and why the Settings API key field
// could not be pasted into at all.
static void mz_install_edit_menu(void) {
  if (NSApp.mainMenu != nil) return;
  NSMenu *main = [[NSMenu alloc] initWithTitle:@""];

  NSMenuItem *app_item = [main addItemWithTitle:@"MaccyZig" action:NULL keyEquivalent:@""];
  app_item.submenu = [[NSMenu alloc] initWithTitle:@"MaccyZig"];

  NSMenuItem *edit_item = [main addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""];
  NSMenu *edit = [[NSMenu alloc] initWithTitle:mz_t(@"Edit")];
  // Standard selectors, resolved against whatever holds first responder.
  [edit addItemWithTitle:mz_t(@"Undo") action:@selector(undo:) keyEquivalent:@"z"];
  [[edit addItemWithTitle:mz_t(@"Redo") action:@selector(redo:) keyEquivalent:@"z"]
      setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItemWithTitle:mz_t(@"Cut") action:@selector(cut:) keyEquivalent:@"x"];
  [edit addItemWithTitle:mz_t(@"Copy") action:@selector(copy:) keyEquivalent:@"c"];
  [edit addItemWithTitle:mz_t(@"Paste") action:@selector(paste:) keyEquivalent:@"v"];
  [edit addItemWithTitle:mz_t(@"Select All") action:@selector(selectAll:) keyEquivalent:@"a"];
  edit_item.submenu = edit;

  NSApp.mainMenu = main;
}

// "It will not click" is a statement about event routing, and routing cannot
// be seen from outside: whether the mouse-down reached this process at all,
// which window and view it was aimed at, and whether the app was active and
// the window key when it arrived. While tracing is on, every mouse-down says
// so in the inspector -- including the ones that fell on the panel's rectangle
// and were delivered to some other app, which is what a dead panel looks like
// from the inside.
//
// The monitors exist only while tracing is on: an app that is not being
// debugged has no business watching mouse-downs, its own or anyone else's.
- (void)syncClickTrace {
  if (!mz_jev_debug()) {
    for (id monitor in self.clickTraceMonitors) [NSEvent removeMonitor:monitor];
    self.clickTraceMonitors = nil;
    return;
  }
  if (self.clickTraceMonitors != nil) return;
  __weak typeof(self) weak_self = self;
  id local = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                                   handler:^NSEvent *_Nullable(NSEvent *event) {
    MZAppController *controller = weak_self;
    NSWindow *window = event.window;
    NSView *frame_view = window.contentView.superview ?: window.contentView;
    NSView *hit = [frame_view hitTest:event.locationInWindow];
    NSView *control = hit;
    while (control != nil && ![control isKindOfClass:NSControl.class]) control = control.superview;
    NSString *where = window == controller.panel ? @"panel"
        : window == controller.settingsWindow ? @"settings"
        : window == controller.inspectorWindow ? @"inspector"
        : window == nil ? @"no window" : NSStringFromClass(window.class);
    mz_jev_log(@"click: %@ at %.0f,%.0f -> %@%@ | app active=%d, window key=%d%@", where,
               event.locationInWindow.x, event.locationInWindow.y,
               hit != nil ? NSStringFromClass(hit.class) : @"nothing",
               control != nil && control != hit ? [@" in " stringByAppendingString:NSStringFromClass(control.class)] : @"",
               NSApp.isActive, window.isKeyWindow,
               [control isKindOfClass:NSControl.class] && !((NSControl *)control).enabled ? @", control is DISABLED" : @"");
    return event;
  }];
  // Mouse-downs that went to another app. Only worth a line when they fell
  // inside one of this app's visible windows: that click was meant for us.
  // Nothing else about them is looked at or kept.
  id global = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^(NSEvent *event) {
    (void)event;
    MZAppController *controller = weak_self;
    NSPoint at = NSEvent.mouseLocation;
    for (NSWindow *window in @[ controller.panel ?: (id)NSNull.null, controller.settingsWindow ?: (id)NSNull.null ]) {
      if (![window isKindOfClass:NSWindow.class] || !window.isVisible || !NSPointInRect(at, window.frame)) continue;
      mz_jev_log(@"click: at %.0f,%.0f on screen, inside the %@, was delivered to ANOTHER app (frontmost: %@) | "
                 @"app active=%d, window key=%d, ignores mouse=%d, level=%ld",
                 at.x, at.y, window == controller.panel ? @"panel" : @"settings window",
                 NSWorkspace.sharedWorkspace.frontmostApplication.localizedName, NSApp.isActive, window.isKeyWindow,
                 window.ignoresMouseEvents, (long)window.level);
    }
  }];
  self.clickTraceMonitors = [NSArray arrayWithObjects:local, global, nil];  // global is nil without permission
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  mz_install_edit_menu();
  [self syncClickTrace];
  // ~12s of model loading, once, on a utility queue. Starting it here means
  // the first panel that needs to read the screen does not pay for it.
  if (mz_jev_enabled()) mz_ocr_prewarm();
  // Tracing is a mode you leave on while chasing something, so bring its
  // window back rather than making the user find the menu item again.
  if (mz_jev_debug()) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self showJevInspector]; });
  }
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

  // Common modes so capture keeps running while menus are open or the panel
  // scrolls; tolerance lets the system coalesce wakeups for battery.
  NSTimer *pollTimer = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(pollTimer:) userInfo:nil repeats:YES];
  pollTimer.tolerance = 0.1;
  [NSRunLoop.mainRunLoop addTimer:pollTimer forMode:NSRunLoopCommonModes];

  // Keep the paste target fresh: whenever the user activates another app
  // (including while the panel floats pinned above it), that app becomes the
  // destination for the next paste.
  [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                     selector:@selector(workspaceDidActivateApp:)
                                                         name:NSWorkspaceDidActivateApplicationNotification
                                                       object:nil];
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
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (void)workspaceDidActivateApp:(NSNotification *)note {
  NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
  if (app == nil) return;
  if (app.processIdentifier == NSRunningApplication.currentApplication.processIdentifier) return;
  self.previousFrontmostApp = app;
}

- (void)pollTimer:(NSTimer *)timer {
  (void)timer;
  void (*poll)(void) = self.callbacks.on_poll;
  if (poll == NULL) return;
  // Skip the tick when the previous capture is still running (e.g. a huge
  // screenshot insert) so slow polls don't queue up behind each other.
  static dispatch_semaphore_t inflight;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ inflight = dispatch_semaphore_create(1); });
  if (dispatch_semaphore_wait(inflight, DISPATCH_TIME_NOW) != 0) return;
  dispatch_async(mz_db_queue(), ^{
    poll();
    dispatch_semaphore_signal(inflight);
  });
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
  self.titleMark.accessibilityElement = NO;
  self.titleMark.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
  [self.rootView addSubview:self.titleMark];

  self.appTitleLabel = mz_label(@"Maccy", [NSFont systemFontOfSize:25 weight:NSFontWeightBold], mz_text_primary());
  self.appTitleLabel.alignment = NSTextAlignmentCenter;
  self.appTitleLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
  [self.rootView addSubview:self.appTitleLabel];

  self.pinButton = [self chromeButtonWithSymbol:@"pin" action:@selector(toggleWindowPin:)];
  self.pinButton.toolTip = mz_t(@"Keep window on top");
  self.pinButton.accessibilityLabel = self.pinButton.toolTip;
  self.pinButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  [self.rootView addSubview:self.pinButton];

  self.settingsButton = [self chromeButtonWithSymbol:@"gearshape" action:@selector(showSettings:)];
  self.settingsButton.toolTip = mz_t(@"Settings");
  self.settingsButton.accessibilityLabel = self.settingsButton.toolTip;
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
  searchIcon.accessibilityElement = NO;
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
  self.searchField.accessibilityLabel = mz_t(@"Search Clipboard History");
  [self.searchBox addSubview:self.searchField];

  // A key cap with a border sits exactly where the clear button appears, and
  // it was a plain view: it looked pressable and did nothing. What looks like a
  // button is a button -- this one does what the shortcut it shows does.
  self.searchHint = [[MZKeyCapButton alloc] initWithFrame:NSZeroRect];
  self.searchHint.title = @"";
  self.searchHint.bordered = NO;
  self.searchHint.target = self;
  self.searchHint.action = @selector(focusSearchFromHint:);
  self.searchHint.toolTip = mz_t(@"Search");
  self.searchHint.accessibilityLabel = self.searchHint.toolTip;
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

  self.searchClearButton = [self chromeButtonWithSymbol:@"xmark.circle.fill" action:@selector(clearSearch:)];
  self.searchClearButton.image = mz_symbol_image(@"xmark.circle.fill", 17.0);
  self.searchClearButton.toolTip = mz_t(@"Clear Search");
  self.searchClearButton.accessibilityLabel = self.searchClearButton.toolTip;
  self.searchClearButton.hidden = YES;
  [self.searchBox addSubview:self.searchClearButton];

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

  self.emptyStateView = [[NSView alloc] initWithFrame:NSZeroRect];
  self.emptyStateView.hidden = YES;
  [self.listCard addSubview:self.emptyStateView];

  self.emptyStateTitleLabel = mz_label(@"", [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold], mz_text_primary());
  self.emptyStateTitleLabel.alignment = NSTextAlignmentCenter;
  [self.emptyStateView addSubview:self.emptyStateTitleLabel];

  self.emptyStateBodyLabel = mz_label(@"", [NSFont systemFontOfSize:13 weight:NSFontWeightRegular], mz_text_secondary());
  self.emptyStateBodyLabel.alignment = NSTextAlignmentCenter;
  self.emptyStateBodyLabel.maximumNumberOfLines = 2;
  self.emptyStateBodyLabel.lineBreakMode = NSLineBreakByWordWrapping;
  [self.emptyStateView addSubview:self.emptyStateBodyLabel];

  self.emptyStateActionButton = [NSButton buttonWithTitle:@"" target:self action:@selector(performEmptyStateAction:)];
  self.emptyStateActionButton.bezelStyle = NSBezelStyleRounded;
  self.emptyStateActionButton.focusRingType = NSFocusRingTypeDefault;
  [self.emptyStateView addSubview:self.emptyStateActionButton];

  NSImageView *countIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(outerMargin + contentInset, 25.5, 18, 18)];
  countIcon.image = mz_symbol_image(@"checkmark.circle", 16.0);
  countIcon.contentTintColor = mz_primary_orange_shadow();
  countIcon.accessibilityElement = NO;
  [self.rootView addSubview:countIcon];

  self.countLabel = mz_label(@"0 items", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], mz_text_secondary());
  self.countLabel.frame = NSMakeRect(outerMargin + contentInset + 28, 20.0, 120, 29.0);
  mz_center_text_field_vertically(self.countLabel);
  [self.rootView addSubview:self.countLabel];

  self.jevBadge = mz_label(@"", [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], mz_primary_orange_shadow());
  self.jevBadge.alignment = NSTextAlignmentRight;
  self.jevBadge.lineBreakMode = NSLineBreakByTruncatingTail;
  self.jevBadge.hidden = YES;
  mz_center_text_field_vertically(self.jevBadge);
  [self.rootView addSubview:self.jevBadge];

  self.footerActionsButton = [self footerTextButtonWithTitle:mz_t(@"Actions…") action:@selector(showHeaderMenu:)];
  self.footerActionsButton.accessibilityLabel = mz_t(@"Actions");
  self.footerActionsButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
  [self.rootView addSubview:self.footerActionsButton];

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
    @{@"title": mz_t(@"Toggle Favorite"), @"selector": NSStringFromSelector(@selector(toggleSelectedFavorite:)), @"symbol": @"star", @"key": @"p", @"modifiers": @(NSEventModifierFlagCommand)},
    @{@"title": mz_t(@"Paste as Plain Text"), @"selector": NSStringFromSelector(@selector(pasteSelectedAsPlainText:)), @"symbol": @"doc.on.doc", @"key": @"v", @"modifiers": @(NSEventModifierFlagCommand | NSEventModifierFlagOption)},
    @{@"title": mz_t(@"Reveal"), @"selector": NSStringFromSelector(@selector(revealSelected:)), @"symbol": @"magnifyingglass", @"key": @"r", @"modifiers": @(NSEventModifierFlagCommand)},
  ];
  for (NSDictionary *spec in menu_specs) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:spec[@"title"] action:NSSelectorFromString(spec[@"selector"]) keyEquivalent:spec[@"key"]];
    item.target = self;
    item.image = mz_menu_symbol_image(spec[@"symbol"]);
    item.keyEquivalentModifierMask = [spec[@"modifiers"] unsignedIntegerValue];
    [self.actionsMenu addItem:item];
  }
  [self.actionsMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *settings_item = [[NSMenuItem alloc] initWithTitle:mz_t(@"Settings") action:@selector(showSettings:) keyEquivalent:@","];
  settings_item.target = self;
  settings_item.image = mz_menu_symbol_image(@"gearshape");
  settings_item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [self.actionsMenu addItem:settings_item];

  // Jev lives in the Actions menu rather than the Settings window because the
  // Settings layout is fixed-coordinate; a checkbox here costs no relayout.
  NSMenuItem *jev_item = [[NSMenuItem alloc] initWithTitle:mz_t(@"Suggest what to paste (Jev)")
                                                    action:@selector(toggleJevSuggestions:)
                                             keyEquivalent:@""];
  jev_item.target = self;
  jev_item.image = mz_menu_symbol_image(@"sparkles");
  jev_item.toolTip = mz_t(@"Sends item previews, the focused field and the text on screen around it "
                           "to the Jev service chosen in Settings. Off by default.");
  jev_item.state = mz_jev_enabled() ? NSControlStateValueOn : NSControlStateValueOff;
  self.jevMenuItem = jev_item;
  [self.actionsMenu addItem:jev_item];

  // Permissions live in Settings now; this slot is for working out why a
  // suggestion did or did not appear, which is otherwise invisible.
  NSMenuItem *debug_item = [[NSMenuItem alloc] initWithTitle:mz_t(@"Log Jev Decisions")
                                                      action:@selector(toggleJevDebug:)
                                               keyEquivalent:@""];
  debug_item.target = self;
  debug_item.image = mz_menu_symbol_image(@"doc.text.magnifyingglass");
  debug_item.state = mz_jev_debug() ? NSControlStateValueOn : NSControlStateValueOff;
  self.jevScreenMenuItem = debug_item;
  [self.actionsMenu addItem:debug_item];

  NSMenuItem *quit_item = [[NSMenuItem alloc] initWithTitle:mz_t(@"Quit") action:@selector(quitApplication:) keyEquivalent:@"q"];
  quit_item.target = self;
  quit_item.image = mz_menu_symbol_image(@"xmark");
  quit_item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
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
  // Right-align both with the card column (W - outerMargin), not 1pt past it.
  self.settingsButton.frame = NSMakeRect(W - outerMargin - 30.0, H - chromeTop, 30.0, 30.0);
  self.pinButton.frame = NSMakeRect(W - outerMargin - 30.0 - 14.0 - 28.0, H - chromeTop + 1.0, 28.0, 28.0);

  // Search row — full width minus side margins.
  CGFloat searchY = H - 123.0;
  self.searchBox.frame = NSMakeRect(outerMargin, searchY, W - outerMargin * 2.0, searchHeight);
  CGFloat searchInner = self.searchBox.bounds.size.width;
  self.searchField.frame = NSMakeRect(contentTextX, 7.5, MAX(0.0, searchInner - contentTextX - 87.0), 32.0);
  self.searchHint.frame = NSMakeRect(searchInner - 58.0, 9.0, 43.0, 29.0);
  self.searchClearButton.frame = self.searchHint.frame;
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
  self.emptyStateView.frame = self.listCard.bounds;
  CGFloat empty_mid_y = NSMidY(self.emptyStateView.bounds);
  CGFloat empty_width = MAX(0.0, NSWidth(self.emptyStateView.bounds) - 64.0);
  self.emptyStateTitleLabel.frame = NSMakeRect(32.0, empty_mid_y + 20.0, empty_width, 24.0);
  self.emptyStateBodyLabel.frame = NSMakeRect(32.0, empty_mid_y - 28.0, empty_width, 40.0);
  self.emptyStateActionButton.frame = NSMakeRect(floor((NSWidth(self.emptyStateView.bounds) - 132.0) * 0.5),
                                                 empty_mid_y - 76.0,
                                                 132.0,
                                                 30.0);

  // Footer count anchors bottom-left; the neutral row-actions entry stays centered.
  // (countIcon/countLabel use fixed bottom-left coordinates that don't depend on W.)
  self.footerActionsButton.frame = NSMakeRect(floor((W - 116.0) * 0.5), 20.0, 116.0, 29.0);
  CGFloat jevX = NSMaxX(self.footerActionsButton.frame) + 12.0;
  self.jevBadge.frame = NSMakeRect(jevX, 20.0, MAX(0.0, W - outerMargin - contentInset - jevX), 29.0);

  // Reflow visible rows to the list's new width.
  [self relayoutItemViews];
  [self updateKeyViewLoop];
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
  NSButton *button = [[MZRowActionButton alloc] initWithFrame:NSZeroRect];
  button.title = @"";
  button.bordered = NO;
  button.image = mz_symbol_image(symbol, 20.0);
  button.contentTintColor = mz_text_primary();
  button.focusRingType = NSFocusRingTypeDefault;
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
  button.focusRingType = NSFocusRingTypeDefault;
  button.framed = tag == MZFilterModeFavorites;
  button.accentCorner = tag == MZFilterModeAll;
  button.target = self;
  button.action = @selector(changeFilter:);
  [button sendActionOn:NSEventMaskLeftMouseDown];
  return button;
}

- (NSButton *)footerTextButtonWithTitle:(NSString *)title action:(SEL)action {
  NSButton *button = [[MZRowActionButton alloc] initWithFrame:NSZeroRect];
  button.title = title;
  button.bordered = NO;
  button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  button.contentTintColor = mz_text_secondary();
  button.focusRingType = NSFocusRingTypeDefault;
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
  self.pinButton.accessibilityValue = @(self.windowPinned);
}

- (void)show {
  // Open on the display the user is working on (the one holding the mouse),
  // not whichever screen owns the key window.
  NSPoint mouse = NSEvent.mouseLocation;
  NSScreen *screen = NSScreen.mainScreen;
  for (NSScreen *candidate in NSScreen.screens) {
    if (NSMouseInRect(mouse, candidate.frame, NO)) {
      screen = candidate;
      break;
    }
  }
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
  // This has to happen before the panel takes activation a few lines down:
  // Chromium-based apps (browsers, Electron) report their real focused field
  // only while active, and "the whole web page" an instant later. Called on
  // every show, so an element held from an earlier one is never reused.
  mz_jev_capture_focus(mz_jev_enabled() && self.previousFrontmostApp != nil
                           ? self.previousFrontmostApp.processIdentifier : 0);

  // Reset interaction state every time the panel is summoned. Users expect a
  // fresh "top of history, ready to type" view -- not whatever row/search was
  // left over from the previous session.
  if (self.searchField.stringValue.length > 0) {
    self.searchField.stringValue = @"";
    void (*search)(const char *) = self.callbacks.on_search;
    if (search != NULL) dispatch_async(mz_db_queue(), ^{ search(""); });
  }
  [self updateSearchChrome];
  // Force a visual refresh of the selection even if the controller already had
  // row 0 marked selected (selectRowAtIndex early-returns when nothing changes).
  // Resetting to -1 first guarantees `updateItemViewAtIndex` repaints the cell's
  // selected border every time the panel pops open.
  self.selectedRowIndex = -1;
  self.userDroveSelection = NO;
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
  [self moveJevInspectorClearOfPanel];

  // makeKeyAndOrderFront restores any scroll position AppKit autosaved, so the
  // pin-to-top reset must happen after the panel is on screen. The async
  // refresh that follows will then call scrollSelectedRowToVisible against
  // row 0, keeping the document at origin if rows arrived in the meantime.
  NSClipView *clipView = self.listScrollView.contentView;
  if (clipView != nil) {
    [clipView scrollToPoint:NSZeroPoint];
    [self.listScrollView reflectScrolledClipView:clipView];
  }

  void (*toggle)(void) = self.callbacks.on_toggle;
  if (toggle != NULL) {
    dispatch_async(mz_db_queue(), ^{ toggle(); });
  }

  // Reading the screen takes ~200ms, and we are about to spend 200ms waiting
  // for rows anyway, so starting it here costs next to nothing on the clock.
  if (mz_jev_enabled() && self.previousFrontmostApp != nil) {
    mz_ocr_begin(self.previousFrontmostApp.processIdentifier);
  }

  // The refresh above lands through mz_app_set_rows a few milliseconds from
  // now; asking Jev before that would hand it the previous snapshot.
  // ponytail: fixed delay, move to a set_rows hook if a slow db makes it miss.
  [self clearJevSuggestion];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (self.panel.isVisible) [self requestJevSuggestion];
  });
}

- (void)hide {
  [self clearJevSuggestion];
  [self.panel orderOut:nil];
  [self restorePreviousFrontmostApp];
}

// Jev's answer is about the empty destination field, so it stops being
// relevant the moment the user narrows the list themselves.
- (void)clearJevSuggestion {
  mz_jev_cancel();
  mz_ocr_cancel();
  self.jevRequestGeneration += 1;
  // The pick wears an accent of its own now, so it counts as a mark to clear.
  BOOL had_marks = self.jevRunnerUpRowIDs.count > 0 || self.jevSuggestedRowID != 0;
  self.jevSuggestedRowID = 0;
  self.jevSuggestedConfidence = 0.0;
  self.jevRunnerUpRowIDs = nil;
  self.jevBadge.stringValue = @"";
  self.jevBadge.hidden = YES;
  if (had_marks) [self applyJevRunnerUpMarks];
}

// Row objects carry the mark so the cell can stay a pure function of its row.
// Bumping rowsGeneration is what makes the scroll path's reconfigure cache
// notice the change.
// The controller's ids are the truth; the flags on MZRow are a cache of them
// for the cell to read. Row objects are rebuilt from scratch on every refresh
// (a poll that saw a new copy, a search, a pin), so anything that replaces
// `allRows` has to stamp the new objects too or the marks silently vanish.
- (void)stampJevMarksOnRows:(NSArray<MZRow *> *)rows {
  for (MZRow *row in rows) {
    row.jevRunnerUp = [self.jevRunnerUpRowIDs containsObject:@(row.rowID)];
    row.jevPicked = self.jevSuggestedRowID != 0 && row.rowID == self.jevSuggestedRowID;
    row.jevConfidence = row.jevPicked ? self.jevSuggestedConfidence : 0.0;
  }
}

- (void)applyJevRunnerUpMarks {
  [self stampJevMarksOnRows:self.allRows];
  self.rowsGeneration += 1;
  [self reloadItemViews];
}

- (void)requestJevSuggestion {
  [self clearJevSuggestion];
  if (!mz_jev_enabled()) return;
  // A suggestion that arrives after the user has already made their own choice
  // is not help, it is theft of the selection.
  if (self.userDroveSelection) return;

  // Only the entries the user can actually see are candidates, capped so a
  // 500-item history does not turn into a 500-option question.
  // ponytail: flat cap, rank candidates first if the top 12 miss too often.
  NSUInteger count = MIN(self.rows.count, (NSUInteger)12);
  if (count < 2) return;
  NSArray<MZRow *> *snapshot = [self.rows subarrayWithRange:NSMakeRange(0, count)];
  NSString *destination = self.previousFrontmostApp.bundleIdentifier ?: @"";
  pid_t target = self.previousFrontmostApp != nil ? self.previousFrontmostApp.processIdentifier : 0;
  NSUInteger generation = ++self.jevRequestGeneration;

  // The paste log lives in SQLite, and the db queue may be busy hashing a
  // multi-megabyte capture, so read it there and come back rather than
  // stalling the panel that is already on screen.
  dispatch_async(mz_db_queue(), ^{
    int64_t *ids = calloc(count, sizeof(int64_t));
    MZPasteSignals *pastes = calloc(count, sizeof(MZPasteSignals));
    if (ids == NULL || pastes == NULL) { free(ids); free(pastes); return; }
    for (NSUInteger i = 0; i < count; i++) ids[i] = snapshot[i].rowID;
    mz_app_paste_signals(destination.UTF8String, ids, count, pastes);
    free(ids);

    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != self.jevRequestGeneration || !self.panel.isVisible || self.userDroveSelection) {
        free(pastes);
        return;
      }
      MZJevCandidate *candidates = calloc(count, sizeof(MZJevCandidate));
      if (candidates == NULL) { free(pastes); return; }
      for (NSUInteger i = 0; i < count; i++) {
        MZRow *row = snapshot[i];
        candidates[i].row_id = row.rowID;
        candidates[i].preview = row.title.UTF8String;
        candidates[i].source_app = row.app.UTF8String;
        candidates[i].content_kind = (int)row.contentKind;
        candidates[i].copied_at = row.copiedAt;
        candidates[i].copy_count = (int)row.copyCount;
        candidates[i].pinned = row.pinned ? 1 : 0;
        candidates[i].source_context = row.sourceContext.UTF8String;
        candidates[i].pastes_into_destination = pastes[i].pastes_into_destination;
        candidates[i].pasted_here_recently = pastes[i].pasted_here_recently;
        candidates[i].sibling_pasted_here_recently = pastes[i].sibling_pasted_here_recently;
      }
      // mz_jev_suggest copies everything it needs before it returns, so the
      // candidate array and its autoreleased UTF-8 buffers can go now.
      mz_jev_suggest(target, candidates, count,
                     ^(int64_t rowID, double confidence, NSArray<NSNumber *> *runnerUps, NSString *status) {
        if (!self.panel.isVisible || generation != self.jevRequestGeneration) return;
        // Between the request going out and the answer coming back the user
        // may have started choosing for themselves. They win.
        if (self.userDroveSelection) return;
        // The panel only ever shows a pick. Setup and service problems
        // (no key, timeout, rejected key) belong to Settings, which already
        // reports them; repeating them here nags on every open.
        (void)status;
        if (rowID <= 0) return;
        NSInteger index = [self indexOfRowID:rowID inRows:self.rows];
        if (index < 0) return;
        self.jevSuggestedRowID = rowID;
        self.jevSuggestedConfidence = confidence;
        self.jevRunnerUpRowIDs = [NSSet setWithArray:runnerUps ?: @[]];
        [self applyJevRunnerUpMarks];
        [self selectRowAtIndex:index focusList:NO];
        // selectRowAtIndex is also the user's path, so clear the flag it set.
        self.userDroveSelection = NO;
        self.jevBadge.textColor = mz_primary_orange_shadow();
        self.jevBadge.stringValue = [NSString stringWithFormat:@"✦ %@ · %.0f%%", mz_t(@"Jev picked"), confidence * 100.0];
        self.jevBadge.hidden = NO;
      });
      free(candidates);
      free(pastes);
    });
  });
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
  // Re-pin the snapshot so PASTE can read it, and leave it in place after
  // dispatch: nulling it here made any non-hiding action (star toggle, ⌘P,
  // Reveal) destroy the paste target for the rest of the session. The
  // workspace-activation observer keeps the property fresh from here on.
  self.previousFrontmostApp = snapshot;
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
    // Scroll fast path: a cell that already shows this row for the current
    // rows generation only needs its selection chrome diffed, not a full
    // reconfigure (symbol images, date formatting, forced layout).
    if (view.objectValue == item && view.configuredGeneration == self.rowsGeneration) {
      [view applySelectedAppearance:(index == self.selectedRowIndex)];
      continue;
    }
    [view configureWithRow:item
                  selected:(index == self.selectedRowIndex)
                    target:self
                      icon:[self iconForRow:item]
              revealEnabled:[self rowSupportsReveal:item]];
    view.configuredGeneration = self.rowsGeneration;
  }

  [CATransaction commit];
}

- (void)listScrollViewDidScroll:(NSNotification *)notification {
  (void)notification;
  // A popover is anchored to a row that is now moving; recycling only clears
  // the cells that scrolled off, so the rest would keep a stranded bubble.
  for (MZClipboardCellView *view in self.itemViews) [view dismissImagePreview];
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
  // CALayer animation queueing.
  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  [self updateVisibleItemViews];

  [CATransaction commit];
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
    view.configuredGeneration = self.rowsGeneration;
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
  view.configuredGeneration = self.rowsGeneration;
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
  MZClipboardCellView *previousView = [self visibleItemViewForRowIndex:previous];
  MZClipboardCellView *boundedView = [self visibleItemViewForRowIndex:bounded];
  if (previousView != nil) [previousView applySelectedAppearance:NO];
  if (boundedView != nil) [boundedView applySelectedAppearance:YES];
  [self scrollSelectedRowToVisible];
  boundedView = [self visibleItemViewForRowIndex:bounded];
  if (boundedView != nil) [boundedView applySelectedAppearance:YES];
  if (focusList) [self.panel makeFirstResponder:self.listContentView];
  [self updateFilterButtons];
}

- (void)moveSelectionByDelta:(NSInteger)delta focusList:(BOOL)focusList {
  self.userDroveSelection = YES;
  if (self.rows.count == 0) return;
  NSInteger selected = self.selectedRowIndex;
  if (selected < 0) selected = 0;
  [self selectRowAtIndex:selected + delta focusList:focusList];
}

- (void)moveSelectionByPageDelta:(NSInteger)delta focusList:(BOOL)focusList {
  self.userDroveSelection = YES;
  if (self.rows.count == 0) return;
  NSInteger step = MAX(1, (NSInteger)floor(self.listScrollView.contentView.bounds.size.height / 74.0) - 1);
  [self moveSelectionByDelta:delta * step focusList:focusList];
}

- (void)moveSelectionToBoundary:(BOOL)toEnd focusList:(BOOL)focusList {
  self.userDroveSelection = YES;
  if (self.rows.count == 0) return;
  [self selectRowAtIndex:(toEnd ? (NSInteger)self.rows.count - 1 : 0) focusList:focusList];
}

- (void)applyCurrentFilterPreservingSelection:(int64_t)selectedRowID {
  self.rowsGeneration += 1;
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
    button.state = active ? NSControlStateValueOn : NSControlStateValueOff;
    button.accessibilityLabel = button.title;
    button.accessibilityValue = @(active);
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
  self.countLabel.accessibilityLabel = self.countLabel.stringValue;
  [self updateEmptyState];
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
  self.userDroveSelection = YES;
  MZRow *row = [sender.objectValue isKindOfClass:[MZRow class]] ? sender.objectValue : nil;
  if (row == nil) return;
  mz_debug_log(@"selectRowForItemView rowID=%lld title=%@", row.rowID, row.title);
  [self selectRowID:row.rowID];
}

- (void)showMenuFromView:(NSView *)view {
  if (view == nil) return;
  MZRow *selected = [self selectedItem];
  for (NSMenuItem *item in self.actionsMenu.itemArray) {
    if (item.action == @selector(toggleSelectedFavorite:) ||
        item.action == @selector(pasteSelectedAsPlainText:)) {
      item.enabled = selected != nil;
    }
    if (item.action == @selector(revealSelected:)) {
      item.enabled = selected != nil && [self rowSupportsReveal:selected];
    }
  }
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

- (void)selectRowFromButton:(MZRowActionButton *)sender {
  [self selectRowID:sender.rowID];
  if (NSApp.currentEvent.clickCount >= 2) {
    [self performRowAction:MZ_APP_ACTION_PASTE rowID:sender.rowID hidesPanel:YES];
  }
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
  // Wipes everything including favorites with no undo — confirm first.
  NSAlert *alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = mz_t(@"Clear all clipboard history?");
  alert.informativeText = mz_t(@"This removes every item, including favorites. This cannot be undone.");
  [alert addButtonWithTitle:mz_t(@"Clear All")];
  [alert addButtonWithTitle:mz_t(@"Cancel")];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  mz_app_dispatch_action(self, MZ_APP_ACTION_CLEAR_ALL, 0);
}

- (void)quitApplication:(id)sender {
  (void)sender;
  mz_app_dispatch_action(self, MZ_APP_ACTION_QUIT, 0);
}

// The menu item and the Settings switch are two views of one flag; whichever
// the user touched, both end up here.
- (void)applyJevEnabled:(BOOL)enabled {
  mz_jev_set_enabled(enabled);
  if (enabled) mz_ocr_prewarm();
  self.jevMenuItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
  self.settingsJevSwitch.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
  [self updateJevSettingsStatus];
  // Switching this on is a request for the feature, not for a checkbox. Take
  // the user straight to whatever is still missing instead of leaving them to
  // discover later that nothing ever appears.
  if (enabled) {
    NSString *unused = nil;
    SEL fix = [self jevBlockerFix:&unused];
    if (fix != NULL) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [self performSelector:fix withObject:nil];
#pragma clang diagnostic pop
    }
  }
  if (enabled && self.panel.isVisible) {
    [self requestJevSuggestion];
  } else {
    [self clearJevSuggestion];
  }
}

- (void)toggleJevDebug:(id)sender {
  (void)sender;
  if (self.inspectorWindow.isVisible) {
    [self.inspectorWindow orderOut:nil];
    mz_jev_set_debug(NO);
    self.jevScreenMenuItem.state = NSControlStateValueOff;
    [self syncClickTrace];
    return;
  }
  mz_jev_set_debug(YES);
  self.jevScreenMenuItem.state = NSControlStateValueOn;
  [self syncClickTrace];
  [self showJevInspector];
}

// A live window rather than a log file: the question being answered is always
// "what just happened", and a file you have to go and open answers it too late.
- (void)buildJevInspector {
  if (self.inspectorWindow != nil) return;
  const CGFloat width = 720.0, height = 620.0, imageHeight = 220.0, captionHeight = 20.0;
  self.inspectorWindow = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, width, height)
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.inspectorWindow.title = mz_t(@"Jev Inspector");
  self.inspectorWindow.releasedWhenClosed = NO;
  self.inspectorWindow.minSize = NSMakeSize(520, 360);

  NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
  root.wantsLayer = YES;
  root.layer.backgroundColor = mz_panel_fill().CGColor;
  self.inspectorWindow.contentView = root;

  // What the screen reader actually saw, when it ran at all.
  self.inspectorImage = [[NSImageView alloc] initWithFrame:
      NSMakeRect(12, height - imageHeight - 12, width - 24, imageHeight)];
  self.inspectorImage.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.inspectorImage.imageAlignment = NSImageAlignTop;
  self.inspectorImage.wantsLayer = YES;
  self.inspectorImage.layer.backgroundColor = mz_card_fill().CGColor;
  self.inspectorImage.layer.cornerRadius = 8.0;
  self.inspectorImage.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [root addSubview:self.inspectorImage];

  self.inspectorCaption = mz_label(@"", [NSFont systemFontOfSize:11], mz_text_muted());
  self.inspectorCaption.frame = NSMakeRect(12, height - imageHeight - 12 - captionHeight, width - 24, captionHeight);
  self.inspectorCaption.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [root addSubview:self.inspectorCaption];

  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
      NSMakeRect(12, 12, width - 24, height - imageHeight - captionHeight - 36)];
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = NO;
  scroll.drawsBackground = YES;
  scroll.backgroundColor = mz_card_fill();
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.borderType = NSNoBorder;

  self.inspectorText = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
  self.inspectorText.editable = NO;
  self.inspectorText.drawsBackground = NO;
  self.inspectorText.textColor = mz_text_primary();
  self.inspectorText.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  self.inspectorText.textContainerInset = NSMakeSize(8, 8);
  self.inspectorText.verticallyResizable = YES;
  self.inspectorText.horizontallyResizable = NO;
  self.inspectorText.autoresizingMask = NSViewWidthSizable;
  self.inspectorText.textContainer.widthTracksTextView = YES;
  scroll.documentView = self.inspectorText;
  [root addSubview:scroll];

  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(refreshJevInspector)
                                             name:kMZJevLogChangedNotification
                                           object:nil];
}

- (void)showJevInspector {
  [self buildJevInspector];
  mz_jev_log(@"=== inspector opened; open the panel over an app to trace a suggestion ===");
  [self refreshJevInspector];
  [NSApp activateIgnoringOtherApps:YES];
  if (!self.inspectorWindow.isVisible) [self.inspectorWindow center];
  [self.inspectorWindow makeKeyAndOrderFront:nil];
  [self moveJevInspectorClearOfPanel];
}

// The panel opens centred, and the inspector opens centred, so the one window
// that shows what just happened was hidden by the thing that made it happen.
// Park it alongside whenever they would overlap, and leave it alone when the
// user has already moved it somewhere clear.
- (void)moveJevInspectorClearOfPanel {
  if (!self.inspectorWindow.isVisible || !self.panel.isVisible) return;
  NSRect screen = (self.panel.screen ?: NSScreen.mainScreen).visibleFrame;
  NSRect placed = mz_jev_inspector_frame(self.inspectorWindow.frame, self.panel.frame, screen);
  if (NSEqualRects(placed, self.inspectorWindow.frame)) return;
  [self.inspectorWindow setFrame:placed display:YES];
  // Behind the panel in the ordering, but no longer under it.
  [self.inspectorWindow orderFront:nil];
}

- (void)refreshJevInspector {
  if (self.inspectorText == nil) return;
  NSArray<NSString *> *lines = mz_jev_log_lines();
  self.inspectorText.string = lines.count > 0
      ? [lines componentsJoinedByString:@"\n"]
      : mz_t(@"Nothing traced yet. Open the clipboard panel over another app.");
  // Follow the tail: the newest line is the one being read.
  [self.inspectorText scrollRangeToVisible:NSMakeRange(self.inspectorText.string.length, 0)];

  CGImageRef capture = mz_ocr_copy_last_capture();
  if (capture != NULL) {
    NSSize size = NSMakeSize(CGImageGetWidth(capture), CGImageGetHeight(capture));
    self.inspectorImage.image = [[NSImage alloc] initWithCGImage:capture size:size];
    self.inspectorCaption.stringValue = [NSString stringWithFormat:
        mz_t(@"Last screen read: %.0f×%.0f px"), size.width, size.height];
    CGImageRelease(capture);
  } else {
    self.inspectorImage.image = nil;
    self.inspectorCaption.stringValue = mz_t(@"No screen read yet — apps that report a text field never need one.");
  }
}

- (void)requestScreenReadingPermission:(id)sender {
  (void)sender;
  if (mz_ocr_permitted()) {
    mz_open_privacy_pane(@"Privacy_ScreenCapture");
    return;
  }
  // Registers the app in the Screen Recording list and shows the system
  // prompt. macOS only applies the grant after a relaunch, so say so.
  mz_ocr_request_permission();
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = mz_t(@"Allow screen reading");
  alert.informativeText =
      mz_t(@"Enable MaccyZig under Privacy & Security → Screen Recording, then quit and reopen "
            "MaccyZig. Each time the panel opens, Jev will then read the part of the window just "
            "above where you paste — never the whole screen.");
  [alert addButtonWithTitle:mz_t(@"Open Settings")];
  [alert addButtonWithTitle:mz_t(@"Cancel")];
  [NSApp activateIgnoringOtherApps:YES];
  if ([alert runModal] == NSAlertFirstButtonReturn) mz_open_privacy_pane(@"Privacy_ScreenCapture");
  [self updateJevSettingsStatus];
}

- (void)toggleJevSuggestions:(id)sender {
  (void)sender;
  [self applyJevEnabled:!mz_jev_enabled()];
}

- (void)changeJevEnabledFromSettings:(NSSwitch *)sender {
  BOOL enabled = sender.state == NSControlStateValueOn;
  [self applyJevEnabled:enabled];
  // Switching on without a key leaves one obvious next step; put the caret there.
  if (enabled && mz_jev_api_key() == nil) {
    [self.settingsWindow makeFirstResponder:self.settingsJevKeyField];
  }
}

// Says what the feature will actually do right now, so an enabled switch with
// no key does not look like a working setup.
// Everything Jev needs before it can say anything, in the order the user
// should deal with them. Returns the selector to run to fix the first gap, or
// NULL when there is none, so the switch and the status line never disagree
// about whether this feature can actually work.
- (SEL)jevBlockerFix:(NSString **)message_out {
  if (mz_jev_api_key() == nil) {
    *message_out = @"Needs an API key below.";
    return @selector(focusJevKeyField);
  }
  if (mz_ax_is_trusted(0) == 0) {
    *message_out = @"Needs Accessibility to see what you are pasting into.";
    return @selector(requestAccessibilityPermission:);
  }
  if (!mz_ocr_permitted()) {
    *message_out = @"Needs Screen Recording to read the screen just above where you paste.";
    return @selector(requestScreenReadingPermission:);
  }
  *message_out = nil;
  return NULL;
}

- (void)focusJevKeyField {
  [self.settingsWindow makeFirstResponder:self.settingsJevKeyField];
}

// A permission row says what is true right now. Missing: a warning and the
// one prominent button that fixes it. Granted: a plain statement and an
// ordinary button that opens the system pane where it can be revoked. Both
// rows go through here so they cannot drift apart again -- the Accessibility
// row used to be a fixed orange "Grant Permission…" whatever the real state.
- (void)showPermission:(BOOL)granted
                  note:(NSTextField *)note
               centerY:(CGFloat)center_y
                button:(MZChamferedButton *)button
                  text:(NSArray<NSString *> *)text {
  if (note == nil) return;
  note.stringValue = mz_t(text[granted ? 0 : 1]);
  note.textColor = granted ? mz_text_secondary() : mz_warning_yellow();
  CGFloat height = ceil([note.cell cellSizeForBounds:NSMakeRect(0, 0, 222, CGFLOAT_MAX)].height);
  note.frame = NSMakeRect(16, center_y - height * 0.5, 222, height);
  button.title = mz_t(text[granted ? 2 : 3]);
  button.active = !granted;
}

- (void)updatePermissionRows {
  [self showPermission:mz_ax_is_trusted(0) != 0
                  note:self.settingsAccessNote
               centerY:108.0
                button:self.settingsAccessButton
                  text:@[ @"Allowed. MaccyZig pastes straight into the app you were using.",
                          @"Direct paste requires Accessibility permission.",
                          @"Open Accessibility…", @"Grant Permission…" ]];
  [self showPermission:mz_ocr_permitted()
                  note:self.settingsScreenNote
               centerY:36.0
                button:self.settingsScreenButton
                  text:@[ @"Allowed. Jev reads the screen just above where you paste.",
                          @"Lets Jev read the screen just above where you paste.",
                          @"Open Screen Recording…", @"Allow Screen Reading…" ]];
}

// The person may have been away in System Settings changing exactly what
// these rows describe.
- (void)windowDidBecomeKey:(NSNotification *)notification {
  if (notification.object == self.settingsWindow) [self updateJevSettingsStatus];
}

- (void)updateJevSettingsStatus {
  [self updatePermissionRows];
  if (self.settingsJevStatus == nil) return;
  if (!mz_jev_enabled()) {
    self.settingsJevStatus.textColor = mz_text_muted();
    self.settingsJevStatus.stringValue = mz_t(@"Off — nothing leaves this Mac.");
    return;
  }
  NSString *blocker = nil;
  if ([self jevBlockerFix:&blocker] != NULL) {
    self.settingsJevStatus.textColor = mz_warning_yellow();
    self.settingsJevStatus.stringValue = mz_t(blocker);
    return;
  }
  self.settingsJevStatus.textColor = mz_text_secondary();
  self.settingsJevStatus.stringValue =
      mz_t(@"On — sends previews, the field and the screen around it. Never credentials.");
}

- (void)setJevStatus:(NSString *)message color:(NSColor *)color {
  self.settingsJevStatus.textColor = color;
  self.settingsJevStatus.stringValue = mz_t(message);
}

#pragma mark Jev service

- (NSString *)jevServiceShortName {
  switch (mz_jev_service()) {
    case MZJevServiceVercel: return @"Vercel";
    case MZJevServiceCustom: return mz_t(@"Custom");
    case MZJevServiceTypeSafe: break;
  }
  return @"TypeSafe";
}

// Everything in Settings that depends on which service is chosen: the button's
// face, whether that service already has a key, and the status line.
- (void)syncJevServiceControls {
  [self.settingsJevServiceButton setDisplayTitle:[self jevServiceShortName]];
  self.settingsJevKeyField.stringValue = @"";
  self.settingsJevKeyField.placeholderString = mz_jev_api_key() != nil ? @"••••••••••••" : mz_t(@"API key");
  [self updateJevSettingsStatus];
}

- (void)showJevServiceChoices:(NSButton *)sender {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:mz_t(@"Jev Service")];
  NSArray<NSString *> *titles = @[ @"TypeSafe", @"Vercel AI Gateway", mz_t(@"Custom endpoint…") ];
  NSMenuItem *selected = nil;
  for (NSUInteger i = 0; i < titles.count; i++) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:titles[i] action:@selector(changeJevService:) keyEquivalent:@""];
    item.target = self;
    item.tag = (NSInteger)i;
    if ((NSInteger)i == mz_jev_service()) {
      item.state = NSControlStateValueOn;
      selected = item;
    }
    [menu addItem:item];
  }
  [menu popUpMenuPositioningItem:selected atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
}

- (void)changeJevService:(NSMenuItem *)sender {
  MZJevService service = (MZJevService)sender.tag;
  // The custom service is nothing without an address, so choosing it is
  // filling in the form; cancelling the form leaves the choice as it was.
  if (service == MZJevServiceCustom && ![self editCustomJevEndpoint]) return;
  mz_jev_set_service(service);
  [self syncJevServiceControls];
  // A different service is a different key; if it has none yet, that is the
  // next thing to type.
  if (mz_jev_api_key() == nil) [self.settingsWindow makeFirstResponder:self.settingsJevKeyField];
  if (mz_jev_enabled() && self.panel.isVisible) [self requestJevSuggestion];
}

// Returns NO when the person cancelled.
- (BOOL)editCustomJevEndpoint {
  NSArray<NSString *> *labels = @[ mz_t(@"Base URL"), mz_t(@"Model"), mz_t(@"Extra header"), mz_t(@"Header value") ];
  NSArray<NSString *> *hints = @[ @"https://gateway.ai.cloudflare.com/v1/<account>/<gateway>/custom-<slug>",
                                  @"jev-latest", @"cf-aig-authorization",
                                  mz_jev_custom_has_header_value() ? @"••••••••••••" : @"Bearer …" ];
  NSArray<NSString *> *values = @[ mz_jev_custom_base_url(),
                                   mz_jev_custom_model(),
                                   mz_jev_custom_header_name(), @"" ];
  const CGFloat width = 460.0, row = 30.0, label_width = 104.0;
  NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, row * labels.count)];
  NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
  for (NSUInteger i = 0; i < labels.count; i++) {
    CGFloat y = row * (labels.count - 1 - i);
    NSTextField *label = [NSTextField labelWithString:labels[i]];
    label.alignment = NSTextAlignmentRight;
    label.frame = NSMakeRect(0, y + 5, label_width, 18);
    [form addSubview:label];
    // The header's value is a credential for the gateway; like the API key it
    // is typed unseen and never shown back.
    NSTextField *field = i == 3 ? [[NSSecureTextField alloc] initWithFrame:NSZeroRect]
                                : [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.frame = NSMakeRect(label_width + 8, y + 3, width - label_width - 8, 22);
    field.placeholderString = hints[i];
    field.stringValue = values[i];
    field.cell.usesSingleLineMode = YES;
    field.cell.scrollable = YES;
    field.accessibilityLabel = labels[i];
    [form addSubview:field];
    [fields addObject:field];
  }
  for (NSUInteger i = 0; i + 1 < fields.count; i++) fields[i].nextKeyView = fields[i + 1];
  fields.lastObject.nextKeyView = fields.firstObject;

  NSString *problem = nil;
  while (YES) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = mz_t(@"Custom Jev endpoint");
    NSString *explanation = mz_t(@"Any address that speaks TypeSafe's API — a Cloudflare AI Gateway custom provider "
                                  "in front of api.typesafe.ai, for one. The base URL is everything before "
                                  "/v1/systemone. The extra header is only for gateways that authenticate "
                                  "separately; leave it empty otherwise. The API key is set in Settings as usual.");
    alert.informativeText = problem != nil ? [NSString stringWithFormat:@"%@\n\n⚠️ %@", explanation, mz_t(problem)]
                                           : explanation;
    alert.accessoryView = form;
    [alert addButtonWithTitle:mz_t(@"Save")];
    [alert addButtonWithTitle:mz_t(@"Cancel")];
    alert.window.initialFirstResponder = fields.firstObject;
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) return NO;
    problem = mz_jev_set_custom(fields[0].stringValue, fields[1].stringValue, fields[2].stringValue,
                                fields[3].stringValue);
    if (problem == nil) return YES;
  }
}

- (void)saveJevKeyFromSettings:(id)sender {
  (void)sender;
  if (!self.settingsJevSave.enabled) return;  // a check is already in flight
  NSString *entered = [self.settingsJevKeyField.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (entered.length == 0) {
    // Never treat an empty submit as "delete the key": Return, a VoiceOver
    // confirm or a stray click on an empty field would silently destroy a
    // working credential.
    [self setJevStatus:@"Enter an API key first" color:mz_warning_yellow()];
    [self.settingsWindow makeFirstResponder:self.settingsJevKeyField];
    return;
  }

  // Verify before storing: a rejected key must never become the stored one,
  // or the next open would report "On" for a setup that cannot work.
  self.settingsJevSave.enabled = NO;
  self.settingsJevKeyField.enabled = NO;
  [self setJevStatus:@"Checking the key…" color:mz_text_secondary()];

  mz_jev_verify_api_key(entered, ^(BOOL ok, NSString *message) {
    self.settingsJevSave.enabled = YES;
    self.settingsJevKeyField.enabled = YES;
    if (!ok) {
      // Keep the typed key so a typo can be fixed in place.
      [self setJevStatus:message color:mz_warning_yellow()];
      [self.settingsWindow makeFirstResponder:self.settingsJevKeyField];
      return;
    }
    if (!mz_jev_set_api_key(entered)) {
      [self setJevStatus:@"The keychain refused to store the key" color:mz_warning_yellow()];
      return;
    }
    // Clear the field: the key is in the keychain now, and leaving it on
    // screen is the one place it could still be read off a shared display.
    [self syncJevServiceControls];
    // A key the user just proved works is almost always meant to be used.
    [self applyJevEnabled:YES];
    [self setJevStatus:@"API key works — suggestions are on." color:mz_text_secondary()];
  });
}

static void mz_open_privacy_pane(NSString *anchor) {
  NSURL *url = [NSURL URLWithString:[@"x-apple.systempreferences:com.apple.preference.security?"
                                        stringByAppendingString:anchor]];
  if (url != nil) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)requestAccessibilityPermission:(id)sender {
  (void)sender;
  if (mz_ax_is_trusted(0) != 0) {
    mz_open_privacy_pane(@"Privacy_Accessibility");
    return;
  }
  mz_app_show_accessibility_alert();
}

- (void)buildSettingsWindow {
  if (self.settingsWindow != nil) return;

  const CGFloat width = 520.0;
  // Sections are laid out bottom-up in fixed coordinates.
  const CGFloat height = 814.0;
  self.settingsWindow = [[MZSettingsWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, width, height)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.settingsWindow.title = mz_t(@"Settings");
  self.settingsWindow.titleVisibility = NSWindowTitleHidden;
  self.settingsWindow.titlebarAppearsTransparent = YES;
  self.settingsWindow.movableByWindowBackground = YES;
  self.settingsWindow.backgroundColor = NSColor.clearColor;
  self.settingsWindow.opaque = NO;
  self.settingsWindow.hasShadow = YES;
  self.settingsWindow.releasedWhenClosed = NO;

  NSButton *native_close = [self.settingsWindow standardWindowButton:NSWindowCloseButton];
  NSButton *native_mini = [self.settingsWindow standardWindowButton:NSWindowMiniaturizeButton];
  NSButton *native_zoom = [self.settingsWindow standardWindowButton:NSWindowZoomButton];
  native_close.hidden = YES;
  native_mini.hidden = YES;
  native_zoom.hidden = YES;

  NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
  content.wantsLayer = YES;
  content.layer.cornerRadius = 18.0;
  content.layer.masksToBounds = YES;
  content.layer.backgroundColor = mz_panel_fill().CGColor;
  content.layer.borderWidth = 1.0;
  content.layer.borderColor = mz_panel_border().CGColor;
  self.settingsWindow.contentView = content;

  NSImageView *mark = [[NSImageView alloc] initWithFrame:NSMakeRect(190, 760, 22, 40)];
  mark.image = mz_resource_image(@"logo-mark", @"png");
  mark.imageScaling = NSImageScaleProportionallyUpOrDown;
  mark.accessibilityElement = NO;
  [content addSubview:mark];

  NSTextField *title = mz_label(mz_t(@"Settings"), [NSFont systemFontOfSize:22 weight:NSFontWeightBold], mz_text_primary());
  title.frame = NSMakeRect(222, 766, 138, 29);
  title.accessibilityLabel = mz_t(@"Settings");
  [content addSubview:title];

  NSButton *close = [self chromeButtonWithSymbol:@"xmark" action:@selector(closeSettings:)];
  close.frame = NSMakeRect(width - 52, 764, 30, 30);
  close.toolTip = mz_t(@"Close");
  close.accessibilityLabel = close.toolTip;
  [content addSubview:close];

  NSTextField *general = mz_label(mz_t(@"General"), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], mz_text_secondary());
  general.frame = NSMakeRect(28, 713, 464, 20);
  [content addSubview:general];

  NSView *general_card = [[NSView alloc] initWithFrame:NSMakeRect(24, 639, 472, 64)];
  general_card.wantsLayer = YES;
  general_card.layer.cornerRadius = 10.0;
  general_card.layer.backgroundColor = mz_card_fill().CGColor;
  general_card.layer.borderWidth = 1.0;
  general_card.layer.borderColor = mz_card_border().CGColor;
  [content addSubview:general_card];

  NSTextField *language = mz_label(mz_t(@"Language"), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], mz_text_primary());
  language.frame = NSMakeRect(16, 21, 146, 22);
  [general_card addSubview:language];

  self.settingsLanguageButton = [[MZSettingsChoiceButton alloc] initWithFrame:NSMakeRect(184, 10, 272, 44)];
  self.settingsLanguageButton.target = self;
  self.settingsLanguageButton.action = @selector(showLanguageChoices:);
  self.settingsLanguageButton.accessibilityLabel = mz_t(@"Language");
  [general_card addSubview:self.settingsLanguageButton];

  NSTextField *history = mz_label(mz_t(@"History"), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], mz_text_secondary());
  history.frame = NSMakeRect(28, 605, 464, 20);
  [content addSubview:history];

  NSView *history_card = [[NSView alloc] initWithFrame:NSMakeRect(24, 454, 472, 140)];
  history_card.wantsLayer = YES;
  history_card.layer.cornerRadius = 10.0;
  history_card.layer.backgroundColor = mz_card_fill().CGColor;
  history_card.layer.borderWidth = 1.0;
  history_card.layer.borderColor = mz_card_border().CGColor;
  [content addSubview:history_card];

  NSTextField *history_limit = mz_label(mz_t(@"History Limit"), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], mz_text_primary());
  history_limit.frame = NSMakeRect(16, 101, 146, 22);
  [history_card addSubview:history_limit];

  self.settingsHistoryButton = [[MZSettingsChoiceButton alloc] initWithFrame:NSMakeRect(184, 90, 272, 44)];
  self.settingsHistoryButton.target = self;
  self.settingsHistoryButton.action = @selector(showHistoryChoices:);
  self.settingsHistoryButton.accessibilityLabel = mz_t(@"History Limit");
  [history_card addSubview:self.settingsHistoryButton];

  NSView *history_divider = [[NSView alloc] initWithFrame:NSMakeRect(16, 72, 440, 1)];
  history_divider.wantsLayer = YES;
  history_divider.layer.backgroundColor = mz_card_border().CGColor;
  [history_card addSubview:history_divider];

  MZChamferedButton *clear_unpinned = [self filterButtonWithTitle:mz_t(@"Clear Unpinned") tag:-1];
  clear_unpinned.framed = YES;
  clear_unpinned.accentCorner = NO;
  clear_unpinned.target = self;
  clear_unpinned.action = @selector(clearUnpinned:);
  clear_unpinned.frame = NSMakeRect(184, 18, 128, 38);
  [history_card addSubview:clear_unpinned];

  MZChamferedButton *clear_all = [self filterButtonWithTitle:mz_t(@"Clear All") tag:-1];
  clear_all.framed = YES;
  clear_all.accentCorner = NO;
  clear_all.target = self;
  clear_all.action = @selector(clearAll:);
  clear_all.frame = NSMakeRect(324, 18, 132, 38);
  [history_card addSubview:clear_all];

  NSTextField *shortcuts = mz_label(mz_t(@"Shortcuts & Permissions"), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], mz_text_secondary());
  shortcuts.frame = NSMakeRect(28, 420, 464, 20);
  [content addSubview:shortcuts];

  NSView *shortcuts_card = [[NSView alloc] initWithFrame:NSMakeRect(24, 194, 472, 216)];
  shortcuts_card.wantsLayer = YES;
  shortcuts_card.layer.cornerRadius = 10.0;
  shortcuts_card.layer.backgroundColor = mz_card_fill().CGColor;
  shortcuts_card.layer.borderWidth = 1.0;
  shortcuts_card.layer.borderColor = mz_card_border().CGColor;
  [content addSubview:shortcuts_card];

  NSTextField *hotkey = mz_label(mz_t(@"Global Hotkey"), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], mz_text_primary());
  hotkey.frame = NSMakeRect(16, 177, 146, 22);
  [shortcuts_card addSubview:hotkey];

  self.settingsHotkeyButton = [[MZSettingsChoiceButton alloc] initWithFrame:NSMakeRect(184, 166, 272, 44)];
  self.settingsHotkeyButton.target = self;
  self.settingsHotkeyButton.action = @selector(showHotkeyChoices:);
  self.settingsHotkeyButton.accessibilityLabel = mz_t(@"Global Hotkey");
  [shortcuts_card addSubview:self.settingsHotkeyButton];

  NSView *shortcut_divider = [[NSView alloc] initWithFrame:NSMakeRect(16, 148, 440, 1)];
  shortcut_divider.wantsLayer = YES;
  shortcut_divider.layer.backgroundColor = mz_card_border().CGColor;
  [shortcuts_card addSubview:shortcut_divider];

  self.settingsAccessNote = mz_label(@"", [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
                                     mz_text_secondary());
  self.settingsAccessNote.maximumNumberOfLines = 2;
  self.settingsAccessNote.lineBreakMode = NSLineBreakByWordWrapping;
  [shortcuts_card addSubview:self.settingsAccessNote];

  MZChamferedButton *permission = (MZChamferedButton *)[self filterButtonWithTitle:@"" tag:-1];
  permission.framed = YES;
  permission.accentCorner = NO;
  permission.target = self;
  permission.action = @selector(requestAccessibilityPermission:);
  permission.frame = NSMakeRect(252, 86, 204, 44);
  [shortcuts_card addSubview:permission];
  self.settingsAccessButton = permission;

  NSView *screen_divider = [[NSView alloc] initWithFrame:NSMakeRect(16, 72, 440, 1)];
  screen_divider.wantsLayer = YES;
  screen_divider.layer.backgroundColor = mz_card_border().CGColor;
  [shortcuts_card addSubview:screen_divider];

  // Screen Recording is what lets Jev see what the user sees around the paste,
  // in every app. It belongs next to the other permission, not buried in a menu.
  self.settingsScreenNote = mz_label(@"", [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
                                     mz_text_secondary());
  self.settingsScreenNote.maximumNumberOfLines = 2;
  self.settingsScreenNote.lineBreakMode = NSLineBreakByWordWrapping;
  [shortcuts_card addSubview:self.settingsScreenNote];

  self.settingsScreenButton = (MZChamferedButton *)[self filterButtonWithTitle:@"" tag:-1];
  self.settingsScreenButton.framed = YES;
  self.settingsScreenButton.accentCorner = NO;
  self.settingsScreenButton.target = self;
  self.settingsScreenButton.action = @selector(requestScreenReadingPermission:);
  self.settingsScreenButton.frame = NSMakeRect(252, 14, 204, 44);
  [shortcuts_card addSubview:self.settingsScreenButton];
  [self updatePermissionRows];

  NSTextField *jev = mz_label(mz_t(@"Suggestions"), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], mz_text_secondary());
  jev.frame = NSMakeRect(28, 160, 464, 20);
  [content addSubview:jev];

  NSView *jev_card = [[NSView alloc] initWithFrame:NSMakeRect(24, 24, 472, 126)];
  jev_card.wantsLayer = YES;
  jev_card.layer.cornerRadius = 10.0;
  jev_card.layer.backgroundColor = mz_card_fill().CGColor;
  jev_card.layer.borderWidth = 1.0;
  jev_card.layer.borderColor = mz_card_border().CGColor;
  [content addSubview:jev_card];

  NSTextField *jev_title = mz_label(mz_t(@"Suggest what to paste (Jev)"),
                                    [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], mz_text_primary());
  jev_title.frame = NSMakeRect(16, 92, 360, 22);
  [jev_card addSubview:jev_title];

  // The switch's size is the system's, not ours (it grew with newer macOS),
  // so measure it and pin its trailing edge to the card's content inset.
  self.settingsJevSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
  NSSize switch_size = self.settingsJevSwitch.fittingSize;
  self.settingsJevSwitch.frame = NSMakeRect(456.0 - switch_size.width, 103.0 - switch_size.height * 0.5,
                                            switch_size.width, switch_size.height);
  self.settingsJevSwitch.state = mz_jev_enabled() ? NSControlStateValueOn : NSControlStateValueOff;
  self.settingsJevSwitch.target = self;
  self.settingsJevSwitch.action = @selector(changeJevEnabledFromSettings:);
  self.settingsJevSwitch.accessibilityLabel = mz_t(@"Suggest what to paste (Jev)");
  [jev_card addSubview:self.settingsJevSwitch];

  NSView *jev_divider = [[NSView alloc] initWithFrame:NSMakeRect(16, 76, 440, 1)];
  jev_divider.wantsLayer = YES;
  jev_divider.layer.backgroundColor = mz_card_border().CGColor;
  [jev_card addSubview:jev_divider];

  // Whose key this is, and with it where requests go. It stands where a fixed
  // "TypeSafe API Key" label used to be, so the card did not have to grow.
  self.settingsJevServiceButton = [[MZSettingsChoiceButton alloc] initWithFrame:NSMakeRect(16, 34, 160, 38)];
  self.settingsJevServiceButton.target = self;
  self.settingsJevServiceButton.action = @selector(showJevServiceChoices:);
  self.settingsJevServiceButton.accessibilityLabel = mz_t(@"Jev Service");
  [jev_card addSubview:self.settingsJevServiceButton];

  // Same well as the choice buttons above. The secure field keeps its own
  // cell (swapping in the centering cell would drop bullet echo), so it is
  // centered inside a styled container instead.
  NSView *jev_key_well = [[NSView alloc] initWithFrame:NSMakeRect(184, 34, 148, 38)];
  jev_key_well.wantsLayer = YES;
  jev_key_well.layer.cornerRadius = 8.0;
  jev_key_well.layer.backgroundColor = mz_color(28, 31, 35, 1.0).CGColor;
  jev_key_well.layer.borderWidth = 1.0;
  jev_key_well.layer.borderColor = mz_card_border().CGColor;
  [jev_card addSubview:jev_key_well];
  ((MZSettingsWindow *)self.settingsWindow).textWell = jev_key_well;

  // Secure field: the key is a credential, and Settings is shareable screen.
  self.settingsJevKeyField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
  // Whether a key is stored is state, and showSettings: syncs state on every
  // open. Building the window never touches the keychain.
  self.settingsJevKeyField.placeholderString = mz_t(@"API key");
  self.settingsJevKeyField.font = [NSFont systemFontOfSize:14];
  self.settingsJevKeyField.textColor = mz_text_primary();
  self.settingsJevKeyField.bezeled = NO;
  self.settingsJevKeyField.bordered = NO;
  self.settingsJevKeyField.drawsBackground = NO;
  self.settingsJevKeyField.focusRingType = NSFocusRingTypeNone;
  self.settingsJevKeyField.cell.usesSingleLineMode = YES;
  self.settingsJevKeyField.cell.scrollable = YES;
  CGFloat key_height = self.settingsJevKeyField.fittingSize.height;
  self.settingsJevKeyField.frame = NSMakeRect(12, (38.0 - key_height) * 0.5, 148 - 24, key_height);
  self.settingsJevKeyField.target = self;
  self.settingsJevKeyField.action = @selector(saveJevKeyFromSettings:);
  self.settingsJevKeyField.accessibilityLabel = mz_t(@"API Key");
  [jev_key_well addSubview:self.settingsJevKeyField];

  MZChamferedButton *jev_save = [self filterButtonWithTitle:mz_t(@"Save & Check") tag:-1];
  jev_save.framed = YES;
  jev_save.accentCorner = NO;
  jev_save.target = self;
  jev_save.action = @selector(saveJevKeyFromSettings:);
  jev_save.frame = NSMakeRect(342, 34, 114, 38);
  [jev_card addSubview:jev_save];
  self.settingsJevSave = jev_save;

  self.settingsJevStatus = mz_label(@"", [NSFont systemFontOfSize:12 weight:NSFontWeightRegular], mz_text_secondary());
  self.settingsJevStatus.frame = NSMakeRect(16, 8, 440, 20);
  self.settingsJevStatus.lineBreakMode = NSLineBreakByTruncatingTail;
  self.settingsJevStatus.maximumNumberOfLines = 1;
  [jev_card addSubview:self.settingsJevStatus];

  [self updateHistoryLimitMenu];
  [self updateHotkeyMenu];
  [self.settingsJevServiceButton setDisplayTitle:[self jevServiceShortName]];
  [self.settingsLanguageButton setDisplayTitle:(gLang == MZLangChinese ? @"中文" : @"English")];

  self.settingsLanguageButton.nextKeyView = self.settingsHistoryButton;
  self.settingsHistoryButton.nextKeyView = clear_unpinned;
  clear_unpinned.nextKeyView = clear_all;
  clear_all.nextKeyView = self.settingsHotkeyButton;
  self.settingsHotkeyButton.nextKeyView = permission;
  permission.nextKeyView = self.settingsScreenButton;
  self.settingsScreenButton.nextKeyView = self.settingsJevSwitch;
  self.settingsJevSwitch.nextKeyView = self.settingsJevServiceButton;
  self.settingsJevServiceButton.nextKeyView = self.settingsJevKeyField;
  self.settingsJevKeyField.nextKeyView = jev_save;
  jev_save.nextKeyView = close;
  close.nextKeyView = self.settingsLanguageButton;
  self.settingsWindow.initialFirstResponder = self.settingsLanguageButton;
  self.settingsWindow.delegate = self;
}

- (void)showSettings:(id)sender {
  (void)sender;
  [self buildSettingsWindow];
  // The window is built once but the Actions-menu item can flip the flag
  // afterwards, so re-sync the controls on every open.
  self.settingsJevSwitch.state = mz_jev_enabled() ? NSControlStateValueOn : NSControlStateValueOff;
  [self syncJevServiceControls];
  [NSApp activateIgnoringOtherApps:YES];
  if (!self.settingsWindow.isVisible) [self.settingsWindow center];
  [self.settingsWindow makeKeyAndOrderFront:nil];
  [self.settingsWindow makeFirstResponder:self.settingsLanguageButton];
}

- (void)closeSettings:(id)sender {
  (void)sender;
  [self.settingsWindow orderOut:nil];
  if (self.panel.isVisible) [self.panel makeKeyAndOrderFront:nil];
}

- (void)showLanguageChoices:(NSButton *)sender {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:mz_t(@"Language")];
  NSMenuItem *english = [[NSMenuItem alloc] initWithTitle:@"English" action:@selector(changeLanguageFromSettings:) keyEquivalent:@""];
  english.target = self;
  english.tag = MZLangEnglish;
  [menu addItem:english];
  NSMenuItem *chinese = [[NSMenuItem alloc] initWithTitle:@"中文" action:@selector(changeLanguageFromSettings:) keyEquivalent:@""];
  chinese.target = self;
  chinese.tag = MZLangChinese;
  [menu addItem:chinese];
  NSMenuItem *selected = gLang == MZLangChinese ? chinese : english;
  selected.state = NSControlStateValueOn;
  [menu popUpMenuPositioningItem:selected atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
}

- (void)showHistoryChoices:(NSButton *)sender {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:mz_t(@"History Limit")];
  NSMenuItem *selected = nil;
  for (NSNumber *choice in mz_max_item_choices()) {
    NSInteger value = choice.integerValue;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:mz_max_items_title(value) action:@selector(changeHistoryLimit:) keyEquivalent:@""];
    item.target = self;
    item.tag = value;
    item.state = value == self.maxItemsLimit ? NSControlStateValueOn : NSControlStateValueOff;
    if (value == self.maxItemsLimit) selected = item;
    [menu addItem:item];
  }
  [menu popUpMenuPositioningItem:selected atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
}

- (void)showHotkeyChoices:(NSButton *)sender {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:mz_t(@"Global Hotkey")];
  NSArray<NSArray<NSString *> *> *presets = @[
    @[ @"⌘⇧V", @"cmd-shift-v" ],
    @[ @"⌃⇧V", @"ctrl-shift-v" ],
    @[ @"⌥⌘V", @"opt-cmd-v" ],
    @[ mz_t(@"Disabled"), @"disabled" ],
  ];
  NSString *current = [NSUserDefaults.standardUserDefaults stringForKey:@"MZHotkeyPreset"] ?: @"cmd-shift-v";
  NSMenuItem *selected = nil;
  for (NSArray<NSString *> *preset in presets) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:preset[0] action:@selector(changeHotkeyPreset:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = preset[1];
    item.state = [current isEqualToString:preset[1]] ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.state == NSControlStateValueOn) selected = item;
    [menu addItem:item];
  }
  [menu popUpMenuPositioningItem:selected atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
}

- (void)changeLanguageFromSettings:(NSMenuItem *)sender {
  mz_lang_set((MZLang)sender.tag);
}

- (void)changeHistoryLimit:(id)sender {
  NSMenuItem *item = sender;
  NSInteger value = item.tag;
  if (value <= 0) return;
  self.maxItemsLimit = value;
  [NSUserDefaults.standardUserDefaults setInteger:value forKey:kMZMaxItemsDefaultsKey];
  [self updateHistoryLimitMenu];
  void (*on_change)(int64_t) = self.callbacks.on_max_items_change;
  if (on_change != NULL) {
    // Shrinking the limit can cascade-delete thousands of rows; keep that off
    // the main thread.
    dispatch_async(mz_db_queue(), ^{ on_change((int64_t)value); });
  }
}

- (void)handleLanguageChange:(NSNotification *)note {
  (void)note;
  [self applyLocalization];
}

- (void)changeHotkeyPreset:(id)sender {
  NSMenuItem *item = sender;
  NSString *presetId = item.representedObject;
  if (presetId.length == 0) return;
  int status = mz_hotkey_apply_preset(presetId.UTF8String);
  [self updateHotkeyMenu];
  if (status != 0) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = mz_t(@"Hotkey registration failed. Another app may already be using this shortcut.");
    [alert addButtonWithTitle:mz_t(@"OK")];
    [alert runModal];
  }
}

- (void)updateHotkeyMenu {
  if (self.settingsHotkeyButton == nil) return;
  NSString *current = [NSUserDefaults.standardUserDefaults stringForKey:@"MZHotkeyPreset"] ?: @"cmd-shift-v";
  NSDictionary<NSString *, NSString *> *titles = @{
    @"cmd-shift-v": @"⌘⇧V",
    @"ctrl-shift-v": @"⌃⇧V",
    @"opt-cmd-v": @"⌥⌘V",
    @"disabled": mz_t(@"Disabled"),
  };
  [self.settingsHotkeyButton setDisplayTitle:titles[current] ?: @"⌘⇧V"];
}

- (void)updateHistoryLimitMenu {
  if (self.settingsHistoryButton == nil) return;
  [self.settingsHistoryButton setDisplayTitle:mz_max_items_title(self.maxItemsLimit)];
}

- (void)applyLocalization {
  // Row subtitles are language-dependent; force a full cell reconfigure.
  self.rowsGeneration += 1;
  // Re-translate every static string we can reach. Per-row subtitles are reset
  // through reloadItemViews below, which calls mz_subtitle_for_row again.
  if (self.statusItem != nil) self.statusItem.button.toolTip = mz_t(@"Maccy");
  if (self.pinButton != nil) {
    self.pinButton.toolTip = mz_t(@"Keep window on top");
    self.pinButton.accessibilityLabel = self.pinButton.toolTip;
  }
  if (self.settingsButton != nil) {
    self.settingsButton.toolTip = mz_t(@"Settings");
    self.settingsButton.accessibilityLabel = self.settingsButton.toolTip;
  }
  if (self.searchField != nil) {
    self.searchField.placeholderString = mz_t(@"Search clipboard history...");
    self.searchField.accessibilityLabel = mz_t(@"Search Clipboard History");
  }
  if (self.searchHint != nil) {
    self.searchHint.toolTip = mz_t(@"Search");
    self.searchHint.accessibilityLabel = self.searchHint.toolTip;
  }
  if (self.searchClearButton != nil) {
    self.searchClearButton.toolTip = mz_t(@"Clear Search");
    self.searchClearButton.accessibilityLabel = self.searchClearButton.toolTip;
  }

  // Filter tabs (4 main + favorites). Order in self.filterButtons matches insertion.
  if (self.filterButtons.count >= 5) {
    NSArray<NSString *> *tabs = @[ mz_t(@"All"), mz_t(@"Text"), mz_t(@"Links"), mz_t(@"Images") ];
    for (NSUInteger i = 0; i < tabs.count; i++) self.filterButtons[i].title = tabs[i];
    self.filterButtons[4].title = mz_t(@"☆  Favorites");
    [self updateFilterButtons];
  }

  if (self.footerActionsButton != nil) {
    self.footerActionsButton.title = mz_t(@"Actions…");
    self.footerActionsButton.accessibilityLabel = mz_t(@"Actions");
  }

  for (NSMenuItem *item in self.actionsMenu.itemArray) {
    if (item.action == @selector(toggleSelectedFavorite:)) item.title = mz_t(@"Toggle Favorite");
    if (item.action == @selector(pasteSelectedAsPlainText:)) item.title = mz_t(@"Paste as Plain Text");
    if (item.action == @selector(revealSelected:)) item.title = mz_t(@"Reveal");
    if (item.action == @selector(showSettings:)) item.title = mz_t(@"Settings");
    if (item.action == @selector(toggleJevSuggestions:)) item.title = mz_t(@"Suggest what to paste (Jev)");
    if (item.action == @selector(toggleJevDebug:)) item.title = mz_t(@"Log Jev Decisions");
    if (item.action == @selector(quitApplication:)) item.title = mz_t(@"Quit");
  }

  BOOL settings_visible = self.settingsWindow.isVisible;
  if (self.settingsWindow != nil) {
    [self.settingsWindow orderOut:nil];
    self.settingsWindow = nil;
    self.settingsLanguageButton = nil;
    self.settingsHistoryButton = nil;
    self.settingsHotkeyButton = nil;
    self.settingsJevSwitch = nil;
    self.settingsJevServiceButton = nil;
    self.settingsJevKeyField = nil;
    self.settingsJevStatus = nil;
    self.settingsAccessNote = nil;
    self.settingsAccessButton = nil;
    self.settingsScreenNote = nil;
    self.settingsScreenButton = nil;
    self.settingsJevSave = nil;
  }
  if (settings_visible) [self showSettings:nil];

  // Re-render rows so subtitles + count label refresh.
  [self updateSearchChrome];
  [self updateCountLabel];
  [self reloadItemViews];
}

// ⌘F and its key cap. Something the person asked for has to be seen to
// happen, and this nearly never was: the panel opens with the caret already in
// the search field, and focusing a focused, empty field changes nothing on
// screen -- so both looked dead. The search box answers with a flash of its
// border.
- (void)focusSearchFromHint:(id)sender {
  (void)sender;
  [self focusSearchFieldSelectingText:YES];
  CABasicAnimation *colour = [CABasicAnimation animationWithKeyPath:@"borderColor"];
  colour.fromValue = (__bridge id)mz_primary_orange_shadow().CGColor;
  colour.toValue = (__bridge id)self.searchBox.layer.borderColor;
  CABasicAnimation *width = [CABasicAnimation animationWithKeyPath:@"borderWidth"];
  width.fromValue = @2.0;
  width.toValue = @(self.searchBox.layer.borderWidth);
  CAAnimationGroup *flash = [CAAnimationGroup animation];
  flash.animations = @[ colour, width ];
  flash.duration = 0.5;
  flash.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
  [self.searchBox.layer addAnimation:flash forKey:@"focus-flash"];
}

- (void)clearSearch:(id)sender {
  (void)sender;
  if (self.searchField.stringValue.length == 0) return;
  self.searchField.stringValue = @"";
  [self updateSearchChrome];
  [self focusSearchFieldSelectingText:NO];
  void (*search)(const char *) = self.callbacks.on_search;
  if (search != NULL) dispatch_async(mz_db_queue(), ^{ search(""); });
}

- (void)updateSearchChrome {
  BOOL has_query = self.searchField.stringValue.length > 0;
  self.searchHint.hidden = has_query;
  self.searchClearButton.hidden = !has_query;
  [self updateKeyViewLoop];
}

- (void)performEmptyStateAction:(id)sender {
  (void)sender;
  if (self.searchField.stringValue.length > 0) {
    [self clearSearch:nil];
    return;
  }
  if (self.filterMode != MZFilterModeAll && self.filterButtons.count > 0) {
    [self changeFilter:self.filterButtons[0]];
    [self focusSearchFieldSelectingText:NO];
  }
}

- (void)updateEmptyState {
  BOOL empty = self.rows.count == 0;
  self.listScrollView.hidden = empty;
  self.emptyStateView.hidden = !empty;
  if (!empty) {
    [self updateKeyViewLoop];
    return;
  }

  if (self.searchField.stringValue.length > 0) {
    self.emptyStateTitleLabel.stringValue = mz_t(@"No Matches");
    self.emptyStateBodyLabel.stringValue = mz_t(@"Try another search or clear the query.");
    self.emptyStateActionButton.title = mz_t(@"Clear Search");
    self.emptyStateActionButton.hidden = NO;
  } else if (self.filterMode != MZFilterModeAll) {
    self.emptyStateTitleLabel.stringValue = mz_t(@"No Items in This Filter");
    self.emptyStateBodyLabel.stringValue = mz_t(@"Switch to All to see your clipboard history.");
    self.emptyStateActionButton.title = mz_t(@"Show All");
    self.emptyStateActionButton.hidden = NO;
  } else {
    self.emptyStateTitleLabel.stringValue = mz_t(@"Clipboard History Is Empty");
    self.emptyStateBodyLabel.stringValue = mz_t(@"Copy something and it will appear here.");
    self.emptyStateActionButton.title = @"";
    self.emptyStateActionButton.hidden = YES;
  }
  self.emptyStateActionButton.accessibilityLabel = self.emptyStateActionButton.title;
  [self updateKeyViewLoop];
}

- (void)updateKeyViewLoop {
  if (self.searchField == nil) return;
  NSView *current = self.searchField;
  if (!self.searchClearButton.hidden) {
    current.nextKeyView = self.searchClearButton;
    current = self.searchClearButton;
  }
  for (NSButton *button in self.filterButtons) {
    current.nextKeyView = button;
    current = button;
  }
  BOOL empty_without_action = !self.emptyStateView.hidden && self.emptyStateActionButton.hidden;
  NSView *history_target = !self.emptyStateView.hidden && !self.emptyStateActionButton.hidden
      ? self.emptyStateActionButton
      : (empty_without_action ? self.footerActionsButton : self.listContentView);
  current.nextKeyView = history_target;
  current = history_target;
  if (current != self.footerActionsButton) current.nextKeyView = self.footerActionsButton;
  self.footerActionsButton.nextKeyView = self.pinButton;
  self.pinButton.nextKeyView = self.settingsButton;
  self.settingsButton.nextKeyView = self.searchField;
}

- (BOOL)handleKeyEvent:(NSEvent *)event {
  if (!self.panel.isVisible) return NO;

  NSResponder *first = self.panel.firstResponder;
  NSText *editor = [first isKindOfClass:[NSText class]] ? (NSText *)first : nil;
  // While an input method is composing (Chinese/Japanese/Korean marked text),
  // every key — Enter, arrows, Escape — belongs to the IME. Intercepting them
  // here would commit/paste mid-composition and make CJK search unusable.
  if ([first isKindOfClass:[NSTextView class]] && ((NSTextView *)first).hasMarkedText) {
    return NO;
  }

  NSEventModifierFlags modifiers = mz_app_modifier_flags(event);
  BOOL hasCommand = (modifiers & NSEventModifierFlagCommand) != 0;
  BOOL hasOption = (modifiers & NSEventModifierFlagOption) != 0;
  BOOL hasShift = (modifiers & NSEventModifierFlagShift) != 0;

  if (event.keyCode == 53) {
    if (self.settingsWindow.isKeyWindow) {
      [self.settingsWindow orderOut:nil];
      [self.panel makeKeyAndOrderFront:nil];
      return YES;
    }
    [self hide];
    return YES;
  }
  if (self.settingsWindow.isKeyWindow) return NO;
  if (event.keyCode == 48 && !hasCommand && !hasOption) {
    NSWindow *window = NSApp.keyWindow ?: self.panel;
    NSView *current = [window.firstResponder isKindOfClass:[NSText class]]
        ? self.searchField
        : ([window.firstResponder isKindOfClass:[NSView class]] ? (NSView *)window.firstResponder : self.searchField);
    NSView *target = hasShift ? current.previousKeyView : current.nextKeyView;
    if (target != nil) [window makeFirstResponder:target];
    return YES;
  }

  if (hasCommand && mz_app_matches_command_key(event, 3, @"f")) {
    [self focusSearchFromHint:nil];
    return YES;
  }
  if (hasCommand && mz_app_matches_command_key(event, 43, @",")) {
    [self showSettings:nil];
    return YES;
  }
  // ⌘A / ⌘C / ⌘X / ⌘V are dispatched by the Edit menu installed at launch, so
  // they reach whatever field holds first responder without help from here.
  // The one thing still worth saying is that while the search field is being
  // edited, ⌘V means "paste into the search box", not "paste the selected
  // history item" -- so let the menu have it rather than claiming it below.
  if (hasCommand && !hasOption && !hasShift && editor != nil &&
      (mz_app_matches_command_key(event, 0, @"a") || mz_app_matches_command_key(event, 8, @"c") ||
       mz_app_matches_command_key(event, 7, @"x") || mz_app_matches_command_key(event, 9, @"v"))) {
    return NO;
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
    // Keep focus in the search field while arrowing through results — typing
    // must keep working. Explicit list focus is only taken when the user
    // isn't editing text.
    BOOL focusList = editor == nil;
    switch (event.keyCode) {
      case 126:
        [self moveSelectionByDelta:-1 focusList:focusList];
        return YES;
      case 125:
        [self moveSelectionByDelta:1 focusList:focusList];
        return YES;
      case 116:
        [self moveSelectionByPageDelta:-1 focusList:focusList];
        return YES;
      case 121:
        [self moveSelectionByPageDelta:1 focusList:focusList];
        return YES;
      case 115:
        [self moveSelectionToBoundary:NO focusList:focusList];
        return YES;
      case 119:
        [self moveSelectionToBoundary:YES focusList:focusList];
        return YES;
      default:
        break;
    }
  }

  if (!mz_app_is_enter_event(event) || hasCommand) return NO;
  if ([first isKindOfClass:[NSButton class]]) return NO;
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
  // Typing is not choosing a row, it is narrowing the list -- so the previous
  // answer is stale but a fresh one on the smaller candidate set is better
  // than none. -dispatchPendingSearch re-asks once the rows have landed.
  [self clearJevSuggestion];
  if (obj.object != self.searchField) return;
  [self updateSearchChrome];
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
  // Rows arrive asynchronously from the db queue; give them the same head
  // start -show gives them before asking Jev about the filtered set.
  // ponytail: fixed delay, move to a set_rows hook if a slow db makes it miss.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (self.panel.isVisible) [self requestJevSuggestion];
  });
  (void)sender;
  void (*search)(const char *) = self.callbacks.on_search;
  if (search == NULL || self.searchField == nil) return;
  NSString *query = [self.searchField.stringValue copy];
  dispatch_async(mz_db_queue(), ^{ search(query.UTF8String); });
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
  (void)textView;
  if (control != self.searchField) return NO;
  if (commandSelector == @selector(insertTab:)) {
    [self.panel makeFirstResponder:self.searchField.nextKeyView];
    return YES;
  }
  if (commandSelector == @selector(insertBacktab:)) {
    [self.panel makeFirstResponder:self.searchField.previousKeyView];
    return YES;
  }
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

#pragma mark - Click audit

// Can a person click what they can see? Pure geometry on the live view tree,
// asked the way AppKit asks it: hit-test the window's frame view at points
// spread over each control. Nothing is clicked, so nothing fires.
//
// Two rules. A point on a control must land on a control -- that one, or
// another laid over it on purpose (the star on a history row) -- never on a
// label, a plain view or nothing, which is a dead spot the person cannot see.
// And every control must be hit by at least one of its own points. On top of
// that, in a window that is movable by its background, the view that receives
// the mouse-down must not hand it to the window drag.
//
// This is the net for a whole class of bug rather than one instance of it: a
// hitTest: override in the wrong coordinate space, a label or an invisible
// view laid over a button, a control poking out of a clipping superview, a
// custom control that does not claim its mouse-down.
static BOOL mz_view_is_clickable(NSView *view) {
  if (![view isKindOfClass:NSControl.class]) return NO;
  NSControl *control = (NSControl *)view;
  BOOL editable = [control isKindOfClass:NSTextField.class] && ((NSTextField *)control).editable;
  return control.enabled && (control.action != NULL || editable);
}

static void mz_audit_clicks_in(NSView *view, NSView *frame_view, NSMutableArray<NSString *> *failures,
                               NSUInteger *audited) {
  if (view.hidden) return;
  if (!mz_view_is_clickable(view)) {
    for (NSView *child in view.subviews) mz_audit_clicks_in(child, frame_view, failures, audited);
    return;
  }
  *audited += 1;
  static const CGFloat spots[5][2] = {{0.5, 0.5}, {0.12, 0.5}, {0.88, 0.5}, {0.5, 0.2}, {0.5, 0.8}};
  NSString *name = view.accessibilityLabel.length > 0 ? view.accessibilityLabel
      : [view isKindOfClass:NSButton.class] && ((NSButton *)view).title.length > 0 ? ((NSButton *)view).title
      : NSStringFromClass(view.class);
  BOOL reached = NO;
  for (int i = 0; i < 5; i++) {
    NSPoint local = NSMakePoint(NSMinX(view.bounds) + NSWidth(view.bounds) * spots[i][0],
                                NSMinY(view.bounds) + NSHeight(view.bounds) * spots[i][1]);
    // The frame view has no superview, so its hitTest: takes window coordinates.
    NSView *hit = [frame_view hitTest:[view convertPoint:local toView:nil]];
    BOOL own = hit != nil && (hit == view || [hit isDescendantOf:view]);
    reached = reached || own;
    NSView *receiver = hit;
    while (receiver != nil && !mz_view_is_clickable(receiver)) receiver = own ? nil : receiver.superview;
    NSString *problem = nil;
    if (!own && receiver == nil) {
      problem = hit == nil ? @"nothing is hit there"
                           : [NSString stringWithFormat:@"the click lands on %@, which does nothing",
                                                        NSStringFromClass(hit.class)];
    } else if (own && hit.mouseDownCanMoveWindow && view.window.movableByWindowBackground) {
      problem = @"the mouse-down would drag the window";
    }
    if (problem != nil) {
      [failures addObject:[NSString stringWithFormat:@"\"%@\" at %.0f%%,%.0f%% of its area: %@", name,
                                                     spots[i][0] * 100.0, spots[i][1] * 100.0, problem]];
    }
  }
  if (!reached) [failures addObject:[NSString stringWithFormat:@"\"%@\" cannot be reached at all", name]];
  // What is inside a control is that control's business.
}

static NSUInteger mz_audit_clicks(NSWindow *window, NSString *label, NSUInteger *failed) {
  [window.contentView layoutSubtreeIfNeeded];
  NSMutableArray<NSString *> *failures = [NSMutableArray array];
  NSUInteger audited = 0;
  mz_audit_clicks_in(window.contentView, window.contentView.superview ?: window.contentView, failures, &audited);
  for (NSString *failure in failures) fprintf(stderr, "ui-self-check FAIL [%s] %s\n", label.UTF8String, failure.UTF8String);
  *failed += failures.count;
  printf("%s: %lu clickable control(s) audited\n", label.UTF8String, (unsigned long)audited);

  // MZ_UI_SNAPSHOT_DIR=<dir> also renders each window to a PNG there, so its
  // layout can be looked at without ever putting it on the user's screen.
  const char *directory = getenv("MZ_UI_SNAPSHOT_DIR");
  if (directory != NULL) {
    NSView *content = window.contentView;
    NSBitmapImageRep *rep = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:rep];
    NSString *path = [[NSString stringWithUTF8String:directory]
        stringByAppendingPathComponent:[label stringByAppendingPathExtension:@"png"]];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
  }
  return audited;
}

// Why there is no "click it for real" pass here: a mouse-down sent through
// -[NSApplication sendEvent:] is only delivered to a window that is on screen,
// and AppKit answers it by making that window key -- which takes the keyboard
// away from whoever is working at the machine, under every activation policy,
// non-activating panels included. Tried, measured, removed. Event routing at
// run time is traced instead; see syncClickTrace.
//
// `maccy-zig ui-self-check`. Builds the real windows off screen -- never shown,
// never activated -- and audits them, in both languages because string lengths
// move and resize things.
int mz_app_ui_self_check(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSUInteger failed = 0;
    for (int lang = 0; lang < 2; lang++) {
      gLang = lang == 0 ? MZLangEnglish : MZLangChinese;
      NSString *suffix = lang == 0 ? @"English" : @"中文";
      MZAppCallbacks none = {0};
      gController = [[MZAppController alloc] initWithCallbacks:none];

      [gController buildSettingsWindow];
      mz_audit_clicks(gController.settingsWindow, [@"Settings, " stringByAppendingString:suffix], &failed);

      [gController buildPanel];
      MZAppRow rows[3] = {
        {.id = 1, .title = "https://example.com/a", .subtitle = "", .app = "com.apple.Safari", .copied_at = 1, .content_kind = 1},
        {.id = 2, .title = "git status", .subtitle = "", .app = "com.apple.Terminal", .copied_at = 2, .content_kind = 1, .pinned = 1},
        {.id = 3, .title = "hello", .subtitle = "", .app = "", .copied_at = 3, .content_kind = 1},
      };
      mz_app_set_rows(rows, 3);
      mz_audit_clicks(gController.panel, [@"Panel, " stringByAppendingString:suffix], &failed);

      // The shortcut hint is a button: pressing it puts the caret in the search field.
      [gController.panel makeFirstResponder:nil];
      [gController.searchHint performClick:nil];
      if (mz_focused_view(gController.panel) != gController.searchField) {
        failed += 1;
        fprintf(stderr, "ui-self-check FAIL [Panel, %s] pressing the ⌘F hint did not focus the search field\n",
                suffix.UTF8String);
      }
      // ...and says so on screen, since the caret is usually there already.
      if ([gController.searchBox.layer animationForKey:@"focus-flash"] == nil) {
        failed += 1;
        fprintf(stderr, "ui-self-check FAIL [Panel, %s] pressing the ⌘F hint gave no visible answer\n", suffix.UTF8String);
      }

      // The same window in its other state: a query typed, so the clear button
      // takes the place of the shortcut hint. A control that only exists in one
      // state is only audited if that state is visited.
      gController.searchField.stringValue = @"git";
      [gController updateSearchChrome];
      mz_audit_clicks(gController.panel, [@"Panel with a query, " stringByAppendingString:suffix], &failed);

      // And it has to do its job: pressing it empties the query and the hint
      // comes back. performClick: goes through the button, not around it.
      [gController.searchClearButton performClick:nil];
      if (gController.searchField.stringValue.length != 0 || gController.searchHint.hidden
          || !gController.searchClearButton.hidden) {
        failed += 1;
        fprintf(stderr, "ui-self-check FAIL [Panel, %s] pressing the clear button left query=\"%s\" hint hidden=%d clear hidden=%d\n",
                suffix.UTF8String, gController.searchField.stringValue.UTF8String, gController.searchHint.hidden,
                gController.searchClearButton.hidden);
      }
      gController = nil;
    }
    printf("ui-self-check %s\n", failed == 0 ? "ok" : "FAILED");
    return failed == 0 ? 0 : 1;
  }
}

void mz_app_run(MZAppCallbacks callbacks) {
  @autoreleasepool {
    mz_lang_load();
    NSApplication *app = [NSApplication sharedApplication];
    // The whole UI is hand-painted with dark colors; without pinning the
    // appearance, system-drawn surfaces (popovers, alerts, menus) render
    // light-on-light for light-mode users — the hover preview was unreadable.
    app.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
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
  // Copy before dispatching: the caller (Zig) may free the buffer as soon as
  // this function returns, long before the block runs on the main queue.
  NSString *value = text ? ([NSString stringWithUTF8String:text] ?: @"M") : @"M";
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gController.statusItem.button.image != nil) {
      gController.statusItem.button.toolTip = value.length ? value : @"Maccy";
    } else {
      gController.statusItem.button.title = value.length ? value : @"M";
    }
  });
}

void mz_app_set_rows(const MZAppRow *rows, size_t count) {
  // Explicit pool: the first refresh runs before mz_app_run's pool exists, and
  // later calls arrive from the db queue where drain timing is unspecified.
  @autoreleasepool {
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
      row.sourceContext = mz_string_from_utf8_or_fallback(rows[i].source_context, @"");
      [copy addObject:row];
    }

    mz_debug_log(@"set_rows count=%zu", count);

    void (^apply)(void) = ^{
      int64_t selectedRowID = 0;
      MZRow *selected = [gController selectedItem];
      if (selected != nil) selectedRowID = selected.rowID;

      [gController stampJevMarksOnRows:copy];
      gController.allRows = copy;
      [gController applyCurrentFilterPreservingSelection:selectedRowID];
      mz_debug_log(@"set_rows applied count=%lu selected=%lld",
                   (unsigned long)copy.count, selectedRowID);
    };
    // Apply inline when already on the main thread: an async hop would let a
    // just-typed Enter act on rows the user can no longer see.
    if (NSThread.isMainThread) {
      apply();
    } else {
      dispatch_async(dispatch_get_main_queue(), apply);
    }
  }
}

void mz_app_invalidate_preview_cache(void) {
  [mz_preview_cache() removeAllObjects];
}

void mz_app_beep(void) {
  dispatch_async(dispatch_get_main_queue(), ^{ NSBeep(); });
}

void mz_app_reveal_target(const char *target) {
  if (target == NULL) return;
  // Copy before dispatching — the Zig caller frees `target` when it returns,
  // so reading it inside the async block was a use-after-free.
  NSString *value = [NSString stringWithUTF8String:target];
  dispatch_async(dispatch_get_main_queue(), ^{
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

void mz_app_show_accessibility_alert(void) {
  // The native AXIsProcessTrustedWithOptions prompt is small and easy to
  // miss — especially since we hide the panel right before triggering paste,
  // so the system dialog can land behind whatever app the user just left.
  // We complement it with a louder, app-level alert that activates the app
  // and offers a one-click jump to the Accessibility settings pane.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gController != nil) {
      [gController.panel orderOut:nil];
    }
    [NSApp activateIgnoringOtherApps:YES];

    BOOL trusted = mz_ax_is_trusted(0) != 0;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    if (trusted) {
      alert.messageText = mz_t(@"Accessibility permission already granted");
      alert.informativeText = mz_t(@"MaccyZig already has the permission it needs to paste into other apps.");
      [alert addButtonWithTitle:mz_t(@"OK")];
      [alert runModal];
      return;
    }

    alert.messageText = mz_t(@"Accessibility permission required");
    alert.informativeText = mz_t(@"MaccyZig needs Accessibility permission so it can paste a clipboard "
                                 "item into the app you were using. Click \"Open Settings\", enable "
                                 "MaccyZig under Privacy & Security → Accessibility, then come back "
                                 "and try again.");
    [alert addButtonWithTitle:mz_t(@"Open Settings")];
    [alert addButtonWithTitle:mz_t(@"Cancel")];
    NSModalResponse resp = [alert runModal];
    if (resp != NSAlertFirstButtonReturn) return;

    // Triggering the native prompt is what registers MaccyZig in the
    // Accessibility list. Without this, the user opens Settings and finds
    // nothing to toggle.
    mz_ax_is_trusted(1);
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    if (url != nil) {
      [[NSWorkspace sharedWorkspace] openURL:url];
    }
  });
}
