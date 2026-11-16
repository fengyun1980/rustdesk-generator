#!/bin/bash
set -euo pipefail

# Upload build artifacts to the console backend.
# Usage: upload-artifacts.sh <backend-url> <build-token> <artifact-dir> [status]
# Arguments:
#   backend-url:  Backend URL (base path for upload endpoint)
#   build-token: Token authenticating the upload request
#   artifact-dir: Directory containing build artifacts to upload
#   status:       Build status to report (default: completed)
#
# Tries this repo's backend first (/callback with a status field), then falls
# back to the rustdesk-console endpoint (/upload) when /callback is absent.

BACKEND_URL="${1:?backend-url required}"
BUILD_TOKEN="${2:?build-token required}"
ARTIFACT_DIR="${3:?artifact-dir required}"
STATUS="${4:-completed}"
BACKEND_URL="${BACKEND_URL%/}"

FILES_ARGS=()
for f in "$ARTIFACT_DIR"/*; do
  [ -f "$f" ] && FILES_ARGS+=(-F "files=@$f")
done

if [ "${#FILES_ARGS[@]}" -eq 0 ]; then
  echo "No artifact files found in $ARTIFACT_DIR"
  exit 0
fi

RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT

send() { # <path> <form-args...>
  local path="$1"
  shift
  curl -sS -o "${RESPONSE_FILE}" -w '%{http_code}' \
    --connect-timeout 15 --max-time 600 \
    -X POST "${BACKEND_URL}${path}" \
    -H "X-Callback-Token: ${BUILD_TOKEN}" \
    -H "X-Build-Token: ${BUILD_TOKEN}" \
    "$@" || echo '000'
}

# This repo's backend: /callback with status.
for attempt in 1 2 3; do
  CODE="$(send "/callback" -F "status=${STATUS}" "${FILES_ARGS[@]}")"
  case "${CODE}" in
    2*) echo "Artifacts uploaded to /callback (HTTP ${CODE})"; exit 0 ;;
    404|405) break ;;
  esac
  echo "Upload attempt ${attempt}/3 to /callback failed (HTTP ${CODE})" >&2
  sleep $((attempt * 3))
done

# rustdesk-console: /upload without a status field.
for attempt in 1 2 3; do
  CODE="$(send "/upload" "${FILES_ARGS[@]}")"
  case "${CODE}" in
    2*) echo "Artifacts uploaded to /upload (HTTP ${CODE})"; exit 0 ;;
  esac
  echo "Upload attempt ${attempt}/3 to /upload failed (HTTP ${CODE})" >&2
  sleep $((attempt * 3))
done

echo "ERROR: failed to upload artifacts" >&2
cat "${RESPONSE_FILE}" >&2 || true
exit 1
