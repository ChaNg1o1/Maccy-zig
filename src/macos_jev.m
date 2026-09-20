#import "macos_jev.h"
#import <os/lock.h>
#import <stdio.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "macos_ocr.h"
#import <Security/Security.h>

// Jev (TypeSafe System One) picks which clipboard entry belongs in the app the
// user is about to paste into. The model returns a typed Choice over candidate
// row ids -- no free text -- so the answer drops straight into the selection
// logic. https://docs.typesafe.ai/api

// Three ways to reach the same model, one wire format. TypeSafe's own API,
// Vercel AI Gateway's TypeSafe-compatible API ("an existing client only needs
// its base URL changed") and any transparent proxy in front of TypeSafe -- a
// Cloudflare AI Gateway custom provider, say -- all take this request and
// return this response. What differs is only where it is sent, what the model
// is called there, and the credentials. Base URLs follow the SDKs' convention:
// everything before /v1/systemone.
static NSString *const kMZJevSystemOnePath = @"/v1/systemone";
static NSString *const kMZJevTypeSafeBase = @"https://api.typesafe.ai";
static NSString *const kMZJevTypeSafeModel = @"jev-latest";
static NSString *const kMZJevVercelBase = @"https://ai-gateway.vercel.sh/typesafe";
static NSString *const kMZJevVercelModel = @"typesafe-ai/jev";
static NSString *const kMZJevServiceKey = @"MZJevService";
static NSString *const kMZJevCustomBaseKey = @"MZJevCustomBaseURL";
static NSString *const kMZJevCustomModelKey = @"MZJevCustomModel";
static NSString *const kMZJevCustomHeaderNameKey = @"MZJevCustomHeaderName";
static NSString *const kMZJevEnabledKey = @"MZJevEnabled";
static NSString *const kMZJevNoneOption = @"none";

// Sent per candidate. Long enough to tell two entries apart, short enough that
// a stray paragraph of private text does not leave the machine wholesale.
static const NSUInteger kMZJevPreviewChars = 200;
// Same budget for what sits in the field the user is typing into.
static const NSUInteger kMZJevContextChars = 400;
// The caret's neighbourhood is the informative part; the rest of a long field
// is the "large state full of irrelevant detail" that costs accuracy.
static const NSUInteger kMZJevCaretChars = 120;
// The last lines of a terminal: enough for the previous output and the prompt.
static const NSUInteger kMZJevTailChars = 200;
// A Choice's probabilities are relative -- they sum to 1 across every option,
// so the more candidates there are the thinner each slice gets. An absolute
// floor is therefore miscalibrated by construction: measured against the live
// model, a WeChat chat box got the right entry at p=0.38 while a bank "Amount
// (USD)" field correctly answered `none` at p=0.98. A fixed 0.40 cut threw the
// first away and would have kept nothing extra on the second.
//
// So judge the pick against its own distribution instead, using numbers the
// response already carries:
//   * it has to beat the explicit "nothing fits" option, and
//   * it has to be clearly ahead of the runner-up, or the model is really
//     saying "one of these two" and moving the selection is a coin flip.
static const double kMZJevRunnerUpMargin = 1.6;
// How many also-rans get a faint mark in the list. Three rows of sparkle
// would be a second selection; two is a hint.
static const NSUInteger kMZJevRunnerUpMarks = 2;
// The newest entry is already selected when the panel opens, for free. Moving
// the selection off it is the one action that can make things worse, so a
// pick has to beat the default by more than it has to beat anything else:
// staying put when unsure costs the arrow keys the user was going to press
// anyway, while moving to the wrong row costs their trust.
static const double kMZJevDisplaceDefaultMargin = 3.0;
// The panel is on screen while this runs. Past ~1.5s the user has already
// picked by hand and a late suggestion would yank the selection.
static const NSTimeInterval kMZJevTimeout = 1.5;
// AX reads against a hung app must not hold up the request.
static const float kMZJevAXTimeout = 0.35f;
// The screen read starts when the panel opens and costs ~200ms warm; the
// request is assembled ~200ms after that, plus however long Accessibility
// took. So it has usually landed, and this is the most the request will wait
// when it has not. One rule for every app: the context is what the app says
// about the field plus what is on screen around it, never one or the other
// depending on which app it is.
static const NSTimeInterval kMZJevOcrTopUp = 0.2;

// Main-thread only, which every caller already is: mz_jev_suggest and
// mz_jev_cancel are driven by panel lifecycle events, and the one write from
// inside the request hops back to the main queue. The generation counter makes
// a cancelled request's completion a no-op even if it is already in flight.
static NSURLSessionDataTask *gJevTask = nil;
static NSUInteger gJevGeneration = 0;

#pragma mark - Debug tracing

static NSString *const kMZJevDebugKey = @"MZJevDebug";
NSString *const kMZJevLogChangedNotification = @"MZJevLogChanged";
// Enough to hold several suggestions in full; older lines fall off the front.
static const NSUInteger kMZJevLogCapacity = 600;

BOOL mz_jev_debug(void) { return [NSUserDefaults.standardUserDefaults boolForKey:kMZJevDebugKey]; }

void mz_jev_debug_this_process(void) {
  // The registration domain is volatile: it is a default for this process and
  // never reaches the saved setting.
  [NSUserDefaults.standardUserDefaults registerDefaults:@{kMZJevDebugKey: @YES}];
}
void mz_jev_set_debug(BOOL enabled) {
  [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kMZJevDebugKey];
}

// Written from the panel, the ocr queue and the network callback; read by the
// inspector on the main thread.
static NSLock *mz_jev_log_lock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSLock new]; });
  return lock;
}
static NSMutableArray<NSString *> *gJevLogLines = nil;

NSArray<NSString *> *mz_jev_log_lines(void) {
  NSLock *lock = mz_jev_log_lock();
  [lock lock];
  NSArray<NSString *> *copy = [gJevLogLines copy] ?: @[];
  [lock unlock];
  return copy;
}

void mz_jev_log_clear(void) {
  NSLock *lock = mz_jev_log_lock();
  [lock lock];
  [gJevLogLines removeAllObjects];
  [lock unlock];
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter postNotificationName:kMZJevLogChangedNotification object:nil];
  });
}

void mz_jev_log(NSString *format, ...) {
  if (!mz_jev_debug()) return;
  va_list args;
  va_start(args, format);
  NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  if (body == nil) return;

  static NSDateFormatter *stamp = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    stamp = [NSDateFormatter new];
    stamp.dateFormat = @"HH:mm:ss.SSS";
  });
  NSString *line = [NSString stringWithFormat:@"%@  %@", [stamp stringFromDate:NSDate.date], body];

  NSLock *lock = mz_jev_log_lock();
  [lock lock];
  if (gJevLogLines == nil) gJevLogLines = [NSMutableArray array];
  [gJevLogLines addObject:line];
  if (gJevLogLines.count > kMZJevLogCapacity) {
    [gJevLogLines removeObjectsInRange:NSMakeRange(0, gJevLogLines.count - kMZJevLogCapacity)];
  }
  [lock unlock];

  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter postNotificationName:kMZJevLogChangedNotification object:nil];
  });
}

#pragma mark - Settings

BOOL mz_jev_enabled(void) {
  return [NSUserDefaults.standardUserDefaults boolForKey:kMZJevEnabledKey];
}

void mz_jev_set_enabled(BOOL enabled) {
  [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kMZJevEnabledKey];
}

#pragma mark - Credentials

// A development build run straight out of zig-out is a different binary on
// every rebuild, so the legacy keychain's ACL never matches it and macOS asks
// the user to approve access again, every time. Keep those runs in their own
// item so they can never nag about — or accumulate ACL entries on — the one
// the installed app uses.
static NSString *mz_jev_keychain_service(void) {
  static NSString *service;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    BOOL bundled = NSBundle.mainBundle.bundleIdentifier != nil;
    service = bundled ? @"io.github.chang1o1.MaccyZig" : @"io.github.chang1o1.MaccyZig.dev";
  });
  return service;
}
// One item per service, so switching back and forth never loses a key. The
// first account name predates the others and stays as it is: it is what
// installed copies already have in their keychains.
static NSString *mz_jev_key_account(MZJevService service) {
  switch (service) {
    case MZJevServiceVercel: return @"vercel-ai-gateway-api-key";
    case MZJevServiceCustom: return @"custom-api-key";
    case MZJevServiceTypeSafe: break;
  }
  return @"typesafe-api-key";
}
static NSString *const kMZJevCustomHeaderAccount = @"custom-header-value";

// Read once per launch per item. The panel wants the key every time it opens,
// and each read is a chance for the system to put an authorisation dialog in
// front of the user. NSNull marks "looked, nothing there".
static NSMutableDictionary<NSString *, id> *mz_jev_secret_cache(void) {
  static NSMutableDictionary *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
  return cache;
}

// The keychain, not NSUserDefaults: the defaults plist sits unencrypted in the
// user's container and gets swept up by backups and support bundles.
static NSDictionary *mz_jev_keychain_query(NSString *account) {
  return @{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: mz_jev_keychain_service(),
    (__bridge id)kSecAttrAccount: account,
  };
}

static NSString *mz_jev_secret(NSString *account) {
  NSMutableDictionary *cache = mz_jev_secret_cache();
  @synchronized(cache) {
    id cached = cache[account];
    if (cached != nil) return cached == NSNull.null ? nil : cached;
  }
  NSMutableDictionary *query = [NSMutableDictionary dictionaryWithDictionary:mz_jev_keychain_query(account)];
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = NULL;
  NSString *value = nil;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess && result != NULL) {
    NSData *data = (__bridge_transfer NSData *)result;
    value = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length == 0) value = nil;
  }
  @synchronized(cache) { cache[account] = value ?: (id)NSNull.null; }
  return value;
}

