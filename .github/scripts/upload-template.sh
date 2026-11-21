#!/bin/bash
set -euo pipefail

# 将模板文件上传至 GitHub Release，用于 template-patch 构建。
# 若 Release 不存在则自动创建，然后上传模板文件。
# 用法：upload-template.sh <version> <tree-hash> <files...>
# 参数：
# version: RustDesk 版本号（例如 1.5.1）
# tree-hash: 注入公钥后的 Git tree 哈希值（完整哈希）
# files: 要上传的模板文件

VERSION="${1:?version required}"
TREE_HASH="${2:?tree-hash required}"
shift 2
FILES=("$@")

TAG="template-${VERSION}-${TREE_HASH:0:7}"

if ! gh release view "${TAG}" -R "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
  gh release create "${TAG}" -R "${GITHUB_REPOSITORY}" \
    --title "Templates for ${VERSION} (${TREE_HASH:0:7})" \
    --notes "Auto-generated template build"
  echo "Created Release: ${TAG}"
fi

for FILE in "${FILES[@]}"; do
  if [ -f "${FILE}" ]; then
    gh release upload "${TAG}" -R "${GITHUB_REPOSITORY}" "${FILE}" --clobber
    echo "Uploaded: $(basename "${FILE}")"
  else
    echo "Warning: file not found: ${FILE}"
  fi
done
