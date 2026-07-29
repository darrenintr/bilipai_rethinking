# 一键安装快捷指令

## 直接安装链接（推荐）

由于 Apple Shortcuts 的格式限制，最简单的方式是点击下面的链接直接添加：

### 🔗 快捷指令安装链接

**方案 1: 使用预构建的快捷指令（需要先上传）**

```
https://www.icloud.com/shortcuts/[ID_HERE]
```

> 注意：需要先在 iOS 设备上创建快捷指令，然后分享获取 iCloud 链接

---

**方案 2: 使用 Shortcuts URL Scheme 半自动创建**

在 Safari 中打开以下链接会跳转到快捷指令 App：

```
shortcuts://create-shortcut
```

然后按照提示手动添加操作。

---

## 📱 手动创建步骤（最可靠）

如果上述链接不可用，请按照以下步骤手动创建：

### 第 1 步：创建新快捷指令

1. 打开 **快捷指令** App
2. 点击右上角 **+** 号
3. 点击 **添加操作**

### 第 2 步：添加操作

按顺序添加以下 6 个操作：

#### 操作 1️⃣：获取快捷指令输入
- 搜索：`获取快捷指令输入`
- 点击添加

#### 操作 2️⃣：下载 URL
- 搜索：`下载 URL` 或 `Download URL`
- 点击 **URL** 字段
- 选择 **快捷指令输入** 变量
- 开启 **显示下载进度**

#### 操作 3️⃣：保存文件
- 搜索：`保存文件` 或 `Save File`
- 点击 **服务**，选择 **iCloud Drive**（或 **询问每次运行时**）
- 点击 **目标路径**，输入：`Shortcuts/Paladala/`
- 点击 **询问文件名位置**，关闭
- 文件名输入：`Paladala-latest.ipa`
- 开启 **覆盖现有文件**

#### 操作 4️⃣：获取文件
- 搜索：`获取文件` 或 `Get File`
- 应该自动使用上一步保存的文件

#### 操作 5️⃣：URL 编码
- 搜索：`URL 编码` 或 `URL Encode`
- 点击 **文本** 字段
- 选择 **文件** 变量
- 编码模式：**百分号编码**

#### 操作 6️⃣：打开 URL
- 搜索：`打开 URL` 或 `Open URL`
- 在 URL 字段中输入：`sidestore://install?url=`
- **不要按回车！** 点击字段末尾，然后点击 **变量** 按钮
- 选择 **URL 编码的文本** 变量
- 最终 URL 应该显示：`sidestore://install?url=[URL编码的文本]`

### 第 3 步：配置快捷指令

1. 点击右上角 **设置图标** （···）
2. 在顶部重命名为：**安装Paladala**
   - ⚠️ **必须完全匹配！** 包括大小写
3. 向下滚动，配置以下选项：
   - ✅ **在共享表单中显示**
   - ✅ **接受类型** → 点击添加 → 选择 **URL**
   - ✅ **允许从其他 App 运行** （如果有此选项）
4. 点击 **完成**

### 第 4 步：测试

1. 在快捷指令列表中，点击刚创建的 **安装Paladala**
2. 输入测试 URL：
   ```
   https://github.com/darrenintr/pure-bilibili-rethinking/releases/download/v0.5.1/Paladala-unsigned.ipa
   ```
3. 点击 **运行**
4. 观察是否：
   - ✅ 显示下载进度
   - ✅ 下载完成
   - ✅ 自动跳转到 SideStore
   - ✅ SideStore 显示安装界面

---

## 🔧 替代方案：使用其他侧载工具

如果你使用的不是 SideStore，请修改**操作 6**的 URL：

### AltStore
```
altstore://install?url=[URL编码的文本]
```

### Feather
```
feather://install?url=[URL编码的文本]
```

### 手动安装（最通用）
将操作 6 改为 **显示通知**：
- 标题：`下载完成`
- 正文：`请在 Files App 中找到 Paladala-latest.ipa 并手动安装`

---

## 📤 分享快捷指令

创建完成后，你可以分享给其他用户：

1. 长按 **安装Paladala** 快捷指令
2. 选择 **分享**
3. 选择 **复制 iCloud 链接**
4. 将链接更新到本文档顶部或 `ShortcutManager.swift` 中

---

## ❓ 故障排除

### 快捷指令无法运行
- 检查名称是否为 **安装Paladala**（完全匹配）
- 检查是否允许从其他 App 运行
- 重启快捷指令 App

### 下载失败
- 检查网络连接
- 确认 IPA URL 有效
- 检查 iCloud Drive 存储空间

### SideStore 无法打开
- 确认已安装 SideStore
- 检查 SideStore 是否在后台运行
- 尝试手动在 Files App 中打开 IPA

### 文件保存位置
- iCloud Drive: `iCloud Drive/Shortcuts/Paladala/Paladala-latest.ipa`
- 本地: `我的 iPhone/Shortcuts/Paladala/Paladala-latest.ipa`

---

## 📝 技术细节

### 快捷指令流程
```
输入 IPA URL
    ↓
下载文件（显示进度）
    ↓
保存到 iCloud Drive/Shortcuts/Paladala/
    ↓
获取保存的文件路径
    ↓
URL 编码文件路径
    ↓
调用 sidestore://install?url=[编码后的路径]
    ↓
SideStore 安装 IPA
```

### 调用方式
App 通过 x-callback-url 调用：
```
shortcuts://x-callback-url/run-shortcut?name=安装Paladala&input=<IPA_URL>
```

---

## 🎉 完成

快捷指令创建完成后，在 Paladala App 的「关于」页面点击「我已安装」即可开始使用一键更新功能！
