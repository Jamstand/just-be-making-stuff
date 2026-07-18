/*
 * End-to-end test: loads the extension into Chromium, opens the fixture page,
 * and verifies price badges appear (including on late-loaded content).
 * Run: node test/e2e.mjs   (requires `playwright` npm package + a Chromium)
 */
import { chromium } from 'playwright';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdirSync } from 'node:fs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const outDir = process.env.LPP_SHOT_DIR || join(root, 'docs');
mkdirSync(outDir, { recursive: true });

const ctx = await chromium.launchPersistentContext('', {
  headless: true,
  executablePath: process.env.LPP_CHROME || '/opt/pw-browsers/chromium',
  args: [
    `--disable-extensions-except=${root}`,
    `--load-extension=${root}`,
  ],
});

let failures = 0;
const check = (ok, msg) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${msg}`);
  if (!ok) failures++;
};

try {
  const page = await ctx.newPage();
  await page.goto('file://' + join(root, 'test', 'fixture.html'));

  // Manifest only auto-matches helixrentals.com, so inject the same files the
  // "Scan this page" button would (scripting.executeScript equivalent).
  await page.addStyleTag({ path: join(root, 'content', 'content.css') });
  await page.addScriptTag({ path: join(root, 'lib', 'matcher.js') });

  // The content script talks to the real background worker via chrome.runtime —
  // available here because the extension is actually loaded.
  let [bg] = ctx.serviceWorkers();
  if (!bg) bg = await ctx.waitForEvent('serviceworker', { timeout: 10_000 });
  check(!!bg, 'background service worker is running');
  const extId = new URL(bg.url()).host;

  // file:// pages can't message the extension without externally_connectable,
  // so run the content script with the extension's runtime bridged in via the
  // background worker answering lookups directly.
  const db = await bg.evaluate(async () => {
    const r = await fetch(chrome.runtime.getURL('data/lens-prices.json'));
    return r.json();
  });
  check(Array.isArray(db.lenses) && db.lenses.length >= 11, `background loads DB (${db.lenses.length} lenses)`);

  // Simulate the message channel: stub chrome.runtime.sendMessage on the page
  // with the same logic the background applies (matcher runs in-page anyway).
  await page.evaluate((dbJson) => {
    const db = dbJson;
    window.chrome = window.chrome || {};
    window.chrome.storage = { onChanged: { addListener() {} } };
    window.chrome.runtime = {
      lastError: null,
      sendMessage(msg, cb) {
        if (msg.type === 'get-settings') return cb({ badges: true, live: false });
        if (msg.type === 'lens-lookup') {
          const res = window.LensMatch.match(msg.name, db.lenses);
          return cb({
            found: !!res,
            entry: res ? res.entry : null,
            asOf: db.asOf,
            query: window.LensMatch.searchQuery(res ? res.entry : msg.name),
            links: window.LensMatch.marketLinks(res ? res.entry : msg.name),
          });
        }
        cb({});
      },
    };
  }, db);
  await page.addScriptTag({ path: join(root, 'content', 'content.js') });

  await page.waitForSelector('.lpp-badge', { timeout: 5000 });
  await page.waitForTimeout(1800); // let the late-loaded card + rescan happen
  const badges = await page.$$('.lpp-badge');
  check(badges.length >= 13, `badges injected for all cards incl. late-loaded (got ${badges.length})`);

  const knownCount = await page.$$eval('.lpp-badge:not(.lpp-badge--unknown)', (els) => els.length);
  const unknownCount = await page.$$eval('.lpp-badge--unknown', (els) => els.length);
  check(knownCount >= 11, `matched badges show prices (got ${knownCount})`);
  check(unknownCount >= 1, `unknown lens gets a links-only badge (got ${unknownCount})`);

  const badgeText = await page.$eval('.lpp-badge', (el) => el.textContent);
  check(/New\s*\$[\d,]+/.test(badgeText) && /Used\s*\$[\d,]+–\$[\d,]+/.test(badgeText),
    `badge shows new & used prices ("${badgeText.trim()}")`);

  // Popover
  await badges[0].click();
  await page.waitForSelector('.lpp-popover', { timeout: 3000 });
  const popText = await page.$eval('.lpp-popover', (el) => el.textContent);
  check(/eBay sold/.test(popText) && /MPB/.test(popText) && /KEH/.test(popText),
    'popover has marketplace links');
  check(/as of \d{4}-\d{2}-\d{2}/.test(popText), 'popover shows price-guide date');

  await page.screenshot({ path: join(outDir, 'screenshot-fixture.png'), fullPage: true });

  // Popup page (real extension page, real background messaging)
  const popup = await ctx.newPage();
  await popup.goto(`chrome-extension://${extId}/popup/popup.html?q=${encodeURIComponent('Sony FE 24-105mm f/4 G OSS')}`);
  await popup.waitForSelector('#result .title', { timeout: 5000 });
  const popupTitle = await popup.$eval('#result .title', (el) => el.textContent);
  check(/24-105/.test(popupTitle), `popup lookup resolves ("${popupTitle}")`);
  const footer = await popup.$eval('#foot', (el) => el.textContent);
  check(/lenses in price guide/.test(footer), `popup footer shows DB info ("${footer.trim()}")`);
  await popup.setViewportSize({ width: 400, height: 640 });
  await popup.screenshot({ path: join(outDir, 'screenshot-popup.png') });

  console.log(failures ? `\n${failures} check(s) FAILED` : '\nAll e2e checks passed.');
} finally {
  await ctx.close();
}
process.exit(failures ? 1 : 0);
