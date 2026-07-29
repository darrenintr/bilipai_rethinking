#!/bin/bash
#
# 生成可用的 Apple Shortcuts URL
# 这个脚本会生成一个 iCloud 分享链接格式的 URL
#

set -e

echo "=== 创建 Paladala 安装快捷指令 ==="
echo ""
echo "由于 Apple Shortcuts 的限制，最简单的方式是："
echo ""
echo "方法 1: 使用 Shortcuts 链接（推荐）"
echo "----------------------------------------"
echo ""
echo "在 iOS 设备上访问以下 URL："
echo ""
echo "https://www.icloud.com/shortcuts/[YOUR_SHORTCUT_ID]"
echo ""
echo "或者使用下面的快捷指令创建助手："
echo ""

# 生成一个简化的快捷指令定义
cat > /tmp/paladala-shortcut.json <<'EOF'
{
  "name": "安装Paladala",
  "description": "自动下载并安装 Paladala IPA 到 SideStore",
  "actions": [
    {
      "type": "GetShortcutInput",
      "parameters": {
        "Type": "URL"
      }
    },
    {
      "type": "DownloadURL",
      "parameters": {
        "URL": "{{ShortcutInput}}",
        "ShowProgress": true
      }
    },
    {
      "type": "SaveFile",
      "parameters": {
        "Service": "iCloud Drive",
        "DestinationPath": "Shortcuts/Paladala/",
        "Filename": "Paladala-latest.ipa",
        "Overwrite": true,
        "CreateIntermediateDirectories": true
      }
    },
    {
      "type": "GetFile",
      "parameters": {}
    },
    {
      "type": "URLEncode",
      "parameters": {
        "Text": "{{File}}",
        "Mode": "PercentEncoding"
      }
    },
    {
      "type": "OpenURL",
      "parameters": {
        "URL": "sidestore://install?url={{URLEncodedText}}"
      }
    }
  ],
  "settings": {
    "allowedInShareSheet": true,
    "acceptedTypes": ["URL"],
    "canRunInApp": true,
    "canRunFromOtherApps": true
  }
}
EOF

echo "快捷指令定义已生成: /tmp/paladala-shortcut.json"
echo ""
echo "方法 2: 手动创建（最可靠）"
echo "----------------------------------------"
echo ""
echo "请按照以下步骤在 iOS 设备上创建："
echo ""
echo "1. 打开快捷指令 App"
echo "2. 点击 '+' 创建新快捷指令"
echo "3. 搜索并添加以下操作："
echo ""
echo "   [获取快捷指令输入]"
echo "     • 类型: URL"
echo ""
echo "   [下载 URL]"
echo "     • URL: 快捷指令输入"
echo "     • 显示下载进度: 开启"
echo ""
echo "   [保存文件]"
echo "     • 服务: iCloud Drive"
echo "     • 目标路径: Shortcuts/Paladala/"
echo "     • 文件名: Paladala-latest.ipa"
echo "     • 覆盖: 开启"
echo ""
echo "   [获取文件]"
echo "     （使用上一步的文件）"
echo ""
echo "   [URL 编码]"
echo "     • 文本: 文件"
echo "     • 模式: 百分号编码"
echo ""
echo "   [打开 URL]"
echo "     • URL: sidestore://install?url="
echo "     • 在末尾添加变量: URL 编码的文本"
echo ""
echo "4. 点击右上角设置图标"
echo "5. 重命名为: 安装Paladala"
echo "6. 开启以下选项:"
echo "   • 在共享表单中显示"
echo "   • 接受类型: URL"
echo "   • 允许从其他 App 运行"
echo ""
echo "方法 3: 使用快捷指令库链接"
echo "----------------------------------------"
echo ""
echo "你可以创建一个快捷指令库链接供用户一键添加："
echo ""
echo "1. 创建好快捷指令后"
echo "2. 长按快捷指令"
echo "3. 选择'分享'"
echo "4. 选择'复制 iCloud 链接'"
echo "5. 将链接添加到 README 或 App 内"
echo ""
echo "然后在 ShortcutManager.swift 中更新 openShortcutsApp() 函数："
echo ""
echo "  let shortcutURL = URL(string: \"YOUR_ICLOUD_SHORTCUT_LINK\")"
echo ""
echo "完成！"
