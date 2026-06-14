# BiliPai Native (iOS)

专为 Apple 生态打造的第三方 Bilibili 原生客户端。纯净、流畅、回归本质。

---

## 🌟 为什么选择 BiliPai Native？

**BiliPai Native** 不是官方 App 的简单复刻，而是一个基于 SwiftUI 重新设计的原生工具。它去除了所有不必要的社交臃肿功能和广告，只保留最核心的观看体验。

*   **真正的原生体验**：完全使用 Swift 与 SwiftUI 构建，完美适配 iOS 15+ 的毛玻璃效果与系统动效。
*   **懂你的推荐**：直接接入 B 站移动端原生推荐算法，刷到的都是你感兴趣的内容。
*   **极致同步**：扫码登录，个人历史记录、收藏夹、追番列表完美同步。
*   **无广告干扰**：没有任何开屏广告或信息流广告。
*   **专业播放**：原生 HLS 播放器，支持 4K、倍速、系统级画中画 (PiP)。

## 📸 界面预览

<div align="center">
  <img src="docs/images/screenshot_real_1_home.png" width="30%" alt="Home" />
  <img src="docs/images/screenshot_real_2_video.png" width="30%" alt="Video" />
  <img src="docs/images/screenshot_real_3_dynamic.png" width="30%" alt="Dynamic" />
</div>

## 📥 安装指南 (推荐 Sideload)

由于 iOS 系统的封闭性，推荐使用 **SideStore** + **LiveContainer** 的组合，配合 **iLoader** 实现无缝安装与长期使用。

### 1. 准备工作
*   下载并安装 **SideStore** (推荐：支持无线续签)。
*   下载 **LiveContainer** IPA (推荐：突破 3 个 App 限制)。
*   下载本仓库 Release 提供的 **BiliPaiNative.ipa**。

### 2. 安装步骤
1.  **引导 LiveContainer**: 在 SideStore 中点击 `+` 号安装 LiveContainer。
2.  **使用 iLoader (关键)**: 
    *   安装并打开 **iLoader**。
    *   点击 `Add App`，选择下载好的 `BiliPaiNative.ipa`。
    *   iLoader 会自动将应用配置并引导至 LiveContainer 容器中。
3.  **启动**: 打开 LiveContainer，在列表中找到 **BiliPai Native** 即可启动。

> [!TIP]
> 这种安装方式不需要越狱，且在 SideStore 的自动续签下可以一直使用。

## 🛠️ 核心功能一览

| 功能 | 描述 |
| :--- | :--- |
| **视频播放** | 支持高码率 4K/1080P，进度条预览，播放进度自动同步至账号。 |
| **首页推荐** | 与手机版一致的个性化视频流，支持下拉刷新、无限加载。 |
| **动态列表** | 关注的 UP 主视频更新实时推送，支持图文内容查看。 |
| **搜索建议** | 毫秒级联想搜索，实时热门搜索榜单。 |
| **个人管理** | 支持稍后再看、历史记录、收藏夹管理、黑名单同步。 |

## ⚠️ 免责声明

1. 本项目仅供学习交流 iOS 开发技术，请勿用于商业用途。
2. 视频内容版权归 Bilibili 官方及 UP 主所有。
3. 本应用不收集任何隐私数据，账号信息仅存储在您设备的 Keychain 安全区域。

---

<div align="center">
  <sub>( ゜- ゜)つロ 干杯~</sub>
</div>
