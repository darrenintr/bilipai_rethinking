#!/bin/bash
# iOS 设备上通过 a-Shell 或 iSH 运行的安装脚本
# 需要先安装 gh CLI: pkg install gh (Termux) 或 apk add github-cli (iSH)

set -euo pipefail

REPO="darrenintr/pure-bilibili-rethinking"
APP_NAME="Paladala"

echo "🔍 获取最新 release..."

# 使用 GitHub API 获取最新 prerelease（无需认证）
LATEST_JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=1")
TAG=$(echo "$LATEST_JSON" | grep -m1 '"tag_name"' | cut -d'"' -f4)
DOWNLOAD_URL=$(echo "$LATEST_JSON" | grep -o "https://github.com/.*/releases/download/.*${APP_NAME}-unsigned-.*\.ipa" | head -n1)

if [ -z "$TAG" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo "❌ 无法获取最新 release"
    exit 1
fi

echo "📦 最新版本: $TAG"
echo "🔗 下载链接: $DOWNLOAD_URL"

# 下载到 iOS Files app 可访问的位置
DOWNLOAD_DIR="${HOME}/Documents/IPA"
mkdir -p "$DOWNLOAD_DIR"

IPA_FILE="${APP_NAME}-unsigned-${TAG}.ipa"
IPA_PATH="${DOWNLOAD_DIR}/${IPA_FILE}"

echo "⬇️  下载中..."
curl -fL -o "$IPA_PATH" "$DOWNLOAD_URL"

if [ ! -f "$IPA_PATH" ]; then
    echo "❌ 下载失败"
    exit 1
fi

echo "✅ 下载完成: $IPA_PATH"
echo ""
echo "📲 请在 Files app 中找到该文件并分享到 SideStore 安装"
echo "   路径: Documents/IPA/${IPA_FILE}"

# 尝试打开 SideStore（如果支持 URL scheme）
open "sidestore://" 2>/dev/null || true
