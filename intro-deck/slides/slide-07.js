// Slide 07 - 关键能力 - 体验
// 6 feature tiles (different mix: experience-oriented)
const { theme, FONT } = require('./theme.js');
const { addPageBadge, addEyebrow, addTitle, addCard, addFooter } = require('./_shared.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();
  slide.background = { color: theme.bg };

  addEyebrow(slide, '06  /  CAPABILITIES -- EXPERIENCE', theme.cyan);
  addTitle(slide, '关键能力 -- 体验');

  slide.addText('让 iOS 用户拿到完整的 Apple 平台集成能力,而不只是一个套壳网页.', {
    x: 0.5, y: 1.75, w: 9.0, h: 0.4,
    fontSize: 14, color: theme.secondary, fontFace: FONT.cn,
    align: 'left', valign: 'middle', margin: 0,
  });

  const features = [
    { glyph: 'iOS', title: 'Liquid Glass 26', desc: 'iOS 26 用真 GlassEffectContainer;旧系统降级 ultraThinMaterial;统一设计 token', color: theme.accent },
    { glyph: 'iPad', title: 'iPad 真分栏', desc: 'NavigationSplitView 4 tab + sidebar user card;横竖屏自适应,不走"放大版手机"路线', color: theme.cyan },
    { glyph: 'INT', title: 'App Intents + Deep Link', desc: 'Siri 打开 / 搜索 / 继续播放 / 稍后再看;paladala:// 完整 deep link 矩阵', color: theme.violet },
    { glyph: 'OFF', title: '离线下载', desc: 'DASH/SIDX 重组 + 本地 HLS 代理;支持断点续传;离线视频可独立播放', color: theme.green },
    { glyph: 'POP', title: '小窗浮窗', desc: 'MiniPlayerOverlay 可拖动,可展开回内嵌;Live Activity 锁屏继续直播', color: theme.accent },
    { glyph: 'LIVE', title: '直播 + 音乐', desc: '直播独立 Tab + 互动;音乐 Tab 走 AVPlayer 纯音频 + 同步歌词滚动', color: theme.cyan },
  ];

  const cardW = 2.75;
  const cardH = 1.42;
  const colGap = 0.10;
  const rowGap = 0.15;
  const startX = 0.5;
  const startY = 2.20;

  features.forEach((f, i) => {
    const col = i % 3;
    const row = Math.floor(i / 3);
    const x = startX + col * (cardW + colGap);
    const y = startY + row * (cardH + rowGap);

    addCard(slide, x, y, cardW, cardH, { fill: theme.light, border: theme.divider, radius: 0.14 });

    slide.addShape('roundRect', {
      x: x + 0.22, y: y + 0.20, w: 0.60, h: 0.42,
      fill: { color: f.color }, line: { color: f.color, width: 0 },
      rectRadius: 0.08,
    });
    slide.addText(f.glyph, {
      x: x + 0.22, y: y + 0.20, w: 0.60, h: 0.42,
      fontSize: 10, bold: true, color: 'FFFFFF', fontFace: FONT.en,
      align: 'center', valign: 'middle', margin: 0,
    });

    slide.addText(f.title, {
      x: x + 0.95, y: y + 0.20, w: cardW - 1.10, h: 0.42,
      fontSize: 14, bold: true, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });

    slide.addText(f.desc, {
      x: x + 0.22, y: y + 0.72, w: cardW - 0.40, h: 0.62,
      fontSize: 10, color: theme.secondary, fontFace: FONT.cn,
      align: 'left', valign: 'top', margin: 0,
      lineSpacingMultiple: 1.30,
    });
  });

  addFooter(slide, 'PALADALA  /  06  CAPABILITIES  --  EXPERIENCE');
  addPageBadge(slide, 7);
}

module.exports = { createSlide };
