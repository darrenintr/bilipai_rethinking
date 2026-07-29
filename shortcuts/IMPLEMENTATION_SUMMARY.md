# Apple Shortcuts 一键更新实现总结

## 实现概述

已完成将 Paladala 的一键更新功能迁移到使用 Apple Shortcuts 的实现。用户首次使用时安装快捷指令，之后每次检查更新时，App 会自动调用快捷指令完成 IPA 下载和 SideStore 安装。

## 已实现的功能

### 1. ShortcutManager.swift（新文件）
核心管理器，负责：
- ✅ 追踪快捷指令安装状态（UserDefaults 持久化）
- ✅ 显示/隐藏首次安装引导界面
- ✅ 通过 x-callback-url 调用快捷指令
- ✅ 打开 Shortcuts App 或 GitHub 上的快捷指令文件

### 2. ShortcutInstallPromptView（在 ShortcutManager.swift 中）
首次使用引导界面：
- ✅ 符合 Street Redesign 风格的全屏引导界面
- ✅ 三步安装说明（下载→添加→确认）
- ✅ "下载快捷指令" 按钮（主操作）
- ✅ "我已安装" 按钮（完成设置）
- ✅ "暂时跳过" 按钮（延迟设置）

### 3. UpdateManager.swift（已修改）
更新逻辑调整：
- ✅ 检查快捷指令安装状态
- ✅ 如果未安装，显示引导界面
- ✅ 调用快捷指令而不是直接下载
- ✅ 将 IPA URL 传递给快捷指令
- ✅ 保留下载进度追踪（供未来使用）

### 4. AboutView.swift（已修改）
UI 集成：
- ✅ 添加 `@StateObject private var shortcutManager`
- ✅ 检查更新前验证快捷指令安装状态
- ✅ 显示快捷指令安装引导 sheet
- ✅ 更新状态消息文案（"已调用快捷指令..."）
- ✅ 添加"设置快捷指令"按钮（错误恢复）
- ✅ 按钮文案改为"一键安装"

### 5. 文档和脚本
- ✅ `shortcuts/README.md` - 完整的技术文档
- ✅ `shortcuts/build-shortcut.sh` - 快捷指令构建指南
- ✅ `shortcuts/TEST_CHECKLIST.md` - 完整的测试清单

## 工作流程

```
用户首次打开「关于」页面并点击「检查更新」
    ↓
ShortcutManager 检测到未安装快捷指令
    ↓
显示 ShortcutInstallPromptView 引导界面
    ↓
用户点击「下载快捷指令」
    ↓
打开 Safari/Shortcuts App 安装快捷指令
    ↓
用户点击「我已安装」
    ↓
ShortcutManager 标记已安装并持久化
    ↓
用户再次点击「检查更新」
    ↓
UpdateManager 检查 GitHub Releases API
    ↓
发现新版本，显示「一键安装」按钮
    ↓
用户点击「一键安装」
    ↓
UpdateManager 调用 ShortcutManager.installIPA(from: ipaURL)
    ↓
ShortcutManager 构造 x-callback-url 并打开
    ↓
Shortcuts App 运行「安装Paladala」快捷指令
    ↓
快捷指令下载 IPA → 保存到 iCloud Drive → 调用 SideStore
    ↓
SideStore 安装 IPA
    ↓
完成更新
```

## 技术细节

### URL Scheme
```swift
// App → Shortcuts
shortcuts://x-callback-url/run-shortcut?name=安装Paladala&input=<IPA_URL>

// Shortcuts → SideStore
sidestore://install?url=<file:///.../Paladala-latest.ipa>
```

### 快捷指令操作流程
1. 接收 IPA URL 作为输入
2. 下载 IPA 文件（显示进度）
3. 保存到 iCloud Drive/Shortcuts/Paladala/
4. URL 编码文件路径
5. 调用 SideStore URL scheme
6. （可选）失败时显示通知

### 持久化
```swift
UserDefaults.standard.bool(forKey: "hasInstalledPaladalaShortcut")
```

## 待完成的任务

### 必须在 iOS 设备上完成：
1. **创建快捷指令**
   - 在 Shortcuts App 中按照 `build-shortcut.sh` 的步骤手动创建
   - 命名为「安装Paladala」（必须完全匹配）
   - 配置允许从其他 App 运行

2. **导出快捷指令文件**
   - 长按快捷指令 → 分享 → 存储到文件
   - 保存为 `shortcuts/安装Paladala.shortcut`

3. **测试集成**
   - 按照 `TEST_CHECKLIST.md` 逐项测试
   - 验证完整的用户流程

### 代码集成：
1. **添加 ShortcutManager.swift 到 Xcode 项目**
   - 打开 Xcode
   - 将 `ShortcutManager.swift` 添加到项目
   - 确认 Target Membership 正确

2. **编译和测试**
   - 编译项目检查错误
   - 在真机上运行测试

### 可选改进：
- 自动检测 SideStore/AltStore/Feather
- 支持断点续传
- 添加下载缓存
- 快捷指令版本检测和更新提示

## 优势

相比之前的实现（直接下载 + 分享菜单）：

1. **更流畅的用户体验**
   - 真正的一键操作，无需手动选择 SideStore
   - 下载和安装完全自动化

2. **更好的可维护性**
   - 快捷指令可以独立更新
   - 用户可以自定义安装逻辑

3. **更高的灵活性**
   - 支持多种侧载工具（SideStore/AltStore/Feather）
   - 可以添加更多自动化步骤

4. **符合 iOS 设计理念**
   - 利用系统原生的 Shortcuts 功能
   - 用户有完全的控制权

## 文件清单

### 新增文件
```
ios/Paladala/Paladala/ShortcutManager.swift          # 核心管理器 + 引导 UI
shortcuts/README.md                                   # 技术文档
shortcuts/build-shortcut.sh                           # 构建指南
shortcuts/TEST_CHECKLIST.md                           # 测试清单
shortcuts/IMPLEMENTATION_SUMMARY.md                   # 本文档
```

### 修改文件
```
ios/Paladala/Paladala/UpdateManager.swift            # 调用快捷指令
ios/Paladala/Paladala/AboutView.swift                # UI 集成
```

### 待添加文件
```
shortcuts/安装Paladala.shortcut                       # 快捷指令文件（需在 iOS 上创建）
```

## 下一步

1. 在 macOS/iOS 设备上：
   - 打开 Xcode 项目
   - 添加 `ShortcutManager.swift` 到项目
   - 编译测试

2. 在 iOS 设备上：
   - 按照 `build-shortcut.sh` 创建快捷指令
   - 导出 `.shortcut` 文件
   - 运行完整测试流程

3. 提交代码：
   ```bash
   git add ios/Paladala/Paladala/ShortcutManager.swift
   git add ios/Paladala/Paladala/UpdateManager.swift
   git add ios/Paladala/Paladala/AboutView.swift
   git add shortcuts/
   git commit -m "feat(ios): implement one-tap update with Apple Shortcuts"
   git push
   ```

## 相关资源

- [Apple Shortcuts 文档](https://support.apple.com/guide/shortcuts/welcome/ios)
- [x-callback-url 规范](http://x-callback-url.com/)
- [SideStore URL Scheme](https://docs.sidestore.io/)
