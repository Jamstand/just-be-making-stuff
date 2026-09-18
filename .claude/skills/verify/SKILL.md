---
name: verify
description: Build, launch and drive this repo's pages in a real browser to verify a change works — recipe for the Express server + Puppeteer/Chromium setup used here.
---

# Verifying pages in this repo

Everything is served by one Express app (`server.js`) from `public/`. Pages are
self-contained HTML files; short routes like `/portfolio`, `/photo-ai`, `/design`
are one-liners in `server.js`.

## Launch

```bash
npm install                                   # pure-JS deps, no native builds
PORT=3457 nohup node server.js > /tmp/server.log 2>&1 &   # pick a free port; needs no .env
curl -s --noproxy '*' -o /dev/null -w "%{http_code}\n" http://localhost:3457/portfolio
```

Gotchas:
- `curl` without `--noproxy '*'` can return `000` in sandboxed sessions where an
  HTTPS proxy is configured; the server is fine — Chromium reaches it directly.
- `pkill -f "node server.js"` matches its own shell; use `pkill -x node`.
- The server prints the OBS-widget banner on start; Spotify/Twitch/Plaid
  "not connected" lines are normal without keys.

## Drive in a browser

`puppeteer-core` is a devDependency and Chromium is preinstalled:

```js
const puppeteer = require('puppeteer-core');
const browser = await puppeteer.launch({
  executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', // or glob chromium-*/chrome-linux/chrome
  args: ['--no-sandbox', '--disable-setuid-sandbox'], headless: true,
});
```

- Collect `page.on('pageerror')` and `console` errors — a clean run has none.
- Pages use `scroll-behavior: smooth`; set
  `document.documentElement.style.scrollBehavior = 'auto'` before programmatic
  scrolling, or IntersectionObserver reveals and `scrollIntoView` checks race.
- Check `document.documentElement.scrollWidth - clientWidth` for horizontal
  overflow at 320/390/1440 widths.
- Fonts are self-hosted under `public/fonts/`; assert with
  `document.fonts.check('500 20px "Caveat"')` after `document.fonts.ready`.

## Flows worth driving on `/portfolio`

- Filter chips → visible `.card` count and `aria-pressed`.
- Card click → `<dialog id="lightbox">` open, `#lbStatus` text, ArrowLeft/Right
  stays within the active filter, Escape clears `#lbMedia` and body scroll lock.
- 390px: `#menuBtn` → menu `.open`, focus on first link, `main.inert`; Escape
  returns focus; resizing past 760px auto-closes.
- Config-driven paths (`SITE.reelUrl`, `WORK[].media`) can only be exercised by
  serving a temporary copy of the page with the config edited — write it as
  `public/_verify-*.html`, drive it, delete it before committing.
