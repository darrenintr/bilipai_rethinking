// Slide 08 - 典型场景
// 4 user journey steps shown as a horizontal flow
const { theme, FONT } = require('./theme.js');
const { addPageBadge, addEyebrow, addTitle, addCard, addFooter } = require('./_shared.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();
  slide.background = { color: theme.bg };

  addEyebrow(slide, '07  /  USE CASES', theme.green);
  addTitle(slide, '典型用法');

  slide.addText('四个真实使用场景,展示 Paladala 在日常追番,看片,跨设备,听歌上的完整闭环.', {
    x: 0.5, y: 1.75, w: 9.0, h: 0.4,
    fontSize: 14, color: theme.secondary, fontFace: FONT.cn,
    align: 'left', valign: 'middle', margin: 0,
  });

  const cases = [
    {
      num: '01',
      tag: 'BROWSING',
      title: '首页追番',
      flow: ['Home Tab 5 tab 入口', 'categoryStrip 横滚', 'AI 视频总结可展开', 'tap 进 VideoDetail'],
      color: theme.accent,
    },
    {
      num: '02',
      tag: 'OFFLINE',
      title: '通勤缓存',
      flow: ['详情页下载 chip', 'DASH/SIDX 重组', '本地 HLS 代理', '离线秒开,无网可看'],
      color: theme.cyan,
    },
    {
      num: '03',
      tag: 'CONTINUE',
      title: '跨设备接力',
      flow: ['iPhone 看 30s', '进度自动持久化', 'iPad ResumePromptSheet', 'iPad 续播 + 浮窗'],
      color: theme.violet,
    },
    {
      num: '04',
      tag: 'BACKGROUND',
      title: '后台听音乐',
      flow: ['Music Tab 列表', '切后台继续播', '锁屏封面 + 控制', '关闭应用即停'],
      color: theme.green,
    },
  ];

  const cardW = 2.05;
  const cardH = 2.85;
  const colGap = 0.10;
  const startX = 0.5;
  const startY = 2.20;

  cases.forEach((c, i) => {
    const x = startX + i * (cardW + colGap);
    addCard(slide, x, startY, cardW, cardH, { fill: theme.light, border: theme.divider, radius: 0.14 });

    // Top color band
    slide.addShape('rect', {
      x, y: startY, w: cardW, h: 0.06,
      fill: { color: c.color }, line: { color: c.color, width: 0 },
    });

    // Big number
    slide.addText(c.num, {
      x: x + 0.20, y: startY + 0.18, w: cardW - 0.4, h: 0.55,
      fontSize: 30, bold: true, color: c.color, fontFace: FONT.en,
      align: 'left', valign: 'middle', margin: 0,
    });

    // Tag
    slide.addText(c.tag, {
      x: x + 0.20, y: startY + 0.72, w: cardW - 0.4, h: 0.20,
      fontSize: 9, color: theme.secondary, bold: true, fontFace: FONT.en,
      charSpacing: 3, align: 'left', valign: 'middle', margin: 0,
    });

    // Title
    slide.addText(c.title, {
      x: x + 0.20, y: startY + 0.92, w: cardW - 0.4, h: 0.35,
      fontSize: 16, bold: true, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });

    // Divider
    slide.addShape('rect', {
      x: x + 0.20, y: startY + 1.32, w: 0.6, h: 0.03,
      fill: { color: c.color }, line: { color: c.color, width: 0 },
    });

    // Flow steps
    c.flow.forEach((s, j) => {
      const sy = startY + 1.45 + j * 0.32;
      // Step number circle
      slide.addShape('ellipse', {
        x: x + 0.20, y: sy + 0.05, w: 0.18, h: 0.18,
        fill: { color: c.color }, line: { color: c.color, width: 0 },
      });
      slide.addText(String(j + 1), {
        x: x + 0.20, y: sy + 0.05, w: 0.18, h: 0.18,
        fontSize: 8, bold: true, color: 'FFFFFF', fontFace: FONT.en,
        align: 'center', valign: 'middle', margin: 0,
      });
      slide.addText(s, {
        x: x + 0.45, y: sy, w: cardW - 0.6, h: 0.28,
        fontSize: 10, color: theme.primary, fontFace: FONT.cn,
        align: 'left', valign: 'middle', margin: 0,
      });
    });
  });

  addFooter(slide, 'PALADALA  /  07  USE CASES');
  addPageBadge(slide, 8);
}

module.exports = { createSlide };
