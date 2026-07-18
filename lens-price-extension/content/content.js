/*
 * Lens Price Peek — content script.
 * Finds anything on the page that reads like a lens name ("Sony FE 24-70mm
 * f/2.8 GM Lens"...) and pins a New/Used market-price badge under it.
 * Selector-free by design: rental sites change their markup, lens names don't.
 */
(function () {
  'use strict';

  if (window.__lensPricePeekLoaded) { window.__lensPricePeekRescan && window.__lensPricePeekRescan(); return; }
  window.__lensPricePeekLoaded = true;

  // chrome.* (also provided by Firefox) supports the callback style used here.
  var api = typeof chrome !== 'undefined' && chrome.runtime ? chrome : browser;
  var LM = window.LensMatch;
  if (!LM) return;

  var processed = new WeakSet();
  var settings = { badges: true, live: true };

  function send(msg) {
    return new Promise(function (resolve) {
      try {
        api.runtime.sendMessage(msg, function (res) {
          void api.runtime.lastError; // swallow "receiving end does not exist"
          resolve(res);
        });
      } catch (e) { resolve(null); }
    });
  }

  function fmt(n) {
    if (n === null || n === undefined) return null;
    return '$' + Math.round(n).toLocaleString('en-US');
  }

  /* ---------- find candidate title elements ---------- */

  function findCandidates(rootNode) {
    var out = [];
    var walker = document.createTreeWalker(rootNode || document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        var t = node.nodeValue;
        if (!t || t.length < 8 || t.length > 160) return NodeFilter.FILTER_REJECT;
        if (!/\d\s*mm/i.test(t) || !/f\s*\/?\s*\d/i.test(t)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var node;
    while ((node = walker.nextNode())) {
      var el = node.parentElement;
      if (!el || processed.has(el)) continue;
      var tag = el.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEXTAREA' || tag === 'INPUT') continue;
      if (el.closest('.lpp-badge, .lpp-popover')) continue;
      var text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
      if (!LM.looksLikeLens(text)) continue;
      processed.add(el);
      out.push({ el: el, name: text });
    }
    return out;
  }

  /* ---------- badge rendering ---------- */

  function makeBadge(candidate, res) {
    var badge = document.createElement('div');
    badge.className = 'lpp-badge' + (res.found ? '' : ' lpp-badge--unknown');

    var entry = res.entry;
    var html = '<span class="lpp-logo" title="Lens Price Peek">◉</span>';

    if (res.found) {
      var newTxt = entry.discontinued || entry.new == null
        ? '<span class="lpp-muted">discontinued</span>'
        : '<b>' + fmt(entry.new) + '</b>';
      html += '<span class="lpp-part">New ' + newTxt + '</span>';
      html += '<span class="lpp-sep">·</span>';
      html += '<span class="lpp-part lpp-used">Used <b>' + fmt(entry.usedLow) + '–' + fmt(entry.usedHigh) + '</b></span>';
    } else {
      html += '<span class="lpp-part lpp-muted">Market price</span>';
    }
    html += '<span class="lpp-live" hidden></span>';
    html += '<button class="lpp-more" type="button" title="Details & marketplace links">ⓘ</button>';
    badge.innerHTML = html;

    badge.addEventListener('click', function (ev) {
      // Cards are usually wrapped in one big <a>; keep clicks on the badge local.
      ev.preventDefault();
      ev.stopPropagation();
      togglePopover(badge, candidate, res);
    });

    return badge;
  }

  function updateBadgeLive(badge, live) {
    if (!live || live.error || live.disabled || !live.median) return;
    var el = badge.querySelector('.lpp-live');
    if (!el) return;
    el.hidden = false;
    el.innerHTML = '<span class="lpp-sep">·</span>eBay sold <b>' + fmt(live.median) + '</b>';
    badge.__live = live;
  }

  /* ---------- details popover ---------- */

  var popover = null;

  function closePopover() {
    if (popover) { popover.remove(); popover = null; }
  }

  document.addEventListener('click', function (e) {
    if (popover && !popover.contains(e.target) && !e.target.closest('.lpp-badge')) closePopover();
  }, true);

  function togglePopover(badge, candidate, res) {
    if (popover && popover.__for === badge) { closePopover(); return; }
    closePopover();

    var entry = res.entry;
    var live = badge.__live;
    var p = document.createElement('div');
    p.className = 'lpp-popover';
    p.__for = badge;

    var rows = '';
    if (res.found) {
      rows += '<div class="lpp-row"><span>New (street)</span><b>' +
        (entry.new != null ? fmt(entry.new) : 'discontinued') + '</b></div>';
      rows += '<div class="lpp-row"><span>Used (typical)</span><b>' +
        fmt(entry.usedLow) + ' – ' + fmt(entry.usedHigh) + '</b></div>';
      if (live && live.median) {
        rows += '<div class="lpp-row"><span>eBay sold, recent (' + live.count + ' sales)</span><b>' +
          fmt(live.low) + ' – ' + fmt(live.high) + ' <span class="lpp-median">med ' + fmt(live.median) + '</span></b></div>';
      }
      if (entry.notes) rows += '<div class="lpp-note">' + escapeHtml(entry.notes) + '</div>';
    } else {
      rows += '<div class="lpp-note">Not in the bundled price list — check the marketplaces below.</div>';
    }

    var links = res.links || {};
    var linkHtml = [
      ['eBay sold', links.ebaySold],
      ['MPB', links.mpb],
      ['KEH', links.keh],
      ['B&H new', links.bh]
    ].map(function (l) {
      return '<a href="' + l[1] + '" target="_blank" rel="noopener noreferrer">' + l[0] + ' ↗</a>';
    }).join('');

    p.innerHTML =
      '<div class="lpp-pop-title">' + escapeHtml(res.found ? entry.model : candidate.name) + '</div>' +
      rows +
      '<div class="lpp-links">' + linkHtml + '</div>' +
      '<div class="lpp-foot">USD · price guide as of ' + escapeHtml(res.asOf || '?') + ' · not an offer to buy/sell</div>';

    p.addEventListener('click', function (ev) { ev.stopPropagation(); });

    document.body.appendChild(p);
    var r = badge.getBoundingClientRect();
    var top = r.bottom + window.scrollY + 6;
    var left = Math.max(8, Math.min(r.left + window.scrollX, window.scrollX + document.documentElement.clientWidth - 328));
    p.style.top = top + 'px';
    p.style.left = left + 'px';
    popover = p;
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------- pipeline ---------- */

  function processCandidate(candidate) {
    send({ type: 'lens-lookup', name: candidate.name }).then(function (res) {
      if (!res) return;
      var badge = makeBadge(candidate, res);
      candidate.el.insertAdjacentElement('afterend', badge);

      if (settings.live && res.query) {
        send({ type: 'live-used', query: res.query }).then(function (live) {
          updateBadgeLive(badge, live);
        });
      }
    });
  }

  var scanScheduled = false;
  function scan() {
    if (!settings.badges) return;
    var candidates = findCandidates(document.body);
    for (var i = 0; i < candidates.length; i++) processCandidate(candidates[i]);
  }

  function scheduleScan() {
    if (scanScheduled) return;
    scanScheduled = true;
    setTimeout(function () { scanScheduled = false; scan(); }, 500);
  }

  window.__lensPricePeekRescan = scheduleScan;

  function removeAllBadges() {
    document.querySelectorAll('.lpp-badge').forEach(function (b) { b.remove(); });
    closePopover();
    processed = new WeakSet();
  }

  api.storage.onChanged.addListener(function (changes, area) {
    if (area !== 'local' || !changes.settings) return;
    var next = changes.settings.newValue || {};
    var wasOn = settings.badges;
    settings = Object.assign({}, settings, next);
    if (wasOn && !settings.badges) removeAllBadges();
    else if (!wasOn && settings.badges) scheduleScan();
  });

  send({ type: 'get-settings' }).then(function (s) {
    if (s) settings = Object.assign(settings, s);
    scan();
    new MutationObserver(function (muts) {
      for (var i = 0; i < muts.length; i++) {
        if (muts[i].addedNodes && muts[i].addedNodes.length) { scheduleScan(); return; }
      }
    }).observe(document.body, { childList: true, subtree: true });
  });
})();
