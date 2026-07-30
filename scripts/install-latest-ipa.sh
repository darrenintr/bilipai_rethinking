#!/bin/bash
# 一键从 GitHub 拉取最新 IPA 并通过 SideStore 安装

set -euo pipefail

REPO="darrenintr/pure-bilibili-rethinking"  # 替换为你的实际 GitHub repo
APP_NAME="Paladala"
DOWNLOAD_DIR="${HOME}/Downloads/PalaIPA"

echo "🔍 获取最新 release..."

# 使用 gh CLI 获取最新 prerelease 信息
LATEST_RELEASE=$(gh release list --repo "$REPO" --limit 1 | head -n1)
TAG=$(echo "$LATEST_RELEASE" | awk '{print $1}')

if [ -z "$TAG" ]; then
    echo "❌ 无法获取最新 release"
    exit 1
fi

echo "📦 最新版本: $TAG"

# 创建下载目录
mkdir -p "$DOWNLOAD_DIR"

# 下载 IPA 文件
IPA_FILE="${APP_NAME}-unsigned-${TAG}.ipa"
IPA_PATH="${DOWNLOAD_DIR}/${IPA_FILE}"

echo "⬇️  下载 $IPA_FILE..."
gh release download "$TAG" \
    --repo "$REPO" \
    --pattern "${IPA_FILE}" \
    --dir "$DOWNLOAD_DIR" \
    --clobber

if [ ! -f "$IPA_PATH" ]; then
    echo "❌ 下载失败"
    exit 1
fi

echo "✅ 下载完成: $IPA_PATH"

# 方式 1: 使用 SideStore URL scheme（如果 SideStore 支持）
echo "📲 尝试通过 URL scheme 安装..."
open "sidestore://install?url=file://${IPA_PATH}" 2>/dev/null && {
    echo "✅ 已发送到 SideStore"
    exit 0
}

# 方式 2: 打开文件让用户手动分享到 SideStore
echo "📲 打开 IPA 文件，请手动分享到 SideStore..."
open "$IPA_PATH"

echo ""
echo "💡 使用说明："
echo "   1. 在弹出的分享菜单中选择 SideStore"
echo "   2. 或将文件拖到 SideStore 应用窗口"