static BOOL mz_jev_set_secret(NSString *account, NSString *secret) {
  NSString *trimmed = [secret ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  // Whatever happens below, the cache must not outlive the change.
  NSMutableDictionary *cache = mz_jev_secret_cache();
  @synchronized(cache) { cache[account] = trimmed.length > 0 ? (id)[trimmed copy] : (id)NSNull.null; }
  NSDictionary *query = mz_jev_keychain_query(account);
  if (trimmed.length == 0) {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess || status == errSecItemNotFound;
  }

  NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                  (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
  if (status == errSecItemNotFound) {
    NSMutableDictionary *add = [NSMutableDictionary dictionaryWithDictionary:query];
    add[(__bridge id)kSecValueData] = data;
    // Only ever needed while the user is at the machine, and this keeps it out
    // of iCloud Keychain and off other devices.
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
  }
  return status == errSecSuccess;
}

NSString *mz_jev_api_key(void) { return mz_jev_secret(mz_jev_key_account(mz_jev_service())); }

BOOL mz_jev_set_api_key(NSString *key) { return mz_jev_set_secret(mz_jev_key_account(mz_jev_service()), key); }

#pragma mark - Service

MZJevService mz_jev_service(void) {
  NSInteger stored = [NSUserDefaults.standardUserDefaults integerForKey:kMZJevServiceKey];
  return stored == MZJevServiceVercel || stored == MZJevServiceCustom ? (MZJevService)stored : MZJevServiceTypeSafe;
}

void mz_jev_set_service(MZJevService service) {
  [NSUserDefaults.standardUserDefaults setInteger:service forKey:kMZJevServiceKey];
}

NSString *mz_jev_custom_base_url(void) { return [NSUserDefaults.standardUserDefaults stringForKey:kMZJevCustomBaseKey] ?: @""; }

NSString *mz_jev_custom_model(void) {
  NSString *model = [NSUserDefaults.standardUserDefaults stringForKey:kMZJevCustomModelKey];
  return model.length > 0 ? model : kMZJevTypeSafeModel;
}

NSString *mz_jev_custom_header_name(void) {
  return [NSUserDefaults.standardUserDefaults stringForKey:kMZJevCustomHeaderNameKey] ?: @"";
}

BOOL mz_jev_custom_has_header_value(void) { return mz_jev_secret(kMZJevCustomHeaderAccount) != nil; }

// A base URL as a person pastes it: with or without the endpoint path on the
// end, with or without a trailing slash. https only -- the key and previews of
// what is on the clipboard travel to this address.
NSString *mz_jev_normalised_base_url(NSString *text, NSString **problem) {
  NSString *trimmed = [text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
  if ([trimmed.lowercaseString hasSuffix:kMZJevSystemOnePath]) {
    trimmed = [trimmed substringToIndex:trimmed.length - kMZJevSystemOnePath.length];
  }
  while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
  NSURLComponents *parts = [NSURLComponents componentsWithString:trimmed];
  if (trimmed.length == 0 || parts == nil || parts.host.length == 0) {
    if (problem != NULL) *problem = @"Enter the service's base URL";
    return nil;
  }
  if (![parts.scheme.lowercaseString isEqualToString:@"https"]) {
    if (problem != NULL) *problem = @"The base URL has to start with https://";
    return nil;
  }
  if (parts.query != nil || parts.fragment != nil || parts.user != nil) {
    if (problem != NULL) *problem = @"The base URL cannot carry a query, a fragment or credentials";
    return nil;
  }
  return trimmed;
}

// An extra request header, for gateways that authenticate separately from the
// model provider. The three named here are this client's own.
NSString *mz_jev_header_name_problem(NSString *name) {
  if (name.length == 0) return nil;
  NSCharacterSet *token = [NSCharacterSet characterSetWithCharactersInString:
      @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"];
  if ([name rangeOfCharacterFromSet:token.invertedSet].location != NSNotFound) return @"That is not a valid header name";
  if ([@[ @"authorization", @"content-type", @"content-length", @"host" ] containsObject:name.lowercaseString]) {
    return @"That header is set by MaccyZig itself";
  }
  return nil;
}

NSString *mz_jev_set_custom(NSString *base_url, NSString *model, NSString *header_name, NSString *header_value) {
  NSString *problem = nil;
  NSString *base = mz_jev_normalised_base_url(base_url, &problem);
  if (base == nil) return problem;
  NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
  NSString *name = [header_name ?: @"" stringByTrimmingCharactersInSet:space];
  problem = mz_jev_header_name_problem(name);
  if (problem != nil) return problem;
  NSString *value = [header_value ?: @"" stringByTrimmingCharactersInSet:space];
  // A blank value field means "keep what is stored", as the key field does:
  // the stored value is never shown, so it cannot be retyped from sight.
  if (name.length > 0 && value.length == 0 && !mz_jev_custom_has_header_value()) return @"Enter a value for the header";
  if ([value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
    return @"The header value cannot span lines";
  }

  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  [defaults setObject:base forKey:kMZJevCustomBaseKey];
  [defaults setObject:[model ?: @"" stringByTrimmingCharactersInSet:space] forKey:kMZJevCustomModelKey];
  [defaults setObject:name forKey:kMZJevCustomHeaderNameKey];
  if (name.length == 0) {
    mz_jev_set_secret(kMZJevCustomHeaderAccount, nil);
  } else if (value.length > 0 && !mz_jev_set_secret(kMZJevCustomHeaderAccount, value)) {
    return @"Could not save the header value to the keychain";
  }
  return nil;
}

NSString *mz_jev_service_name(void) {
  switch (mz_jev_service()) {
    case MZJevServiceVercel: return @"Vercel AI Gateway";
    case MZJevServiceCustom: return [NSURLComponents componentsWithString:mz_jev_custom_base_url()].host ?: @"custom endpoint";
    case MZJevServiceTypeSafe: break;
  }
  return @"TypeSafe";
}

// Everything one request needs to know about where it is going, taken in one
// go so that a request never mixes two services' settings.
@interface MZJevRoute : NSObject
@property(nonatomic, copy) NSURL *url;
@property(nonatomic, copy) NSString *model;
@property(nonatomic, copy) NSString *apiKey;
@property(nonatomic, copy) NSString *headerName;
@property(nonatomic, copy) NSString *headerValue;
@end
@implementation MZJevRoute
@end

// Address and model name for a service: the part with no secrets in it, and
// so the part the self-check can hold to the documented values.
static MZJevRoute *mz_jev_route_for(MZJevService service, NSString *custom_base, NSString *custom_model) {
  NSString *base = service == MZJevServiceVercel ? kMZJevVercelBase
      : service == MZJevServiceCustom ? mz_jev_normalised_base_url(custom_base, NULL) : kMZJevTypeSafeBase;
  if (base == nil) return nil;
  MZJevRoute *route = [MZJevRoute new];
  route.url = [NSURL URLWithString:[base stringByAppendingString:kMZJevSystemOnePath]];
  route.model = service == MZJevServiceVercel ? kMZJevVercelModel
      : service == MZJevServiceCustom && custom_model.length > 0 ? custom_model : kMZJevTypeSafeModel;
  return route.url != nil ? route : nil;
}

// `key` overrides the stored one: checking a key before it is saved.
static MZJevRoute *mz_jev_route(NSString *key) {
  MZJevService service = mz_jev_service();
  MZJevRoute *route = mz_jev_route_for(service, mz_jev_custom_base_url(), mz_jev_custom_model());
  if (route == nil) return nil;
  route.apiKey = key ?: mz_jev_api_key();
  if (service == MZJevServiceCustom && mz_jev_custom_header_name().length > 0) {
    route.headerName = mz_jev_custom_header_name();
    route.headerValue = mz_jev_secret(kMZJevCustomHeaderAccount);
  }
  return route;
}

#pragma mark - Redaction

BOOL mz_jev_looks_like_secret(NSString *text) {
  if (text.length == 0) return NO;
  static NSRegularExpression *pattern = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Common credential shapes: vendor-prefixed keys, AWS access key ids, PEM
    // blocks, and `password = ...` style assignments.
    pattern = [NSRegularExpression regularExpressionWithPattern:
        @"(sk-[A-Za-z0-9_-]{12,})"
        @"|(gh[pousr]_[A-Za-z0-9]{16,})"
        @"|(xox[abprs]-[A-Za-z0-9-]{10,})"
        @"|(AKIA[0-9A-Z]{16})"
        @"|(-----BEGIN [A-Z ]*PRIVATE KEY-----)"
        @"|((?:password|passwd|secret|api[_-]?key|token)\\s*[:=]\\s*\\S{6,})"
        @"|(eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.)"
                                                       options:NSRegularExpressionCaseInsensitive
                                                         error:NULL];
  });
  return [pattern firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

// jev-1.13 "will perform better on semantic representations than numeric" and
// "reads dates as text, not as ordered quantities", so anything ordinal is
// bucketed here rather than handed over as a number for the model to rank.
static NSString *mz_jev_age(int64_t copied_at, int64_t now) {
  if (copied_at <= 0) return @"at an unknown time";
  int64_t seconds = now - copied_at;
  if (seconds < 0) seconds = 0;
  if (seconds < 45) return @"just now";
  if (seconds < 15 * 60) return @"a few minutes ago";
  if (seconds < 60 * 60) return @"within the last hour";
  if (seconds < 12 * 60 * 60) return @"earlier today";
  if (seconds < 48 * 60 * 60) return @"yesterday";
  if (seconds < 14 * 24 * 60 * 60) return @"days ago";
  return @"weeks ago";
}

// Only shapes that are unambiguous from structure alone. There is deliberately
// no "shell command" shape: that needs a list of command names, the list is
// never complete, and measurement showed the label itself moves the answer
// (`npx …` 0.49 -> 0.62 once labelled), so commands on the list would be
// favoured over commands off it. The model recognises a command from its text;
// with no list at all the same scenarios still score 6/6.
//
// The shape of an entry is a regex job, not a judgment, and naming it in
// English also gives Jev a handle on entries whose text is CJK -- a script the
// model is documented to read less accurately than English.
static NSString *mz_jev_shape(NSString *text, int content_kind) {
  if (content_kind == 3) return @"an image";
  if (content_kind == 4) return @"a file";
  static NSDictionary<NSString *, NSString *> *patterns = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    patterns = @{
      @"a URL": @"^(https?|ftp|file)://\\S+$",
      @"an email address": @"^[^@\\s]+@[^@\\s]+\\.[A-Za-z]{2,}$",
      @"a file path": @"^(~|/)[^\\s]*$",
      @"a number": @"^[-+]?[0-9][0-9,._]*%?$",
      @"a date": @"^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2}$",
      @"a phone number": @"^[+]?[0-9][0-9 ()-]{6,}$",
    };
  });
  for (NSString *label in patterns) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:patterns[label]
                                                                       options:NSRegularExpressionCaseInsensitive
                                                                         error:NULL];
    if ([re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil) return label;
  }
  if ([text rangeOfString:@"\n"].location != NSNotFound) return @"a multi-line snippet";
  if ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"{};<>()=" ]].location != NSNotFound
      && [text rangeOfString:@" "].location != NSNotFound) {
    return @"a fragment of code";
  }
  return @"a piece of text";
}

// Real fields come back padded with characters that carry no meaning: Lark's
// chat box pads with U+200B, Chrome hands back U+FFFC where an inline object
// sat. They are pure noise in the request.
static NSString *mz_jev_strip_invisibles(NSString *text) {
  static NSCharacterSet *junk = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableCharacterSet *set = [NSMutableCharacterSet new];
    [set formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:
        @"\u200B\u200C\u200D\u2060\uFEFF\uFFFC\u00AD"]];
    [set formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
    // Private-use code points: icon-font glyphs in a shell prompt (Nerd Fonts
    // live here) mean something only to the font that draws them.
    [set addCharactersInRange:NSMakeRange(0xE000, 0xF8FF - 0xE000 + 1)];
    [set addCharactersInRange:NSMakeRange(0xF0000, 0xFFFFD - 0xF0000 + 1)];
    [set addCharactersInRange:NSMakeRange(0x100000, 0x10FFFD - 0x100000 + 1)];
    // Newlines and tabs are real content, not junk.
    [set removeCharactersInString:@"\n\t"];
    junk = [set copy];
  });
  return [[text componentsSeparatedByCharactersInSet:junk] componentsJoinedByString:@""];
}

