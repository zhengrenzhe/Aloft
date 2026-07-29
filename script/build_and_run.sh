#!/usr/bin/env bash
set -euo pipefail

readonly APP_NAME="Aloft"
readonly BUNDLE_ID="com.bytedance.aloft"
readonly MIN_SYSTEM_VERSION="14.0"
readonly INSTALLED_APP_BUNDLE="/Applications/$APP_NAME.app"
readonly INSTALLED_APP_BINARY="$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--release|--stage-release|--install-release]" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

case "${1:-run}" in
  run)
    MODE="run"
    BUILD_CONFIGURATION="debug"
    ;;
  --debug|debug)
    MODE="debug"
    BUILD_CONFIGURATION="debug"
    ;;
  --logs|logs)
    MODE="logs"
    BUILD_CONFIGURATION="debug"
    ;;
  --telemetry|telemetry)
    MODE="telemetry"
    BUILD_CONFIGURATION="debug"
    ;;
  --verify|verify)
    MODE="verify"
    BUILD_CONFIGURATION="debug"
    ;;
  --release|release)
    MODE="release"
    BUILD_CONFIGURATION="release"
    ;;
  --stage-release|stage-release)
    MODE="stage-release"
    BUILD_CONFIGURATION="release"
    ;;
  --install-release|install-release)
    MODE="install-release"
    BUILD_CONFIGURATION="release"
    ;;
  *)
    usage
    exit 2
    ;;
esac
readonly MODE
readonly BUILD_CONFIGURATION

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly DIST_DIR="$PROJECT_ROOT/dist"
readonly APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
readonly APP_CONTENTS="$APP_BUNDLE/Contents"
readonly APP_MACOS="$APP_CONTENTS/MacOS"
readonly APP_RESOURCES="$APP_CONTENTS/Resources"
readonly APP_BINARY="$APP_MACOS/$APP_NAME"
readonly INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$PROJECT_ROOT"

process_is_running() {
  /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1
}

validate_dist_directory() {
  local physical_dist

  if [[ -L "$DIST_DIR" ]]; then
    echo "error: refusing symlinked distribution directory $DIST_DIR" >&2
    exit 1
  fi
  if [[ ! -d "$DIST_DIR" ]]; then
    echo "error: distribution path is not a directory: $DIST_DIR" >&2
    exit 1
  fi

  physical_dist="$(cd "$DIST_DIR" && pwd -P)" || {
    echo "error: could not resolve distribution directory $DIST_DIR" >&2
    exit 1
  }
  if [[ "$physical_dist" != "$PROJECT_ROOT/dist" ]]; then
    echo "error: distribution directory resolves outside the project: $physical_dist" >&2
    exit 1
  fi
}

prepare_dist_directory() {
  if [[ -L "$DIST_DIR" ]]; then
    echo "error: refusing symlinked distribution directory $DIST_DIR" >&2
    exit 1
  fi
  if [[ -e "$DIST_DIR" && ! -d "$DIST_DIR" ]]; then
    echo "error: distribution path is not a directory: $DIST_DIR" >&2
    exit 1
  fi
  if [[ ! -e "$DIST_DIR" ]]; then
    /bin/mkdir "$DIST_DIR"
  fi

  validate_dist_directory
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
  if ! process_is_running; then
    return
  fi

  echo "error: an existing $APP_NAME process is still running after 6 seconds." >&2
  echo "A second instance was not built or launched." >&2
  echo "Resolve any resistant managed command shown by Aloft, then run this script again." >&2
  exit 1
}

stage_app_bundle() {
  local build_bin_path
  local build_binary
  local build_resource_bundle
  local build_swiftterm_resource_bundle
  local staging_root
  local staged_bundle
  local staged_contents
  local staged_macos
  local staged_resources
  local staged_binary
  local staged_plist

  swift build -c "$BUILD_CONFIGURATION"
  build_bin_path="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
  build_binary="$build_bin_path/$APP_NAME"
  build_resource_bundle="$build_bin_path/Aloft_AloftApp.bundle"
  build_swiftterm_resource_bundle="$build_bin_path/SwiftTerm_SwiftTerm.bundle"

  if [[ ! -x "$build_binary" ]]; then
    echo "error: SwiftPM did not produce executable $build_binary" >&2
    exit 1
  fi
  if [[ ! -d "$build_resource_bundle" ]]; then
    echo "error: SwiftPM did not produce resource bundle $build_resource_bundle" >&2
    exit 1
  fi
  if [[ ! -d "$build_swiftterm_resource_bundle" ]]; then
    echo "error: SwiftPM did not produce resource bundle $build_swiftterm_resource_bundle" >&2
    exit 1
  fi

  staging_root="$(/usr/bin/mktemp -d "$DIST_DIR/.aloft-stage.XXXXXX")"
  staged_bundle="$staging_root/$APP_NAME.app"
  staged_contents="$staged_bundle/Contents"
  staged_macos="$staged_contents/MacOS"
  staged_resources="$staged_contents/Resources"
  staged_binary="$staged_macos/$APP_NAME"
  staged_plist="$staged_contents/Info.plist"

  cleanup_staging() {
    /bin/rm -rf "$staging_root"
  }
  trap cleanup_staging EXIT

  /bin/mkdir -p "$staged_macos" "$staged_resources"
  /bin/cp "$build_binary" "$staged_binary"
  /bin/chmod +x "$staged_binary"
  /usr/bin/ditto \
    "$build_resource_bundle" \
    "$staged_resources/Aloft_AloftApp.bundle"
  /usr/bin/ditto \
    "$build_swiftterm_resource_bundle" \
    "$staged_resources/SwiftTerm_SwiftTerm.bundle"

  /bin/cat >"$staged_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>ar</string>
    <string>de</string>
    <string>en</string>
    <string>es</string>
    <string>fr</string>
    <string>ja</string>
    <string>ko</string>
    <string>pt-BR</string>
    <string>ru</string>
    <string>zh-Hans</string>
    <string>zh-Hant</string>
  </array>
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
  /usr/bin/codesign --force --sign - "$staged_bundle"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$staged_bundle"

  validate_dist_directory
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
  local bundle="${1:-$APP_BUNDLE}"
  /usr/bin/open -n "$bundle"
}

