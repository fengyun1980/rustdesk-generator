#!/bin/bash
set -euo pipefail

# Upload build artifacts to File Browser, create a per-file share link, and
# report the direct download URLs back to the console as a small JSON payload.
# This avoids pushing large binaries through the console upload endpoint, which
# is unreliable over the public internet.
#
# Usage: upload-artifacts.sh <backend-url> <build-token> <artifact-dir>
# Env:
#   FILEBROWSER_URL   Base URL of File Browser (e.g. http://host:8880)
#   FILEBROWSER_USER  File Browser username
#   FILEBROWSER_PASS  File Browser password
#   FILEBROWSER_DIR   Base directory in File Browser (e.g. /Software/RustDesk)

BACKEND_URL="${1:?backend-url required}"
BUILD_TOKEN="${2:?build-token required}"
ARTIFACT_DIR="${3:?artifact-dir required}"

: "${FILEBROWSER_URL:?FILEBROWSER_URL required}"
: "${FILEBROWSER_USER:?FILEBROWSER_USER required}"
: "${FILEBROWSER_PASS:?FILEBROWSER_PASS required}"
: "${FILEBROWSER_DIR:?FILEBROWSER_DIR required}"

FB="${FILEBROWSER_URL%/}"
BUILD_ID="$(basename "$BACKEND_URL")"

# 按产物扩展名归类，上传到 DIR/<平台>/<构建ID>，避免不同平台的包混在同一个目录。
CATEGORY=""
for f in "$ARTIFACT_DIR"/*; do
  [ -f "$f" ] || continue
  ext="$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    apk) CATEGORY=android ;;
    ipa) CATEGORY=apple/ipad ;;
    dmg|pkg) CATEGORY=apple/macos ;;
    exe|msi) CATEGORY=windows ;;
    appimage|deb|rpm|gz) CATEGORY=linux ;;
  esac
  [ -n "$CATEGORY" ] && break
done

if [ -n "$CATEGORY" ]; then
  DEST_DIR="${FILEBROWSER_DIR%/}/${CATEGORY}/${BUILD_ID}"
else
  DEST_DIR="${FILEBROWSER_DIR%/}/${BUILD_ID}"
fi
echo "Upload category: ${CATEGORY:-none}"

# 读取用户自定义的应用名称，用作编译产物的文件名前缀。
# custom.txt = base64(64 字节 Ed25519 签名 + JSON)，其中 app-name 即用户填写的名称。
APP_NAME=""
if CFG_JSON="$(curl -fsS "${BACKEND_URL}/config" \
  -H "X-Build-Token: ${BUILD_TOKEN}")"; then
  APP_NAME="$(printf '%s' "$CFG_JSON" | python3 -c '
import sys, json, base64
try:
    data = json.load(sys.stdin).get("customTxt") or ""
    raw = base64.b64decode(data)
    print(json.loads(raw[64:]).get("app-name") or "")
except Exception:
    print("")
' 2>/dev/null)"
fi

# 去掉 Windows 文件名不允许的字符，并截断过长名称
SAFE_APP_NAME="$(printf '%s' "$APP_NAME" | python3 -c '
import re, sys
s = sys.stdin.read().strip()
s = re.sub(r"[\\/:*?\"<>|]", "_", s).strip(" .")
print(s[:50])
')"
[ -n "$SAFE_APP_NAME" ] && echo "Artifact prefix: ${SAFE_APP_NAME}" \
  || echo "No custom app name, keep default artifact names"

# 登录：该端点以纯文本形式返回 JWT.
TOKEN="$(curl -fsS -X POST "${FB}/api/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${FILEBROWSER_USER}\",\"password\":\"${FILEBROWSER_PASS}\"}")"

entries=""
for f in "$ARTIFACT_DIR"/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  # 用自定义应用名称替换产物默认的 rustdesk 前缀（保留版本号与架构后缀）
  if [ -n "$SAFE_APP_NAME" ]; then
    suffix="${name#rustdesk}"
    [ "$suffix" = "$name" ] && suffix="-${name}"
    name="${SAFE_APP_NAME}${suffix}"
  fi
  # URL 编码，兼容中文、空格等名称。
  # 路径必须从 stdin 传入：Windows 运行器是 Git Bash，以参数形式传入以 "/" 开头的
  # 路径会被 MSYS 转成 "C:/Program Files/Git/..."，导致上传目录错乱。
  encoded_path="$(printf '%s' "${DEST_DIR}/${name}" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')"
  remote_path="${encoded_path}"
  size="$(wc -c < "$f" | tr -d ' ')"

  # 创建上传槽位（TUS）。设置 override=true 可允许 GitHub 重新运行时覆盖已有内容.
  curl -fsS -X POST "${FB}/api/tus${remote_path}?override=true" \
    -H "X-Auth: ${TOKEN}" \
    -H "Upload-Length: ${size}" >/dev/null

  # 以流式方式传输文件字节.
  curl -fsS -X PATCH "${FB}/api/tus${remote_path}" \
    -H "X-Auth: ${TOKEN}" \
    -H "Content-Type: application/offset+octet-stream" \
    -H "Upload-Offset: 0" \
    --data-binary "@${f}" >/dev/null

  # 创建公开分享链接，并生成直接下载 URL.
  share_resp="$(curl -fsS -X POST "${FB}/api/share${remote_path}" \
    -H "X-Auth: ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"password":"","expires":"","unit":"hours"}')"
  hash="$(printf '%s' "$share_resp" | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p')"
  if [ -z "$hash" ]; then
    echo "Failed to parse share hash for ${name}: ${share_resp}" >&2
    exit 1
  fi

  if [ -n "$entries" ]; then entries="${entries},"; fi
  entries="${entries}{\"name\":\"${name}\",\"url\":\"${FB}/api/public/dl/${hash}\"}"
done

if [ -z "$entries" ]; then
  echo "No artifact files found in ${ARTIFACT_DIR}"
  exit 0
fi

# 将下载 URL 回传至控制台（一个小型 JSON 载荷）.
curl -fsS -X POST "${BACKEND_URL}/upload" \
  -H "X-Build-Token: ${BUILD_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"files\":[${entries}]}"
