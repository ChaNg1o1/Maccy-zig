<p align="center">
  <img src="assets/repo-header.png" alt="MaccyZig repository header">
</p>

<h1 align="center">MaccyZig</h1>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Zig" src="https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white">
  <img alt="UI" src="https://img.shields.io/badge/UI-AppKit%20%2B%20Cocoa-5c6bc0">
</p>

MaccyZig helps you find and reuse things you copied on macOS.

It lives in the menu bar, keeps a searchable clipboard history, and lets you quickly paste old text, links, images, and files without switching apps or digging through notes.

## Download

Prebuilt macOS builds are published on the GitHub [Releases](https://github.com/ChaNg1o1/Maccy-zig/releases) page. You can also use the Releases panel on the right side of the repository page.

Download `MaccyZig-*-macOS.zip`, unzip it, then move `MaccyZig.app` to `/Applications`.

Because the release build is ad-hoc signed (not notarized), macOS Gatekeeper blocks the first launch with an "Apple could not verify" dialog. To open it:

1. Double-click `MaccyZig.app` (dialog appears, close it)
2. Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway**
3. Confirm the dialog

Alternative (terminal):
```sh
xattr -d com.apple.quarantine /Applications/MaccyZig.app
```

The default global hotkey is `⌘⇧V` (configurable from the menu).

## What You Can Do

- Open clipboard history from the macOS menu bar.
- Search recent copied text, links, images, and files.
- Paste an item normally, or paste it as plain text.
- Mark important items as favorites so they stay around.
- Preview copied images before using them.
- Clear old unpinned items when the history gets noisy.
- Configure the history limit from the settings menu.
- Resize the window and keep that size next time.
- Switch the interface between English and Simplified Chinese.

## For Developers

MaccyZig is built with Zig, Objective-C, AppKit, Cocoa, and SQLite. The repository also includes CLI commands for capture, watch, stats, listing, benchmarking, and importing existing Maccy data.

## Requirements

- macOS 14 or newer to run the app.
- Zig `0.16.0` or a compatible recent build to build from source.
- Xcode Command Line Tools to compile the macOS bridge code.
- A codesigning identity pinned in `.signing-identity` (or `CODESIGN_IDENTITY`). See [Code signing and Accessibility](#code-signing-and-accessibility).

Install common prerequisites:

```sh
xcode-select --install
```

## Build

Build the debug/development binary:

```sh
zig build
```

Run the app from the build output:

```sh
zig build run
```

Build an optimized release binary:

```sh
zig build -Doptimize=ReleaseFast
```

## Package The App

Create `dist/MaccyZig.app`:

```sh
./scripts/package-app.sh
```

The packaging script:

- builds `maccy-zig` in `ReleaseFast`
- creates the app bundle under `dist/MaccyZig.app`
- copies `resources/Info.plist`
- generates `AppIcon.icns`
- renders the menu bar template image from `assets/menubar.svg`
- signs the app with the pinned identity (`CODESIGN_IDENTITY`, else `.signing-identity`)

To force a specific signing identity:

```sh
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/package-app.sh
```

### Code signing and Accessibility

macOS remembers an Accessibility grant by the app's *designated requirement*. An
ad-hoc signature has no certificate, so its requirement is a bare
`cdhash H"..."` that changes on every rebuild: System Settings keeps showing a
ticked MaccyZig while `AXIsProcessTrusted()` returns false, and every paste
re-prompts. Signing with a certificate produces a requirement built from the
bundle id and the certificate, which survives rebuilds and reinstalls.

Packaging therefore refuses to guess. Pin one identity, once:

```sh
security find-identity -v -p codesigning
echo "Apple Development: Your Name (TEAMID)" > .signing-identity   # gitignored
```

`CODESIGN_IDENTITY=-` still produces an ad-hoc build for throwaway testing, and
says so. When the identity changes, `scripts/install-replace.sh` notices the
requirement no longer matches and runs `tccutil reset Accessibility` so you
re-grant the permission once instead of on every build.

## Build and Install Locally

Build and install from source:

```sh
./scripts/install-replace.sh
```

This script packages the app and installs it to `/Applications/MaccyZig.app`. MaccyZig installs alongside upstream Maccy — it never modifies `/Applications/Maccy.app` or the original Maccy data.

## Developer CLI

Show help:

```sh
./zig-out/bin/maccy-zig --help
```

Capture the current pasteboard once:

```sh
zig build run -- once
```

Watch the pasteboard continuously:

```sh
./zig-out/bin/maccy-zig watch --max-blob-mib 4
```

List stored history rows:

```sh
./zig-out/bin/maccy-zig list
```

Show storage statistics:

```sh
./zig-out/bin/maccy-zig stats
```

Use a custom database path:

```sh
./zig-out/bin/maccy-zig watch --db /tmp/maccy-zig.sqlite
```

Useful options:

```text
--db PATH            SQLite path
--interval-ms N      Watch polling interval, default 500
--max-items N        Unpinned history cap, default 500
--max-blob-mib N     Skip individual pasteboard blobs above N MiB, default 16
--max-age-days N     Auto-delete unpinned items older than N days, default 0 = off
--no-images          Store text/html/rtf/file URLs only
```

## Verification

Run unit tests:

```sh
zig build test
```

Smoke test the packaged app bundle:

```sh
./scripts/smoke-package.sh
```

Smoke test app launch:

```sh
./scripts/smoke-bundle-launch.sh
```

Generated verification artifacts are written to:

```text
dist/verification/
```

## Release Builds

Release builds are created by GitHub Actions when a tag like `v0.1.0` is pushed, or when the `Release` workflow is run manually from the Actions tab.

The CI runner has no signing certificate, so release builds are ad-hoc signed by explicit request
(`CODESIGN_IDENTITY=-`): the first launch needs the steps in the release notes, and the Accessibility
permission has to be granted again after every upgrade — see the code-signing section above for why.
Both slices take their minimum macOS version from `LSMinimumSystemVersion` in `resources/Info.plist`,
and `scripts/smoke-package.sh` checks that the binary agrees with it.

Each release includes:

- `MaccyZig-<tag>-macOS.zip`
- `MaccyZig-<tag>-macOS.zip.sha256`
- release notes with a small ASCII logo and install notes

## Project Layout

```text
.
├── build.zig
├── assets/
│   ├── logo.png
│   ├── logo-mark.png
│   ├── logo-thumb.png
│   └── menubar.svg
├── resources/
│   └── Info.plist
├── scripts/
│   ├── package-app.sh
│   ├── install-replace.sh
│   ├── smoke-package.sh
│   └── smoke-bundle-launch.sh
└── src/
    ├── main.zig
    ├── capture_service.zig
    ├── storage.zig
    ├── macos_app.m
    ├── macos_clipboard.m
    ├── macos_hotkey.m
    └── macos_paste.m
```

## Data Storage

Default database path:

```text
~/Library/Application Support/MaccyZig/Storage.sqlite
```

The database uses WAL mode and stores metadata in `history_items` and pasteboard payloads in `history_contents`.

## Permissions

Like other clipboard managers, the app reads the system pasteboard. Pasting into other apps may require macOS Accessibility permissions depending on the paste path and target application.

If paste actions do not work, open:

```text
System Settings -> Privacy & Security -> Accessibility
```

Then add or enable `MaccyZig.app`. If the checkbox is already ticked but paste
still prompts, the app was ad-hoc signed — see
[Code signing and Accessibility](#code-signing-and-accessibility).

## Jev suggestions (optional, off by default)

With *Settings → Suggestions* switched on, opening the panel asks
[TypeSafe's Jev model](https://docs.typesafe.ai/) which history entry belongs in
the app you are about to paste into, and preselects it. Jev answers with a typed
choice over the candidate row ids, so the answer feeds the selection directly.
The footer shows what it picked and how sure it was; *Actions… → Suggest what to
paste (Jev)* is the same switch, for toggling without opening Settings.

On the left of the key row in *Settings → Suggestions*, choose which service Jev
is reached through, paste that service's API key and press **Save & Check**: a
real round trip confirms it works, and only then is the key stored in the login
keychain (device-only, never in NSUserDefaults and never in the repo) and the
field cleared. Each service keeps its own key, so switching back and forth never
loses one.

All three speak the same TypeSafe wire format; only the address, the model's
name there and the credentials differ:

| Service | Request URL | Model | Key |
| --- | --- | --- | --- |
| TypeSafe (direct) | `https://api.typesafe.ai/v1/systemone` | `jev-latest` | TypeSafe API key |
| Vercel AI Gateway | `https://ai-gateway.vercel.sh/typesafe/v1/systemone` | `typesafe-ai/jev` | AI Gateway API key |
| Custom endpoint | `<base URL>/v1/systemone` | `jev-latest` unless changed | whatever the upstream wants |

- **Vercel AI Gateway** is used through its
  [TypeSafe-compatible API](https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe). No TypeSafe
  account is needed: create an API key under AI Gateway in the Vercel dashboard. Vercel bills TypeSafe's
  list price with no markup and gives every team monthly free credits, but those cover only a subset of
  models — whether Jev is one of them is whatever Vercel's
  [Free Tier model list](https://vercel.com/ai-gateway/models?freeTier=true) says.
- **Cloudflare AI Gateway**: choose *Custom endpoint…*. Create a
  [custom provider](https://developers.cloudflare.com/ai-gateway/configuration/custom-providers/) in
  Cloudflare with `base_url` `https://api.typesafe.ai` and a slug such as `typesafe`, then enter
  `https://gateway.ai.cloudflare.com/v1/<account_id>/<gateway_id>/custom-typesafe` as the base URL. The
  API key is still your TypeSafe key, which the gateway forwards. For an authenticated gateway, put
  `cf-aig-authorization` and `Bearer <token>` into the extra header; its value is kept in the keychain
  too. The gateway itself is free (logs, caching, rate limiting), but it is a proxy in front of your own
  TypeSafe key: the model calls are still billed by TypeSafe.
- A custom endpoint has to be `https://`: the API key and previews of the clipboard travel to it.

At `$0.042` per million input tokens and about 2k tokens per panel open, one suggestion costs about
$0.0001.

What it is told about each entry, and how the answer is judged, is in
[docs/jev-context.md](docs/jev-context.md) — including the measurements behind
the acceptance rule.

When Jev picks something the footer shows `✦ Jev picked · 98%`, and up to two
also-rans get a faint `✦` next to their source app. A suggestion never moves
the selection once you have started choosing yourself, and searching re-asks
on the narrowed list instead of giving up. When it looks
and declines, nothing is shown — the panel just keeps its normal top-of-history
selection. Only failures you can act on (missing key, rejected key, service
unreachable) get a footer message.

What leaves the machine while it is on: previews of the top 12 visible entries
(200 characters each), the app they were copied from, and the destination app,
window title, focused field (400 characters) and the text on screen just above
it (600 characters). Entries that look like
credentials — `sk-…`, `ghp_…`, `AKIA…`, PEM blocks, `password = …`, JWTs — are
dropped from the candidate set and never sent, and a focused field holding one
is not echoed back. A pick is shown only when it beats the explicit "none of
these" option and is clearly ahead of the runner-up; otherwise nothing moves.

The destination is always described twice: by Accessibility (what the app says
about the field) and by the screen (what you are looking at, in any app
whatever it is built with). For the second, Jev reads a box of the window just
above where the paste will land — caret, else the focused field, else the
pointer — through ScreenCaptureKit and Vision: about 200ms, started while the
panel is already waiting for rows, and only the lines nearest the paste are
recognised and sent (600 characters at most, credential-shaped lines dropped).
That needs Screen Recording, granted from *Settings → Shortcuts & Permissions*
next to the Accessibility one.
`maccy-zig ocr-check` times the path on your own machine. *Actions… → Log Jev
Decisions* opens a live inspector window showing the last screen capture and,
under it, every suggestion's destination context, the option sentences sent, the
probabilities that came back, the accept/reject verdict and the stage timings.
It stays open across launches while tracing is on, and writes nothing to disk. While it is
on it also traces where each mouse-down in the app's own windows landed (window, view, whether the
app was active), which is what a "this button does nothing" report needs; with tracing off no
mouse monitor exists.

Each candidate also says where it was copied from (window title and page or
file, read at copy time while Jev is on), whether it was just pasted here, and
whether it was gathered alongside something that was. Every paste leaves an
evaluation sample; `maccy-zig jev-eval`, run from inside the app bundle, replays
them against the current prompt and reports precision and wrong-row yanks, and
`maccy-zig jev-context` prints what Jev is told about the focused field.

Check the redaction and confidence logic offline:

```sh
./zig-out/bin/maccy-zig jev-self-check
```

Check that every control in the app's windows can actually be reached by a
click. It builds the real Settings window and panel off screen, in both
languages, and hit-tests points across each control the way AppKit does — no
window is shown and nothing is clicked. `MZ_UI_SNAPSHOT_DIR=<dir>` also renders
each window to a PNG there:

```sh
./zig-out/bin/maccy-zig ui-self-check
```

## Shipping Checklist

Before publishing a release on GitHub:

- Run `zig build test`.
- Run `./zig-out/bin/maccy-zig jev-self-check` and `./zig-out/bin/maccy-zig ui-self-check`.
- Run `./scripts/smoke-package.sh`.
- Run `./scripts/smoke-bundle-launch.sh`.
- Verify the packaged app on a clean macOS account or machine.
- Confirm the packaged bundle identifier is `io.github.chang1o1.MaccyZig` (separate from upstream Maccy so TCC permissions stay isolated).

## License

MaccyZig is available under the MIT License. See [LICENSE](LICENSE).
