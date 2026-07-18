/* Unit tests for lib/matcher.js — run: node test/matcher.test.mjs */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const sandbox = { self: {} };
vm.createContext(sandbox);
vm.runInContext(readFileSync(join(here, '..', 'lib', 'matcher.js'), 'utf8'), sandbox);
const LM = sandbox.self.LensMatch;

const db = JSON.parse(readFileSync(join(here, '..', 'data', 'lens-prices.json'), 'utf8'));

let pass = 0, fail = 0;
function expectMatch(query, expectedIdPart) {
  const res = LM.match(query, db.lenses);
  const got = res ? res.entry.id : null;
  const ok = expectedIdPart === null ? got === null : got !== null && got.includes(expectedIdPart);
  if (ok) { pass++; }
  else { fail++; console.error(`FAIL: "${query}" -> ${got} (expected ${expectedIdPart})`); }
}

// The exact titles from the Helix Rentals screenshot
expectMatch('Sigma 16mm f/1.4 DC DN Contemporary Lens (Sony E)', 'sigma-16');
expectMatch('Sony FE 12-24mm f/2.8 GM Lens', '12-24');
expectMatch('Sony FE 24-70mm f/2.8 GM Lens', '24-70');
expectMatch('Sony FE 24-105mm f/4 G OSS Lens', '24-105');
expectMatch('Sony FE 50mm f/1.4 GM Lens', '50');
expectMatch('Tamron 11-20mm f/2.8 Di III-A RXD Lens (Sony E)', '11-20');
expectMatch('Tamron 17-70mm f/2.8 Di III-A VC RXD Lens for Sony E', '17-70');
expectMatch('Tamron 18-300mm f/3.5-6.3 Di III-A VC VXD Lens for Sony E', '18-300');
expectMatch('Tamron 35mm f/2.8 Di III OSD M 1:2 Lens for Sony E', '35');
expectMatch('Tamron 70-300mm f/4.5-6.3 Di III RXD Lens for Sony E', '70-300');
expectMatch('Tamron 150-500mm f/5-6.7 Di III VC VXD Lens (Sony E)', '150-500');

// Sloppy user queries
expectMatch('sony 24-105 f4', '24-105');
expectMatch('tamron 150-500', '150-500');

// Must NOT cross-match
expectMatch('Sony FE 24-70mm f/2.8 GM II Lens', null); // version II not in provisional DB
expectMatch('Canon RF 999mm f/9.9', null);

// looksLikeLens heuristics
const yes = [
  'Sony FE 24-70mm f/2.8 GM Lens',
  'Tamron 150-500mm f/5-6.7 Di III VC VXD Lens (Sony E)',
];
const no = [
  '$35 day, $55 3-day, $125 week',
  'Pitman Photo Supply',
  '50mm of rain fell', // no aperture
];
for (const t of yes) { if (LM.looksLikeLens(t)) pass++; else { fail++; console.error(`FAIL looksLikeLens(yes): ${t}`); } }
for (const t of no) { if (!LM.looksLikeLens(t)) pass++; else { fail++; console.error(`FAIL looksLikeLens(no): ${t}`); } }

console.log(`matcher tests: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
