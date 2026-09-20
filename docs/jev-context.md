# What Jev is told, and why

The suggestion is one `Choice` question. Its options are the visible clipboard
entries plus `none`; its state is the destination field. Everything ordinal or
comparative in an option is computed in `src/macos_jev.m` before the request
goes out, because [`jev-1.13` reads dates as text rather than ordered
quantities](https://docs.typesafe.ai/model-jaggedness/jev-1.13) and is not a
calculator.

## One option, one sentence

```
"git rebase -i HEAD~3" — a piece of text, copied from Terminal earlier today;
copied from the app being pasted into; copied 4 times in all;
pasted into this app 3 times before
```

| Clause | Source | Why code computes it |
| --- | --- | --- |
| shape (`a URL`, `an email address`, `a file path`, …) | regex over the preview | only shapes that are unambiguous from structure. There is deliberately no "shell command" shape: it needs a list of command names, the list is never complete, and the label measurably moves the answer, so listed commands would beat unlisted ones. The model recognises a command from its text |
| age (`just now`, `days ago`, …) | `copied_at` vs now | the model cannot rank timestamps |
| `copied from the app being pasted into` | source app vs destination app | a comparison is a hop, and hops cost accuracy |
| `copied N times in all` | `history_items.copy_count` | already stored, never previously sent |
| `starred by the user` | `history_items.pin` | ditto |
| `pasted into this app N times before` | `paste_events` | the only part that remembers this user |
| `copied from "<window title> (<host/path>)" in <app>` | Accessibility, read at copy time | half of "the thing I want" is where it came from; the copy has no latency budget |
| `already pasted into this app moments ago` | `paste_events`, last 120 s | what was just used is probably done with |
| `copied in the same batch as an entry that was pasted…` | same source app within 90 s of a just-pasted entry | the "gathered three things, filling three fields" run |

The records live in `criteria` and nowhere else. Duplicating them into `state`
cost about 30% more input tokens and made the model hop from an option key to a
matching entry elsewhere in the request.

## The destination

`app_name`, `app_bundle_id`, `window_title`, `window_document` (the page or file
a browser or editor has open), `focused_field_kind`, `focused_field_label`,
`focused_field_is_empty`, `text_before_caret` (120 characters, not the whole
field) and `text_the_paste_would_replace` when there is a selection.

Whether the focused element is a text input is decided by **role** (text area,
text field, combo box, search field) or by Accessibility being able to write
its value — not by writability alone. A terminal is a text area whose value
cannot be written through Accessibility; judging by writability told the model
that Ghostty "does not accept text", and it answered `none` to a shell command
copied twenty seconds earlier. For such read-only text views the caret
attribute is meaningless (Ghostty always reports 0), so the last 200 characters
are sent as `text_at_the_end_of_the_view` — the previous output and the prompt
— and no screen reading is needed. For writable fields `text_before_caret`
keeps the *end* of the text before the caret, which is the part next to it.

`text_before_the_field` is the static text that precedes the field in the app's
own reading order, found by climbing the tree and scanning earlier siblings
backwards (at most 90 nodes, 200 ms, 5 snippets; depth is only a backstop at 16
levels, because web content nests a field a dozen wrappers deep and a shallow
limit stops before it reaches anything). For a form that is the label,
which often lives in a sibling element rather than any attribute of the field;
for a chat box it is the last message, which is frequently the whole answer.
Only `AXStaticText` is read: a neighbouring field's value is somebody's input.

Provenance is captured only while Jev is on, clipped (title 90, address 70),
stripped of URL query and fragment, and dropped if it looks like a credential.

A caret in a secure text field aborts the request outright: no suggestion, and
nothing described to the service.

## Two accounts of the same place

The destination is described twice, always, in every app:

* **Accessibility** is what the app chooses to say about the field: structured
  and exact (label, placeholder, markup id, caret text), and absent or partial
  in a great many apps. Measured here: Chrome and Lark (Electron) report the
  focused text field, its value and the caret; Zed reports its window and three
  traffic-light buttons and nothing else, and neither `AXManualAccessibility`
  nor `AXEnhancedUserInterface` changes that outside Chromium.
* **The screen** is what the person is actually looking at, whatever the app is
  built with — but unstructured. `src/macos_ocr.m` reads a box around where the
  paste will land and sends it as `text_on_screen_near_the_field`.

Neither is a fallback for the other, and there is no per-app switch between
them. The tree's reading order is not the visual order (what precedes a chat box
in the tree is often a banner, while what sits above it on screen is the
conversation), and pixels cannot say "this field's name is `email`". An earlier
version read the screen only "for apps that expose no field"; that rule is what
left a chat box with a perfectly good Accessibility element, and the whole
conversation above it, undescribed.

