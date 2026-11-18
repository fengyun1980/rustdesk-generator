#!/bin/bash
set -euo pipefail

BACKEND_URL="${1:?backend-url required}"
CONFIG_URL="${BACKEND_URL}/config"
BUILD_TOKEN="${2:?build-token required}"
OUTPUT_DIR="${3:?output-dir required}"

mkdir -p "${OUTPUT_DIR}/logos"

CONFIG_RESPONSE=$(curl -fsS -H "X-Build-Token: ${BUILD_TOKEN}" "${CONFIG_URL}" | tr -d '\r')

CUSTOM_TXT=$(printf '%s' "${CONFIG_RESPONSE}" | python3 -c "import json,sys; sys.stdout.write(json.load(sys.stdin).get('customTxt',''))" | tr -d '\r')
if [ -n "${CUSTOM_TXT}" ]; then
  printf '%s' "${CUSTOM_TXT}" > "${OUTPUT_DIR}/custom.txt"
  echo "custom.txt written (${#CUSTOM_TXT} bytes)"
else
  echo "No custom.txt content received"
fi

PUBLIC_KEY=$(printf '%s' "${CONFIG_RESPONSE}" | python3 -c "import json,sys; sys.stdout.write(json.load(sys.stdin).get('publicKey',''))" | tr -d '\r')
if [ -n "${PUBLIC_KEY}" ]; then
  printf '%s' "${PUBLIC_KEY}" > "${OUTPUT_DIR}/public-key.txt"
  echo "Public key: ${PUBLIC_KEY}"
else
  echo "No public key received"
fi

LOGOS=$(printf '%s' "${CONFIG_RESPONSE}" | python3 -c "import json,sys; sys.stdout.write('\n'.join(json.load(sys.stdin).get('logos',[])))" | tr -d '\r')
if [ -n "${LOGOS}" ]; then
  while IFS= read -r LOGO; do
    [ -z "${LOGO}" ] && continue
    LOGO=$(printf '%s' "${LOGO}" | tr -d '\r')
    LOGO_ENC=$(python3 -c "import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1]))" "${LOGO}")
    curl -fsS -H "X-Build-Token: ${BUILD_TOKEN}" -o "${OUTPUT_DIR}/logos/${LOGO}" "${BACKEND_URL}/logo/${LOGO_ENC}"
    echo "Downloaded logo: ${LOGO}"
  done <<< "${LOGOS}"
else
  echo "No logos to download"
fi