// The end of a text, not the start: what sits right before the caret, or the
// last lines of a terminal, is the part that says what comes next. Clipping
// from the front kept the opening of a long document and threw that away.
static NSString *mz_jev_clip_tail(NSString *text, NSUInteger limit) {
  NSString *flat = [[mz_jev_strip_invisibles(text) stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (flat.length <= limit) return flat;
  return [@"…" stringByAppendingString:[flat substringFromIndex:flat.length - limit]];
}

static NSString *mz_jev_clip(NSString *text, NSUInteger limit) {
  NSString *flat = [[mz_jev_strip_invisibles(text) stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (flat.length <= limit) return flat;
  return [[flat substringToIndex:limit] stringByAppendingString:@"…"];
}

#pragma mark - Focus context

static NSString *mz_jev_ax_string(AXUIElementRef element, CFStringRef attribute) {
  if (element == NULL) return nil;
  CFTypeRef value = NULL;
  if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return nil;
  NSString *result = nil;
  if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
    result = (__bridge NSString *)value;
    result = result.length > 0 ? [result copy] : nil;
  }
  if (value != NULL) CFRelease(value);
  return result;
}

// How many nodes and how long the walk below may spend. Each node is one IPC
// round trip into another process; this is a side dish, not the meal.
static const NSUInteger kMZJevNeighbourNodes = 90;
static const NSUInteger kMZJevNeighbourSnippets = 5;
static const NSTimeInterval kMZJevNeighbourBudget = 0.2;
// How far up the tree the walk may climb. Web content (browsers, Electron)
// nests a field a dozen or more groups deep, most of them wrappers with a
// single child, so a shallow limit stops before it reaches anything. Climbing
// is cheap -- a wrapper has no earlier siblings to scan -- which makes the
// node and time budgets above the real limits and this only a backstop.
static const int kMZJevNeighbourLevels = 16;

// Role, value and children in one round trip instead of three.
static void mz_jev_ax_node(AXUIElementRef element, NSString **role, NSString **value, NSArray **children) {
  static NSArray *names;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    names = @[ (__bridge id)kAXRoleAttribute, (__bridge id)kAXValueAttribute, (__bridge id)kAXChildrenAttribute ];
  });
  CFArrayRef values = NULL;
  if (AXUIElementCopyMultipleAttributeValues(element, (__bridge CFArrayRef)names, 0, &values) != kAXErrorSuccess
      || values == NULL) return;
  NSArray *row = (__bridge_transfer NSArray *)values;
  if (row.count != 3) return;
  // A missing attribute comes back as an AXValue error, not the type asked for.
  if ([row[0] isKindOfClass:NSString.class]) *role = row[0];
  if ([row[1] isKindOfClass:NSString.class]) *value = row[1];
  if ([row[2] isKindOfClass:NSArray.class]) *children = row[2];
}

// Static text under `node`, last first. Only static text: a neighbouring
// *field's* value is somebody's input, possibly a password, and none of ours.
static void mz_jev_collect_text_reverse(AXUIElementRef node, NSMutableArray<NSString *> *found,
                                        NSUInteger *budget, NSDate *deadline, int depth) {
  if (*budget == 0 || depth > 8 || found.count >= kMZJevNeighbourSnippets) return;
  if (deadline.timeIntervalSinceNow < 0) return;
  *budget -= 1;
  NSString *role = nil, *value = nil;
  NSArray *children = nil;
  mz_jev_ax_node(node, &role, &value, &children);
  if ([role isEqualToString:(__bridge NSString *)kAXStaticTextRole]) {
    NSString *text = [mz_jev_strip_invisibles(value ?: @"")
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length > 1 && !mz_jev_looks_like_secret(text)) [found addObject:mz_jev_clip(text, kMZJevCaretChars)];
    return;
  }
  for (id child in children.reverseObjectEnumerator) {
    mz_jev_collect_text_reverse((__bridge AXUIElementRef)child, found, budget, deadline, depth + 1);
    if (found.count >= kMZJevNeighbourSnippets) return;
  }
}

// The text that comes before the field in reading order. For a form that is
// the field's label, which often lives in a sibling element rather than in any
// attribute of the field itself; for a chat box it is the last message, which
// is frequently the whole answer ("what's your email?"). Browser autofill
// classifies fields from exactly this neighbourhood.
static NSArray<NSString *> *mz_jev_text_before(AXUIElementRef element) {
  NSMutableArray<NSString *> *found = [NSMutableArray array];
  NSUInteger budget = kMZJevNeighbourNodes;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kMZJevNeighbourBudget];
  id branch = (__bridge id)element;
  for (int level = 0; level < kMZJevNeighbourLevels && found.count < kMZJevNeighbourSnippets && budget > 0
                      && deadline.timeIntervalSinceNow > 0; level++) {
    CFTypeRef parent_ref = NULL;
    if (AXUIElementCopyAttributeValue((__bridge AXUIElementRef)branch, kAXParentAttribute, &parent_ref) != kAXErrorSuccess
        || parent_ref == NULL) break;
    id parent = (__bridge_transfer id)parent_ref;
    NSString *role = nil, *value = nil;
    NSArray *children = nil;
    mz_jev_ax_node((__bridge AXUIElementRef)parent, &role, &value, &children);
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < children.count; i++) {
      if (CFEqual((__bridge CFTypeRef)children[i], (__bridge CFTypeRef)branch)) { index = i; break; }
    }
    if (index != NSNotFound) {
      for (NSUInteger i = index; i-- > 0;) {
        mz_jev_collect_text_reverse((__bridge AXUIElementRef)children[i], found, &budget, deadline, 0);
        if (found.count >= kMZJevNeighbourSnippets || budget == 0) break;
      }
    }
    if ([role isEqualToString:(__bridge NSString *)kAXWindowRole]) break;
    branch = parent;
  }
  // Collected nearest-first; hand them over in reading order.
  return found.reverseObjectEnumerator.allObjects;
}

// Text read off the screen around where the paste will land. Recognition sees
// everything in the box, so anything shaped like a credential is dropped line
// by line rather than trusting the region to be innocent.
static void mz_jev_attach_screen_text(NSMutableDictionary *context) {
  NSString *seen = mz_ocr_await(kMZJevOcrTopUp);
  if (seen.length == 0) return;
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (NSString *line in [mz_jev_strip_invisibles(seen) componentsSeparatedByString:@"\n"]) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (trimmed.length > 1 && !mz_jev_looks_like_secret(trimmed)) [lines addObject:trimmed];
  }
  if (lines.count > 0) context[@"text_on_screen_near_the_field"] = [lines componentsJoinedByString:@"\n"];
}

// The element that had focus when the hotkey fired, held across our own
// activation. Written on the main thread, read from the context and screen
// read queues.
static os_unfair_lock gFocusLock = OS_UNFAIR_LOCK_INIT;
static id gCapturedFocus = nil;  // `id` so ARC owns the CF object
static pid_t gCapturedFocusPid = 0;

static id mz_jev_captured_focus(pid_t pid) {
  os_unfair_lock_lock(&gFocusLock);
  id element = gCapturedFocusPid == pid ? gCapturedFocus : nil;
  os_unfair_lock_unlock(&gFocusLock);
  return element;
}

void mz_jev_capture_focus(pid_t pid) {
  id element = nil;
  if (pid > 0 && AXIsProcessTrusted()) {
    AXUIElementRef ax_app = AXUIElementCreateApplication(pid);
    if (ax_app != NULL) {
      // The main thread, in the instant before the panel appears: a slow or
      // hung app gets very little time to hold it up, and this one question is
      // all that is asked here.
      AXUIElementSetMessagingTimeout(ax_app, 0.12f);
      CFTypeRef focused = NULL;
      if (AXUIElementCopyAttributeValue(ax_app, kAXFocusedUIElementAttribute, &focused) == kAXErrorSuccess
          && focused != NULL) {
        element = (__bridge_transfer id)focused;
      }
      CFRelease(ax_app);
    }
  }
  os_unfair_lock_lock(&gFocusLock);
  gCapturedFocus = element;
  gCapturedFocusPid = element != nil ? pid : 0;
  os_unfair_lock_unlock(&gFocusLock);
  if (pid > 0) mz_jev_log(@"focus: %@", element != nil ? @"held the focused element" : @"the app reported no focused element");
}

static BOOL mz_jev_ax_frame(AXUIElementRef element, CGRect *out) {
  CFTypeRef position = NULL, size = NULL;
  CGPoint origin = CGPointZero;
  CGSize extent = CGSizeZero;
  BOOL ok = AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &position) == kAXErrorSuccess
      && AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &size) == kAXErrorSuccess
      && AXValueGetValue((AXValueRef)position, kAXValueTypeCGPoint, &origin)
      && AXValueGetValue((AXValueRef)size, kAXValueTypeCGSize, &extent);
  if (position != NULL) CFRelease(position);
  if (size != NULL) CFRelease(size);
  if (ok) *out = (CGRect){origin, extent};
  return ok;
}

MZJevPasteTarget mz_jev_paste_target(pid_t pid) {
  MZJevPasteTarget target = {CGRectNull, CGRectNull};
  id held = mz_jev_captured_focus(pid);
  if (held == nil) return target;
  AXUIElementRef element = (__bridge AXUIElementRef)held;
  if (!mz_jev_ax_frame(element, &target.field)) return target;

  CFTypeRef range = NULL;
  if (AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &range) != kAXErrorSuccess
      || range == NULL) return target;
  CFTypeRef bounds = NULL;
  if (AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute, range, &bounds)
          == kAXErrorSuccess && bounds != NULL) {
    CGRect caret = CGRectZero;
    if (AXValueGetValue((AXValueRef)bounds, kAXValueTypeCGRect, &caret) && caret.size.height > 0.0) {
      // An insertion point has no width; give it one so it is a rectangle that
      // can be intersected with things.
      caret.size.width = MAX(caret.size.width, 1.0);
      // A caret outside its own field is an app answering in some other
      // coordinate space, or not really answering at all.
      if (CGRectIntersectsRect(caret, target.field)) target.caret = caret;
    }
    CFRelease(bounds);
  }
  CFRelease(range);
  return target;
}