verify_app_started() {
  local expected_binary="${1:-$APP_BINARY}"
  local attempt
  for attempt in {1..50}; do
    if process_is_running_from "$expected_binary"; then
      echo "$APP_NAME is running from $expected_binary"
      return
    fi
    /bin/sleep 0.1
  done
  if process_is_running_from "$expected_binary"; then
    echo "$APP_NAME is running from $expected_binary"
    return
  fi

  echo "error: $APP_NAME did not appear within 5 seconds after launch." >&2
  echo "Run '$0 --logs' to inspect startup logs." >&2
  exit 1
}

process_is_running_from() {
  local expected_binary="$1"
  local pid
  local process_binary

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    process_binary="$(/bin/ps -p "$pid" -o comm=)"
    if [[ "$process_binary" == "$expected_binary" ]]; then
      return 0
    fi
  done < <(/usr/bin/pgrep -x "$APP_NAME" || true)

  return 1
}

install_app_bundle() {
  local install_parent="/Applications"
  local physical_install_parent
  local staging_root
  local staged_install_bundle
  local backup_bundle
  local had_existing=0
  local new_bundle_installed=0

  physical_install_parent="$(cd "$install_parent" && pwd -P)"
  if [[ "$physical_install_parent" != "/Applications" ]]; then
    echo "error: application directory resolves unexpectedly: $physical_install_parent" >&2
    exit 1
  fi
  if [[ -L "$INSTALLED_APP_BUNDLE" ]]; then
    echo "error: refusing to replace symlinked app bundle $INSTALLED_APP_BUNDLE" >&2
    exit 1
  fi
  if [[ -e "$INSTALLED_APP_BUNDLE" && ! -d "$INSTALLED_APP_BUNDLE" ]]; then
    echo "error: installed app path is not a directory: $INSTALLED_APP_BUNDLE" >&2
    exit 1
  fi

  staging_root="$(/usr/bin/mktemp -d "$install_parent/.aloft-install.XXXXXX")"
  staged_install_bundle="$staging_root/$APP_NAME.app"
  backup_bundle="$staging_root/$APP_NAME.previous.app"

  rollback_install() {
    local status=$?
    trap - EXIT
    set +e
    if [[ "$new_bundle_installed" -eq 1 && -d "$INSTALLED_APP_BUNDLE" ]]; then
      /bin/rm -rf "$INSTALLED_APP_BUNDLE"
    fi
    if [[ "$had_existing" -eq 1 && -d "$backup_bundle" ]]; then
      /bin/mv "$backup_bundle" "$INSTALLED_APP_BUNDLE"
    fi
    /bin/rm -rf "$staging_root"
    exit "$status"
  }
  trap rollback_install EXIT

  /usr/bin/ditto "$APP_BUNDLE" "$staged_install_bundle"
  /usr/bin/plutil -lint "$staged_install_bundle/Contents/Info.plist" >/dev/null
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$staged_install_bundle"

  if [[ -d "$INSTALLED_APP_BUNDLE" ]]; then
    had_existing=1
    /bin/mv "$INSTALLED_APP_BUNDLE" "$backup_bundle"
  fi
  /bin/mv "$staged_install_bundle" "$INSTALLED_APP_BUNDLE"
  new_bundle_installed=1

  /usr/bin/plutil -lint "$INSTALLED_APP_BUNDLE/Contents/Info.plist" >/dev/null
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP_BUNDLE"

  if [[ "$had_existing" -eq 1 ]]; then
    /bin/rm -rf "$backup_bundle"
  fi
  trap - EXIT
  /bin/rm -rf "$staging_root"
  echo "Installed release app at $INSTALLED_APP_BUNDLE"
}

prepare_dist_directory
if [[ "$MODE" != "stage-release" ]]; then
  request_existing_app_to_quit
fi
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
  release)
    open_app
    verify_app_started
    ;;
  stage-release)
    echo "Staged release app at $APP_BUNDLE"
    ;;
  install-release)
    install_app_bundle
    open_app "$INSTALLED_APP_BUNDLE"
    verify_app_started "$INSTALLED_APP_BINARY"
    ;;
esac