A focused element that is not a text input is reported as
`focused_element_is_a_text_input: false` rather than dressed up as a field, so
the model is not invited to invent a fit.

### Which element has focus is asked before the panel activates

Chromium-based apps (browsers, Electron) report their real focused field only
while they are active; asked an instant after the panel takes activation they
answer "the whole web page". So `-show` calls `mz_jev_capture_focus` first: one
Accessibility question on the main thread (120 ms timeout), holding the element.
A held element stays readable after deactivation, and everything else — frame,
caret, label, neighbours — is read from it on background queues.

### Where the box goes

`mz_ocr_box` is pure geometry and `jev-self-check` holds it to these rules:

* It ends 40 pt below **the line the paste lands on** and extends 420 pt
  upwards, because what explains a paste precedes the insertion point: the
  messages above a chat box, the label above a form field, the code above the
  caret.
* That line comes from the most exact source that can name it: the caret
  (`AXBoundsForRange` of the selection, rejected if it falls outside its own
  field); a focused element no taller than half the box (a taller one says
  nothing about where inside it the paste goes); the pointer if it is inside
  the field, since a click is how a caret gets placed; the middle of the field,
  or of the window when the app reports nothing. Never a corner of the window.
* Sideways it follows the field — the column the person is writing in — from
  900 pt up to 1600 pt, and a wider column is read around the landing line.
* It is slid back inside the window rather than clipped.

The window that bounds the box is the frontmost window of the app containing
the landing place (front-to-back order from `CGWindowList`), titled before
untitled; with no landing place, the app's frontmost ordinary-level window.
"The biggest window" was wrong whenever the app had a second, larger window —
on another display, for instance.

What is **captured** is not a window at all but that part of the display with
every window of the app composited and every other app left out
(`SCContentFilter initWithDisplay:includingApplications:`). Apps split what
looks like one window across several: on this machine Lark keeps an untitled
window of exactly the main window's size in front of it, plus strips along the
menu bar. Which of them holds the pixels is not something to guess at, and the
filter also keeps this app's own panel out of the picture.

### Keeping it off the critical path

| | cost | why it does not show up as latency |
| --- | --- | --- |
| model load | ~12s, once per process | started at launch from `applicationDidFinishLaunching`, on a utility queue |
| locating field and caret | a few ms | Accessibility reads run concurrently with `SCShareableContent` |
| capture | ~25ms | started when the panel opens |
| recognition | 90–200ms | overlaps the 200ms the panel already waits for rows |
| top-up wait | ≤200ms | one rule for every app; returns at once when the read has landed, which it usually has |

Three measured constraints shape it. Vision loads a model **per language set**,
so `["zh-Hans", "en-US"]` is pinned everywhere — asking for `["en-US"]` alone
paid the 12s again. `.fast` recognition returns in 14ms but renders CJK as
noise, so `.accurate` is not optional here. And `.accurate` time follows the
number of text lines far more than the number of pixels: on one 1800x840
capture, 19 lines took 266ms and the 9 nearest 161ms, while a dense 75-line
screen took 460ms — too late to be used at all. So a cheap
`VNDetectTextRectanglesRequest` (8ms) finds where the lines are, and only the
band holding the 24 nearest the landing line is recognised. Those are the lines
that fit the 600-character budget anyway; when the text is cut, it is the lines
farthest from the landing line that go, and what is kept is sent top to bottom.

`maccy-zig ocr-check` times the real path and says where the read was aimed:

```
frontmost app: Ghostty (pid 94546)
  pass 3:    239ms  594 characters
  ocr: reading 1600x420 around the pointer
  ocr: captured 3200x840
  ocr: 43 text line(s) found, 18 nearest recognised in 193ms
```

`maccy-zig jev-context` runs the same three steps as opening the panel — hold
the focus, start the read, build the context — and prints the result.

Turning the Jev switch on is a request for the feature, not for a checkbox, so
it takes the user straight to whatever is still missing — API key, then
Accessibility, then Screen Recording — and the status line under the switch
names the first gap until there is none. Both permissions live together in
*Settings → Shortcuts & Permissions*. The privacy copy says what happens: each
time the panel opens, the part of the window just above the paste is read.
Recognised lines shaped like a credential are dropped one by one.

## Where the request goes