// What the user is looking at: the app, its focused window, and the field the
// caret sits in. Requires the same Accessibility grant auto-paste already
// needs, so it costs the user no extra permission.
//
// Returns nil when the caret is in a secure field -- a password box is never a
// place to suggest clipboard history, and its contents must not be described
// to a third party even in passing.
static NSMutableDictionary *mz_jev_ax_context(pid_t pid) {
  NSMutableDictionary *context = [NSMutableDictionary dictionary];
  NSRunningApplication *app = pid > 0
      ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid]
      : NSWorkspace.sharedWorkspace.frontmostApplication;
  if (app != nil) {
    if (app.localizedName != nil) context[@"app_name"] = app.localizedName;
    if (app.bundleIdentifier != nil) context[@"app_bundle_id"] = app.bundleIdentifier;
  }
  if (pid <= 0 || !AXIsProcessTrusted()) return context;

  AXUIElementRef axApp = AXUIElementCreateApplication(pid);
  if (axApp == NULL) return context;
  AXUIElementSetMessagingTimeout(axApp, kMZJevAXTimeout);

  CFTypeRef window = NULL;
  if (AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute, &window) == kAXErrorSuccess && window != NULL) {
    NSString *title = mz_jev_ax_string((AXUIElementRef)window, kAXTitleAttribute);
    if (title != nil) context[@"window_title"] = mz_jev_clip(title, kMZJevContextChars);
    // Browsers and editors expose the page or file here, which says far more
    // about what belongs in the field than the window title alone.
    NSString *document = mz_jev_ax_string((AXUIElementRef)window, kAXDocumentAttribute);
    if ([document hasPrefix:@"file://"]) {
      // A terminal reports its working directory here, an editor its file.
      NSString *path = [NSURL URLWithString:document].path ?: document;
      document = [path stringByAbbreviatingWithTildeInPath];
    }
    if (document != nil) context[@"window_document"] = mz_jev_clip(document, kMZJevContextChars);
    CFRelease(window);
  }

  CFTypeRef focused = NULL;
  id held = mz_jev_captured_focus(pid);
  if (held != nil) {
    // Captured while the app was still active; see mz_jev_capture_focus.
    focused = CFRetain((__bridge CFTypeRef)held);
  } else if (AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute, &focused) != kAXErrorSuccess) {
    focused = NULL;
  }
  if (focused == NULL) {
    // An app that exposes no focused element at all.
    context[@"focused_element_is_a_text_input"] = @NO;
    CFRelease(axApp);
    return context;
  }
  AXUIElementRef element = (AXUIElementRef)focused;

  NSString *subrole = mz_jev_ax_string(element, kAXSubroleAttribute);
  if ([subrole isEqualToString:(__bridge NSString *)kAXSecureTextFieldSubrole]) {
    CFRelease(focused);
    CFRelease(axApp);
    return nil;
  }

  // Is this somewhere text goes? Role first: a terminal is an AXTextArea whose
  // value Accessibility may not *write*, and judging by writability alone told
  // the model that Ghostty "does not accept text" -- so it answered `none` to
  // a shell command copied twenty seconds earlier. Zed's focused element is
  // its window, Finder's a file list, a browser's focused article is page
  // content: those are the cases that are genuinely not text inputs.
  Boolean writable = false;
  AXUIElementIsAttributeSettable(element, kAXValueAttribute, &writable);
  NSString *ax_role = mz_jev_ax_string(element, kAXRoleAttribute);
  BOOL editable = writable
      || [ax_role isEqualToString:(__bridge NSString *)kAXTextAreaRole]
      || [ax_role isEqualToString:(__bridge NSString *)kAXTextFieldRole]
      || [ax_role isEqualToString:(__bridge NSString *)kAXComboBoxRole]
      || [subrole isEqualToString:(__bridge NSString *)kAXSearchFieldSubrole];
  // @YES/@NO, not @(expr): a C comparison boxes as an int and reaches the
  // model as 1, while the instructions talk about it being "false".
  context[@"focused_element_is_a_text_input"] = editable ? @YES : @NO;

  NSString *role = mz_jev_ax_string(element, kAXRoleDescriptionAttribute);
  if (role != nil) context[editable ? @"focused_field_kind" : @"focused_element_kind"] = role;
  // What the field says about itself. Each of these is a separate signal and
  // they used to be collapsed into one with `?:`, which threw the placeholder
  // away whenever a description existed -- and "you@example.com" is often the
  // most telling of the lot. The label proper comes first from the element the
  // app *declares* to be this field's title (a web <label for=…>), which beats
  // guessing from position.
  NSString *label = nil;
  CFTypeRef title_element = NULL;
  if (AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute, &title_element) == kAXErrorSuccess
      && title_element != NULL) {
    label = mz_jev_ax_string((AXUIElementRef)title_element, kAXValueAttribute)
        ?: mz_jev_ax_string((AXUIElementRef)title_element, kAXTitleAttribute);
    CFRelease(title_element);
  }
  if (label == nil) {
    label = mz_jev_ax_string(element, kAXDescriptionAttribute) ?: mz_jev_ax_string(element, kAXTitleAttribute);
  }
  if (label != nil) {
    // On an editable field this is the prompt ("Email address"); anywhere else
    // it is just whatever content happens to be focused.
    context[editable ? @"focused_field_label" : @"focused_element_text"] =
        mz_jev_clip(label, kMZJevContextChars);
  }
  if (editable) {
    NSString *placeholder = mz_jev_ax_string(element, kAXPlaceholderValueAttribute);
    if (placeholder != nil) context[@"focused_field_placeholder"] = mz_jev_clip(placeholder, kMZJevCaretChars);
    NSString *help = mz_jev_ax_string(element, kAXHelpAttribute);
    if (help != nil) context[@"focused_field_help"] = mz_jev_clip(help, kMZJevCaretChars);
    // The HTML id of a web or Electron field ("email", "billing-phone"): the
    // same signal browser autofill classifies fields by. Long ids are
    // generated noise ("input-7f3a9c…"), so only short ones are worth sending.
    NSString *identifier = mz_jev_ax_string(element, CFSTR("AXDOMIdentifier"));
    if (identifier.length > 0 && identifier.length <= 40) context[@"focused_field_identifier"] = identifier;
  }

  if (!editable) {
    // Nothing further to read from this element, and no caret to read it around.
    CFRelease(focused);
    CFRelease(axApp);
    return context;
  }

  NSArray<NSString *> *before = mz_jev_text_before(element);
  if (before.count > 0) context[@"text_before_the_field"] = before;

  NSString *value = mz_jev_ax_string(element, kAXValueAttribute);
  if (value != nil && mz_jev_looks_like_secret(value)) {
    // A field already holding a credential must not be echoed to the service.
    value = nil;
  }
  context[@"focused_field_is_empty"] = value.length == 0 ? @YES : @NO;
  if (value.length > 0 && !writable) {
    // A read-only text view is a terminal or something like one. Its caret
    // attribute is not meaningful (Ghostty always reports 0); what matters is
    // where the text ends, which is the prompt.
    context[@"text_at_the_end_of_the_view"] = mz_jev_clip_tail(value, kMZJevTailChars);
  } else if (value.length > 0) {
    NSUInteger caret = value.length;
    CFTypeRef range_value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &range_value) == kAXErrorSuccess
        && range_value != NULL) {
      CFRange range = {0, 0};
      if (AXValueGetValue((AXValueRef)range_value, kAXValueTypeCFRange, &range) && range.location >= 0) {
        caret = MIN((NSUInteger)range.location, value.length);
      }
      CFRelease(range_value);
    }
    context[@"text_before_caret"] = mz_jev_clip_tail([value substringToIndex:caret], kMZJevCaretChars);
    // What follows the caret frames the gap as much as what precedes it:
    // "Dear ___, thanks for" or `curl ___ | jq`.
    NSString *after = [value substringFromIndex:caret];
    if ([after stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0) {
      context[@"text_after_caret"] = mz_jev_clip(after, 80);
    }

    NSString *selected = mz_jev_ax_string(element, kAXSelectedTextAttribute);
    if (selected.length > 0 && !mz_jev_looks_like_secret(selected)) {
      // A selection means the paste replaces it, which is a strong hint.
      context[@"text_the_paste_would_replace"] = mz_jev_clip(selected, kMZJevCaretChars);
    }
  }

  CFRelease(focused);
  CFRelease(axApp);
  return context;
}

// Two independent accounts of the same place, always both. Accessibility is
// what the app chooses to say about the field: structured, exact, and absent
// or partial in a great many apps. The screen is what the person is actually
// looking at, in every app whatever it is built with -- but unstructured.
// Neither is a fallback for the other: the tree's reading order is not the
// visual order (what precedes a chat box in the tree is often a banner, while
// what sits above it on screen is the conversation), and pixels cannot say
// "this field's name is email".
static NSDictionary *mz_jev_focus_context(pid_t pid) {
  NSMutableDictionary *context = mz_jev_ax_context(pid);
  if (context == nil) return nil;  // secure field
  mz_jev_attach_screen_text(context);
  return context;
}

#pragma mark - Request / response

// One option, one sentence. Everything ordinal or comparative in it was
// computed in code, because that is the half of the job jev-1.13 is documented
// to be bad at -- and keeping the record here rather than splitting it between
// `criteria` and `state` removes a hop the model would otherwise have to make
// from an option key to a matching entry somewhere else in the request.
static NSString *mz_jev_option_text(NSDictionary *entry) {
  NSMutableArray<NSString *> *clauses = [NSMutableArray array];
  NSString *source_context = entry[@"source_context"];
  // Where it came from is half of what "the thing I want" means to a person:
  // the address from *that email*, not a string shaped like an address.
  NSString *origin = source_context.length > 0
      ? [NSString stringWithFormat:@"\"%@\" in %@", source_context, entry[@"source_app"]]
      : entry[@"source_app"];
  [clauses addObject:[NSString stringWithFormat:@"%@, copied from %@ %@", entry[@"shape"], origin, entry[@"age"]]];
  if ([entry[@"copied_from_destination"] boolValue]) {
    [clauses addObject:@"copied from the app being pasted into"];
  }
  int reuse = [entry[@"copy_count"] intValue];
  if (reuse > 1) [clauses addObject:[NSString stringWithFormat:@"copied %d times in all", reuse]];
  if ([entry[@"pinned"] boolValue]) [clauses addObject:@"starred by the user"];
  // Copying and pasting come in runs: someone gathers a name, an email and a
  // phone number, then fills three fields. What was just used is probably
  // done with; what was gathered alongside it is probably next.
  if ([entry[@"pasted_here_recently"] boolValue]) {
    [clauses addObject:@"already pasted into this app moments ago"];
  } else if ([entry[@"sibling_pasted_here_recently"] boolValue]) {
    [clauses addObject:@"copied in the same batch as an entry that was pasted into this app moments ago"];
  }
  int pastes = [entry[@"pastes_into_destination"] intValue];
  if (pastes > 0) {
    [clauses addObject:pastes == 1 ? @"pasted into this app once before"
                                   : [NSString stringWithFormat:@"pasted into this app %d times before", pastes]];
  }
  return [NSString stringWithFormat:@"\"%@\" — %@", entry[@"preview"],
                                    [clauses componentsJoinedByString:@"; "]];
}

// History stores the source app as a bundle id. "copied from com.google.Chrome"
// is not how anyone describes it, and comparing that id with the destination's
// display *name* meant "copied from the app being pasted into" never fired
// outside the tests, which used names on both sides.
static NSString *mz_jev_app_name(NSString *bundle_id) {
  if (bundle_id.length == 0) return @"an unknown app";
  static NSMutableDictionary<NSString *, NSString *> *names;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ names = [NSMutableDictionary dictionary]; });
  @synchronized(names) {
    NSString *known = names[bundle_id];
    if (known != nil) return known;
    NSString *name = nil;
    NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundle_id];
    if (url != nil) {
      [url getResourceValue:&name forKey:NSURLLocalizedNameKey error:NULL];
      name = name.stringByDeletingPathExtension;
    }
    // Uninstalled since: the last component of the id is still better than the id.
    if (name.length == 0) name = [bundle_id componentsSeparatedByString:@"."].lastObject ?: bundle_id;
    names[bundle_id] = name;
    return name;
  }
}

static NSString *mz_jev_source_context(const char *raw) {
  NSString *context = raw != NULL ? [NSString stringWithUTF8String:raw] : nil;
  if (context.length == 0 || mz_jev_looks_like_secret(context)) return @"";
  return mz_jev_clip(context, 100);
}

// Builds the POST body. Split out from the networking so the self-check can
// inspect it without touching the network.
static NSDictionary *mz_jev_build_body(NSDictionary *focus, NSArray<NSDictionary *> *entries, NSString *model) {
  NSMutableDictionary *criteria = [NSMutableDictionary dictionaryWithCapacity:entries.count + 1];
  for (NSDictionary *entry in entries) {
    criteria[[entry[@"id"] stringValue]] = mz_jev_option_text(entry);
  }
  // Without a no-match option the model is forced to pick something, which is
  // exactly when a suggestion is worse than no suggestion.
  criteria[kMZJevNoneOption] = @"None of these belongs in this field, or the field gives no "
                               @"indication of what would belong there.";

  NSMutableDictionary *state = [NSMutableDictionary dictionaryWithObject:focus forKey:@"destination"];
  NSMutableDictionary *questions = [NSMutableDictionary dictionary];
  questions[@"pick"] = @{
    @"type": @"choice",
    @"instructions": @"A person is pasting into the place described by `destination`. "
                     @"Each option is one entry from their clipboard history. Which "
                     @"entry are they about to paste? Decide from what the destination is "
                     @"asking for and what each entry actually contains. "
                     @"`destination.text_before_the_field` is the text that precedes the "
                     @"field on screen, in reading order: a form label, or the last "
                     @"messages of a conversation. "
                     @"`destination.focused_field_identifier` is the field's name in the page's "
                     @"markup, such as `email` or `billing-phone`. "
                     @"`destination.text_at_the_end_of_the_view` is the last text showing in a "
                     @"view such as a terminal, ending where typing continues. When "
                     @"`destination.focused_element_is_a_text_input` is false the app does not "
                     @"describe where text goes. `destination.text_on_screen_near_the_field` is "
                     @"what the person sees around the place the paste will land, read off the "
                     @"screen top to bottom and ending near that place -- the conversation above "
                     @"a chat box, the lines above a caret. It may repeat "
                     @"`destination.text_before_the_field` and may include surrounding "
                     @"interface. The entries "
                     @"are listed with where and how recently they were copied, how often they "
                     @"have been reused, and what this person has pasted into this same "
                     @"app before; weigh those against how well the content fits the "
                     @"destination. "
                     // Measured on a real paste: two shell commands fit a terminal, one
                     // copied twenty seconds ago and one "copied 9 times in all". Without
                     // this sentence the reuse count won 0.62 to 0.20 and the selection
                     // was yanked off the right row; with it the fresh copy leads, and a
                     // fresh URL still loses to `git rebase` at a shell prompt (0.89).
                     @"People usually paste what they copied most recently: prefer the most "
                     @"recently copied entry that fits the destination, and choose an older "
                     @"entry only when the recent ones clearly do not fit or the older one "
                     @"fits distinctly better.",
    @"criteria": criteria,
  };

  // Shadow question: asked and recorded, deliberately not acted on. Opening
  // the panel already hints the newest entry is not wanted (or ⌘V would have
  // done), and whether "the newest entry fits" is a useful brake on moving the
  // selection is an empirical question. `maccy-zig jev-eval` reports how this
  // number separates the two cases; wire it into the verdict only if it does.
  //
  // Its subject goes in the instructions, never in `state`: every question in
  // a request reads the same state, and `jev-eval` caught a `most_recent_entry`
  // field there dragging the main question toward the newest entry (a Terminal
  // prompt got a GitHub URL at p=0.92 instead of the shell command).
  for (NSDictionary *entry in entries) {
    if ([entry[@"rank"] intValue] != 0) continue;
    questions[@"default_fits"] = @{
      @"type": @"noul",
      @"instructions": [NSString stringWithFormat:
          @"Would a person paste this clipboard entry into the place described by "
          @"`destination`? The entry: %@", mz_jev_option_text(entry)],
    };
    break;
  }

  return @{@"model": model, @"state": state, @"questions": questions};
}

