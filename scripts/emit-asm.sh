#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
zig build -Doptimize=ReleaseFast
mkdir -p profile
otool -tvV ./zig-out/bin/maccy-zig > profile/maccy-zig.arm64.s
size ./zig-out/bin/maccy-zig > profile/maccy-zig.size.txt
printf 'wrote profile/maccy-zig.arm64.s and profile/maccy-zig.size.txt\n'
