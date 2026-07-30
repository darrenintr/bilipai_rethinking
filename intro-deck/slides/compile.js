// compile.js - assembles all slide modules into a single PPTX
const path = require('path');
const pptxgen = require('pptxgenjs');
const { theme } = require('./theme.js');

const pres = new pptxgen();
pres.layout = 'LAYOUT_16x9';
pres.title = 'Paladala 项目介绍';
pres.author = 'Paladala';
pres.company = 'darrenintr/pure-bilibili-rethinking';

for (let i = 1; i <= 10; i++) {
  const num = String(i).padStart(2, '0');
  const mod = require(path.join(__dirname, `slide-${num}.js`));
  mod.createSlide(pres, theme);
}

const outPath = path.join(__dirname, 'output', 'paladala-intro-2026.pptx');
pres.writeFile({ fileName: outPath })
  .then((f) => { console.log('Wrote:', f); })
  .catch((e) => { console.error('FAIL:', e); process.exit(1); });
