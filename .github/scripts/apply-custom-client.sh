#!/bin/bash
set -euo pipefail

# Apply custom-client branding / runtime files.
#
# Usage: apply-custom-client.sh <platform> <phase> <config-dir> [path]
#   platform: windows | macos | linux | android | ios
#   phase:    source  brand the RustDesk source tree before compiling
#                     (platform icons, product/app names)
#             bundle  write runtime files into the built application
#                     (custom.txt, logo assets)
#   config-dir: directory produced by fetch-custom-config.sh
#   path:      source -> repository root (default ".")
#              bundle -> windows: dist dir (e.g. rustdesk)
#                        macos:   RustDesk.app
#                        linux:   flutter linux bundle
#                        android: flutter dir (uses flutter/assets)
#
# Missing customization is not an error: every step is skipped when the
# corresponding file was not provided by the console.

PLATFORM="${1:?platform required}"
PHASE="${2:?phase required}"
CONFIG_DIR="${3:?config-dir required}"
TARGET="${4:-.}"

APP_NAME=""
if [ -f "${CONFIG_DIR}/app-name.txt" ]; then
  APP_NAME="$(cat "${CONFIG_DIR}/app-name.txt")"
fi
LOGOS="${CONFIG_DIR}/logos"
CUSTOM_TXT="${CONFIG_DIR}/custom.txt"

log() { echo "[custom-client] $*"; }

copy_custom_txt() { # <dest>
  if [ -f "${CUSTOM_TXT}" ]; then
    mkdir -p "$(dirname "$1")"
    cp "${CUSTOM_TXT}" "$1"
    log "custom.txt -> $1"
  fi
}

