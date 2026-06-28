import { Metric, FeatureCard } from "./types";

export const PERFORMANCE_METRICS: Metric[] = [
  {
    label: "App Bundle Size",
    paladalaValue: "~14 MB",
    officialValue: "~340 MB",
    improvement: "24x Smaller",
    unit: "MB",
  },
  {
    label: "Memory Footprint",
    paladalaValue: "~34 MB",
    officialValue: "~520 MB",
    improvement: "15x Lower",
    unit: "MB",
  },
  {
    label: "Cold Boot Startup",
    paladalaValue: "~0.1s",
    officialValue: "~2.0s",
    improvement: "20x Faster",
    unit: "Seconds",
  },
];

export const FEATURES_LIST: FeatureCard[] = [
  {
    title: "Local HLS Proxy",
    description:
      "On-device DASH-to-HLS proxy server converts Bilibili streams on-the-fly. Zero external dependencies — pure Foundation and GCDHTTPServer.",
    badge: "Network",
    iconName: "Radio",
  },
  {
    title: "Dual Design Language",
    description:
      "Switch between Material 3 and Liquid Glass aesthetics. Glass surfaces use ultraThinMaterial with brand-tinted highlights — no iOS 26 required.",
    badge: "Design",
    iconName: "Palette",
  },
  {
    title: "Mini Player Overlay",
    description:
      "Persistent bottom bar keeps video playing as you browse. Managed via MiniPlayerStore with full AVPlayer lifecycle control.",
    badge: "UX",
    iconName: "PictureInPicture",
  },
  {
    title: "Pure Swift Networking",
    description:
      "2,700+ lines of Bilibili API coverage in pure URLSession — feed, comments, live rooms, search, auth, history, likes. No WKWebView.",
    badge: "API",
    iconName: "Globe",
  },
  {
    title: "Apple Watch Companion",
    description:
      "WatchSession reports playback progress every 30 seconds. Native watchOS integration for remote control.",
    badge: "Ecosystem",
    iconName: "Watch",
  },
  {
    title: "Diagnostic Logger",
    description:
      "In-app diagnostic logging across playback, proxy, auth, network, and fullscreen categories. Viewable and shareable from Settings.",
    badge: "Infra",
    iconName: "Bug",
  },
];

export const SAMPLE_DANMAKUS: string[] = [
  "66666666! 純 Swift 寫嘅 Bilibili 客戶端!",
  "終於唔使 WebView 啦 🎉",
  "本地 HLS Proxy 真係快到飛起",
  "Liquid Glass 效果靚到爆",
  "13,784 行 Swift 代碼，零依賴",
  "Mini Player 好好用，切 page 都唔斷",
  "Apple Watch 都支援，太強了",
  "Material 3 同 Liquid Glass 隨時切換",
  "Pure SwiftUI + AVKit 播放器 🔥",
  "Diagnostic Logger 幫我 debug 咗好多嘢",
  "開源精神！感謝作者",
  "Paladala 繼續加油 💪",
];
