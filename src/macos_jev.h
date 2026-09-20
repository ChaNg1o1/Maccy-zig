#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/// One clipboard entry offered to Jev as a paste candidate.
typedef struct MZJevCandidate {
  int64_t row_id;
  /// UTF-8 preview of the entry. Callers pass whatever they already show in
  /// the list; mz_jev_suggest truncates and redacts before it leaves the
  /// machine.
  const char *preview;
  /// App the entry was copied from, or NULL.
  const char *source_app;
  /// MZAppContentKind value.
  int content_kind;
  /// Unix seconds the entry was last copied. Turned into a described age in
  /// code: jev-1.13 reads dates as text, not as ordered quantities, so a raw
  /// timestamp is something it cannot rank.
  int64_t copied_at;
  /// How many times the entry has been copied. A strong reuse prior.
  int copy_count;
  /// Non-zero when the user starred the entry.
  int pinned;
  /// How many times this entry has already been pasted into the destination
  /// app, from the local paste log. Code's memory, not the model's guess.
  int pastes_into_destination;
  /// Where it was copied from: window title and page or file. May be NULL.
  const char *source_context;
  /// Non-zero when this very entry went into the destination moments ago.
  int pasted_here_recently;
  /// Non-zero when an entry gathered alongside this one (same source, same
  /// minute or so) went into the destination moments ago: the "copied three
  /// things, now filling three fields" pattern.
  int sibling_pasted_here_recently;
} MZJevCandidate;

/// Whether the user has switched Jev suggestions on. This flag is the only
/// authority: with it off nothing is collected and no request is made, and
/// with it on a missing API key is reported rather than silently ignored.
BOOL mz_jev_enabled(void);
void mz_jev_set_enabled(BOOL enabled);

/// The TypeSafe API key, or nil. The login keychain is the only store: an
/// environment override would silently shadow whatever Settings shows, and a
/// GUI app launched from Finder would not see it anyway.
NSString *mz_jev_api_key(void);

/// Save the key to the keychain, or clear it when `key` is nil or empty.
/// Returns NO if the keychain refused the write.
BOOL mz_jev_set_api_key(NSString *key);

/// Check a key against the service before the user relies on it. `completion`
/// runs on the main queue with a message ready to show in Settings.
void mz_jev_verify_api_key(NSString *key, void (^completion)(BOOL ok, NSString *message));

/// Remember which element has focus in `pid`. This is the one question that
/// has to be asked before the panel takes activation: Chromium-based apps
/// (browsers, Electron) report their real focused field only while active, and
/// "the whole web page" an instant later. A held element stays readable
/// afterwards, so everything else is read from it off the main thread.
/// `pid` <= 0 just forgets the previous element.
void mz_jev_capture_focus(pid_t pid);

/// Where the paste will land on screen, in global top-left coordinates.
typedef struct {
  CGRect field;  ///< the focused element; CGRectNull when the app reports none
  CGRect caret;  ///< the insertion point inside it; CGRectNull when the app does not say
} MZJevPasteTarget;

/// Reads the element remembered by mz_jev_capture_focus. Talks to the target
/// app, so not for the main thread.
MZJevPasteTarget mz_jev_paste_target(pid_t pid);

/// Ask Jev which candidate belongs in whatever `target_pid` is about to
/// receive a paste. `completion` runs on the main queue exactly once: with a
/// positive row id for a confident pick, or 0 and a short human-readable
/// status otherwise. `runner_ups` carries the next-best row ids that were
/// still plausible, for marking without moving the selection.
void mz_jev_suggest(pid_t target_pid,
                    const MZJevCandidate *candidates,
                    size_t count,
                    void (^completion)(int64_t row_id,
                                       double confidence,
                                       NSArray<NSNumber *> *runner_ups,
                                       NSString *status));

/// The ingredients of the most recent question -- destination context and
/// candidate records, as JSON -- or nil if none was built since the last take.
/// Taking clears it, so one question is never attributed to two pastes.
/// Stored with the paste it led to, this is one evaluation sample.
NSString *mz_jev_take_last_sample(void);

/// What replaying one stored sample against the live model produced.
typedef struct MZJevEvalResult {
  int64_t choice_row;       ///< Row Jev chose; 0 when it chose "none".
  int accepted;             ///< Whether the acceptance rule would have acted on it.
  double probability;       ///< Probability of the chosen option.
  double default_fits;      ///< The shadow "does the newest entry fit?" noul; -1 if not asked.
  int chosen_present;       ///< Whether the row the user really pasted was a candidate.
  int input_tokens;
} MZJevEvalResult;

/// Rebuild the request for `sample_json` with the *current* builder, send it,
/// and judge the answer with the *current* acceptance rule. Blocks; CLI only.
/// Returns 0 on success.
int mz_jev_eval_sample(const char *sample_json, int64_t chosen_row, MZJevEvalResult *out);

/// Cancel an in-flight suggestion; its completion will not run. Called when
/// the panel closes or the user starts typing a search.
void mz_jev_cancel(void);

/// True when the text looks like a credential (API key, token, private key,
/// password assignment). Such entries are never sent off the machine.
/// Exposed for the self-check in `maccy-zig jev --self-check`.
BOOL mz_jev_looks_like_secret(NSString *text);

/// Verbose tracing of everything a suggestion is built from: the destination
/// context, whether the screen was read and what it said, the options sent,
/// and the probabilities that came back. Off by default. The trace is kept in
/// memory and shown in the app's own inspector window -- a log file you have
/// to go and find answers the question too late.
BOOL mz_jev_debug(void);
/// Trace for the lifetime of this process without touching the saved setting.
/// For the command-line probes.
void mz_jev_debug_this_process(void);
void mz_jev_set_debug(BOOL enabled);
/// Oldest first. Capped, so a long session cannot grow without bound.
NSArray<NSString *> *mz_jev_log_lines(void);
void mz_jev_log_clear(void);
/// Posted on the main queue whenever a line is appended.
extern NSString *const kMZJevLogChangedNotification;
/// No-op when debug is off, so call sites need no guard.
void mz_jev_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Where the inspector window should sit so the clipboard panel does not cover
/// it. Returns `inspector` unchanged when the two do not overlap, so a window
/// the user has already parked somewhere clear is left alone. Pure geometry,
/// which is why it is here and covered by the self-check.
NSRect mz_jev_inspector_frame(NSRect inspector, NSRect panel, NSRect screen);

/// Print, as JSON, exactly what Jev would be told about whatever is focused
/// `delay_seconds` from now -- long enough to click into the app in question.
/// Backs `maccy-zig jev-context`. Returns 0 on success.
int mz_jev_print_context(int delay_seconds);

/// Offline self-check of redaction, request framing and the confidence gate.
/// Returns 0 on success. Backs `maccy-zig jev-self-check`.
int mz_jev_self_check(void);
