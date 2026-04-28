#!/usr/bin/env bash
set -u

backend="xcode-llvm"
min_line_rate="0.90"

for arg in "$@"; do
  case "$arg" in
    --backend=*) backend="${arg#*=}" ;;
    --min-line-rate=*) min_line_rate="${arg#*=}" ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

coverage_dir="zig-out/coverage"
mkdir -p "$coverage_dir"

allowlist=(
  "src/storage.zig"
  "src/capture_service.zig"
)

for optional in src/cli_options.zig src/import_maccy.zig src/app_core.zig; do
  if [[ -f "$optional" ]]; then
    allowlist+=("$optional")
  fi
done

echo "coverage_backend=$backend"
echo "coverage_metric=aggregate_line_coverage"
echo "coverage_min_line_rate=$min_line_rate"
printf 'coverage_allowlist=%s\n' "${allowlist[*]}"
echo "coverage_excluded=src/main.zig mixed runtime glue; src/macos_*.m; src/macos_*.h; AppKit/C-ABI boundary wrappers unless seam-extracted"

run_and_capture() {
  local label="$1"
  shift
  local log="$coverage_dir/${label}.log"
  echo "+ $*" | tee "$log"
  "$@" >>"$log" 2>&1
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "coverage_status=unavailable"
    echo "coverage_error=missing tool: $1"
    exit 2
  fi
}

report_no_profile() {
  local reason="$1"
  echo "coverage_status=unavailable"
  echo "coverage_error=$reason"
  echo "coverage_note=Zig test binary did not produce a consumable profile-backed coverage report; no coverage percentage claimed."
  exit 2
}

if [[ "$backend" == "xcode-llvm" ]]; then
  if ! xcrun --find llvm-cov >/dev/null 2>&1; then
    report_no_profile "xcrun llvm-cov not available"
  fi
  if ! xcrun --find llvm-profdata >/dev/null 2>&1; then
    report_no_profile "xcrun llvm-profdata not available"
  fi

  rm -f "$coverage_dir"/storage-test "$coverage_dir"/storage.profraw "$coverage_dir"/storage.profdata
  if run_and_capture "xcode-direct-zig-test" zig test src/storage.zig --test-no-exec -femit-bin="$coverage_dir/storage-test" -fllvm; then
    LLVM_PROFILE_FILE="$coverage_dir/storage.profraw" "$coverage_dir/storage-test" >>"$coverage_dir/xcode-direct-run.log" 2>&1 || true
    if [[ -f "$coverage_dir/storage.profraw" ]]; then
      if xcrun llvm-profdata merge -sparse "$coverage_dir/storage.profraw" -o "$coverage_dir/storage.profdata" >>"$coverage_dir/xcode-direct-profdata.log" 2>&1 &&
        xcrun llvm-cov report "$coverage_dir/storage-test" -instr-profile="$coverage_dir/storage.profdata" src/storage.zig >"$coverage_dir/xcode-direct-report.txt" 2>&1; then
        cat "$coverage_dir/xcode-direct-report.txt"
        exit 0
      fi
    fi
  fi

  test_bin="$coverage_dir/maccy-zig-test"
  if [[ ! -x "$test_bin" ]]; then
    report_no_profile "coverage test binary missing: $test_bin"
  fi

  rm -f "$coverage_dir"/maccy-zig-test.profraw "$coverage_dir"/maccy-zig-test.profdata
  LLVM_PROFILE_FILE="$coverage_dir/maccy-zig-test.profraw" "$test_bin" >>"$coverage_dir/xcode-build-wired-run.log" 2>&1 || true
  if [[ ! -f "$coverage_dir/maccy-zig-test.profraw" ]]; then
    report_no_profile "no .profraw produced by direct or build-wired Zig test attempts"
  fi

  if ! xcrun llvm-profdata merge -sparse "$coverage_dir/maccy-zig-test.profraw" -o "$coverage_dir/maccy-zig-test.profdata" >>"$coverage_dir/xcode-build-wired-profdata.log" 2>&1; then
    report_no_profile "llvm-profdata could not merge the build-wired profile"
  fi

  if ! xcrun llvm-cov report "$test_bin" -instr-profile="$coverage_dir/maccy-zig-test.profdata" "${allowlist[@]}" >"$coverage_dir/xcode-build-wired-report.txt" 2>&1; then
    report_no_profile "llvm-cov could not report line coverage for the allowlist"
  fi

  cat "$coverage_dir/xcode-build-wired-report.txt"
  exit 0
elif [[ "$backend" == "kcov" ]]; then
  require_tool kcov
  test_bin="$coverage_dir/maccy-zig-test"
  if [[ ! -x "$test_bin" ]]; then
    echo "coverage_status=unavailable"
    echo "coverage_error=coverage test binary missing: $test_bin"
    exit 2
  fi
  include_path="$(IFS=,; echo "${allowlist[*]}")"
  rm -rf "$coverage_dir/kcov"
  kcov --include-pattern="$include_path" "$coverage_dir/kcov" "$test_bin"
  echo "coverage_status=generated"
  echo "coverage_report=$coverage_dir/kcov/index.html"
  echo "coverage_note=parse raw allowlist line counts before claiming >= $min_line_rate"
else
  echo "coverage_status=unavailable"
  echo "coverage_error=unsupported backend: $backend"
  exit 2
fi
