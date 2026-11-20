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
DEST_DIR="${FILEBROWSER_DIR%/}/${BUILD_ID}"

# Login: the endpoint returns the JWT as a raw text body.
TOKEN="$(curl -fsS -X POST "${FB}/api/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${FILEBROWSER_USER}\",\"password\":\"${FILEBROWSER_PASS}\"}")"

entries=""
for f in "$ARTIFACT_DIR"/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  remote_path="${DEST_DIR}/${name}"
  size="$(wc -c < "$f" | tr -d ' ')"

  # Create the upload slot (TUS). override=true lets GitHub re-runs overwrite.
  curl -fsS -X POST "${FB}/api/tus${remote_path}?override=true" \
    -H "X-Auth: ${TOKEN}" \
    -H "Upload-Length: ${size}" >/dev/null

  # Stream the file bytes.
  curl -fsS -X PATCH "${FB}/api/tus${remote_path}" \
    -H "X-Auth: ${TOKEN}" \
    -H "Content-Type: application/offset+octet-stream" \
    -H "Upload-Offset: 0" \
    --data-binary "@${f}" >/dev/null

  # Create a public share and derive the direct download URL.
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

# Report download URLs back to the console (a tiny JSON payload).
curl -fsS -X POST "${BACKEND_URL}/upload" \
  -H "X-Build-Token: ${BUILD_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"files\":[${entries}]}"
