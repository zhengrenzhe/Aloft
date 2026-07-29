#!/usr/bin/env bash
set -euo pipefail

readonly APP_NAME="Aloft"
readonly BUNDLE_ID="com.bytedance.aloft"
readonly MIN_SYSTEM_VERSION="14.0"

usage() {
  echo "usage: $0 [run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify]" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

case "${1:-run}" in
  run)
    readonly MODE="run"
    ;;
  --debug|debug)
    readonly MODE="debug"
    ;;
  --logs|logs)
    readonly MODE="logs"
    ;;
  --telemetry|telemetry)
    readonly MODE="telemetry"
    ;;
  --verify|verify)
    readonly MODE="verify"
    ;;
  *)
    usage
    exit 2
    ;;
esac

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DIST_DIR="$PROJECT_ROOT/dist"
readonly APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
readonly APP_CONTENTS="$APP_BUNDLE/Contents"
readonly APP_MACOS="$APP_CONTENTS/MacOS"
readonly APP_BINARY="$APP_MACOS/$APP_NAME"
readonly INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$PROJECT_ROOT"

process_is_running() {
  /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1
}

request_existing_app_to_quit() {
  if ! process_is_running; then
    return
  fi

  local osascript_error
  osascript_error="$(
    /usr/bin/osascript \
      -e 'tell application id "com.bytedance.aloft" to quit' \
      2>&1
  )" || {
    if [[ "$osascript_error" != *"(-600)"* ]]; then
      echo "error: could not ask the existing $APP_NAME instance to quit:" >&2
      echo "$osascript_error" >&2
      exit 1
    fi
  }

  local attempt
  for attempt in {1..60}; do
    if ! process_is_running; then
      return
    fi
    /bin/sleep 0.1
  done

  echo "error: an existing $APP_NAME process is still running after 6 seconds." >&2
  echo "A second instance was not built or launched." >&2
  echo "Resolve any resistant managed command shown by Aloft, then run this script again." >&2
  exit 1
}

stage_app_bundle() {
  local build_bin_path
  local build_binary
  local staging_root
  local staged_bundle
  local staged_contents
  local staged_macos
  local staged_binary
  local staged_plist

  swift build
  build_bin_path="$(swift build --show-bin-path)"
  build_binary="$build_bin_path/$APP_NAME"

  if [[ ! -x "$build_binary" ]]; then
    echo "error: SwiftPM did not produce executable $build_binary" >&2
    exit 1
  fi

  /bin/mkdir -p "$DIST_DIR"
  staging_root="$(/usr/bin/mktemp -d "$DIST_DIR/.aloft-stage.XXXXXX")"
  staged_bundle="$staging_root/$APP_NAME.app"
  staged_contents="$staged_bundle/Contents"
  staged_macos="$staged_contents/MacOS"
  staged_binary="$staged_macos/$APP_NAME"
  staged_plist="$staged_contents/Info.plist"

  cleanup_staging() {
    /bin/rm -rf "$staging_root"
  }
  trap cleanup_staging EXIT

  /bin/mkdir -p "$staged_macos"
  /bin/cp "$build_binary" "$staged_binary"
  /bin/chmod +x "$staged_binary"

  /bin/cat >"$staged_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Aloft opens optional companion shells in Ghostty.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  /usr/bin/plutil -lint "$staged_plist" >/dev/null

  if [[ "$APP_BUNDLE" != "$PROJECT_ROOT/dist/Aloft.app" ]]; then
    echo "error: refusing to replace unexpected bundle path $APP_BUNDLE" >&2
    exit 1
  fi
  /bin/rm -rf "$APP_BUNDLE"
  /bin/mv "$staged_bundle" "$APP_BUNDLE"
  trap - EXIT
  cleanup_staging
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_app_started() {
  local attempt
  for attempt in {1..50}; do
    if process_is_running; then
      echo "$APP_NAME is running from $APP_BUNDLE"
      return
    fi
    /bin/sleep 0.1
  done

  echo "error: $APP_NAME did not appear within 5 seconds after launch." >&2
  echo "Run '$0 --logs' to inspect startup logs." >&2
  exit 1
}

request_existing_app_to_quit
stage_app_bundle

case "$MODE" in
  run)
    open_app
    ;;
  debug)
    /usr/bin/xcrun lldb -- "$APP_BINARY"
    ;;
  logs)
    open_app
    /usr/bin/log stream \
      --info \
      --style compact \
      --predicate "process == \"$APP_NAME\""
    ;;
  telemetry)
    open_app
    /usr/bin/log stream \
      --info \
      --style compact \
      --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  verify)
    open_app
    verify_app_started
    ;;
esac
