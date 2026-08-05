#!/usr/bin/env bash
set -euo pipefail

readonly APP_NAME="Aloft"
readonly SYSTEM_LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  echo "usage: $0 <release-directory> [lsregister]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

release_directory="$1"
lsregister="${2:-$SYSTEM_LSREGISTER}"

if [[ -L "$release_directory" ]]; then
  echo "error: refusing symlinked release directory $release_directory" >&2
  exit 1
fi
if [[ ! -d "$release_directory" ]]; then
  echo "error: release directory does not exist: $release_directory" >&2
  exit 1
fi
if [[ ! -x "$lsregister" ]]; then
  echo "error: lsregister is not executable: $lsregister" >&2
  exit 1
fi

readonly PHYSICAL_RELEASE_DIRECTORY="$(cd "$release_directory" && pwd -P)"
readonly APP_BUNDLE="$PHYSICAL_RELEASE_DIRECTORY/$APP_NAME.app"
readonly RELEASE_ARCHIVE="$PHYSICAL_RELEASE_DIRECTORY/$APP_NAME.zip"

if [[ -L "$APP_BUNDLE" ]]; then
  echo "error: refusing symlinked app bundle $APP_BUNDLE" >&2
  exit 1
fi
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: release app bundle does not exist: $APP_BUNDLE" >&2
  exit 1
fi
if [[ ! -f "$APP_BUNDLE/Contents/Info.plist" ]]; then
  echo "error: release app bundle has no Info.plist: $APP_BUNDLE" >&2
  exit 1
fi
if [[ -L "$RELEASE_ARCHIVE" || -d "$RELEASE_ARCHIVE" ]]; then
  echo "error: refusing unexpected archive path $RELEASE_ARCHIVE" >&2
  exit 1
fi

staging_root="$(/usr/bin/mktemp -d "$PHYSICAL_RELEASE_DIRECTORY/.aloft-archive.XXXXXX")"
staged_archive="$staging_root/$APP_NAME.zip"
expanded_root="$staging_root/expanded"

cleanup_staging() {
  /bin/rm -rf "$staging_root"
}
trap cleanup_staging EXIT

/usr/bin/ditto \
  -c \
  -k \
  --sequesterRsrc \
  --keepParent \
  "$APP_BUNDLE" \
  "$staged_archive"
/bin/mkdir "$expanded_root"
/usr/bin/ditto -x -k "$staged_archive" "$expanded_root"
if [[ ! -f "$expanded_root/$APP_NAME.app/Contents/Info.plist" ]]; then
  echo "error: archived app bundle failed verification" >&2
  exit 1
fi

/bin/mv -f "$staged_archive" "$RELEASE_ARCHIVE"
/bin/rm -rf "$APP_BUNDLE"
"$lsregister" -gc

trap - EXIT
cleanup_staging
echo "Archived release app at $RELEASE_ARCHIVE"
