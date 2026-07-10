#import "macos_hotkey.h"
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>

static EventHotKeyRef g_hotkey = NULL;
static EventHandlerRef g_handler = NULL;
static MZHotKeyCallback g_callback = NULL;

static NSString *const kMZHotkeyPresetKey = @"MZHotkeyPreset";

typedef struct MZHotkeyPreset {
  const char *id;
  UInt32 key_code;
  UInt32 modifiers;
} MZHotkeyPreset;

// The default stays cmd-shift-v for continuity, but it shadows the system-wide
// "Paste and Match Style" shortcut in Chrome/VS Code/Word — hence the presets
// menu that lets users move off it or disable the hotkey entirely.
static const MZHotkeyPreset kMZPresets[] = {
    {"cmd-shift-v", kVK_ANSI_V, cmdKey | shiftKey},
    {"ctrl-shift-v", kVK_ANSI_V, controlKey | shiftKey},
    {"opt-cmd-v", kVK_ANSI_V, cmdKey | optionKey},
    {"disabled", 0, 0},
};

static const MZHotkeyPreset *mz_hotkey_preset_for_id(NSString *preset_id) {
  for (size_t i = 0; i < sizeof(kMZPresets) / sizeof(kMZPresets[0]); i++) {
    if ([preset_id isEqualToString:[NSString stringWithUTF8String:kMZPresets[i].id]]) {
      return &kMZPresets[i];
    }
  }
  return &kMZPresets[0];
}

static const MZHotkeyPreset *mz_hotkey_stored_preset(void) {
  NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kMZHotkeyPresetKey];
  return mz_hotkey_preset_for_id(stored ?: @"cmd-shift-v");
}

static OSStatus mz_hotkey_handler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
  (void)nextHandler;
  (void)userData;
  EventHotKeyID hotKeyID;
  GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hotKeyID), NULL, &hotKeyID);
  if (hotKeyID.signature == 'MZHK' && hotKeyID.id == 1 && g_callback != NULL) {
    g_callback();
    return noErr;
  }
  return eventNotHandledErr;
}

static int mz_hotkey_register_preset(const MZHotkeyPreset *preset) {
  if (g_hotkey != NULL) {
    UnregisterEventHotKey(g_hotkey);
    g_hotkey = NULL;
  }
  if (preset->key_code == 0 && preset->modifiers == 0) return 0;  // disabled

  EventTypeSpec eventType = { .eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed };
  if (g_handler == NULL) {
    OSStatus hs = InstallApplicationEventHandler(&mz_hotkey_handler, 1, &eventType, NULL, &g_handler);
    if (hs != noErr) return (int)hs;
  }
  EventHotKeyID hotKeyID = { .signature = 'MZHK', .id = 1 };
  OSStatus rs = RegisterEventHotKey(preset->key_code, preset->modifiers, hotKeyID, GetApplicationEventTarget(), 0, &g_hotkey);
  return (int)rs;
}

int mz_hotkey_register_popup(MZHotKeyCallback callback) {
  g_callback = callback;
  return mz_hotkey_register_preset(mz_hotkey_stored_preset());
}

int mz_hotkey_apply_preset(const char *preset_id) {
  NSString *preset = preset_id != NULL ? [NSString stringWithUTF8String:preset_id] : @"cmd-shift-v";
  [NSUserDefaults.standardUserDefaults setObject:preset forKey:kMZHotkeyPresetKey];
  return mz_hotkey_register_preset(mz_hotkey_preset_for_id(preset));
}

void mz_hotkey_unregister_popup(void) {
  if (g_hotkey != NULL) {
    UnregisterEventHotKey(g_hotkey);
    g_hotkey = NULL;
  }
  if (g_handler != NULL) {
    RemoveEventHandler(g_handler);
    g_handler = NULL;
  }
  g_callback = NULL;
}