copy_logos() { # <assets-dir>
  local dest="$1" file
  [ -d "${LOGOS}" ] || return 0
  mkdir -p "${dest}"
  for file in "${LOGOS}"/*; do
    [ -f "${file}" ] || continue
    cp "${file}" "${dest}/$(basename "${file}")"
    log "logo $(basename "${file}") -> ${dest}"
  done
}

resize_png() { # <src> <dst> <size>
  local src="$1" dst="$2" size="$3"
  mkdir -p "$(dirname "${dst}")"
  if command -v convert >/dev/null 2>&1; then
    convert "${src}" -resize "${size}x${size}" "${dst}" 2>/dev/null && return 0
  fi
  if command -v sips >/dev/null 2>&1; then
    sips -z "${size}" "${size}" "${src}" --out "${dst}" >/dev/null 2>&1 && return 0
  fi
  # Unsupported/invalid image: keep the build going with the original file.
  cp "${src}" "${dst}"
}

replace_manifest_label() { # <manifest> <label>
  python3 - "$1" "$2" <<'PY'
import re
import sys

path, label = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
except OSError:
    sys.exit(0)
text = re.sub(r'android:label="RustDesk"', 'android:label="%s"' % label, text)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY
}

if [ "${PHASE}" = "source" ]; then
  case "${PLATFORM}" in
    windows)
      if [ -f "${LOGOS}/icon.ico" ]; then
        cp "${LOGOS}/icon.ico" "${TARGET}/res/icon.ico"
        mkdir -p "${TARGET}/flutter/windows/runner/resources"
        cp "${LOGOS}/icon.ico" "${TARGET}/flutter/windows/runner/resources/app_icon.ico"
        log "windows executable and MSI icon replaced"
      fi
      if [ -n "${APP_NAME}" ]; then
        python3 - "${TARGET}/flutter/windows/runner/Runner.rc" "${APP_NAME}" <<'PY'
import sys

path, name = sys.argv[1], sys.argv[2]
pairs = [
    ('"FileDescription", "RustDesk Remote Desktop"', f'"FileDescription", "{name}"'),
    ('"InternalName", "rustdesk"', f'"InternalName", "{name}"'),
    ('"OriginalFilename", "rustdesk.exe"', f'"OriginalFilename", "{name}.exe"'),
    ('"ProductName", "RustDesk"', f'"ProductName", "{name}"'),
]
try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
except OSError:
    sys.exit(0)
for old, new in pairs:
    text = text.replace(old, new)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY
        log "windows version resource branded as ${APP_NAME}"
      fi
      ;;
    macos)
      if [ -f "${LOGOS}/icon.png" ] && command -v iconutil >/dev/null 2>&1; then
        iconset="$(mktemp -d)/AppIcon.iconset"
        mkdir -p "${iconset}"
        for size in 16 32 128 256 512; do
          resize_png "${LOGOS}/icon.png" "${iconset}/icon_${size}x${size}.png" "${size}"
          resize_png "${LOGOS}/icon.png" "${iconset}/icon_${size}x${size}@2x.png" "$((size * 2))"
        done
        if iconutil -c icns "${iconset}" -o "${TARGET}/flutter/macos/Runner/AppIcon.icns" 2>/dev/null; then
          log "macOS app icon replaced"
        else
          echo "WARNING: failed to build AppIcon.icns" >&2
        fi
      fi
      if [ -n "${APP_NAME}" ] && [ -f "${TARGET}/flutter/macos/Runner/Info.plist" ] \
        && [ -x /usr/libexec/PlistBuddy ]; then
        for key in CFBundleDisplayName CFBundleName; do
          /usr/libexec/PlistBuddy -c "Set :${key} ${APP_NAME}" \
            "${TARGET}/flutter/macos/Runner/Info.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Add :${key} string ${APP_NAME}" \
              "${TARGET}/flutter/macos/Runner/Info.plist"
        done
        log "macOS bundle name set to ${APP_NAME}"
      fi
      ;;
    android)
      MANIFEST="${TARGET}/flutter/android/app/src/main/AndroidManifest.xml"
      if [ -n "${APP_NAME}" ] && [ -f "${MANIFEST}" ]; then
        replace_manifest_label "${MANIFEST}" "${APP_NAME}"
        log "android app label set to ${APP_NAME}"
      fi
      if [ -f "${LOGOS}/icon.png" ]; then
        for entry in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
          density="${entry%%:*}"
          size="${entry##*:}"
          dir="${TARGET}/flutter/android/app/src/main/res/mipmap-${density}"
          [ -d "${dir}" ] || continue
          for name in ic_launcher.png ic_launcher_round.png ic_launcher_foreground.png; do
            [ -f "${dir}/${name}" ] || continue
            resize_png "${LOGOS}/icon.png" "${dir}/${name}" "${size}"
          done
        done
        log "android launcher icons replaced"
      fi
      ;;
    ios)
      if [ -f "${LOGOS}/icon.png" ]; then
        ICONSET="${TARGET}/flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset"
        for icon in "${ICONSET}"/Icon-App-*.png; do
          [ -f "${icon}" ] || continue
          base="$(basename "${icon}" .png)"
          dims="${base#Icon-App-}"
          dims="${dims%%@*}"
          scale="${base##*@}"
          scale="${scale%x}"
          width="${dims%x*}"
          size="$(python3 -c "print(int(round(float('${width}') * ${scale})))")"
          resize_png "${LOGOS}/icon.png" "${icon}" "${size}"
        done
        log "iOS app icons replaced"
      fi
      if [ -n "${APP_NAME}" ] && [ -f "${TARGET}/flutter/ios/Runner/Info.plist" ] \
        && [ -x /usr/libexec/PlistBuddy ]; then
        for key in CFBundleDisplayName CFBundleName; do
          /usr/libexec/PlistBuddy -c "Set :${key} ${APP_NAME}" \
            "${TARGET}/flutter/ios/Runner/Info.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Add :${key} string ${APP_NAME}" \
              "${TARGET}/flutter/ios/Runner/Info.plist"
        done
        log "iOS bundle name set to ${APP_NAME}"
      fi
      ;;
    linux)
      if [ -n "${APP_NAME}" ]; then
        for desktop in "${TARGET}/res/rustdesk.desktop" "${TARGET}/res/rustdesk-link.desktop"; do
          [ -f "${desktop}" ] || continue
          sed -i "s/^Name=RustDesk$/Name=${APP_NAME}/" "${desktop}"
        done
        log "linux desktop entries renamed to ${APP_NAME}"
      fi
      if [ -f "${LOGOS}/icon.png" ]; then
        cp "${LOGOS}/icon.png" "${TARGET}/res/icon.png"
        cp "${LOGOS}/icon.png" "${TARGET}/res/128x128@2x.png"
        resize_png "${LOGOS}/icon.png" "${TARGET}/res/128x128.png" 128
        resize_png "${LOGOS}/icon.png" "${TARGET}/res/64x64.png" 64
        resize_png "${LOGOS}/icon.png" "${TARGET}/res/32x32.png" 32
        log "linux package icons replaced"
      fi
      ;;
    *)
      echo "Unknown platform: ${PLATFORM}" >&2
      exit 1
      ;;
  esac
  exit 0
fi

case "${PLATFORM}" in
  windows)
    copy_custom_txt "${TARGET}/custom.txt"
    copy_logos "${TARGET}/data/flutter_assets/assets"
    ;;
  macos)
    # RustDesk reads custom.txt from Contents/Resources on macOS (the
    # executable lives in Contents/MacOS).
    copy_custom_txt "${TARGET}/Contents/Resources/custom.txt"
    ASSETS="${TARGET}/Contents/Frameworks/App.framework/Resources/flutter_assets/assets"
    if [ ! -d "$(dirname "${ASSETS}")" ]; then
      ASSETS="${TARGET}/Contents/MacOS/data/flutter_assets/assets"
    fi
    copy_logos "${ASSETS}"
    ;;
  linux)
    # Linux clients read custom.txt from the directory of the executable.
    copy_custom_txt "${TARGET}/custom.txt"
    copy_logos "${TARGET}/data/flutter_assets/assets"
    ;;
  android|ios)
    copy_custom_txt "${TARGET}/flutter/assets/custom.txt"
    copy_logos "${TARGET}/flutter/assets"
    ;;
  *)
    echo "Unknown platform: ${PLATFORM}" >&2
    exit 1
    ;;
esac
