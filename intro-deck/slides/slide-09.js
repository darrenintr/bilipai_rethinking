// Slide 09 - 和现有 AI 工具的差异
// Comparison table: Paladala vs 官方 iOS / 旧 BiliPai / AI-only tools
const { theme, FONT } = require('./theme.js');
const { addPageBadge, addEyebrow, addTitle, addCard, addFooter } = require('./_shared.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();
  slide.background = { color: theme.bg };

  addEyebrow(slide, '08  /  VS AI TOOLS', theme.violet);
  addTitle(slide, '和现有 AI 工具的差异');

  slide.addText('AI 工具遍地都是,但要的是"完整客户端 + AI 增强",而不是"只做总结"或"只跑 AI".', {
    x: 0.5, y: 1.75, w: 9.0, h: 0.4,
    fontSize: 14, color: theme.secondary, fontFace: FONT.cn,
    align: 'left', valign: 'middle', margin: 0,
  });

  // Table area
  const tableX = 0.5;
  const tableY = 2.20;
  const tableW = 8.45;
  const col1W = 1.45;  // 维度
  const col2W = 1.75;  // Paladala
  const col3W = 1.75;  // 官方 iOS
  const col4W = 1.75;  // 旧 BiliPai
  const col5W = 1.75;  // AI 单独工具

  const headerH = 0.40;
  const rowH = 0.30;

  // Header row
  addCard(slide, tableX, tableY, tableW, headerH, { fill: theme.light, border: theme.divider, radius: 0.08 });

  const headers = [
    { t: '维度', c: theme.secondary, w: col1W, x: tableX + 0.18, emph: false },
    { t: 'Paladala', c: theme.accent, w: col2W, x: tableX + col1W, emph: true },
    { t: '官方 iOS', c: theme.secondary, w: col3W, x: tableX + col1W + col2W, emph: false },
    { t: '旧 BiliPai', c: theme.secondary, w: col4W, x: tableX + col1W + col2W + col3W, emph: false },
    { t: 'AI 单独工具', c: theme.secondary, w: col5W, x: tableX + col1W + col2W + col3W + col4W, emph: false },
  ];

  headers.forEach((h) => {
    slide.addText(h.t, {
      x: h.x, y: tableY, w: h.w - 0.10, h: headerH,
      fontSize: h.emph ? 13 : 11, bold: true, color: h.c, fontFace: FONT.cn,
      align: h.emph ? 'center' : 'left', valign: 'middle', margin: 0,
    });
  });

  // Divider line under header
  slide.addShape('rect', {
    x: tableX, y: tableY + headerH, w: tableW, h: 0.01,
    fill: { color: theme.divider }, line: { color: theme.divider, width: 0 },
  });

  // Data rows
  const rows = [
    ['完整播放体验', 'Y  AVPlayer 三态', 'Y  但 UI 臃肿', 'Y  Android 限定', 'N  无播放'],
    ['AI 视频总结', 'Y  原生集成', 'Y  部分场景', 'N', 'Y  唯一卖点'],
    ['离线 / 缓存', 'Y  DASH 本地代理', 'N  仅分片缓存', 'Y', 'N'],
    ['iOS 26 Liquid Glass', 'Y  真 GlassEffect', 'N', 'N', 'N'],
    ['跨设备 (iPhone / iPad)', 'Y  独立分栏', 'Y  仅缩放', 'N  仅 Android', 'N'],
    ['Siri / App Intents', 'Y  全套', 'N', 'N', 'N'],
    ['隐私 / 开源', 'Y  MIT, 公开 API', 'N  闭源 + 埋点', 'Y  Apache', 'N  多为闭源'],
  ];

  rows.forEach((r, i) => {
    const ry = tableY + headerH + 0.05 + i * rowH;
    // Row tint
    if (i % 2 === 0) {
      slide.addShape('rect', {
        x: tableX, y: ry, w: tableW, h: rowH,
        fill: { color: theme.light, transparency: 60 },
        line: { color: theme.light, width: 0, transparency: 100 },
      });
    }
    // Col 1 (label)
    slide.addText(r[0], {
      x: tableX + 0.18, y: ry, w: col1W - 0.18, h: rowH,
      fontSize: 10, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });
    // Cols 2-5
    const xs = [tableX + col1W, tableX + col1W + col2W, tableX + col1W + col2W + col3W, tableX + col1W + col2W + col3W + col4W];
    const ws = [col2W, col3W, col4W, col5W];
    for (let j = 0; j < 4; j++) {
      const val = r[j + 1];
      // Parse leading "Y "/"N "
      const isYes = val.startsWith('Y');
      const isNo = val.startsWith('N');
      const tagColor = isYes ? theme.green : isNo ? theme.red : theme.secondary;
      const tagLetter = isYes ? 'Y' : isNo ? 'N' : '?';
      const rest = val.substring(2);

      // Pill
      slide.addShape('roundRect', {
        x: xs[j] + 0.10, y: ry + 0.06, w: 0.20, h: 0.18,
        fill: { color: tagColor }, line: { color: tagColor, width: 0 },
        rectRadius: 0.04,
      });
      slide.addText(tagLetter, {
        x: xs[j] + 0.10, y: ry + 0.06, w: 0.20, h: 0.18,
        fontSize: 8, bold: true, color: 'FFFFFF', fontFace: FONT.en,
        align: 'center', valign: 'middle', margin: 0,
      });
      slide.addText(rest, {
        x: xs[j] + 0.36, y: ry, w: ws[j] - 0.46, h: rowH,
        fontSize: 9, color: j === 0 ? theme.primary : theme.secondary, fontFace: FONT.cn,
        align: 'left', valign: 'middle', margin: 0,
        bold: j === 0,
      });
    }
  });

  addFooter(slide, 'PALADALA  /  08  VS AI TOOLS');
  addPageBadge(slide, 9);
}

module.exports = { createSlide };
