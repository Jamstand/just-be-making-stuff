/* Lens Price Peek — popup / lookup window */
(function () {
  'use strict';

  var api = typeof browser !== 'undefined' ? browser : chrome;

  var $q = document.getElementById('q');
  var $result = document.getElementById('result');
  var $scan = document.getElementById('scan');
  var $scanMsg = document.getElementById('scan-msg');
  var $badges = document.getElementById('opt-badges');
  var $live = document.getElementById('opt-live');
  var $foot = document.getElementById('foot');

  function send(msg) {
    return new Promise(function (resolve) {
      api.runtime.sendMessage(msg, function (res) {
        void api.runtime.lastError;
        resolve(res);
      });
    });
  }

  function fmt(n) {
    if (n === null || n === undefined) return null;
    return '$' + Math.round(n).toLocaleString('en-US');
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------- search ---------- */

  var searchTimer = null;
  var searchSeq = 0;

  $q.addEventListener('input', function () {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(runSearch, 250);
  });

  function runSearch() {
    var name = $q.value.trim();
    var seq = ++searchSeq;
    if (name.length < 4) { $result.hidden = true; return; }

    send({ type: 'lens-lookup', name: name }).then(function (res) {
      if (seq !== searchSeq || !res) return;
      renderResult(name, res, seq);
    });
  }

  function renderResult(name, res, seq) {
    var html = '';
    var links = res.links || {};

    if (res.found) {
      var e = res.entry;
      html += '<div class="title">' + escapeHtml(e.model) + '</div>';
      html += '<div class="row"><span>New (street)</span><b>' +
        (e.new != null ? fmt(e.new) : 'discontinued') + '</b></div>';
      html += '<div class="row"><span>Used (typical)</span><b>' +
        fmt(e.usedLow) + ' – ' + fmt(e.usedHigh) + '</b></div>';
      html += '<div class="row live-row" hidden><span>eBay sold, recent</span><b></b></div>';
      if (e.notes) html += '<div class="note">' + escapeHtml(e.notes) + '</div>';
    } else {
      html += '<div class="title">' + escapeHtml(name) + '</div>';
      html += '<div class="note">Not in the bundled price list (try a fuller name, e.g. brand + focal length + aperture). Marketplace links below still work.</div>';
    }

    html += '<div class="links">' +
      '<a target="_blank" rel="noopener" href="' + links.ebaySold + '">eBay sold ↗</a>' +
      '<a target="_blank" rel="noopener" href="' + links.mpb + '">MPB ↗</a>' +
      '<a target="_blank" rel="noopener" href="' + links.keh + '">KEH ↗</a>' +
      '<a target="_blank" rel="noopener" href="' + links.bh + '">B&amp;H new ↗</a>' +
      '</div>';
    html += '<div class="live-status"></div>';

    $result.innerHTML = html;
    $result.hidden = false;

    var $status = $result.querySelector('.live-status');
    var $liveRow = $result.querySelector('.live-row');

    if (res.query) {
      $status.textContent = 'Checking recent eBay sold prices…';
      send({ type: 'live-used', query: res.query }).then(function (live) {
        if (seq !== searchSeq) return;
        if (!live || live.disabled) { $status.textContent = ''; return; }
        if (live.error || !live.median) {
          $status.textContent = 'Live eBay lookup unavailable right now.';
          return;
        }
        $status.textContent = '';
        if ($liveRow) {
          $liveRow.hidden = false;
          $liveRow.querySelector('b').innerHTML =
            fmt(live.low) + ' – ' + fmt(live.high) + ' <span class="med">med ' + fmt(live.median) + '</span>';
        } else {
          $status.textContent = 'Recent eBay sold: ' + fmt(live.low) + '–' + fmt(live.high) +
            ' (median ' + fmt(live.median) + ', ' + live.count + ' sales)';
        }
      });
    }
  }

  /* ---------- scan this page ---------- */

  $scan.addEventListener('click', function () {
    $scanMsg.textContent = 'Scanning…';
    api.tabs.query({ active: true, currentWindow: true }, function (tabs) {
      var tab = tabs && tabs[0];
      if (!tab || !tab.id || /^(chrome|about|edge|moz-extension|chrome-extension):/.test(tab.url || '')) {
        $scanMsg.textContent = 'Cannot scan this page.';
        return;
      }
      send({ type: 'scan-page', tabId: tab.id }).then(function (res) {
        $scanMsg.textContent = res && res.ok
          ? 'Done — lens badges added where lenses were found.'
          : 'Scan failed: ' + (res && res.error || 'unknown error');
      });
    });
  });

  /* ---------- settings ---------- */

  send({ type: 'get-settings' }).then(function (s) {
    if (!s) return;
    $badges.checked = !!s.badges;
    $live.checked = !!s.live;
  });

  function pushSettings() {
    send({
      type: 'set-settings',
      settings: { badges: $badges.checked, live: $live.checked }
    });
  }
  $badges.addEventListener('change', pushSettings);
  $live.addEventListener('change', pushSettings);

  /* ---------- footer + deep-link query ---------- */

  send({ type: 'db-info' }).then(function (info) {
    if (info && info.count) {
      $foot.textContent = info.count + ' lenses in price guide · USD · updated ' + info.asOf +
        ' · prices are estimates, not offers';
    } else {
      $foot.textContent = 'Price data unavailable.';
    }
  });

  var params = new URLSearchParams(location.search);
  var q = params.get('q');
  if (q) {
    $q.value = q;
    runSearch();
  }
})();
