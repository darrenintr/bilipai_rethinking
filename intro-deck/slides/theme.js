// Shared theme + helpers for Paladala intro deck
// Bili-pink + dark glass aesthetic. LAYOUT_16x9 = 10" x 5.625"

const theme = {
  // 5-key palette
  primary:   'F5F6FA',  // light text
  secondary: '9AA0AE',  // muted text
  accent:    'FB7299',  // B 站 pink
  light:     '1B1D27',  // card / glass surface
  bg:        '0D0E14',  // deep dark background

  // extras (still a 5-key theme + a couple of accents we promise to use sparingly)
  pink:      'FB7299',
  pinkSoft:  '3A1F2A',  // tint background for pink callouts
  cyan:      '4FC1E9',
  cyanSoft:  '15303A',
  violet:    '8B5CF6',
  violetSoft:'241A3A',
  green:     '34D399',
  red:       'F87171',
  divider:   '2A2D3A',
};

const FONT_CN = 'Microsoft YaHei';
const FONT_EN = 'Arial';

const FONT = {
  cn: FONT_CN,
  en: FONT_EN,
};

// Reusable shadow factory (PptxGenJS mutates options in place, so never reuse)
const makeShadow = () => ({
  type: 'outer', blur: 12, offset: { x: 0, y: 2 },
  color: '000000', opacity: 0.35,
});

const makeSoftShadow = () => ({
  type: 'outer', blur: 18, offset: { x: 0, y: 4 },
  color: '000000', opacity: 0.45,
});

module.exports = {
  theme,
  FONT,
  makeShadow,
  makeSoftShadow,
};
