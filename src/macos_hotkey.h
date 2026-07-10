#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MZHotKeyCallback)(void);
/// Registers the popup hotkey using the preset persisted in NSUserDefaults
/// (key "MZHotkeyPreset"; defaults to cmd-shift-v). Returns 0 on success, a
/// Carbon OSStatus on failure, and 0 when the preset is "disabled".
int mz_hotkey_register_popup(MZHotKeyCallback callback);
/// Re-register the stored callback for a new preset id and persist it.
/// Known ids: "cmd-shift-v", "ctrl-shift-v", "opt-cmd-v", "disabled".
int mz_hotkey_apply_preset(const char *preset_id);
void mz_hotkey_unregister_popup(void);

#ifdef __cplusplus
}
#endif
