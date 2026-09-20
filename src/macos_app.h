#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MZAppRow {
  int64_t id;
  const char *title;
  const char *subtitle;
  const char *app;
  int64_t copied_at;
  int64_t pin_order;
  int content_kind;
  int pinned;
  int has_image;
  int copy_count;
  /// Where the entry was copied from -- window title and, when the app
  /// exposes one, the page or file -- or "" when unknown.
  const char *source_context;
} MZAppRow;

typedef enum MZAppContentKind {
  MZ_APP_CONTENT_TEXT = 1,
  MZ_APP_CONTENT_LINK = 2,
  MZ_APP_CONTENT_IMAGE = 3,
  MZ_APP_CONTENT_FILE = 4,
  MZ_APP_CONTENT_OTHER = 5,
} MZAppContentKind;

typedef enum MZAppAction {
  MZ_APP_ACTION_COPY = 1,
  MZ_APP_ACTION_PASTE = 2,
  MZ_APP_ACTION_PASTE_PLAIN = 3,
  MZ_APP_ACTION_TOGGLE_PIN = 4,
  MZ_APP_ACTION_CLEAR_UNPINNED = 5,
  MZ_APP_ACTION_CLEAR_ALL = 6,
  MZ_APP_ACTION_QUIT = 7,
  MZ_APP_ACTION_REVEAL = 8,
} MZAppAction;

typedef void (*MZAppActionCallback)(MZAppAction action, int64_t row_id, int target_pid);

typedef struct MZAppCallbacks {
  void (*on_toggle)(void);
  void (*on_poll)(void);
  void (*on_search)(const char *query);
  void (*on_select)(int64_t id, int paste, int target_pid);
  void (*on_clear)(int all);
  void (*on_quit)(void);
  void (*on_max_items_change)(int64_t max_items);
} MZAppCallbacks;

int64_t mz_app_load_max_items(int64_t fallback);
void mz_app_set_initial_max_items(int64_t max_items);
void mz_app_run(MZAppCallbacks callbacks);

/// Builds the app's windows off screen and checks that every control in them
/// can actually be reached by a click. Backs `maccy-zig ui-self-check`.
/// Returns 0 when everything is reachable.
int mz_app_ui_self_check(void);
void mz_app_set_action_callback(MZAppActionCallback callback);
void mz_app_toggle(void);
void mz_app_show(void);
void mz_app_hide(void);
void mz_app_set_rows(const MZAppRow *rows, size_t count);
void mz_app_set_status_text(const char *text);
void mz_app_reveal_target(const char *target);
const unsigned char *mz_app_copy_image_preview(int64_t row_id, size_t *len_out);
void mz_app_free_buffer(const unsigned char *buffer, size_t len);

/// Sequence facts about one entry relative to the app being pasted into.
/// Layout matches storage.Db.PasteSignals.
typedef struct MZPasteSignals {
  int32_t pastes_into_destination;
  int32_t pasted_here_recently;
  int32_t sibling_pasted_here_recently;
} MZPasteSignals;

/// Log that `row_id`, at list position `row_rank`, was pasted into
/// `dest_bundle_id`. `was_suggested` and `suggested_row_id` record what Jev
/// had proposed, so the log shows overrides too. A non-NULL `sample_json` is
/// stored alongside as an evaluation sample.
void mz_app_record_paste(int64_t row_id, const char *dest_bundle_id, int was_suggested,
                         int row_rank, int64_t suggested_row_id, const char *sample_json);

/// Fill `out` (length `count`) with the sequence facts for each id in `ids`
/// relative to `dest_bundle_id`. Must run on the db queue.
void mz_app_paste_signals(const char *dest_bundle_id, const int64_t *ids, size_t count, MZPasteSignals *out);

/// Drop all cached preview thumbnails. Must be called after history rows are
/// deleted because SQLite reuses INTEGER PRIMARY KEY values, so a stale cache
/// entry could otherwise serve the old image for a brand-new row.
void mz_app_invalidate_preview_cache(void);

/// Activate the app and show a clear in-app NSAlert about the Accessibility
/// permission state. If the permission is missing, the alert offers an
/// "Open Settings" button that triggers the native trust prompt (so the app
/// is registered in the Accessibility list) and jumps directly to the
/// Privacy & Security → Accessibility pane. Safe to call from any thread.
void mz_app_show_accessibility_alert(void);

/// Audible failure signal (NSBeep). Safe to call from any thread.
void mz_app_beep(void);

#ifdef __cplusplus
}
#endif
