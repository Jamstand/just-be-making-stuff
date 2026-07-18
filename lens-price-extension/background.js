/*
 * Lens Price Peek — background (Chrome MV3 service worker / Firefox event page).
 * Answers price lookups from the content script & popup, fetches live eBay
 * sold prices, and owns the right-click "look up lens price" menu.
 */
'use strict';

// Chrome loads only this file as a service worker; Firefox loads
// lib/matcher.js first via background.scripts.
if (typeof importScripts === 'function' && typeof self.LensMatch === 'undefined') {
  importScripts('lib/matcher.js');
}

// Prefer the callback-style chrome.* namespace, which Firefox also provides;
// Firefox's browser.* is promise-only and would break the callbacks below.
var api = typeof chrome !== 'undefined' && chrome.runtime ? chrome : browser;

var LIVE_CACHE_TTL_MS = 24 * 60 * 60 * 1000; // refresh eBay sold prices daily
var dbPromise = null;

function loadDb() {
  if (!dbPromise) {
    dbPromise = fetch(api.runtime.getURL('data/lens-prices.json'))
      .then(function (r) { return r.json(); });
  }
  return dbPromise;
}

var DEFAULT_SETTINGS = { badges: true, live: true };

function getSettings() {
  return new Promise(function (resolve) {
    api.storage.local.get({ settings: DEFAULT_SETTINGS }, function (res) {
      resolve(Object.assign({}, DEFAULT_SETTINGS, res.settings));
    });
  });
}

/* ---------------- live eBay sold-price lookup ---------------- */

function parseEbaySoldPrices(html) {
  // Sold-search result prices appear as <span class="s-item__price">$1,234.56</span>
  // (sometimes wrapping extra spans, sometimes "X to Y" ranges).
  var prices = [];
  var re = /class="s-item__price"[^>]*>([\s\S]{0,120}?)<\/(?:span|div)>/g;
  var m;
  while ((m = re.exec(html)) !== null && prices.length < 80) {
    var text = m[1].replace(/<[^>]*>/g, ' ');
    var pm = text.match(/\$\s*([\d,]+(?:\.\d{2})?)/);
    if (pm) {
      var v = parseFloat(pm[1].replace(/,/g, ''));
      if (v > 20 && v < 50000) prices.push(v);
    }
  }
  return prices;
}

function median(sorted) {
  var n = sorted.length;
  if (!n) return null;
  return n % 2 ? sorted[(n - 1) / 2] : Math.round((sorted[n / 2 - 1] + sorted[n / 2]) / 2);
}

function fetchEbaySold(query) {
  var url = 'https://www.ebay.com/sch/i.html?_nkw=' + encodeURIComponent(query) +
    '&LH_Sold=1&LH_Complete=1&LH_ItemCondition=3000&_ipg=60';
  var ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
  var timer = ctrl && setTimeout(function () { ctrl.abort(); }, 8000);

  return fetch(url, {
    signal: ctrl ? ctrl.signal : undefined,
    headers: { 'Accept': 'text/html' },
    credentials: 'omit'
  }).then(function (r) {
    if (!r.ok) throw new Error('eBay HTTP ' + r.status);
    return r.text();
  }).then(function (html) {
    if (timer) clearTimeout(timer);
    var prices = parseEbaySoldPrices(html);
    // The first tile is often a "Shop on eBay" placeholder — drop it.
    if (prices.length > 1) prices = prices.slice(1);
    if (prices.length < 3) throw new Error('too few sold listings parsed');
    prices.sort(function (a, b) { return a - b; });
    // Trim outliers (broken/for-parts at the bottom, kits at the top).
    var lo = Math.floor(prices.length * 0.2);
    var hi = Math.ceil(prices.length * 0.8);
    var core = prices.slice(lo, hi);
    return {
      median: Math.round(median(core)),
      low: Math.round(core[0]),
      high: Math.round(core[core.length - 1]),
      count: prices.length,
      ts: Date.now()
    };
  }).catch(function (err) {
    if (timer) clearTimeout(timer);
    throw err;
  });
}

