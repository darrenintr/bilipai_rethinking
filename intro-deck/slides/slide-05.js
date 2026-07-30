// Slide 05 - 技术架构
// Layered architecture diagram
const { theme, FONT } = require('./theme.js');
const { addPageBadge, addEyebrow, addTitle, addCard, addFooter } = require('./_shared.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();
  slide.background = { color: theme.bg };

  addEyebrow(slide, '04  /  ARCHITECTURE', theme.green);
  addTitle(slide, '技术架构');

  slide.addText('三层结构:UI Layer 一致对外,Repository 隔离数据源,Service Layer 封装跨切面能力.', {
    x: 0.5, y: 1.75, w: 9.0, h: 0.4,
    fontSize: 14, color: theme.secondary, fontFace: FONT.cn,
    align: 'left', valign: 'middle', margin: 0,
  });

  // 3 horizontal layers
  const layers = [
    {
      label: 'UI Layer',
      tag: 'SwiftUI + AVKit + Liquid Glass',
      color: theme.accent,
      bg: theme.pinkSoft,
      items: [
        { t: '5 Tab', d: 'Home / Dynamic / Live / Music / Profile' },
        { t: 'VideoDetail', d: 'AVPlayer 三态 (inline / 浮窗 / 全屏)' },
        { t: 'Onboarding + Login', d: '引导 + 扫码登录 sheet' },
      ],
    },
    {
      label: 'Repository',
      tag: 'PaladalaRepository + ViewModel',
      color: theme.cyan,
      bg: theme.cyanSoft,
      items: [
        { t: 'PaladalaRepository', d: '聚合 API / Download / SponsorBlock' },
        { t: 'ViewModel (LoadState)', d: 'isLoading / error / value 四态机' },
        { t: 'AppRouter', d: 'navigationDestination + deep link' },
      ],
    },
    {
      label: 'Service',
      tag: 'API / Storage / Playback',
      color: theme.violet,
      bg: theme.violetSoft,
      items: [
        { t: 'BilibiliAPIClient', d: '推荐 / 热门 / 搜索 / 详情 / 直播' },
        { t: 'LocalHLSProxyServer', d: '本地 HLS 代理 + DASH/SIDX 重组' },
        { t: 'DownloadManager', d: '离线下载 + 断点续传' },
      ],
    },
  ];

  const layerX = 0.5;
  const layerW = 8.45;
  const layerH = 0.90;
  const layerGap = 0.10;
  const layerY0 = 2.20;

  layers.forEach((L, i) => {
    const y = layerY0 + i * (layerH + layerGap);
    addCard(slide, layerX, y, layerW, layerH, { fill: L.bg, border: L.color, radius: 0.12, borderWidth: 0.5 });

    // Left tag block
    slide.addShape('rect', {
      x: layerX, y, w: 0.10, h: layerH,
      fill: { color: L.color }, line: { color: L.color, width: 0 },
    });
    slide.addText(L.label, {
      x: layerX + 0.25, y: y + 0.10, w: 1.85, h: 0.4,
      fontSize: 14, bold: true, color: L.color, fontFace: FONT.en,
      align: 'left', valign: 'middle', margin: 0,
    });
    slide.addText(L.tag, {
      x: layerX + 0.25, y: y + 0.50, w: 1.85, h: 0.4,
      fontSize: 9, color: theme.secondary, fontFace: FONT.en,
      align: 'left', valign: 'middle', margin: 0, charSpacing: 1,
    });

    // Vertical separator
    slide.addShape('rect', {
      x: layerX + 2.20, y: y + 0.20, w: 0.01, h: layerH - 0.40,
      fill: { color: theme.divider }, line: { color: theme.divider, width: 0 },
    });

    // 3 items
    const itemW = (layerW - 2.40) / 3;
    L.items.forEach((it, j) => {
      const ix = layerX + 2.35 + j * itemW;
      slide.addText(it.t, {
        x: ix, y: y + 0.12, w: itemW - 0.15, h: 0.34,
        fontSize: 12, bold: true, color: theme.primary, fontFace: FONT.cn,
        align: 'left', valign: 'middle', margin: 0,
      });
      slide.addText(it.d, {
        x: ix, y: y + 0.46, w: itemW - 0.15, h: 0.40,
        fontSize: 10, color: theme.secondary, fontFace: FONT.cn,
        align: 'left', valign: 'top', margin: 0,
        lineSpacingMultiple: 1.20,
      });
    });
  });

  addFooter(slide, 'PALADALA  /  04  ARCHITECTURE');
  addPageBadge(slide, 5);
}

module.exports = { createSlide };
