/*
 * Builds data/lens-prices.json from researched pricing JSON.
 * Usage: node scripts/build-db.mjs <research.json>
 * where research.json = { asOf, lenses: [{ model, brand, mounts,
 *   new_price_usd, used_price_low_usd, used_price_high_usd, discontinued, notes, sources }] }
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = process.argv[2];
if (!src) { console.error('usage: node scripts/build-db.mjs <research.json>'); process.exit(1); }

const input = JSON.parse(readFileSync(src, 'utf8'));

function slug(model) {
  return model.toLowerCase()
    .replace(/\(.*?\)/g, ' ')
    .replace(/[^a-z0-9.]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
}

const seen = new Set();
const lenses = [];
const problems = [];

for (const l of input.lenses || []) {
  const id = slug(l.model);
  if (seen.has(id)) { problems.push(`duplicate: ${l.model}`); continue; }
  seen.add(id);

  const nw = l.new_price_usd == null ? null : Math.round(l.new_price_usd);
  let lo = Math.round(l.used_price_low_usd);
  let hi = Math.round(l.used_price_high_usd);
  if (!(lo > 0 && hi > 0)) { problems.push(`bad used range: ${l.model}`); continue; }
  if (lo > hi) [lo, hi] = [hi, lo];
  if (nw != null && lo > nw) problems.push(`warn: used low > new for ${l.model}`);

  lenses.push({
    id,
    brand: l.brand,
    model: l.model.replace(/\s*\([^)]*\)/g, '').replace(/\s+/g, ' ').trim(),
    mounts: l.mounts,
    new: nw,
    usedLow: lo,
    usedHigh: hi,
    discontinued: !!l.discontinued,
    notes: l.notes || '',
    sources: (l.sources || []).slice(0, 4)
  });
}

lenses.sort((a, b) => a.brand.localeCompare(b.brand) || a.model.localeCompare(b.model));

const out = {
  asOf: input.asOf,
  currency: 'USD',
  note: 'Street/new prices from major US retailers; used ranges from MPB/KEH/eBay sold listings. Estimates only.',
  lenses
};

writeFileSync(join(here, '..', 'data', 'lens-prices.json'), JSON.stringify(out, null, 2) + '\n');
console.log(`wrote ${lenses.length} lenses (asOf ${input.asOf})`);
if (problems.length) console.log('issues:\n  ' + problems.join('\n  '));
