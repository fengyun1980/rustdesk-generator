#!/bin/bash
set -euo pipefail

# Fetch custom client configuration from the console API.
#
# Usage: fetch-custom-config.sh <backend-url> <build-token> <output-dir>
# Outputs:
#   <output-dir>/custom.txt      - signed custom.txt content
#   <output-dir>/public-key.txt  - base64 public key for sed replacement
#   <output-dir>/app-name.txt    - app-name extracted from custom.txt (if set)
#   <output-dir>/logos/          - downloaded logo files
#
# The JSON is accepted in both shapes:
#   snake_case (this repo's backend): custom_txt / public_key / logos
#   camelCase  (rustdesk-console):    customTxt / publicKey  / logos
# and both token headers are sent, because this backend authenticates with
# X-Callback-Token while rustdesk-console uses x-build-token.

BACKEND_URL="${1:?backend-url required}"
BUILD_TOKEN="${2:?build-token required}"
OUTPUT_DIR="${3:?output-dir required}"
BACKEND_URL="${BACKEND_URL%/}"

mkdir -p "${OUTPUT_DIR}/logos"

AUTH=(
  -H "X-Callback-Token: ${BUILD_TOKEN}"
  -H "X-Build-Token: ${BUILD_TOKEN}"
)

fetch_url() { # <url> <output-file>
  local url="$1" out="$2" attempt
  for attempt in 1 2 3; do
    if curl -fsS --connect-timeout 15 --max-time 120 \
      "${AUTH[@]}" -o "${out}" "${url}"; then
      return 0
    fi
    echo "retry ${attempt}/3: ${url}" >&2
    sleep $((attempt * 2))
  done
  return 1
}

CONFIG_JSON="${OUTPUT_DIR}/config.json"
fetch_url "${BACKEND_URL}/config" "${CONFIG_JSON}"

python3 - "${CONFIG_JSON}" "${OUTPUT_DIR}" <<'PY'
import base64
import json
import os
import sys

config_path, out = sys.argv[1], sys.argv[2]
with open(config_path, encoding="utf-8") as f:
    config = json.load(f)


def pick(*keys):
    for key in keys:
        value = config.get(key)
        if value:
            return value
    return ""


custom_txt = pick("custom_txt", "customTxt")
public_key = pick("public_key", "publicKey")
logos = config.get("logos") or []

if custom_txt:
    with open(os.path.join(out, "custom.txt"), "w", encoding="utf-8") as f:
        f.write(custom_txt)
    print(f"custom.txt written ({len(custom_txt)} bytes)")

    # custom.txt is base64(ed25519 signature || signed JSON). Extracting the
    # app-name lets the build steps brand executables, installers and desktop
    # entries as well as the in-app strings.
    try:
        raw = base64.b64decode(custom_txt)
        payload = json.loads(raw[64:].decode("utf-8"))
        app_name = str(payload.get("app-name") or "").strip()
        if app_name:
            with open(os.path.join(out, "app-name.txt"), "w", encoding="utf-8") as f:
                f.write(app_name)
            print(f"app-name: {app_name}")
    except Exception as exc:  # malformed config must not break the build
        print(f"warning: cannot read app-name from custom.txt: {exc}")
else:
    print("No custom.txt content received")

if public_key:
    with open(os.path.join(out, "public-key.txt"), "w", encoding="utf-8") as f:
        f.write(public_key)
    print(f"Public key: {public_key}")
else:
    print("No public key received")

# Logos are either inline base64 in a dict or a list of names to download.
download = []
if isinstance(logos, dict):
    for name, value in logos.items():
        if not value or not isinstance(value, str):
            download.append(str(name))
            continue
        if value.startswith("data:"):
            value = value.split(",", 1)[1]
        try:
            data = base64.b64decode(value)
        except Exception:
            download.append(str(name))
            continue
        with open(os.path.join(out, "logos", str(name)), "wb") as f:
            f.write(data)
        print(f"logo embedded: {name}")
elif isinstance(logos, list):
    download = [str(name) for name in logos if name]

with open(os.path.join(out, "logos.txt"), "w", encoding="utf-8") as f:
    f.write("".join(f"{name}\n" for name in download))
PY

while IFS= read -r LOGO || [ -n "${LOGO}" ]; do
  [ -n "${LOGO}" ] || continue
  LOGO_NAME="$(basename "${LOGO}")"
  if fetch_url "${BACKEND_URL}/logo/${LOGO_NAME}" "${OUTPUT_DIR}/logos/${LOGO_NAME}"; then
    echo "Downloaded logo: ${LOGO_NAME}"
  else
    echo "WARNING: failed to download logo ${LOGO_NAME}" >&2
  fi
done < "${OUTPUT_DIR}/logos.txt"

# Mark the build as running as early as possible. Best effort: the upstream
# console has no /callback endpoint and simply ignores this.
curl -fsS -X POST "${BACKEND_URL}/callback" \
  "${AUTH[@]}" \
  -F "status=building" >/dev/null 2>&1 || true
