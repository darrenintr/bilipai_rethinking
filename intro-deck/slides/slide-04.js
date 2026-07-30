// Slide 04 - 设计理念
// 2x2 philosophy grid
const { theme, FONT } = require('./theme.js');
const { addPageBadge, addEyebrow, addTitle, addCard, addFooter } = require('./_shared.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();
  slide.background = { color: theme.bg };

  addEyebrow(slide, '03  /  PHILOSOPHY', theme.violet);
  addTitle(slide, '设计理念');

  slide.addText('四项原则贯穿整个项目:平台原生,用户优先,长期可维护,社区驱动.', {
    x: 0.5, y: 1.75, w: 9.0, h: 0.4,
    fontSize: 14, color: theme.secondary, fontFace: FONT.cn,
    align: 'left', valign: 'middle', margin: 0,
  });

  const items = [
    {
      num: '01',
      title: '平台原生优先',
      desc: 'iPhone 走 TabView,iPad 走 NavigationSplitView;iOS 26 启用真 Liquid Glass,老系统降级到 Material 3.',
      color: theme.accent,
    },
    {
      num: '02',
      title: 'SwiftUI 优先',
      desc: '全栈 SwiftUI,无 Storyboard / XIB / WebView;UI 与业务逻辑统一在 View 与 ViewModel 层.',
      color: theme.cyan,
    },
    {
      num: '03',
      title: 'Swift 6 严格并发',
      desc: '开 strict concurrency,所有模型 : Sendable,所有 IO 用 actor / TaskGroup,无任何 @unchecked Sendable.',
      color: theme.violet,
    },
    {
      num: '04',
      title: '隐私友好',
      desc: '只走 B 站公开 API;登录走官方扫码协议;无埋点,无第三方追踪;支持离线优先.',
      color: theme.green,
    },
  ];

  const cardW = 4.20;
  const cardH = 1.45;
  const colGap = 0.10;
  const rowGap = 0.10;
  const startX = 0.5;
  const startY = 2.20;

  items.forEach((it, idx) => {
    const col = idx % 2;
    const row = Math.floor(idx / 2);
    const x = startX + col * (cardW + colGap);
    const y = startY + row * (cardH + rowGap);

    addCard(slide, x, y, cardW, cardH, { fill: theme.light, border: theme.divider, radius: 0.14 });

    // Number
    slide.addText(it.num, {
      x: x + 0.30, y: y + 0.18, w: 1.0, h: 0.7,
      fontSize: 36, bold: true, color: it.color, fontFace: FONT.en,
      align: 'left', valign: 'middle', margin: 0,
    });

    // Title
    slide.addText(it.title, {
      x: x + 1.30, y: y + 0.22, w: cardW - 1.5, h: 0.4,
      fontSize: 17, bold: true, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });

    // Vertical divider
    slide.addShape('rect', {
      x: x + 1.30, y: y + 0.68, w: 0.6, h: 0.03,
      fill: { color: it.color }, line: { color: it.color, width: 0 },
    });

    // Desc
    slide.addText(it.desc, {
      x: x + 0.30, y: y + 0.80, w: cardW - 0.55, h: 0.70,
      fontSize: 11, color: theme.secondary, fontFace: FONT.cn,
      align: 'left', valign: 'top', margin: 0,
      lineSpacingMultiple: 1.30,
    });
  });

  addFooter(slide, 'PALADALA  /  03  PHILOSOPHY');
  addPageBadge(slide, 4);
}

module.exports = { createSlide };
