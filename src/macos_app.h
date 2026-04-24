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

typedef void (*MZAppActionCallback)(MZAppAction action, int64_t row_id);

typedef struct MZAppCallbacks {
  void (*on_toggle)(void);
  void (*on_poll)(void);
  void (*on_search)(const char *query);
  void (*on_select)(int64_t id, int paste);
  void (*on_clear)(int all);
  void (*on_quit)(void);
} MZAppCallbacks;

void mz_app_run(MZAppCallbacks callbacks);
void mz_app_set_action_callback(MZAppActionCallback callback);
void mz_app_toggle(void);
void mz_app_show(void);
void mz_app_hide(void);
void mz_app_set_rows(const MZAppRow *rows, size_t count);
void mz_app_set_status_text(const char *text);
void mz_app_reveal_target(const char *target);

#ifdef __cplusplus
}
#endif
