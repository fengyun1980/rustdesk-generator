#!/bin/bash
set -euo pipefail

# 从 GitHub Release 恢复模板，用于 template-patch 构建。
# 计算 git tree 哈希值（在注入公钥之后），确定 Release 标签，
# 并在模板可用时下载模板文件。
# 用法：restore-template.sh <version> <arch> <output-dir> [<template-types>]
# 参数：
# version: RustDesk 版本号（例如 1.5.1）
# arch: 架构（例如 x86_64、aarch64）
# output-dir: 模板文件的下载目标目录
# template-types: 以空格分隔的模板类型列表（默认："build"）
# 退出码：
# 0 - 模板恢复成功
# 1 - 未找到模板（需执行完整构建）

VERSION="${1:?version required}"
ARCH="${2:?arch required}"
OUTPUT_DIR="${3:?output-dir required}"
TEMPLATE_TYPES="${4:-build}"

TREE_HASH=$(git add -A && git write-tree)
TAG="template-${VERSION}-${TREE_HASH:0:7}"

echo "Tree hash: ${TREE_HASH}"
echo "Template tag: ${TAG}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "tree-hash=${TREE_HASH}" >> "${GITHUB_OUTPUT}"
  echo "template-tag=${TAG}" >> "${GITHUB_OUTPUT}"
fi

mkdir -p "${OUTPUT_DIR}"

ALL_FOUND=true
for TYPE in ${TEMPLATE_TYPES}; do
  ASSET_PATTERN="rustdesk-template-${TYPE}-${ARCH}*"
  if gh release download "${TAG}" -R "${GITHUB_REPOSITORY}" -D "${OUTPUT_DIR}" -p "${ASSET_PATTERN}" --clobber 2>/dev/null; then
    echo "Restored: rustdesk-template-${TYPE}-${ARCH}"
  else
    echo "Not found: rustdesk-template-${TYPE}-${ARCH}"
    ALL_FOUND=false
  fi
done

if [ "${ALL_FOUND}" = "true" ]; then
  echo "All templates restored successfully from ${TAG}"
  BUILD_ARCHIVE="${OUTPUT_DIR}/rustdesk-template-build-${ARCH}.tar.gz"
  if [ -f "${BUILD_ARCHIVE}" ]; then
    tar xzf "${BUILD_ARCHIVE}" -C .
    echo "Extracted build directory"
  fi
  exit 0
else
  echo "Some templates not found in ${TAG}, will need full build"
  rm -rf "${OUTPUT_DIR}"
  exit 1
fi
