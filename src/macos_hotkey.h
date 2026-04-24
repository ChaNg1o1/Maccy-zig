#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MZHotKeyCallback)(void);
int mz_hotkey_register_popup(MZHotKeyCallback callback);
void mz_hotkey_unregister_popup(void);

#ifdef __cplusplus
}
#endif