Three services, one wire format. TypeSafe's own API, Vercel AI Gateway's
[TypeSafe-compatible API](https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe) ("an existing client
only needs its base URL changed") and any transparent proxy in front of TypeSafe — a Cloudflare AI
Gateway [custom provider](https://developers.cloudflare.com/ai-gateway/configuration/custom-providers/),
for one — all take the same request and return the same response. So the question, the options and the
acceptance rule know nothing about the service; an `MZJevRoute` carries the only things that differ:

| | URL | model | credentials |
| --- | --- | --- | --- |
| TypeSafe | `https://api.typesafe.ai/v1/systemone` | `jev-latest` | TypeSafe key |
| Vercel AI Gateway | `https://ai-gateway.vercel.sh/typesafe/v1/systemone` | `typesafe-ai/jev` | AI Gateway key |
| custom | `<base URL>/v1/systemone` | `jev-latest` unless set | upstream's key, plus an optional extra header for the gateway itself |

Base URLs follow the SDKs' convention (everything before `/v1/systemone`), a pasted full endpoint is cut
back to it, and only `https://` is accepted because the key and clipboard previews travel there. Each
service has its own keychain item, so switching never loses a key, and the route is resolved once per
request on the main thread so a request cannot mix two services' settings. Vercel's native
`/v1/evaluate` API was not used: it renames `noul` to `boolean` and the answer fields, which would have
meant a second request builder and parser for no gain.

Both public endpoints were probed with an invalid key: each answers `401` with TypeSafe's error shape.

## Accepting the answer

A `Choice`'s probabilities are relative — they sum to 1 across every option, so
more candidates means thinner slices and an absolute floor is miscalibrated by
construction. The pick is accepted when it beats `none` and leads the runner-up
by `kMZJevRunnerUpMargin` (1.6x). Measured against `jev-latest` with the twelve
entries in `probe` fixtures, over the same history:

| destination | old: absolute 0.40 cut, no context | new: relative gate + computed context | wanted |
| --- | --- | --- | --- |
| Terminal prompt, `$ ` typed | `git rebase…` p=0.81 accept | `git rebase…` p=0.94 accept | `git rebase…` |
| Signup form, "Email address" | email p=1.00 accept | email p=1.00 accept | email |
| WeChat chat box | `hi 周日有空吗` p=0.36 **silent** | `hi 周日有空吗` p=0.45 accept | `hi 周日有空吗` |
| Bank transfer, "Amount (USD)" | `none` p=0.99 silent | `none` p=0.99 silent | silent |

The third row is what the absolute threshold got wrong: a correct pick thrown
away because twelve candidates had split the probability mass.

Two further rules came out of one real paste — `rm -R /Applications/Example.app`
copied from an article, panel opened over Ghostty twenty seconds later, with an
older `npx …` entry in the history that had been "copied 9 times in all":

* **A recency prior in the question.** "People usually paste what they copied
  most recently: prefer the most recently copied entry that fits the
  destination, and choose an older entry only when the recent ones clearly do
  not fit or the older one fits distinctly better." Without it the reuse count
  won 0.62 to 0.20; with it the fresh copy leads 0.50 to 0.36 — and a fresh URL
  still loses to `git rebase` at a shell prompt (0.89), because it does not fit.
* **Displacing the default has to be decisive.** The newest entry is already
  selected when the panel opens. A pick for any other row must beat the
  default's own probability by `kMZJevDisplaceDefaultMargin` (3x): staying put
  when unsure costs the arrow keys the user was going to press anyway, moving to
  the wrong row costs their trust.

Both are statements about clipboard use in general, not about terminals. What
was *not* added: a list of terminal bundle ids, an app-category field (no
measurable effect), and a tightened `none` wording (no measurable effect).

`maccy-zig jev-self-check` asserts these distributions offline, along with
the redaction patterns and the option-sentence construction.

## Seeing why

*Actions… → Log Jev Decisions* opens a live inspector: the last screen capture
at the top, and under it the destination context, every option sentence sent,
the returned probabilities, the accept/reject verdict and the stage timings.
Skips are traced too (`skipped: only 1 candidate after redaction`,
`ocr: skipped, Screen Recording not granted`), because a suggestion that never
appears is exactly the case that needs explaining.

Nothing is written to disk — the trace is a ring buffer in memory and the
capture is held as an image, so turning tracing off leaves nothing behind.

## Measuring instead of guessing

Every paste made from the panel while Jev is on stores one row in
`jev_samples`: the question's *ingredients* (destination context and candidate
records, not the finished request), the row that was pasted, its list position,
and what Jev had proposed. `paste_events.row_rank` records the list position of
every paste regardless.

```sh
/Applications/MaccyZig.app/Contents/MacOS/maccy-zig jev-eval --limit 50
```

replays the latest samples through the **current** request builder and
acceptance rule, one billed request each, and reports top-1 agreement,
coverage, precision, and the count that matters most: accepted-and-wrong, i.e.
selections that would have been yanked to the wrong row. It must be the binary
inside the app bundle — a bare development build uses a separate keychain item
on purpose and cannot read the key.

Because ingredients are stored, a reworded instruction or a new option sentence
is scored against situations recorded before the change. New *fields* cannot be
back-filled into old samples; they are simply absent there.

It earned its keep within minutes of existing. The first draft of the shadow
question below put its subject in `state` as `most_recent_entry`; all questions
in a request share one state, and the replay showed the main question dragged
toward the newest entry — a Terminal prompt answered with a GitHub URL at
p=0.92. With the subject moved into the question's own instructions the same
sample returns the shell command at p=0.96.

Two caveats the report prints itself: agreement on samples where a live
suggestion was on screen is inflated by anchoring, and the free row-0 baseline
from `paste_events` is what any suggestion has to beat.

### The shadow question

`default_fits` — "would a person paste the newest entry here?" — is asked in the
same request and recorded, but not acted on. Opening the panel already hints
the newest entry is not wanted, or ⌘V would have done; whether this number is a
useful brake on moving the selection is empirical. `jev-eval` prints its mean
for pastes of row 0 versus any other row. Wire it into the verdict only if
those two numbers sit clearly apart on real samples.

### Asking what Jev sees

```sh
maccy-zig jev-context        # 3 s to click into the field, then prints the JSON
```

prints exactly the destination context for whatever is focused — the first
thing to check when a suggestion never appears in some app.

## Audit: is the context complete, and is the model fully used?

Asked directly, measured on 2026-09-20 against `jev-1.13.0`.

### Context

Closed by this audit — all generic Accessibility reads, none app-specific:

| Signal | Why it was missing |
| --- | --- |
| `focused_field_placeholder` | collapsed into the label with `?:`, so it was dropped whenever a description existed; "you@example.com" is often the most telling thing a field says |
| label from `AXTitleUIElement` | the element an app *declares* to be the field's title (a web `<label for=…>`) beats inferring the label from position |
| `focused_field_identifier` (`AXDOMIdentifier`) | the HTML id of a web or Electron field (`email`, `billing-phone`): what browser autofill classifies fields by. Ids over 40 characters are generated noise and are not sent |
| `focused_field_help` | tooltip/help text |
| `text_after_caret` | "Dear ___, thanks for" — what follows the gap frames it as much as what precedes it |

Still open:

* **Entry length.** Candidates carry a 200-character preview of a title the
  capture path already truncated to 256 bytes, so a five-thousand-character
  entry and a one-line entry can look alike. Needs the real length from
  `history_contents`, described in words (the model is weak on numbers).
* **Candidate recall.** Only the 12 visible rows are candidates. An entry this
  user pastes into this app every day but last copied a week ago can never be
  suggested. `jev-eval` reports "wanted entry was among the candidates" to size
  this before building retrieval from `paste_events`.
* **Model version.** `jev-latest` is an alias that moves, and the docs say to
  pin the version when thresholds are tuned against it. Ours are.

### Model use: one opaque Choice versus the documented pattern

TypeSafe's own guidance for ranking is *composite scoring* (score independent
dimensions, combine with weights **in code**) plus *speculative fan-out* (many
questions per request; "Jev ingests the state once and evaluates every question
against it in parallel"). Today one `Choice` folds fit, recency, reuse and
paste history into a single judgment, steered by a sentence in the prompt — and
recency and reuse are exactly the numeric, time-ordered reasoning the
jaggedness notes say the model is weak at.

Measured alternative: one `Score` per candidate asking only *how well does this
entry suit the destination* (four levels, recency and reuse stripped from the
sentence), all in one request.

| scenario | per-candidate fit |
| --- | --- |
| signup "Email address" | email 1.00, everything else ≤ 0.03 |
| chat, last message "方便发一下你的手机号吗？" | phone 1.00, everything else ≤ 0.13 |
| bank "Amount (USD)" | **everything ≤ 0.01** — "nothing fits" without a `none` option |
| Chrome address bar | URL 0.91 **and** a search query 0.82 — two entries genuinely fit; a Choice hides this |
| Ghostty prompt | `npx …` 0.61, `rm -R …` 0.58 — both commands suit a terminal equally, which is true: choosing between them is a *prior*, not a judgment |

* **Latency:** 1 Choice 317 ms median; 1 Choice + 12 Scores 336 ms. Twelve more
  questions cost 19 ms.
* **Cost:** ~2,400 input tokens, about $0.0001 per panel open.
* **Robustness:** combining fit with code-side priors
  (`fit × (1 + a·recency + b·reuse + c·habit)`), 64 of 80 weight settings land
  all six scenarios on the right row. The prompt-sentence design is one
  sentence away from 5/6.
* **Rule found on the way:** a default row that does not itself fit
  (`fit < 0.5`) is no anchor worth protecting; the decisive-displacement margin
  should apply only to a default that fits.

Not adopted yet: both designs score 6/6 on the six scenarios, and six is not
evidence. The fit Scores can ride in the same request as the Choice for +19 ms,
so the honest path is to record both on real pastes and let `jev-eval` say which
policy lands on the right row more often.
