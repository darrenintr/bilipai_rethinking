// Slide 03 - 解决什么问题
// 3-column problem cards
const { theme, FONT } = require('./theme.js');
const { addPageBadge, addEyebrow, addTitle, addCard, addFooter } = require('./_shared.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();
  slide.background = { color: theme.bg };

  addEyebrow(slide, '02  /  PROBLEMS', theme.cyan);
  addTitle(slide, '解决什么问题');

  slide.addText('iOS 端长期缺乏一个既现代,又尊重用户,又覆盖完整使用场景的 B 站客户端.', {
    x: 0.5, y: 1.75, w: 9.0, h: 0.4,
    fontSize: 14, color: theme.secondary, fontFace: FONT.cn,
    align: 'left', valign: 'middle', margin: 0,
  });

  // 3 column problem cards
  const cards = [
    {
      label: 'A',
      tag: '官方 iOS 客户端',
      color: theme.cyan,
      lines: [
        '首页信息密度高,广告与运营模块臃肿',
        '没有 Liquid Glass / 灵动岛级系统集成',
        '无法离线缓存原始 DASH 流,只能缓存分片',
      ],
    },
    {
      label: 'B',
      tag: '旧 BiliPai (Android)',
      color: theme.accent,
      lines: [
        '功能成熟,但只服务 Android,无法触达 iOS 用户',
        'Compose / MD3 设计语言与 Apple HIG 错位',
        'iOS 专属能力 (Live Activity / SharePlay / Intents) 缺失',
      ],
    },
    {
      label: 'C',
      tag: '其他第三方 / AI 工具',
      color: theme.violet,
      lines: [
        '多数仅做 AI 总结,字幕或下载,没有完整播放链路',
        '违反 B 站使用条款,或暗藏追踪',
        '无 Apple 平台深度集成,体验碎片化',
      ],
    },
  ];

  const cardW = 2.75;
  const cardH = 3.00;
  const cardY = 2.20;
  const startX = 0.5;
  const gap = 0.10;

  cards.forEach((c, i) => {
    const x = startX + i * (cardW + gap);
    addCard(slide, x, cardY, cardW, cardH, { fill: theme.light, border: theme.divider, radius: 0.16 });

    // Top color band
    slide.addShape('rect', {
      x, y: cardY, w: cardW, h: 0.06,
      fill: { color: c.color }, line: { color: c.color, width: 0 },
    });

    // Big letter A/B/C
    slide.addText(c.label, {
      x: x + 0.25, y: cardY + 0.18, w: 0.7, h: 0.7,
      fontSize: 44, bold: true, color: c.color, fontFace: FONT.en,
      align: 'left', valign: 'middle', margin: 0,
    });

    // Tag
    slide.addText(c.tag, {
      x: x + 0.95, y: cardY + 0.30, w: cardW - 1.1, h: 0.50,
      fontSize: 15, bold: true, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });

    // Divider
    slide.addShape('rect', {
      x: x + 0.25, y: cardY + 1.00, w: cardW - 0.5, h: 0.01,
      fill: { color: theme.divider }, line: { color: theme.divider, width: 0 },
    });

    // Bullets
    c.lines.forEach((line, j) => {
      const ly = cardY + 1.20 + j * 0.60;
      // Pink dot
      slide.addShape('ellipse', {
        x: x + 0.27, y: ly + 0.10, w: 0.08, h: 0.08,
        fill: { color: c.color }, line: { color: c.color, width: 0 },
      });
      slide.addText(line, {
        x: x + 0.45, y: ly, w: cardW - 0.65, h: 0.50,
        fontSize: 11, color: theme.primary, fontFace: FONT.cn,
        align: 'left', valign: 'top', margin: 0,
        lineSpacingMultiple: 1.30,
      });
    });
  });

  addFooter(slide, 'PALADALA  /  02  PROBLEMS');
  addPageBadge(slide, 3);
}

module.exports = { createSlide };
