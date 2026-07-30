// Shared helpers used by every slide
const { theme, FONT, makeShadow } = require('./theme.js');

// Page number badge (mandatory on slides 2+)
function addPageBadge(slide, pageNumber, totalPages = 10) {
  slide.addText(
    [
      { text: String(pageNumber).padStart(2, '0'), options: { color: theme.accent, bold: true, fontSize: 11 } },
      { text: '  /  ' + String(totalPages).padStart(2, '0'), options: { color: theme.secondary, fontSize: 11 } },
    ],
    {
      x: 9.0, y: 5.20, w: 0.85, h: 0.30,
      fontFace: FONT.en, align: 'right', valign: 'middle',
      margin: 0,
    }
  );
}

// Small footer / project label, optional
function addFooter(slide, leftText) {
  slide.addShape('rect', {
    x: 0, y: 5.50, w: 10, h: 0.001,
    fill: { color: theme.divider },
    line: { color: theme.divider, width: 0.5 },
  });
  slide.addText(leftText, {
    x: 0.5, y: 5.20, w: 5.0, h: 0.30,
    fontSize: 10, color: theme.secondary, fontFace: FONT.en,
    align: 'left', valign: 'middle', margin: 0,
  });
}

// Pink-tinted "section eyebrow" header (small all-caps label above a title)
function addEyebrow(slide, label, color) {
  const c = color || theme.accent;
  slide.addShape('rect', {
    x: 0.5, y: 0.55, w: 0.18, h: 0.18,
    fill: { color: c }, line: { color: c, width: 0 },
  });
  slide.addText(label, {
    x: 0.78, y: 0.50, w: 6.0, h: 0.28,
    fontSize: 11, color: c, bold: true,
    fontFace: FONT.en, charSpacing: 4,
    align: 'left', valign: 'middle', margin: 0,
  });
}

// Big slide title (left-aligned)
function addTitle(slide, text, opts = {}) {
  slide.addText(text, {
    x: 0.5, y: opts.y || 0.85, w: opts.w || 9.0, h: opts.h || 0.85,
    fontSize: opts.fontSize || 36, bold: true,
    color: theme.primary, fontFace: FONT.cn,
    align: opts.align || 'left', valign: 'middle', margin: 0,
    fit: 'shrink',
  });
}

// Glass card -- rounded rect on dark background
function addCard(slide, x, y, w, h, opts = {}) {
  const fillColor = opts.fill || theme.light;
  const borderColor = opts.border || theme.divider;
  slide.addShape('roundRect', {
    x, y, w, h,
    fill: { color: fillColor },
    line: { color: borderColor, width: opts.borderWidth || 0.5 },
    rectRadius: opts.radius != null ? opts.radius : 0.18,
    shadow: makeShadow(),
  });
}

// Bullet item with pink dot
function addBullet(slide, x, y, w, text, opts = {}) {
  const fontSize = opts.fontSize || 14;
  const color = opts.color || theme.primary;
  slide.addShape('ellipse', {
    x, y: y + fontSize * 0.04, w: fontSize * 0.18, h: fontSize * 0.18,
    fill: { color: opts.dotColor || theme.accent },
    line: { color: opts.dotColor || theme.accent, width: 0 },
  });
  slide.addText(text, {
    x: x + fontSize * 0.30, y, w: w - fontSize * 0.30, h: fontSize * 0.30,
    fontSize, color, fontFace: FONT.cn,
    align: 'left', valign: 'middle', margin: 0,
  });
}

module.exports = {
  addPageBadge,
  addFooter,
  addEyebrow,
  addTitle,
  addCard,
  addBullet,
};
