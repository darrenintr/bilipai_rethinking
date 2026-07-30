// Slide 06 - 关键能力 - 播放
// 6 feature tiles in a 3x2 grid
const { theme, FONT } = require('./theme.js');
const { addPageBadge, addEyebrow, addTitle, addCard, addFooter } = require('./_shared.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();
  slide.background = { color: theme.bg };

  addEyebrow(slide, '05  /  CAPABILITIES -- PLAYBACK', theme.accent);
  addTitle(slide, '关键能力 -- 播放');

  slide.addText('围绕"看视频"这件事,补齐 B 站官方客户端欠缺的播放链路.', {
    x: 0.5, y: 1.75, w: 9.0, h: 0.4,
    fontSize: 14, color: theme.secondary, fontFace: FONT.cn,
    align: 'left', valign: 'middle', margin: 0,
  });

  const features = [
    { glyph: 'AV', title: 'AVPlayer 内核', desc: 'AVPlayerViewController inline + 浮窗 + 全屏三态;本地 HLS 代理 + DASH/SIDX 重组', color: theme.accent },
    { glyph: '4K', title: '画质 / 字幕 / 弹幕', desc: '画质多档切换;原生字幕轨道;可关闭弹幕叠层;本地缓存秒开', color: theme.cyan },
    { glyph: 'AI', title: 'B 站 AI 视频总结', desc: '视频详情直接挂载 B 站官方 AI 总结 API,章节跳转,文本可复制', color: theme.violet },
    { glyph: '>>', title: 'SponsorBlock 拦截', desc: '内置 SponsorBlock 服务,自动跳过恰饭 / 自我介绍 / 片尾,统计累计节省时长', color: theme.green },
    { glyph: '<>', title: '手势交互', desc: '双击左/中/右 ±10s / 点赞;长按 0.4s 2x 速播;竖屏浮窗拖动可关', color: theme.accent },
    { glyph: 'CDN', title: '稳播优选', desc: 'CDN 区域优选 + 手动检测 + 失败 fallback,弱网下自动切到备用节点', color: theme.cyan },
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

    // Glyph badge
    slide.addShape('roundRect', {
      x: x + 0.22, y: y + 0.20, w: 0.60, h: 0.42,
      fill: { color: f.color }, line: { color: f.color, width: 0 },
      rectRadius: 0.08,
    });
    slide.addText(f.glyph, {
      x: x + 0.22, y: y + 0.20, w: 0.60, h: 0.42,
      fontSize: 11, bold: true, color: 'FFFFFF', fontFace: FONT.en,
      align: 'center', valign: 'middle', margin: 0,
    });

    // Title
    slide.addText(f.title, {
      x: x + 0.95, y: y + 0.20, w: cardW - 1.10, h: 0.42,
      fontSize: 14, bold: true, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });

    // Desc
    slide.addText(f.desc, {
      x: x + 0.22, y: y + 0.72, w: cardW - 0.40, h: 0.62,
      fontSize: 10, color: theme.secondary, fontFace: FONT.cn,
      align: 'left', valign: 'top', margin: 0,
      lineSpacingMultiple: 1.30,
    });
  });

  addFooter(slide, 'PALADALA  /  05  CAPABILITIES  --  PLAYBACK');
  addPageBadge(slide, 6);
}

module.exports = { createSlide };