// Returns the picked row id, or 0 with `status` explaining why nothing was
// picked. Split out from the networking so the self-check can drive it with a
// canned payload.
static int64_t mz_jev_pick_from_answer(NSDictionary *payload,
                                       int64_t default_row,
                                       double *confidence_out,
                                       NSArray<NSNumber *> **runner_ups_out,
                                       NSString **status_out) {
  *confidence_out = 0.0;
  *runner_ups_out = @[];
  NSDictionary *answer = payload[@"answers"][@"pick"];
  if (![answer isKindOfClass:NSDictionary.class]) {
    *status_out = @"Jev returned no answer";
    return 0;
  }
  NSString *choice = answer[@"choice"];
  NSDictionary *probabilities = answer[@"probabilities"];
  double probability = [probabilities[choice] doubleValue];
  *confidence_out = probability;

  // "Jev looked and declined" is not news: the panel already shows the
  // top-of-history default, and a line of chrome saying nothing happened every
  // time the user opens the panel is pure noise. Only failures the user can
  // act on get a status.
  *status_out = nil;
  if (choice == nil || [choice isEqualToString:kMZJevNoneOption]) return 0;

  double none_probability = [probabilities[kMZJevNoneOption] doubleValue];
  if (probability <= none_probability) return 0;

  double runner_up = 0.0;
  for (NSString *option in probabilities) {
    if ([option isEqualToString:choice] || [option isEqualToString:kMZJevNoneOption]) continue;
    double value = [probabilities[option] doubleValue];
    if (value > runner_up) runner_up = value;
  }
  NSString *default_option = default_row > 0 ? [@(default_row) stringValue] : nil;
  BOOL confirms_default = default_option != nil && [default_option isEqualToString:choice];
  // The margins below exist to stop the selection being moved to the wrong
  // row. Agreeing with the row that is already selected moves nothing, so it
  // cannot make things worse -- and staying silent about it left the user
  // unable to tell that Jev had looked at all.
  if (!confirms_default && runner_up > 0.0 && probability < runner_up * kMZJevRunnerUpMargin) return 0;

  if (default_option != nil && !confirms_default) {
    double default_probability = [probabilities[default_option] doubleValue];
    if (probability < default_probability * kMZJevDisplaceDefaultMargin) return 0;
  }

  // The also-rans worth a mark: still ahead of "nothing fits", so the model
  // rates them plausible, just not the answer.
  NSMutableArray<NSNumber *> *runners = [NSMutableArray array];
  NSArray<NSString *> *ranked = [probabilities keysSortedByValueUsingComparator:^(id a, id b) {
    return [b compare:a];
  }];
  for (NSString *option in ranked) {
    if (runners.count >= kMZJevRunnerUpMarks) break;
    if ([option isEqualToString:choice] || [option isEqualToString:kMZJevNoneOption]) continue;
    if ([probabilities[option] doubleValue] <= none_probability) continue;
    [runners addObject:@(option.longLongValue)];
  }
  *runner_ups_out = runners;

  return (int64_t)choice.longLongValue;
}

#pragma mark - Transport

// One place that knows how to talk to the service, so the suggestion path and
// the Settings "check key" button report failures in the same words.
// `handler` runs off the main queue with either a payload or a message.
static NSURLSessionDataTask *mz_jev_post(NSDictionary *body,
                                         MZJevRoute *route,
                                         NSTimeInterval timeout,
                                         void (^handler)(NSDictionary *payload, NSString *failure)) {
  NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
  if (json == nil) {
    handler(nil, @"Jev request could not be encoded");
    return nil;
  }

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:route.url];
  request.HTTPMethod = @"POST";
  request.timeoutInterval = timeout;
  request.HTTPBody = json;
  [request setValue:[@"Bearer " stringByAppendingString:route.apiKey] forHTTPHeaderField:@"Authorization"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  if (route.headerName.length > 0 && route.headerValue.length > 0) {
    [request setValue:route.headerValue forHTTPHeaderField:route.headerName];
  }

  NSURLSessionDataTask *task =
      [NSURLSession.sharedSession dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    if (error != nil) {
      // A cancelled task is the panel closing, not a failure worth reporting.
      if (error.code == NSURLErrorCancelled) return;
      handler(nil, error.code == NSURLErrorTimedOut ? @"Jev timed out" : @"Jev is unreachable");
      return;
    }
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status == 401 || status == 403) { handler(nil, @"Jev rejected the API key"); return; }
    if (status == 429 || status == 529) { handler(nil, @"Jev is rate limited"); return; }
    if (status != 200) {
      handler(nil, [NSString stringWithFormat:@"Jev returned HTTP %ld", (long)status]);
      return;
    }
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![payload isKindOfClass:NSDictionary.class]) {
      handler(nil, @"Jev returned an unreadable response");
      return;
    }
    handler(payload, nil);
  }];
  return task;
}

void mz_jev_verify_api_key(NSString *key, void (^completion)(BOOL ok, NSString *message)) {
  NSString *trimmed = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (trimmed.length == 0) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"Enter an API key first"); });
    return;
  }
  // Smallest question the service will accept: we only care whether the key
  // and the network work, not what the answer is.
  MZJevRoute *route = mz_jev_route(trimmed);
  if (route == nil) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"Set up the custom endpoint first"); });
    return;
  }
  NSDictionary *body = @{
    @"model": route.model,
    @"state": @"ping",
    @"questions": @{@"ok": @{@"type": @"noul", @"instructions": @"Is this text non-empty?"}},
  };
  NSURLSessionDataTask *task = mz_jev_post(body, route, 10.0, ^(NSDictionary *payload, NSString *failure) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(payload != nil, payload != nil ? @"API key works" : failure);
    });
  });
  [task resume];
}

#pragma mark - Inspector placement

NSRect mz_jev_inspector_frame(NSRect inspector, NSRect panel, NSRect screen) {
  if (!NSIntersectsRect(inspector, panel)) return inspector;
  const CGFloat gap = 12.0;
  NSRect placed = inspector;
  // Prefer the left of the panel, then the right; if neither side fits whole,
  // take the wider side and shrink to it rather than staying hidden.
  CGFloat left_x = NSMinX(panel) - gap - NSWidth(inspector);
  CGFloat right_x = NSMaxX(panel) + gap;
  if (left_x >= NSMinX(screen)) {
    placed.origin.x = left_x;
  } else if (right_x + NSWidth(inspector) <= NSMaxX(screen)) {
    placed.origin.x = right_x;
  } else {
    // Neither side fits the window whole, so shrink it into the wider one.
    // The width has to come from the room actually there: clamping up to a
    // minimum would push the window straight back under the panel, which is
    // the problem this function exists to solve.
    CGFloat room_left = NSMinX(panel) - NSMinX(screen);
    CGFloat room_right = NSMaxX(screen) - NSMaxX(panel);
    CGFloat room = MAX(room_left, room_right) - gap * 2.0;
    // Below this there is nothing useful to show, so leave the window where
    // the user put it rather than shuffling it somewhere equally hidden.
    if (room < 280.0) return inspector;
    placed.size.width = room;
    placed.origin.x = room_left >= room_right ? NSMinX(screen) + gap
                                              : NSMaxX(panel) + gap;
  }
  // Align tops with the panel, then keep the whole window on screen.
  placed.origin.y = MIN(NSMaxY(panel), NSMaxY(screen)) - NSHeight(placed);
  if (NSMinY(placed) < NSMinY(screen)) placed.origin.y = NSMinY(screen);
  return placed;
}

static int64_t mz_jev_default_row(NSArray<NSDictionary *> *entries) {
  for (NSDictionary *entry in entries) {
    if ([entry[@"rank"] intValue] == 0) return [entry[@"id"] longLongValue];
  }
  return 0;
}

#pragma mark - Evaluation samples

// The ingredients, not the finished request: replaying a sample runs them
// through whatever mz_jev_build_body is *now*, so a reworded question or a new
// option sentence can be scored against situations recorded before the change.
static NSLock *mz_jev_sample_lock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSLock new]; });
  return lock;
}
static NSString *gLastSample = nil;

static void mz_jev_remember_sample(NSDictionary *focus, NSArray<NSDictionary *> *entries) {
  NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"destination": focus, @"entries": entries}
                                                 options:0 error:NULL];
  NSString *text = json != nil ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
  NSLock *lock = mz_jev_sample_lock();
  [lock lock];
  gLastSample = text;
  [lock unlock];
}

NSString *mz_jev_take_last_sample(void) {
  NSLock *lock = mz_jev_sample_lock();
  [lock lock];
  NSString *sample = gLastSample;
  gLastSample = nil;
  [lock unlock];
  return sample;
}

int mz_jev_eval_sample(const char *sample_json, int64_t chosen_row, MZJevEvalResult *out) {
  if (sample_json == NULL || out == NULL) return 1;
  memset(out, 0, sizeof(*out));
  out->default_fits = -1.0;
  NSData *data = [NSData dataWithBytes:sample_json length:strlen(sample_json)];
  NSDictionary *sample = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  NSDictionary *focus = sample[@"destination"];
  NSArray<NSDictionary *> *entries = sample[@"entries"];
  if (![focus isKindOfClass:NSDictionary.class] || ![entries isKindOfClass:NSArray.class]) return 2;

  for (NSDictionary *entry in entries) {
    if ([entry[@"id"] longLongValue] == chosen_row) { out->chosen_present = 1; break; }
  }
  MZJevRoute *route = mz_jev_route(nil);
  if (route.apiKey == nil) return 3;

  __block NSDictionary *answer = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  // A generous timeout: this is an offline batch, not a panel waiting to draw.
  NSURLSessionDataTask *task = mz_jev_post(mz_jev_build_body(focus, entries, route.model), route, 20.0,
                                           ^(NSDictionary *payload, NSString *failure) {
    answer = payload;
    dispatch_semaphore_signal(done);
  });
  if (task == nil) return 4;
  [task resume];
  dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)));
  if (answer == nil) return 5;

  NSArray<NSNumber *> *runners = nil;
  NSString *status = nil;
  double probability = 0.0;
  int64_t accepted_row = mz_jev_pick_from_answer(answer, mz_jev_default_row(entries), &probability, &runners, &status);
  NSString *choice = answer[@"answers"][@"pick"][@"choice"];
  out->choice_row = [choice isEqualToString:kMZJevNoneOption] ? 0 : (int64_t)choice.longLongValue;
  out->accepted = accepted_row > 0 ? 1 : 0;
  out->probability = probability;
  NSNumber *fits = answer[@"answers"][@"default_fits"][@"noul"];
  if ([fits isKindOfClass:NSNumber.class]) out->default_fits = fits.doubleValue;
  out->input_tokens = [answer[@"usage"][@"input_tokens"] intValue];
  return 0;
}

