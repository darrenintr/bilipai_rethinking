// Slide 10 - 路线图 + 总结
// 3-column status board + closing
const { theme, FONT, makeShadow } = require('./theme.js');
const { addPageBadge, addEyebrow, addTitle, addCard, addFooter } = require('./_shared.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();
  slide.background = { color: theme.bg };

  addEyebrow(slide, '09  /  ROADMAP', theme.accent);
  addTitle(slide, '现状与下一步');

  slide.addText('v0.5.x 已经覆盖核心播放 / 浏览 / 离线闭环,下面三栏是当前路线图.', {
    x: 0.5, y: 1.75, w: 9.0, h: 0.4,
    fontSize: 14, color: theme.secondary, fontFace: FONT.cn,
    align: 'left', valign: 'middle', margin: 0,
  });

  // 3 status columns
  const columns = [
    {
      label: 'SHIPPED',
      title: '已上线',
      color: theme.green,
      items: [
        'SwiftUI 5 tab + iPad 真分栏',
        'iOS 26 Liquid Glass 真玻璃效果',
        'Swift 6 严格并发',
        'AVPlayer 播放三态 (inline/浮窗/全屏)',
        'SponsorBlock 拦截 + 上报',
        'LocalHLSProxyServer + 离线',
        'B 站官方 AI 视频总结',
        'App Intents + deep link',
      ],
    },
    {
      label: 'IN PROGRESS',
      title: '进行中',
      color: theme.cyan,
      items: [
        'iOS 26 底栏滚动玻璃 / 折射细节',
        '视频返回阴影与共享转场打磨',
        '深色 / 浅色 / Liquid / MD3 主题切换',
        '首页 / 视频 / 评论 skeleton 节奏统一',
        'FFmpeg 解码 / 播放测试集成',
        'Bangumi 番剧 / 影视 API 完善',
      ],
    },
    {
      label: 'NEXT',
      title: '下一步',
      color: theme.violet,
      items: [
        '完整弹幕叠层渲染 (现在仅基础)',
        '认证态历史 / 关注 / 收藏同步',
        'WatchKit / iPad 多任务分屏',
        'VisionOS 空间播放实验',
        'App Store 上架可行性评估',
        '社区协作 / Issue 模板 / CI 公开发布',
      ],
    },
  ];

  const colW = 2.75;
  const colH = 2.80;
  const colGap = 0.10;
  const startX = 0.5;
  const startY = 2.20;

  columns.forEach((col, i) => {
    const x = startX + i * (colW + colGap);
    addCard(slide, x, startY, colW, colH, { fill: theme.light, border: theme.divider, radius: 0.14 });

    // Top color band
    slide.addShape('rect', {
      x, y: startY, w: colW, h: 0.06,
      fill: { color: col.color }, line: { color: col.color, width: 0 },
    });

    // Label
    slide.addText(col.label, {
      x: x + 0.20, y: startY + 0.15, w: colW - 0.4, h: 0.22,
      fontSize: 9, color: col.color, bold: true, fontFace: FONT.en,
      charSpacing: 3, align: 'left', valign: 'middle', margin: 0,
    });

    // Title
    slide.addText(col.title, {
      x: x + 0.20, y: startY + 0.35, w: colW - 0.4, h: 0.40,
      fontSize: 18, bold: true, color: theme.primary, fontFace: FONT.cn,
      align: 'left', valign: 'middle', margin: 0,
    });

    // Divider
    slide.addShape('rect', {
      x: x + 0.20, y: startY + 0.82, w: 0.6, h: 0.03,
      fill: { color: col.color }, line: { color: col.color, width: 0 },
    });

    // Items
    col.items.forEach((it, j) => {
      const iy = startY + 0.95 + j * 0.24;
      // Dot
      slide.addShape('ellipse', {
        x: x + 0.22, y: iy + 0.08, w: 0.07, h: 0.07,
        fill: { color: col.color }, line: { color: col.color, width: 0 },
      });
      slide.addText(it, {
        x: x + 0.38, y: iy, w: colW - 0.55, h: 0.22,
        fontSize: 9.5, color: theme.primary, fontFace: FONT.cn,
        align: 'left', valign: 'middle', margin: 0,
      });
    });
  });

  // Closing call-to-action
  slide.addShape('roundRect', {
    x: 0.5, y: 5.10, w: 8.4, h: 0.32,
    fill: { color: theme.accent, transparency: 80 },
    line: { color: theme.accent, width: 0 },
    rectRadius: 0.05,
  });
  slide.addText('GitHub  /  darrenintr/pure-bilibili-rethinking  /  MIT', {
    x: 0.5, y: 5.10, w: 8.4, h: 0.32,
    fontSize: 10, color: theme.accent, bold: true, fontFace: FONT.en,
    charSpacing: 1, align: 'center', valign: 'middle', margin: 0,
  });

  addFooter(slide, 'PALADALA  /  09  ROADMAP');
  addPageBadge(slide, 10);
}

module.exports = { createSlide };
