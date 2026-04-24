# MaccyZig Architecture

This is a Zig-first rewrite track for Maccy's hot path.

Implemented now:
- AppKit pasteboard snapshot via a narrow Objective-C C ABI shim.
- Zig-owned filtering, hashing, title generation, SQLite persistence, duplicate coalescing, pruning.
- Hard per-blob cap (`--max-blob-mib`) to prevent 190 MiB TIFF entries from becoming resident memory bombs.
- Release/profile scripts and assembly dump support.

Intentional boundary:
- The Objective-C shim is only for Cocoa/AppKit calls that Zig cannot ergonomically call directly yet.
- The performance-critical policy and storage code lives in Zig and can be profiled/disassembled/mutated independently.

Next parity layers:
1. AppKit status item + popover UI.
2. Global shortcut registration and paste event synthesis.
3. Settings migration from org.p0deje.Maccy defaults.
4. Import/migration from SwiftData Storage.sqlite.
5. Rich preview thumbnails with lazy decode cache.