#pragma mark - Entry points

void mz_jev_cancel(void) {
  gJevGeneration += 1;
  [gJevTask cancel];
  gJevTask = nil;
}

void mz_jev_suggest(pid_t target_pid,
                    const MZJevCandidate *candidates,
                    size_t count,
                    void (^completion)(int64_t row_id,
                                       double confidence,
                                       NSArray<NSNumber *> *runner_ups,
                                       NSString *status)) {
  mz_jev_cancel();
  NSUInteger generation = gJevGeneration;
  void (^finish)(int64_t, double, NSArray<NSNumber *> *, NSString *) =
      ^(int64_t row, double conf, NSArray<NSNumber *> *runners, NSString *status) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != gJevGeneration) return;
      completion(row, conf, runners, status);
    });
  };

  if (!mz_jev_enabled()) {
    finish(0, 0.0, nil, nil);
    return;
  }
  // Taken here, on the main thread and in one go: the request below is built
  // on another queue, and it must not see half of a settings change.
  MZJevRoute *route = mz_jev_route(nil);
  if (route.apiKey == nil) {
    finish(0, 0.0, nil, @"Jev needs an API key (Settings)");
    return;
  }

  int64_t now = (int64_t)NSDate.date.timeIntervalSince1970;
  NSMutableArray<NSMutableDictionary *> *entries = [NSMutableArray arrayWithCapacity:count];
  for (size_t i = 0; i < count; i++) {
    const char *raw = candidates[i].preview;
    NSString *preview = raw != NULL ? [NSString stringWithUTF8String:raw] : nil;
    if (preview.length == 0) continue;
    // Credentials stay on the machine. They are dropped from the candidate set
    // rather than masked, so Jev cannot pick one either.
    if (mz_jev_looks_like_secret(preview)) continue;
    const char *app = candidates[i].source_app;
    NSString *source_bundle = app != NULL ? ([NSString stringWithUTF8String:app] ?: @"") : @"";
    [entries addObject:[@{
      @"id": @(candidates[i].row_id),
      @"preview": mz_jev_clip(preview, kMZJevPreviewChars),
      @"shape": mz_jev_shape(preview, candidates[i].content_kind),
      @"source_app": mz_jev_app_name(source_bundle),
      @"source_bundle_id": source_bundle,
      @"age": mz_jev_age(candidates[i].copied_at, now),
      @"copy_count": @(candidates[i].copy_count),
      @"pinned": @(candidates[i].pinned != 0),
      @"pastes_into_destination": @(candidates[i].pastes_into_destination),
      @"copied_from_destination": @NO,
      // List position, so the builder knows which entry is the panel's default
      // even after credentials have been dropped from in front of it.
      @"rank": @(i),
      @"source_context": [mz_jev_source_context(candidates[i].source_context) copy],
      @"pasted_here_recently": @(candidates[i].pasted_here_recently != 0),
      @"sibling_pasted_here_recently": @(candidates[i].sibling_pasted_here_recently != 0),
    } mutableCopy]];
  }
  if (entries.count < 2) {
    mz_jev_log(@"skipped: only %lu candidate(s) after redaction", (unsigned long)entries.count);
    // One candidate is not a decision.
    finish(0, 0.0, nil, nil);
    return;
  }

  // AX reads can block on a busy target app, so gather context off the main
  // thread; the panel is already visible and must stay responsive.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSDictionary *focus = mz_jev_focus_context(target_pid);
    if (focus == nil) {
      // Caret is in a password field. Say nothing and send nothing.
      finish(0, 0.0, nil, nil);
      return;
    }
    // "Did this come from the app I am pasting into?" is a comparison, so code
    // answers it rather than making the model hop between two state fields.
    NSString *destination_bundle = focus[@"app_bundle_id"];
    if (destination_bundle.length > 0) {
      for (NSMutableDictionary *entry in entries) {
        entry[@"copied_from_destination"] =
            [entry[@"source_bundle_id"] isEqualToString:destination_bundle] ? @YES : @NO;
      }
    }
    NSDictionary *body = mz_jev_build_body(focus, entries, route.model);
    mz_jev_remember_sample(focus, entries);
    if (mz_jev_debug()) {
      mz_jev_log(@"--- suggestion ---");
      mz_jev_log(@"destination: %@", focus);
      NSDictionary *criteria = body[@"questions"][@"pick"][@"criteria"];
      for (NSString *option in [criteria.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        mz_jev_log(@"  option %@: %@", option, criteria[option]);
      }
    }
    NSURLSessionDataTask *task = mz_jev_post(body, route, kMZJevTimeout, ^(NSDictionary *payload, NSString *failure) {
      if (payload == nil) {
        mz_jev_log(@"request failed: %@", failure ?: @"cancelled");
        if (failure != nil) finish(0, 0.0, nil, failure);
        return;
      }
      double confidence = 0.0;
      NSArray<NSNumber *> *runners = nil;
      NSString *why = nil;
      int64_t picked = mz_jev_pick_from_answer(payload, mz_jev_default_row(entries), &confidence, &runners, &why);
      mz_jev_log(@"answer: %@", payload[@"answers"][@"pick"]);
      if (payload[@"answers"][@"default_fits"] != nil) {
        mz_jev_log(@"shadow default_fits: %@ (recorded, not acted on)",
                   payload[@"answers"][@"default_fits"][@"noul"]);
      }
      mz_jev_log(@"verdict: %@ (p=%.2f)%@%@",
                 picked > 0 ? [NSString stringWithFormat:@"row %lld", picked] : @"nothing",
                 confidence,
                 runners.count > 0 ? [NSString stringWithFormat:@" runners-up %@", runners] : @"",
                 why != nil ? [NSString stringWithFormat:@" status \"%@\"", why] : @"");
      mz_jev_log(@"tokens: in=%@ out=%@", payload[@"usage"][@"input_tokens"], payload[@"usage"][@"output_tokens"]);
      finish(picked, confidence, runners, why);
    });
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != gJevGeneration) {
        [task cancel];
        return;
      }
      gJevTask = task;
      [task resume];
    });
  });
}

#pragma mark - Context probe