function liveUsedPrice(query) {
  var key = 'live:' + query;
  return new Promise(function (resolve) {
    api.storage.local.get(key, function (res) {
      var cached = res[key];
      if (cached && Date.now() - cached.ts < LIVE_CACHE_TTL_MS) {
        return resolve(cached);
      }
      fetchEbaySold(query).then(function (data) {
        var record = {};
        record[key] = data;
        api.storage.local.set(record);
        resolve(data);
      }).catch(function (err) {
        resolve(cached || { error: String(err && err.message || err) });
      });
    });
  });
}

/* ---------------- message routing ---------------- */

function handleLookup(name) {
  return loadDb().then(function (db) {
    var result = self.LensMatch.match(name, db.lenses);
    var query = self.LensMatch.searchQuery(result ? result.entry : name);
    return {
      found: !!result,
      entry: result ? stripParsed(result.entry) : null,
      score: result ? result.score : 0,
      asOf: db.asOf,
      query: query,
      links: self.LensMatch.marketLinks(result ? result.entry : name)
    };
  });
}

function stripParsed(entry) {
  var copy = {};
  for (var k in entry) if (k !== '_parsed') copy[k] = entry[k];
  return copy;
}

function handleDbInfo() {
  return loadDb().then(function (db) {
    return { asOf: db.asOf, count: db.lenses.length, currency: db.currency };
  });
}

api.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
  if (!msg || !msg.type) return;

  if (msg.type === 'lens-lookup') {
    handleLookup(msg.name).then(sendResponse, function (e) {
      sendResponse({ found: false, error: String(e) });
    });
    return true;
  }

  if (msg.type === 'live-used') {
    getSettings().then(function (s) {
      if (!s.live) return { disabled: true };
      return liveUsedPrice(msg.query);
    }).then(sendResponse, function (e) {
      sendResponse({ error: String(e) });
    });
    return true;
  }

  if (msg.type === 'db-info') {
    handleDbInfo().then(sendResponse, function (e) {
      sendResponse({ error: String(e) });
    });
    return true;
  }

  if (msg.type === 'get-settings') {
    getSettings().then(sendResponse);
    return true;
  }

  if (msg.type === 'set-settings') {
    getSettings().then(function (s) {
      var next = Object.assign({}, s, msg.settings);
      api.storage.local.set({ settings: next }, function () { sendResponse(next); });
    });
    return true;
  }

  if (msg.type === 'scan-page') {
    var tabId = msg.tabId;
    Promise.resolve()
      .then(function () {
        return api.scripting.insertCSS({ target: { tabId: tabId }, files: ['content/content.css'] });
      })
      .then(function () {
        return api.scripting.executeScript({
          target: { tabId: tabId },
          files: ['lib/matcher.js', 'content/content.js']
        });
      })
      .then(function () { sendResponse({ ok: true }); },
            function (e) { sendResponse({ ok: false, error: String(e) }); });
    return true;
  }
});

/* ---------------- context menu ---------------- */

api.runtime.onInstalled.addListener(function () {
  if (!api.contextMenus) return;
  api.contextMenus.removeAll(function () {
    api.contextMenus.create({
      id: 'lpp-lookup',
      title: 'Look up lens price: "%s"',
      contexts: ['selection']
    });
  });
});

if (api.contextMenus && api.contextMenus.onClicked) {
  api.contextMenus.onClicked.addListener(function (info) {
    if (info.menuItemId !== 'lpp-lookup' || !info.selectionText) return;
    var url = api.runtime.getURL('popup/popup.html') +
      '?q=' + encodeURIComponent(info.selectionText.slice(0, 140)) + '&window=1';
    api.windows.create({ url: url, type: 'popup', width: 440, height: 640 });
  });
}
