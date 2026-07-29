#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P
)"
readonly ARTIFACT_ROOT="$PROJECT_ROOT/artifacts/performance"
readonly RUN_ID="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
readonly REPORT_PATH="$ARTIFACT_ROOT/terminal-$RUN_ID.json"
readonly LOG_PATH="$ARTIFACT_ROOT/terminal-$RUN_ID.log"
readonly METADATA_PATH="$ARTIFACT_ROOT/terminal-$RUN_ID-metadata.txt"

cd "$PROJECT_ROOT"

/bin/mkdir -p "$ARTIFACT_ROOT"

{
  echo "run_id=$RUN_ID"
  echo "git_commit=$(git rev-parse HEAD)"
  echo "build_configuration=release"
  echo "swiftterm_version=1.15.0"
  echo "pty_first_bytes=4000000"
  echo "pty_restart_bytes=500000"
  echo
  /usr/sbin/system_profiler SPHardwareDataType \
    | /usr/bin/sed \
      -e '/Serial Number/d' \
      -e '/Hardware UUID/d' \
      -e '/Provisioning UDID/d'
  echo
  /usr/bin/sw_vers
  echo
  /usr/bin/xcodebuild -version
  echo
  /usr/bin/xcrun swift --version
} >"$METADATA_PATH"

swift package clean
swift build -c release

export ALOFT_RUN_PERFORMANCE_TESTS=1
export ALOFT_PERFORMANCE_OUTPUT="$REPORT_PATH"
export ALOFT_PERFORMANCE_PTY_BYTES=4000000
export ALOFT_PERFORMANCE_PTY_RESTART_BYTES=500000
export ALOFT_PERFORMANCE_MAX_NEW_SAMPLES=1
export NSUnbufferedIO=YES

: >"$LOG_PATH"
for workload in \
  plain_utf8_100mb \
  ansi_progress_100mb \
  cursor_addressing \
  unicode_emoji \
  continuous_controls
do
  export ALOFT_PERFORMANCE_WORKLOAD="$workload"
  for backend in \
    output_pipeline \
    swiftterm_core_graphics \
    swiftterm_metal
  do
    export ALOFT_PERFORMANCE_BACKEND="$backend"
    for _ in 1 2 3 4 5
    do
      swift test -c release \
        --filter TerminalPerformanceTests/testReleaseSyntheticTerminalBenchmarkMatrix \
        2>&1 | /usr/bin/tee -a "$LOG_PATH"
    done
  done
done
unset ALOFT_PERFORMANCE_WORKLOAD
unset ALOFT_PERFORMANCE_BACKEND
for backend in \
  text_pty \
  swiftterm_core_graphics_pty \
  swiftterm_metal_pty
do
  export ALOFT_PERFORMANCE_END_TO_END_BACKEND="$backend"
  for _ in 1 2 3 4 5
  do
    swift test -c release \
      --filter TerminalPerformanceTests/testReleaseEndToEndTerminalBenchmarkMatrix \
      2>&1 | /usr/bin/tee -a "$LOG_PATH"
  done
done
unset ALOFT_PERFORMANCE_END_TO_END_BACKEND
unset ALOFT_PERFORMANCE_MAX_NEW_SAMPLES
swift test -c release \
  --filter TerminalPerformanceTests/testReleasePerformanceReportIsComplete \
  2>&1 | /usr/bin/tee -a "$LOG_PATH"

if [[ ! -s "$REPORT_PATH" ]]; then
  echo "error: benchmark did not produce $REPORT_PATH" >&2
  exit 1
fi

echo "report=$REPORT_PATH"
echo "log=$LOG_PATH"
echo "metadata=$METADATA_PATH"
