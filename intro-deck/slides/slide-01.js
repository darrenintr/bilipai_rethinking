// Slide 01 - Cover
// Asymmetric layout: large wordmark on the left, abstract glass blobs on the right
const { theme, FONT, makeShadow } = require('./theme.js');

function createSlide(pres, _theme) {
  const slide = pres.addSlide();

  // Solid dark background
  slide.background = { color: theme.bg };

  // Soft pink glow blob (top-right)
  slide.addShape('ellipse', {
    x: 7.0, y: -1.5, w: 4.5, h: 4.5,
    fill: { color: theme.accent, transparency: 80 },
    line: { color: theme.accent, width: 0, transparency: 100 },
  });

  // Soft cyan glow blob (bottom-right)
  slide.addShape('ellipse', {
    x: 6.0, y: 2.6, w: 4.0, h: 4.0,
    fill: { color: theme.cyan, transparency: 85 },
    line: { color: theme.cyan, width: 0, transparency: 100 },
  });

  // Faint violet accent
  slide.addShape('ellipse', {
    x: 8.0, y: 1.0, w: 2.0, h: 2.0,
    fill: { color: theme.violet, transparency: 88 },
    line: { color: theme.violet, width: 0, transparency: 100 },
  });

  // Project eyebrow (top-left)
  slide.addShape('rect', {
    x: 0.5, y: 0.55, w: 0.18, h: 0.18,
    fill: { color: theme.accent }, line: { color: theme.accent, width: 0 },
  });
  slide.addText('PALADALA  /  iOS  /  2026', {
    x: 0.78, y: 0.50, w: 6.0, h: 0.28,
    fontSize: 11, color: theme.accent, bold: true,
    fontFace: FONT.en, charSpacing: 4,
    align: 'left', valign: 'middle', margin: 0,
  });

  // Massive wordmark
  slide.addText('Paladala', {
    x: 0.5, y: 1.20, w: 7.5, h: 1.5,
    fontSize: 110, bold: true,
    color: theme.primary, fontFace: FONT.en,
    align: 'left', valign: 'middle', margin: 0,
    charSpacing: -3,
  });

  // Pink underline accent
  slide.addShape('rect', {
    x: 0.5, y: 2.85, w: 1.0, h: 0.06,
    fill: { color: theme.accent }, line: { color: theme.accent, width: 0 },
  });

  // Chinese subtitle
  slide.addText('重新设计的 iOS B 站第三方客户端', {
    x: 0.5, y: 3.10, w: 9.0, h: 0.6,
    fontSize: 28, color: theme.primary,
    fontFace: FONT.cn, align: 'left', valign: 'middle', margin: 0,
  });

  // English tagline
  slide.addText('Native SwiftUI  /  Liquid Glass  /  Public Bilibili API', {
    x: 0.5, y: 3.75, w: 9.0, h: 0.4,
    fontSize: 14, color: theme.secondary,
    fontFace: FONT.en, charSpacing: 3,
    align: 'left', valign: 'middle', margin: 0,
  });

  // Meta row at the bottom
  slide.addShape('rect', {
    x: 0.5, y: 4.85, w: 0.04, h: 0.20,
    fill: { color: theme.accent }, line: { color: theme.accent, width: 0 },
  });
  slide.addText('v0.5.x  ·  iOS 16+  ·  iPhone & iPad  ·  Swift 6', {
    x: 0.65, y: 4.80, w: 6.0, h: 0.30,
    fontSize: 12, color: theme.secondary, fontFace: FONT.en,
    align: 'left', valign: 'middle', margin: 0, charSpacing: 1,
  });

  // Right side: vertical label
  slide.addText('PROJECT  INTRO', {
    x: 8.5, y: 4.80, w: 1.4, h: 0.30,
    fontSize: 10, color: theme.accent, fontFace: FONT.en, bold: true,
    charSpacing: 4, align: 'right', valign: 'middle', margin: 0,
  });
}

module.exports = { createSlide };
