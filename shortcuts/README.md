# Paladala 一键更新快捷指令

## 概述

Paladala 使用 Apple Shortcuts 实现一键更新功能。用户只需在首次使用时安装快捷指令，之后每次检查更新时，App 会自动调用快捷指令完成 IPA 下载和安装。

## 工作流程

```
用户点击"检查更新"
    ↓
App 检测是否已安装快捷指令
    ↓ 否
显示安装引导界面
    ↓ 用户安装快捷指令
用户点击"我已安装"
    ↓ 是
App 检查 GitHub Releases
    ↓ 发现新版本
用户点击"一键安装"
    ↓
App 调用快捷指令（传递 IPA URL）
    ↓
快捷指令下载 IPA
    ↓
快捷指令调用 SideStore 安装
    ↓
完成更新
```

## 快捷指令构建步骤

### 方法 1: 手动创建（推荐用于开发和测试）

1. 打开 iOS 快捷指令 App
2. 点击右上角 "+" 创建新快捷指令
3. 添加以下操作：

```
操作 1: 获取快捷指令输入
   - 类型: URL

操作 2: 下载 URL
   - URL: [快捷指令输入]
   - 显示下载进度: 开启

操作 3: 存储文件
   - 服务: iCloud Drive
   - 路径: /Shortcuts/Paladala/
   - 文件名: Paladala-latest.ipa
   - 覆盖现有文件: 开启

操作 4: 获取文件路径
   - 输入: [已保存的文件]

操作 5: URL 编码
   - 输入: [文件路径]
   - 模式: 百分号编码

操作 6: 打开 URL
   - URL: sidestore://install?url=[URL编码的文件路径]
   - （如果 SideStore 不可用，可选：显示通知提示用户手动安装）
```

4. 将快捷指令重命名为: **安装Paladala** (必须完全匹配，包括大小写)
5. 在快捷指令设置中：
   - 允许共享表单输入
   - 允许从其他 App 运行
   - 接受类型: URL

### 方法 2: 使用 .shortcut 文件（推荐用于分发）

我们会在此目录中提供预构建的 `安装Paladala.shortcut` 文件。用户可以：

1. 在 Safari 中打开 GitHub 上的 shortcut 文件链接
2. iOS 会自动打开快捷指令 App
3. 点击"添加快捷指令"

文件位置: `https://github.com/darrenintr/pure-bilibili-rethinking/raw/main/shortcuts/安装Paladala.shortcut`

## 快捷指令调用方式

App 使用 x-callback-url 协议调用快捷指令：

```swift
shortcuts://x-callback-url/run-shortcut?name=安装Paladala&input=<IPA_URL>
```

参数说明：
- `name`: 快捷指令名称（必须是"安装Paladala"）
- `input`: 要下载的 IPA 文件的直接下载 URL

## 替代安装方式

如果 SideStore 不可用，快捷指令可以使用以下替代方式：

### AltStore
```
altstore://install?url=[file_path]
```

### Feather
```
feather://install?url=[file_path]
```

### 手动安装
保存 IPA 到 Files App，让用户通过分享菜单手动选择安装器。

## 故障排除

### 快捷指令无法调用
- 检查快捷指令名称是否完全匹配（包括大小写）
- 确认快捷指令设置中允许"从其他 App 运行"
- 检查 iOS 快捷指令隐私设置

### 下载失败
- 检查网络连接
- 验证 GitHub Release 中的 IPA 文件是否存在
- 查看快捷指令的执行日志

### SideStore 无法安装
- 确认已安装并启动 SideStore
- 检查 SideStore 是否有安装权限
- 尝试手动在 Files App 中打开 IPA

## 技术细节

### UserDefaults 键
- `hasInstalledPaladalaShortcut`: 存储用户是否已安装快捷指令

### 相关代码文件
- `ShortcutManager.swift`: 管理快捷指令状态和调用
- `UpdateManager.swift`: 处理更新检查和调用快捷指令
- `AboutView.swift`: 显示更新 UI 和快捷指令安装引导

### API 端点
```
GitHub Releases API:
https://api.github.com/repos/darrenintr/pure-bilibili-rethinking/releases?per_page=1

返回的 IPA asset 示例:
{
  "name": "Paladala-unsigned.ipa",
  "browser_download_url": "https://github.com/.../Paladala-unsigned.ipa"
}
```

## 未来改进

- [ ] 自动检测 SideStore/AltStore/Feather 并使用对应的 URL scheme
- [ ] 支持断点续传（下载大文件时）
- [ ] 添加下载缓存（避免重复下载相同版本）
- [ ] 提供快捷指令版本检测和自动更新
- [ ] 支持多语言快捷指令（中英文版本）
