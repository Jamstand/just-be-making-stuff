const puppeteer = require('puppeteer-core');

// Colored placeholder art matching each track's vibe
const PLACEHOLDERS = {
  '8863bc11d2aa12b54f5aeb36': { r:180, g:30,  b:60  },  // Blinding Lights - red
  'a91c10fe9472d9bd89802e5a': { r:70,  g:130, b:200 },  // good 4 u - blue
  '2e8ed79e177ff6011076f5f0': { r:200, g:120, b:40  },  // As It Was - orange
  '53dce99bbbaf08a4b4f1aff5': { r:220, g:160, b:60  },  // Flowers - gold
};

function makeSvgDataUrl({ r, g, b }) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300">
    <defs>
      <radialGradient id="g" cx="40%" cy="35%">
        <stop offset="0%" stop-color="rgb(${Math.min(r+60,255)},${Math.min(g+60,255)},${Math.min(b+60,255)})"/>
        <stop offset="100%" stop-color="rgb(${Math.max(r-40,0)},${Math.max(g-40,0)},${Math.max(b-40,0)})"/>
      </radialGradient>
    </defs>
    <rect width="300" height="300" fill="url(#g)"/>
    <text x="50%" y="54%" text-anchor="middle" font-size="80" opacity="0.25">♪</text>
  </svg>`;
  return 'data:image/svg+xml;base64,' + Buffer.from(svg).toString('base64');
}

(async () => {
  const browser = await puppeteer.launch({
    executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
    headless: true,
  });

  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 720 });

  // Intercept Spotify CDN image requests → serve colored SVG placeholders
  await page.setRequestInterception(true);
  page.on('request', req => {
    const url = req.url();
    if (url.includes('i.scdn.co/image/')) {
      const hash = url.split('/').pop();
      const match = Object.entries(PLACEHOLDERS).find(([k]) => hash.includes(k));
      const color = match ? match[1] : { r: 80, g: 80, b: 80 };
      req.respond({
        status: 200,
        contentType: 'image/svg+xml',
        body: Buffer.from(
          `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300">
            <defs><radialGradient id="g" cx="40%" cy="35%">
              <stop offset="0%" stop-color="rgb(${Math.min(color.r+60,255)},${Math.min(color.g+60,255)},${Math.min(color.b+60,255)})"/>
              <stop offset="100%" stop-color="rgb(${Math.max(color.r-40,0)},${Math.max(color.g-40,0)},${Math.max(color.b-40,0)})"/>
            </radialGradient></defs>
            <rect width="300" height="300" fill="url(#g)"/>
            <text x="50%" y="54%" text-anchor="middle" font-size="80" fill="rgba(255,255,255,0.2)">♪</text>
          </svg>`
        ),
      });
    } else {
      req.continue();
    }
  });

  await page.goto('http://localhost:4567/preview.html', { waitUntil: 'networkidle0' });
  await new Promise(r => setTimeout(r, 3500));

  // Full screenshot
  await page.screenshot({ path: '/tmp/widget-preview.png' });

  // Crop to just the widget region (bottom-left)
  await page.screenshot({
    path: '/tmp/widget-crop.png',
    clip: { x: 0, y: 580, width: 500, height: 140 },
  });

  await browser.close();
  console.log('done');
})();