// `maccy-zig jev-context`: answers "what does Jev actually see in this app?"
// without opening the panel, which is the question behind most "why didn't it
// suggest anything here".
int mz_jev_print_context(int delay_seconds) {
  @autoreleasepool {
    if (!AXIsProcessTrusted()) {
      printf("Accessibility is not granted to this binary; only the app name would be visible.\n");
    }
    // The delay is there so a person can click into a field. Aimed at a pid,
    // there is nobody to wait for -- and a panel that hides on deactivation
    // would be gone by the time the wait was over.
    if (getenv("MZ_JEV_CONTEXT_PID") != NULL) delay_seconds = 0;
    if (delay_seconds > 0) {
      printf("focus the field you care about... reading in %d s\n", delay_seconds);
      fflush(stdout);
      [NSThread sleepForTimeInterval:delay_seconds];
    }
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    // MZ_JEV_CONTEXT_PID aims the probe at one process; without it, whatever
    // is frontmost after the delay.
    const char *forced = getenv("MZ_JEV_CONTEXT_PID");
    pid_t pid = forced != NULL ? (pid_t)atoi(forced) : front.processIdentifier;
    // The same three steps, in the same order, as opening the panel -- so what
    // this prints is what a suggestion would have been built from.
    [NSApplication sharedApplication];  // ScreenCaptureKit needs a window-server connection
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    mz_jev_debug_this_process();
    mz_jev_capture_focus(pid);
    mz_ocr_begin(pid);
    // A fresh process pays the recogniser's one-off model load here; the app
    // paid it at launch.
    (void)mz_ocr_await(30.0);
    NSDictionary *focus = mz_jev_focus_context(pid);
    if (focus == nil) {
      printf("secure text field focused: Jev is told nothing and suggests nothing.\n");
      return 0;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:focus
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    printf("%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    for (NSString *line in mz_jev_log_lines()) printf("  %s\n", line.UTF8String);
    return json != nil ? 0 : 1;
  }
}

#pragma mark - Self-check

// The self-check does not care about runner-ups; this keeps its call sites
// readable, since a braced dictionary literal cannot pass through a macro.
static int64_t mz_jev_pick_from_answer_sc(NSDictionary *payload, double *confidence_out, NSString **status_out) {
  NSArray<NSNumber *> *ignored = nil;
  return mz_jev_pick_from_answer(payload, 0, confidence_out, &ignored, status_out);
}

// Exercises the parts that are wrong-by-silence: redaction, candidate framing,
// and the confidence gate. Runs offline. `maccy-zig jev-self-check`.
int mz_jev_self_check(void) {
  int failures = 0;
#define MZ_EXPECT(cond, label)                                                   \
  do {                                                                           \
    if (!(cond)) {                                                               \
      fprintf(stderr, "jev-self-check FAIL: %s\n", (label));                      \
      failures += 1;                                                              \
    }                                                                             \
  } while (0)

  MZ_EXPECT(mz_jev_looks_like_secret(@"sk-apikey-askdjhasjkcvnaeo2143"), "vendor api key");
  MZ_EXPECT(mz_jev_looks_like_secret(@"ghp_1234567890abcdefghij"), "github token");
  MZ_EXPECT(mz_jev_looks_like_secret(@"AKIAIOSFODNN7EXAMPLE"), "aws access key id");
  MZ_EXPECT(mz_jev_looks_like_secret(@"password = hunter2xyz"), "password assignment");
  MZ_EXPECT(mz_jev_looks_like_secret(@"-----BEGIN RSA PRIVATE KEY-----"), "pem block");
  MZ_EXPECT(!mz_jev_looks_like_secret(@"墨尔本有什么好玩的"), "plain text is not a secret");
  MZ_EXPECT(!mz_jev_looks_like_secret(@"console.log('test');"), "code is not a secret");

  NSDictionary *entry = @{@"id": @7, @"preview": @"git rebase -i HEAD~3", @"shape": @"a piece of text",
                          @"source_app": @"Terminal", @"age": @"just now", @"copy_count": @3,
                          @"pinned": @YES, @"pastes_into_destination": @2,
                          @"copied_from_destination": @YES};
  NSDictionary *body = mz_jev_build_body(@{@"app_name": @"Terminal"},
                                         @[entry,
                                           @{@"id": @9, @"preview": @"墨尔本有什么好玩的", @"shape": @"a piece of text",
                                             @"source_app": @"Notes", @"age": @"yesterday", @"copy_count": @1,
                                             @"pinned": @NO, @"pastes_into_destination": @0,
                                             @"copied_from_destination": @NO}],
                                         kMZJevVercelModel);
  NSDictionary *criteria = body[@"questions"][@"pick"][@"criteria"];
  MZ_EXPECT(criteria.count == 3, "two candidates plus a no-match option");
  MZ_EXPECT(criteria[@"7"] != nil && criteria[@"9"] != nil, "options keyed by row id");
  MZ_EXPECT(criteria[kMZJevNoneOption] != nil, "no-match option present");
  MZ_EXPECT([NSJSONSerialization isValidJSONObject:body], "body is serializable");
  MZ_EXPECT(body[@"state"][@"destination"] != nil, "state carries the destination");
  MZ_EXPECT(body[@"state"][@"clipboard_history"] == nil,
            "records live in criteria only, never duplicated into state");

  // Every ordinal fact reaches the model already described, never as a number
  // or a timestamp for it to rank.
  NSString *option = mz_jev_option_text(entry);
  MZ_EXPECT([option containsString:@"just now"], "age is described, not a timestamp");
  MZ_EXPECT([option containsString:@"a piece of text"], "shape is computed in code");
  MZ_EXPECT([option containsString:@"copied 3 times"], "reuse count is stated");
  MZ_EXPECT([option containsString:@"starred"], "starring is stated");
  MZ_EXPECT([option containsString:@"pasted into this app 2 times before"], "paste log is stated");
  MZ_EXPECT([option containsString:@"copied from the app being pasted into"], "same-app origin is stated");
  MZ_EXPECT(![mz_jev_option_text(@{@"id": @1, @"preview": @"x", @"shape": @"a piece of text",
                                   @"source_app": @"Notes", @"age": @"yesterday", @"copy_count": @1,
                                   @"pinned": @NO, @"pastes_into_destination": @0,
                                   @"copied_from_destination": @NO}) containsString:@"starred"],
            "clauses that do not apply are left out");

  // Provenance and sequence clauses.
  NSMutableDictionary *rich = [entry mutableCopy];
  rich[@"source_context"] = @"Zhang San - Contact (crm.example.com/contacts/42)";
  rich[@"rank"] = @0;
  MZ_EXPECT([mz_jev_option_text(rich) containsString:@"copied from \"Zhang San - Contact (crm.example.com/contacts/42)\" in Terminal"],
            "where it was copied from is stated");
  rich[@"sibling_pasted_here_recently"] = @YES;
  MZ_EXPECT([mz_jev_option_text(rich) containsString:@"same batch"], "burst sibling is stated");
  rich[@"pasted_here_recently"] = @YES;
  MZ_EXPECT([mz_jev_option_text(rich) containsString:@"already pasted into this app moments ago"]
                && ![mz_jev_option_text(rich) containsString:@"same batch"],
            "an entry that was itself just pasted says so, and only that");
  MZ_EXPECT([mz_jev_source_context("token=abcdef123456 Dashboard") isEqualToString:@""],
            "a window title that carries a credential is dropped");
  MZ_EXPECT([mz_jev_source_context(NULL) isEqualToString:@""], "no context is empty, not nil");

  // The shadow question exists only when the panel's default row is a candidate.
  NSDictionary *with_default = mz_jev_build_body(@{@"app_name": @"Terminal"}, @[rich], kMZJevTypeSafeModel);
  MZ_EXPECT(with_default[@"questions"][@"default_fits"] != nil,
            "default row present: shadow question is asked about it");
  MZ_EXPECT([with_default[@"state"] count] == 1 && with_default[@"state"][@"destination"] != nil,
            "state holds the destination and nothing else: questions share it");
  NSMutableDictionary *not_default = [rich mutableCopy];
  not_default[@"rank"] = @1;
  NSDictionary *without_default = mz_jev_build_body(@{@"app_name": @"Terminal"}, @[not_default], kMZJevTypeSafeModel);
  MZ_EXPECT(without_default[@"questions"][@"default_fits"] == nil,
            "default row redacted away: nothing to ask about");
  MZ_EXPECT([NSJSONSerialization isValidJSONObject:with_default], "body with shadow question serializes");

  // A sample is taken once and replays through the current builder.
  mz_jev_remember_sample(@{@"app_name": @"Terminal"}, @[rich]);
  NSString *sample = mz_jev_take_last_sample();
  MZ_EXPECT(sample != nil && mz_jev_take_last_sample() == nil, "a sample can be taken exactly once");
  NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[sample dataUsingEncoding:NSUTF8StringEncoding]
                                                         options:0 error:NULL];
  NSDictionary *rebuilt = mz_jev_build_body(parsed[@"destination"], parsed[@"entries"], kMZJevTypeSafeModel);
  MZ_EXPECT([rebuilt[@"questions"][@"pick"][@"criteria"][@"7"] isEqualToString:mz_jev_option_text(rich)],
            "a stored sample rebuilds to the same option sentence");

  MZ_EXPECT([mz_jev_shape(@"https://example.com/a", 1) isEqualToString:@"a URL"], "url shape");
  MZ_EXPECT([mz_jev_shape(@"a@b.co", 1) isEqualToString:@"an email address"], "email shape");
  MZ_EXPECT([mz_jev_shape(@"git status", 1) isEqualToString:@"a piece of text"], "commands are left to the model");
  MZ_EXPECT([mz_jev_shape(@"2026-09-19", 1) isEqualToString:@"a date"], "date shape");
  MZ_EXPECT([mz_jev_shape(@"墨尔本有什么好玩的", 1) isEqualToString:@"a piece of text"], "plain text shape");
  MZ_EXPECT([mz_jev_age(0, 1000) isEqualToString:@"at an unknown time"], "missing timestamp");
  MZ_EXPECT([mz_jev_age(1000, 1010) isEqualToString:@"just now"], "fresh copy");
  MZ_EXPECT([mz_jev_age(1000, 1000 + 3 * 24 * 3600) isEqualToString:@"days ago"], "old copy");

  // Inspector placement. Screen 1728x1080; panel 561 wide, centred.
  NSRect screen = NSMakeRect(0, 0, 1728, 1080);
  NSRect panel = NSMakeRect(583, 300, 561, 700);
  NSRect wide = NSMakeRect(500, 200, 520, 620);
  NSRect clear = NSMakeRect(20, 20, 400, 300);
  MZ_EXPECT(NSEqualRects(mz_jev_inspector_frame(clear, panel, screen), clear),
            "a window already clear of the panel is left where it is");
  NSRect placed = mz_jev_inspector_frame(wide, panel, screen);
  MZ_EXPECT(!NSIntersectsRect(placed, panel), "an overlapping window is moved clear");
  MZ_EXPECT(NSMaxX(placed) == NSMinX(panel) - 12.0, "placed to the left of the panel");
  MZ_EXPECT(NSMaxY(placed) == NSMaxY(panel), "tops aligned with the panel");
  MZ_EXPECT(NSMinX(placed) >= NSMinX(screen) && NSMaxY(placed) <= NSMaxY(screen), "stays on screen");

  // Panel hard against the left edge: the only room is on the right.
  NSRect left_panel = NSMakeRect(0, 300, 561, 700);
  placed = mz_jev_inspector_frame(wide, left_panel, screen);
  MZ_EXPECT(NSMinX(placed) == NSMaxX(left_panel) + 12.0, "falls back to the right side");
  MZ_EXPECT(!NSIntersectsRect(placed, left_panel), "right-side placement still clears the panel");

  // A narrow screen where neither side fits the full width.
  NSRect narrow_screen = NSMakeRect(0, 0, 1000, 1080);
  NSRect narrow_panel = NSMakeRect(220, 300, 561, 700);
  placed = mz_jev_inspector_frame(wide, narrow_panel, narrow_screen);
  MZ_EXPECT(NSEqualRects(placed, wide),
            "too cramped to help: the window is left where the user put it");

  // Room on one side for a usable, if narrower, window.
  NSRect roomy_screen = NSMakeRect(0, 0, 1400, 1080);
  NSRect roomy_panel = NSMakeRect(600, 300, 561, 700);
  placed = mz_jev_inspector_frame(NSMakeRect(700, 200, 900, 620), roomy_panel, roomy_screen);
  MZ_EXPECT(NSWidth(placed) < 900.0 && NSWidth(placed) >= 280.0, "shrinks into the wider side");
  MZ_EXPECT(!NSIntersectsRect(placed, roomy_panel), "the shrunk window still clears the panel");
  MZ_EXPECT(NSMinX(placed) >= 0.0 && NSMaxX(placed) <= 1400.0, "the shrunk window stays on screen");

  // A window taller than the space above the panel bottom must not slide off.
  NSRect tall = NSMakeRect(500, 200, 720, 1200);
  placed = mz_jev_inspector_frame(tall, panel, screen);
  MZ_EXPECT(NSMinY(placed) >= NSMinY(screen), "a tall window is clamped to the screen");

  // Services. The body carries whatever the service calls the model.
  MZ_EXPECT([body[@"model"] isEqualToString:@"typesafe-ai/jev"], "the model name follows the service");
  NSString *problem = nil;
  MZ_EXPECT([mz_jev_normalised_base_url(@" https://gateway.ai.cloudflare.com/v1/acct/gw/custom-typesafe/v1/systemone/ ", &problem)
                isEqualToString:@"https://gateway.ai.cloudflare.com/v1/acct/gw/custom-typesafe"],
            "a pasted endpoint is cut back to its base URL");
  MZ_EXPECT([mz_jev_normalised_base_url(@"https://ai-gateway.vercel.sh/typesafe", &problem)
                isEqualToString:@"https://ai-gateway.vercel.sh/typesafe"], "a base URL is kept as it is");
  MZ_EXPECT(mz_jev_normalised_base_url(@"http://proxy.example.com", &problem) == nil && problem != nil,
            "plain http is refused: the key would travel in the clear");
  MZ_EXPECT(mz_jev_normalised_base_url(@"https://user:pw@proxy.example.com", &problem) == nil, "credentials in the URL are refused");
  MZ_EXPECT(mz_jev_normalised_base_url(@"not a url", &problem) == nil, "garbage is refused");
  MZ_EXPECT(mz_jev_normalised_base_url(@"", &problem) == nil, "empty is refused");
  MZ_EXPECT(mz_jev_header_name_problem(@"cf-aig-authorization") == nil, "a gateway's own auth header is accepted");
  MZ_EXPECT(mz_jev_header_name_problem(@"") == nil, "no extra header is fine");
  MZ_EXPECT(mz_jev_header_name_problem(@"Authorization") != nil, "the client's own headers cannot be overridden");
  MZ_EXPECT(mz_jev_header_name_problem(@"bad header") != nil, "a header name with a space is refused");
  MZJevRoute *direct = mz_jev_route_for(MZJevServiceTypeSafe, nil, nil);
  MZ_EXPECT([direct.url.absoluteString isEqualToString:@"https://api.typesafe.ai/v1/systemone"]
                && [direct.model isEqualToString:@"jev-latest"], "TypeSafe: its own address and model name");
  MZJevRoute *vercel = mz_jev_route_for(MZJevServiceVercel, nil, nil);
  MZ_EXPECT([vercel.url.absoluteString isEqualToString:@"https://ai-gateway.vercel.sh/typesafe/v1/systemone"]
                && [vercel.model isEqualToString:@"typesafe-ai/jev"], "Vercel: the TypeSafe-compatible API and its model name");
  MZJevRoute *proxied = mz_jev_route_for(MZJevServiceCustom, @"https://gateway.ai.cloudflare.com/v1/a/g/custom-typesafe/", @"");
  MZ_EXPECT([proxied.url.absoluteString isEqualToString:@"https://gateway.ai.cloudflare.com/v1/a/g/custom-typesafe/v1/systemone"]
                && [proxied.model isEqualToString:@"jev-latest"], "custom: base URL plus the endpoint path, TypeSafe's model name by default");
  MZ_EXPECT(mz_jev_route_for(MZJevServiceCustom, @"", nil) == nil, "custom with no address goes nowhere");
  // The request as it would leave, without sending it.
  proxied.apiKey = @"key";
  proxied.headerName = @"cf-aig-authorization";
  proxied.headerValue = @"Bearer gateway-token";
  NSURLSessionDataTask *unsent = mz_jev_post(@{@"model": proxied.model}, proxied, 1.0, ^(NSDictionary *p, NSString *f) {
    (void)p;
    (void)f;
  });
  NSDictionary *sent = unsent.originalRequest.allHTTPHeaderFields;
  MZ_EXPECT([sent[@"Authorization"] isEqualToString:@"Bearer key"]
                && [sent[@"cf-aig-authorization"] isEqualToString:@"Bearer gateway-token"]
                && [unsent.originalRequest.URL isEqual:proxied.url], "the provider's key and the gateway's header both go out");
  [unsent cancel];

  MZ_EXPECT(![mz_jev_key_account(MZJevServiceTypeSafe) isEqualToString:mz_jev_key_account(MZJevServiceVercel)]
                && ![mz_jev_key_account(MZJevServiceVercel) isEqualToString:mz_jev_key_account(MZJevServiceCustom)],
            "each service keeps its own key");
  MZ_EXPECT([mz_jev_key_account(MZJevServiceTypeSafe) isEqualToString:@"typesafe-api-key"],
            "the original keychain item keeps its name");

  // Which part of a window the screen read covers. Top-left coordinates: y
  // grows downwards, so "above" is smaller y. Window 1600x1000 at (100, 50).
  CGRect window = CGRectMake(100, 50, 1600, 1000);
  CGPoint away = CGPointMake(5000, 5000);
  CGFloat landing = 0.0;
  NSString *source = nil;

  // A chat box along the bottom with the caret in it.
  MZJevPasteTarget chat = {CGRectMake(500, 940, 1100, 80), CGRectMake(520, 960, 2, 20)};
  CGRect box = mz_ocr_box(window, chat, away, &landing, &source);
  MZ_EXPECT([source isEqualToString:@"the caret"], "a reported caret is the landing line");
  MZ_EXPECT(CGRectGetMinX(box) == 500.0 && CGRectGetWidth(box) == 1100.0, "the box spans the field's column");
  MZ_EXPECT(CGRectGetMaxY(box) == 1020.0 && CGRectGetMinY(box) == 600.0, "most of the box is above the caret");
  MZ_EXPECT(landing > 0.8, "the landing line is near the bottom of the box");

  // The same field from an app that reports no caret.
  chat.caret = CGRectNull;
  box = mz_ocr_box(window, chat, away, &landing, &source);
  MZ_EXPECT([source isEqualToString:@"the focused element"], "a small field stands in for the caret");
  MZ_EXPECT(CGRectGetMinY(box) < 940.0 - 200.0, "the box reaches well above a small field");

  // A caret reported outside the window is an app talking nonsense.
  chat.caret = CGRectMake(520, -4000, 2, 20);
  (void)mz_ocr_box(window, chat, away, &landing, &source);
  MZ_EXPECT([source isEqualToString:@"the focused element"], "a caret outside the window is ignored");

  // An editor pane as tall as the window, no caret: the element says nothing
  // about where in it the paste goes.
  MZJevPasteTarget editor = {CGRectMake(400, 90, 1300, 960), CGRectNull};
  box = mz_ocr_box(window, editor, CGPointMake(900, 700), &landing, &source);
  MZ_EXPECT([source isEqualToString:@"the pointer"], "a click inside the field is where the caret went");
  MZ_EXPECT(CGRectGetMaxY(box) == 740.0 && CGRectGetMinX(box) == 400.0, "pointer line, field column");
  (void)mz_ocr_box(window, editor, CGPointMake(200, 700), &landing, &source);
  MZ_EXPECT([source isEqualToString:@"the middle of the focused element"],
            "a pointer outside the field says nothing about the field");

  // An app that reports nothing at all.
  MZJevPasteTarget unknown = {CGRectNull, CGRectNull};
  box = mz_ocr_box(window, unknown, CGPointMake(300, 400), &landing, &source);
  MZ_EXPECT([source isEqualToString:@"the pointer"] && CGRectGetWidth(box) == 900.0, "pointer, default width");
  box = mz_ocr_box(window, unknown, away, &landing, &source);
  MZ_EXPECT([source isEqualToString:@"the middle of the window"], "last resort is the middle, never a corner");
  MZ_EXPECT(CGRectContainsPoint(box, CGPointMake(900, 550)), "and the box does cover the middle");

  // A caret on the first line: the box cannot go above the window, so it
  // slides down and the landing line ends up near its top.
  MZJevPasteTarget first_line = {CGRectMake(400, 90, 1300, 960), CGRectMake(420, 100, 2, 20)};
  box = mz_ocr_box(window, first_line, away, &landing, &source);
  MZ_EXPECT(CGRectGetMinY(box) == 50.0 && landing < 0.2, "slid inside the window, landing line near the top");

  // A column wider than can be recognised in time is read around the caret.
  CGRect wide_window = CGRectMake(0, 0, 2600, 1400);
  MZJevPasteTarget wide_field = {CGRectMake(100, 100, 2400, 1200), CGRectMake(2450, 800, 1, 20)};
  box = mz_ocr_box(wide_window, wide_field, away, &landing, &source);
  MZ_EXPECT(CGRectGetWidth(box) == 1600.0 && CGRectGetMaxX(box) == 2500.0, "capped width, kept inside the column");

  // A window smaller than the box is read whole.
  CGRect small = CGRectMake(0, 0, 600, 300);
  box = mz_ocr_box(small, unknown, away, &landing, &source);
  MZ_EXPECT(CGRectEqualToRect(box, small), "a small window is read whole");

  double confidence = 0.0;
  NSString *status = nil;
  int64_t picked = mz_jev_pick_from_answer_sc(@{@"answers": @{@"pick": @{
                                               @"type": @"choice", @"choice": @"9",
                                               @"probabilities": @{@"7": @0.12, @"9": @0.81, @"none": @0.07}}}},
                                            &confidence, &status);
  MZ_EXPECT(picked == 9 && status == nil, "confident pick is returned");

  picked = mz_jev_pick_from_answer_sc(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"7",
                                       @"probabilities": @{@"7": @0.34, @"9": @0.33, @"none": @0.33}}}},
                                   &confidence, &status);
  MZ_EXPECT(picked == 0 && status == nil, "a two-way tie is suppressed silently");

  picked = mz_jev_pick_from_answer_sc(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"none",
                                       @"probabilities": @{@"7": @0.1, @"9": @0.1, @"none": @0.8}}}},
                                   &confidence, &status);
  MZ_EXPECT(picked == 0 && status == nil, "no-match is suppressed silently");

  // The three distributions below were measured against jev-latest with the
  // twelve-entry history in docs/jev-context.md; they are what the old
  // absolute 0.40 threshold got wrong.
  picked = mz_jev_pick_from_answer_sc(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"3",
                                       @"probabilities": @{@"3": @0.38, @"none": @0.32, @"7": @0.11, @"2": @0.06}}}},
                                   &confidence, &status);
  MZ_EXPECT(picked == 3, "WeChat chat box: 0.38 beats none and the runner-up");

  picked = mz_jev_pick_from_answer_sc(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"11",
                                       @"probabilities": @{@"11": @0.54, @"2": @0.24, @"4": @0.16, @"none": @0.06}}}},
                                   &confidence, &status);
  MZ_EXPECT(picked == 11, "Chrome address bar: clear winner");

  picked = mz_jev_pick_from_answer_sc(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"none",
                                       @"probabilities": @{@"none": @0.98, @"9": @0.02}}}},
                                   &confidence, &status);
  MZ_EXPECT(picked == 0, "bank amount field: nothing fits");

  // Displacing the default row has to be decisive. Distributions measured on a
  // real paste into Ghostty: row 1968 (`rm -R …`, copied 20 s earlier) was the
  // default and the right answer; row 1960 (`npx …`, "copied 9 times") led.
  NSArray<NSNumber *> *unused_runners = nil;
  picked = mz_jev_pick_from_answer(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"1960",
                                       @"probabilities": @{@"1960": @0.50, @"1968": @0.26, @"none": @0.08}}}},
                                   1968, &confidence, &unused_runners, &status);
  MZ_EXPECT(picked == 0, "a 1.9x lead is not enough to take the selection off the default row");
  picked = mz_jev_pick_from_answer(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"1960",
                                       @"probabilities": @{@"1960": @0.50, @"1968": @0.26, @"none": @0.08}}}},
                                   0, &confidence, &unused_runners, &status);
  MZ_EXPECT(picked == 1960, "the same lead is fine when the default row is not in play");
  picked = mz_jev_pick_from_answer(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"15",
                                       @"probabilities": @{@"15": @0.89, @"11": @0.09, @"none": @0.02}}}},
                                   11, &confidence, &unused_runners, &status);
  MZ_EXPECT(picked == 15, "a decisive pick does displace the default");
  picked = mz_jev_pick_from_answer(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"1968",
                                       @"probabilities": @{@"1968": @0.97, @"1960": @0.02, @"none": @0.01}}}},
                                   1968, &confidence, &unused_runners, &status);
  MZ_EXPECT(picked == 1968, "confirming the default needs no extra margin");
  picked = mz_jev_pick_from_answer(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"1968",
                                       @"probabilities": @{@"1968": @0.40, @"1960": @0.37, @"none": @0.06}}}},
                                   1968, &confidence, &unused_runners, &status);
  MZ_EXPECT(picked == 1968, "a narrow lead still confirms the default: nothing moves, so nothing can go wrong");
  picked = mz_jev_pick_from_answer(@{@"answers": @{@"pick": @{
                                       @"type": @"choice", @"choice": @"1968",
                                       @"probabilities": @{@"1968": @0.30, @"1960": @0.25, @"none": @0.41}}}},
                                   1968, &confidence, &unused_runners, &status);
  MZ_EXPECT(picked == 0, "but not when `none` beats it: that is Jev saying nothing here fits");

  // The end of the text is the informative end.
  MZ_EXPECT([mz_jev_clip_tail(@"aaaa bbbb cccc", 4) isEqualToString:@"…cccc"], "tail clip keeps the end");
  MZ_EXPECT([mz_jev_clip_tail(@"short", 40) isEqualToString:@"short"], "tail clip leaves short text alone");
  MZ_EXPECT([mz_jev_clip_tail(@"\U000F0035 someone ~ \uE0B0 ❯", 200) isEqualToString:@"someone ~  ❯"],
            "icon-font glyphs from a shell prompt are dropped, real symbols kept");
  MZ_EXPECT([mz_jev_clip_tail(@"Last login\n\n~ ❯ ", 200) hasSuffix:@"❯"], "a prompt survives as the end of the view");

  // Bundle ids become names a person would say.
  MZ_EXPECT([mz_jev_app_name(@"com.apple.finder") isEqualToString:@"Finder"], "installed app resolves to its name");
  MZ_EXPECT([mz_jev_app_name(@"com.example.gone.Widget") isEqualToString:@"Widget"], "unknown app falls back to the last id component");
  MZ_EXPECT([mz_jev_app_name(@"") isEqualToString:@"an unknown app"], "no app at all");
  MZ_EXPECT([mz_jev_shape(@"npx skills add typesafe-ai/skills --skill typesafe-ai", 1)
                isEqualToString:mz_jev_shape(@"rm -R /Applications/Example.app", 1)],
            "every command gets the same shape: no list of names to be on or off");


  picked = mz_jev_pick_from_answer_sc(@{@"answers": @{}}, &confidence, &status);
  MZ_EXPECT(picked == 0 && status != nil, "a malformed response still reports");

#undef MZ_EXPECT
  if (failures == 0) printf("jev-self-check ok\n");
  return failures == 0 ? 0 : 1;
}

