// Slide 02 - 是什么
// Left: one-line definition; Right: 3 "pillar" cards
const { theme, FONT } = require('./theme.js');
const { addPageBadge, addEyebrow, addTitle, addCard, addFooter } = require('./_shared.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();
  slide.background = { color: theme.bg };

  addEyebrow(slide, '01  /  WHAT IT IS');
  addTitle(slide, '是什么');

  // Left big quote / one-liner
  slide.addText('Paladala', {
    x: 0.5, y: 1.85, w: 4.6, h: 0.6,
    fontSize: 36, bold: true, color: theme.accent, fontFace: FONT.en,
    align: 'left', valign: 'top', margin: 0,
  });

  slide.addText(
    '一个完全用 SwiftUI 重写的 iOS B 站客户端,基于 B 站公开 API,聚焦现代 Apple 平台的设计语言与播放体验.',
    {
      x: 0.5, y: 2.55, w: 4.6, h: 1.6,
      fontSize: 15, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'top', margin: 0,
      lineSpacingMultiple: 1.45,
    }
  );

  // Meta facts at the bottom-left
  const facts = [
    { k: '来源', v: '从 Android 端 BiliPai 迁移重写' },
    { k: '协议', v: '纯公开 API,无破解' },
    { k: '许可', v: 'MIT, 完全开源' },
  ];
  facts.forEach((f, i) => {
    const y = 4.20 + i * 0.30;
    slide.addText(f.k, {
      x: 0.5, y, w: 0.9, h: 0.26,
      fontSize: 11, color: theme.secondary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });
    slide.addText(f.v, {
      x: 1.45, y, w: 3.6, h: 0.26,
      fontSize: 12, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });
  });

  // Right: 3 pillar cards
  const pillars = [
    {
      tag: 'NATIVE',
      title: 'SwiftUI 原生',
      desc: 'iPhone 5-tab + iPad NavigationSplitView;无 Storyboard,无 XIB',
      color: theme.accent,
    },
    {
      tag: 'PUBLIC API',
      title: 'B 站公开接口',
      desc: '匿名推荐 / 热门 / 搜索 / 视频详情 / 播放地址 / 直播',
      color: theme.cyan,
    },
    {
      tag: 'LIQUID GLASS',
      title: 'iOS 26 玻璃优先',
      desc: 'iOS 26 用真 GlassEffectContainer;旧版降级 ultraThinMaterial',
      color: theme.violet,
    },
  ];

  const cardX = 5.0;
  const cardW = 3.95;
  const cardH = 0.95;
  const cardGap = 0.15;
  const cardY0 = 1.85;

  pillars.forEach((p, i) => {
    const y = cardY0 + i * (cardH + cardGap);
    addCard(slide, cardX, y, cardW, cardH, { fill: theme.light, border: theme.divider, radius: 0.14 });

    // Colored left bar
    slide.addShape('rect', {
      x: cardX, y, w: 0.10, h: cardH,
      fill: { color: p.color }, line: { color: p.color, width: 0 },
    });

    // Tag
    slide.addText(p.tag, {
      x: cardX + 0.30, y: y + 0.12, w: cardW - 0.4, h: 0.22,
      fontSize: 9, color: p.color, bold: true, fontFace: FONT.en,
      charSpacing: 3, align: 'left', valign: 'middle', margin: 0,
    });

    // Title
    slide.addText(p.title, {
      x: cardX + 0.30, y: y + 0.32, w: cardW - 0.4, h: 0.34,
      fontSize: 18, bold: true, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });

    // Desc
    slide.addText(p.desc, {
      x: cardX + 0.30, y: y + 0.66, w: cardW - 0.4, h: 0.32,
      fontSize: 11, color: theme.secondary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });
  });

  addFooter(slide, 'PALADALA  /  01  WHAT IT IS');
  addPageBadge(slide, 2);
}

module.exports = { createSlide };
