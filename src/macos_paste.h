#pragma once
#ifdef __cplusplus
extern "C" {
#endif

int mz_ax_is_trusted(int prompt);
void mz_post_command_v(void);

/// Directly post ⌘V to the given target process PID (typically the app that
/// was frontmost when the user summoned the Maccy panel). Bypasses the
/// frontmost-app routing entirely, which is critical for auto-paste because
/// AppKit's mouseUp handling tends to reassert Maccy as frontmost between
/// "panel hidden" and "key event posted".
/// pid <= 0 falls back to mz_post_command_v's frontmost-route behavior.
void mz_post_command_v_to_pid(int pid);

#ifdef __cplusplus
}
#endif
