/*
 * Lens Price Peek — shared lens-name parser & matcher.
 * Loaded by the background worker/event page, the content script, and the popup.
 */
(function (root) {
  'use strict';

  var BRAND_ALIASES = {
    fuji: 'fujifilm',
    rokinon: 'samyang',
    'om system': 'olympus'
  };

  var BRANDS = [
    'sony', 'canon', 'nikon', 'nikkor', 'sigma', 'tamron', 'fujifilm', 'fuji',
    'panasonic', 'lumix', 'olympus', 'om system', 'leica', 'zeiss', 'samyang',
    'rokinon', 'viltrox', 'laowa', 'tokina', 'pentax', 'hasselblad', 'irix', 'meike'
  ];

  // Tokens that meaningfully distinguish lens lines when focal/aperture tie.
  var SERIES_TOKENS = [
    'gm', 'art', 'contemporary', 'sports', 'rxd', 'vxd', 'osd', 'usd', 'vc',
    'usm', 'stm', 'oss', 'hsm', 'macro', 'micro', 'fisheye', 'pf', 'fl', 'dx',
    'pz', 'tc', 'sam', 'za', 'planar', 'sonnar', 'distagon'
  ];

  function normalize(s) {
    return String(s || '')
      .toLowerCase()
      .replace(/[–—]/g, '-') // en/em dashes
      .replace(/ƒ/g, 'f')          // ƒ
      .replace(/[®™]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  // Earliest brand mention wins ("Tamron 17-70 ... for Sony E" is a Tamron).
  function detectBrand(s) {
    var best = null, bestIdx = Infinity;
    for (var i = 0; i < BRANDS.length; i++) {
      var b = BRANDS[i];
      var m = s.match(new RegExp('(^|[^a-z])(' + b.replace(' ', '\\s+') + ')([^a-z]|$)'));
      if (m) {
        var idx = m.index + m[1].length;
        if (idx < bestIdx) { bestIdx = idx; best = b; }
      }
    }
    if (!best) return null;
    var canonical = best === 'nikkor' ? 'nikon' : best === 'lumix' ? 'panasonic' : best;
    return BRAND_ALIASES[canonical] || canonical;
  }

  // Max aperture: "f/2.8", "f2.8", "f/4.5-5.6". The leading guard keeps the
  // "f" of mount tokens like "RF 50mm" / "XF 35mm" from being read as an
  // aperture prefix. (Macro ratios like "M 1:2" are ignored too.)
  var APERTURE_RE = /(^|[^a-z])f\s*\/?\s*(\d{1,2}(?:\.\d)?)(?:\s*-\s*(\d{1,2}(?:\.\d)?))?/;

  function detectAperture(s) {
    var m = s.match(APERTURE_RE);
    if (!m) return null;
    return { from: parseFloat(m[2]), to: parseFloat(m[3] || m[2]) };
  }

  // Focal length: prefer "12-24mm" / "50mm"; fall back to bare "12-24" / "50"
  // for terse queries like "sony 24-105 f4". Aperture text is stripped first
  // so "f/4.5-6.3" is never read as a focal range.
  function detectFocal(s) {
    var m = s.match(/(\d{1,4}(?:\.\d)?)\s*-\s*(\d{1,4}(?:\.\d)?)\s*mm/);
    if (m) return { from: parseFloat(m[1]), to: parseFloat(m[2]) };
    m = s.match(/(\d{1,4}(?:\.\d)?)\s*mm/);
    if (m) return { from: parseFloat(m[1]), to: parseFloat(m[1]) };

    var bare = s.replace(APERTURE_RE, '$1 ');
    m = bare.match(/(^|\s)(\d{1,4})\s*-\s*(\d{1,4})(?=\s|$)/);
    if (m) return { from: parseFloat(m[2]), to: parseFloat(m[3]) };
    m = bare.match(/(^|\s)(\d{2,4})(?=\s|$)/);
    if (m) {
      var v = parseFloat(m[2]);
      if (v >= 8 && v <= 1600) return { from: v, to: v };
    }
    return null;
  }

  // Generation/version: "II", "III", "Mark 2", Tamron "G2".
  // Roman numerals directly after "Di"/"DG"/"DC" are series names, not versions.
  function detectVersion(s) {
    var m = s.match(/(?:^|\s)(?:mark|mk)\s*(\d|i{1,3}v?)(?=\s|$)/);
    var romans = { i: 1, ii: 2, iii: 3, iv: 4, v: 5 };
    if (m) return romans[m[1]] || parseInt(m[1], 10) || 1;
    if (/(^|\s)g2(\s|$)/.test(s)) return 2; // Tamron G2 line
    var re = /(^|\s)(ii|iii|iv)(?=[\s,)]|$)/g, best = null, r;
    while ((r = re.exec(s)) !== null) {
      var before = s.slice(0, r.index).trim().split(/\s+/).pop();
      if (before === 'di' || before === 'dg' || before === 'dc') continue;
      best = romans[r[2]];
    }
    return best || 1;
  }

  // Explicit mount mentions in the text ("RF", "FE", "Sony E", "Z mount"...).
  function detectMounts(s) {
    var mounts = [];
    if (/(^|\s)rf(-s)?(\s|$)/.test(s)) mounts.push('canon rf');
    if (/(^|\s)ef-s(\s|$)/.test(s)) mounts.push('canon ef-s');
    else if (/(^|\s)ef(\s|$)/.test(s)) mounts.push('canon ef');
    if (/(^|\s)fe(\s|$)/.test(s) || /sony\s*e\b/.test(s) || /e[\s-]?mount/.test(s)) mounts.push('sony e');
    if (/nikon|nikkor/.test(s) && (/(^|\s)z(\s|$)/.test(s) || /(^|\s)z\s?\d/.test(s) || /z[\s-]?mount/.test(s))) mounts.push('nikon z');
    if (/(^|\s)af-[sp](\s|$)/.test(s) || /f[\s-]?mount/.test(s)) mounts.push('nikon f');
    if (/(^|\s)xf?\s?\d|fujifilm x|x[\s-]?mount/.test(s) && /fuji/.test(s)) mounts.push('fujifilm x');
    return mounts;
  }

  function seriesTokens(s) {
    var found = [];
    for (var i = 0; i < SERIES_TOKENS.length; i++) {
      if (new RegExp('(^|[^a-z])' + SERIES_TOKENS[i] + '([^a-z]|$)').test(s)) {
        found.push(SERIES_TOKENS[i]);
      }
    }
    return found;
  }

  function parse(name) {
    var s = normalize(name);
    return {
      raw: s,
      brand: detectBrand(s),
      focal: detectFocal(s),
      aperture: detectAperture(s),
      version: detectVersion(s),
      mounts: detectMounts(s),
      tokens: seriesTokens(s)
    };
  }

  // Quick pre-filter: does this text plausibly name a lens?
  function looksLikeLens(text) {
    var s = normalize(text);
    if (s.length < 8 || s.length > 140) return false;
    if (!/\d{1,4}\s*(?:-\s*\d{1,4}\s*)?mm/.test(s)) return false;
    if (!/f\s*\/?\s*\d/.test(s)) return false;
    return detectBrand(s) !== null || /\blens\b/.test(s);
  }

  function apertureEqual(a, b) {
    if (!a || !b) return false;
    return Math.abs(a.from - b.from) < 0.05;
  }

  function focalEqual(a, b) {
    if (!a || !b) return false;
    return Math.abs(a.from - b.from) < 0.05 && Math.abs(a.to - b.to) < 0.05;
  }

  /*
   * Match a free-text lens name against database entries.
   * Hard constraints: brand, exact focal, max aperture, version, explicit mount.
   * Soft score: shared series tokens (GM vs plain, Art vs Contemporary...).
   * Returns { entry, score } or null.
   */
  function match(name, entries) {
    var q = parse(name);
    if (!q.focal) return null;
    var best = null, bestScore = -1;

    for (var i = 0; i < entries.length; i++) {
      var e = entries[i];
      if (!e._parsed) e._parsed = parse(e.model);
      var p = e._parsed;

      if (q.brand && p.brand && q.brand !== p.brand) continue;
      if (!focalEqual(q.focal, p.focal)) continue;
      if (q.aperture && p.aperture && !apertureEqual(q.aperture, p.aperture)) continue;
      if (q.version !== p.version) continue;

      if (q.mounts.length && e.mounts && e.mounts.length) {
        var entryMounts = e.mounts.map(function (m) { return normalize(m); });
        var overlap = q.mounts.some(function (m) { return entryMounts.indexOf(m) !== -1; });
        if (!overlap) continue;
      }

      var score = 100;
      if (q.brand && p.brand && q.brand === p.brand) score += 20;
      if (q.aperture && p.aperture) score += 10;
      for (var t = 0; t < p.tokens.length; t++) {
        if (q.tokens.indexOf(p.tokens[t]) !== -1) score += 5;
        else score -= 2; // entry claims a series the query doesn't mention
      }
      for (var u = 0; u < q.tokens.length; u++) {
        if (p.tokens.indexOf(q.tokens[u]) === -1) score -= 2;
      }

      if (score > bestScore) { bestScore = score; best = e; }
    }

    return best ? { entry: best, score: bestScore } : null;
  }

  // A concise search query for marketplace links / eBay sold lookups.
  function searchQuery(entryOrName) {
    var name = typeof entryOrName === 'string' ? entryOrName : entryOrName.model;
    return normalize(name)
      .replace(/\(.*?\)/g, ' ')
      .replace(/\blens\b/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function marketLinks(entryOrName) {
    var q = encodeURIComponent(searchQuery(entryOrName));
    return {
      ebaySold: 'https://www.ebay.com/sch/i.html?_nkw=' + q + '&LH_Sold=1&LH_Complete=1',
      mpb: 'https://www.mpb.com/en-us/search?q=' + q,
      keh: 'https://www.keh.com/shop/catalogsearch/result/?q=' + q,
      bh: 'https://www.bhphotovideo.com/c/search?q=' + q
    };
  }

  root.LensMatch = {
    parse: parse,
    match: match,
    looksLikeLens: looksLikeLens,
    normalize: normalize,
    searchQuery: searchQuery,
    marketLinks: marketLinks
  };
})(typeof self !== 'undefined' ? self : this);
