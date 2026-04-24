#import "macos_hotkey.h"
#import <Carbon/Carbon.h>

static EventHotKeyRef g_hotkey = NULL;
static EventHandlerRef g_handler = NULL;
static MZHotKeyCallback g_callback = NULL;

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

int mz_hotkey_register_popup(MZHotKeyCallback callback) {
  g_callback = callback;
  EventTypeSpec eventType = { .eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed };
  if (g_handler == NULL) {
    OSStatus hs = InstallApplicationEventHandler(&mz_hotkey_handler, 1, &eventType, NULL, &g_handler);
    if (hs != noErr) return (int)hs;
  }
  if (g_hotkey != NULL) UnregisterEventHotKey(g_hotkey);
  EventHotKeyID hotKeyID = { .signature = 'MZHK', .id = 1 };
  OSStatus rs = RegisterEventHotKey(kVK_ANSI_V, cmdKey | shiftKey, hotKeyID, GetApplicationEventTarget(), 0, &g_hotkey);
  return (int)rs;
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
