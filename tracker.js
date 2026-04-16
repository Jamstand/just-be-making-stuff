'use strict';

const axios = require('axios');

// ── Config ────────────────────────────────────────────────────────────────────

const COINS = [
  { id: 'bitcoin',  symbol: 'BTC', name: 'Bitcoin' },
  { id: 'ethereum', symbol: 'ETH', name: 'Ethereum' },
];

const RSI_PERIOD      = 14;
const SMA_SHORT       = 50;
const SMA_LONG        = 200;
const VOL_LOOKBACK    = 20;
const TREND_LOOKBACK  = 30;
const PULL_THRESHOLD  = 0.05;   // within 5% of 50MA counts as "near support"
const RSI_ENTRY_LOW   = 35;
const RSI_ENTRY_HIGH  = 55;
const RISK_PCT        = 0.02;   // 2% account risk per trade
const REWARD_RATIO    = 2;      // 2:1 reward:risk
const ACCOUNT_SIZES   = [500, 1000];

// ── API ───────────────────────────────────────────────────────────────────────

async function fetchChart(coinId) {
  const { data } = await axios.get(
    `https://api.coingecko.com/api/v3/coins/${coinId}/market_chart`,
    {
      params:  { vs_currency: 'usd', days: 250, interval: 'daily' },
      timeout: 20000,
      headers: { accept: 'application/json' },
    }
  );
  return {
    prices:  data.prices.map(p => p[1]),
    volumes: data.total_volumes.map(v => v[1]),
  };
}

// ── Indicators ────────────────────────────────────────────────────────────────

function sma(arr, period) {
  if (arr.length < period) return null;
  const slice = arr.slice(-period);
  return slice.reduce((s, v) => s + v, 0) / period;
}

// Wilder's smoothed RSI — returns current RSI value only
function calcRSI(prices, period = RSI_PERIOD) {
  if (prices.length < period + 1) return null;

  const deltas = [];
  for (let i = 1; i < prices.length; i++) deltas.push(prices[i] - prices[i - 1]);

  // Seed: simple average of first `period` deltas
  let avgGain = 0, avgLoss = 0;
  for (let i = 0; i < period; i++) {
    if (deltas[i] > 0) avgGain += deltas[i];
    else               avgLoss += Math.abs(deltas[i]);
  }
  avgGain /= period;
  avgLoss /= period;

  // Smooth through remaining deltas
  for (let i = period; i < deltas.length; i++) {
    const gain = deltas[i] > 0 ? deltas[i] : 0;
    const loss = deltas[i] < 0 ? Math.abs(deltas[i]) : 0;
    avgGain = (avgGain * (period - 1) + gain) / period;
    avgLoss = (avgLoss * (period - 1) + loss) / period;
  }

  if (avgLoss === 0) return 100;
  return 100 - 100 / (1 + avgGain / avgLoss);
}

function detectTrend(prices, n = TREND_LOOKBACK) {
  const slice = prices.slice(-n);
  const mid   = Math.floor(slice.length / 2);
  const first = slice.slice(0, mid);
  const last  = slice.slice(mid);
  const hh = Math.max(...last) > Math.max(...first);
  const hl = Math.min(...last) > Math.min(...first);
  if (hh && hl)   return 'UPTREND';
  if (!hh && !hl) return 'DOWNTREND';
  return 'SIDEWAYS';
}

// 10th-percentile of recent lows as a support proxy
function supportLevel(prices, n = 30) {
  const sorted = [...prices.slice(-n)].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length * 0.10)];
}

function volRatio(volumes, n = VOL_LOOKBACK) {
  const slice = volumes.slice(-n);
  const avg   = slice.reduce((s, v) => s + v, 0) / n;
  return volumes[volumes.length - 1] / avg;
}

// ── Analysis ──────────────────────────────────────────────────────────────────

function analyze({ prices, volumes }) {
  const cur  = prices[prices.length - 1];
  const prev = prices[prices.length - 2];

  const ma50  = sma(prices, SMA_SHORT);
  const ma200 = sma(prices, SMA_LONG);
  const rsi   = calcRSI(prices);
  const trend = detectTrend(prices);
  const sup   = supportLevel(prices);
  const vr    = volRatio(volumes);

  const distFromMA50 = ma50 ? (cur - ma50) / ma50 : null;
  const nearMA50     = distFromMA50 !== null && Math.abs(distFromMA50) < PULL_THRESHOLD;
  const nearSup      = sup != null && cur >= sup * 0.97 && cur <= sup * 1.08;

  return { cur, prev, dayPct: (cur - prev) / prev * 100,
           ma50, ma200, rsi, trend, sup, vr,
           distFromMA50, nearMA50, nearSup };
}

function buildScore(a) {
  const criteria = [];
  let pts = 0;

  // 1. Long-term bull market (above 200MA)
  const c1 = a.ma200 !== null && a.cur > a.ma200;
  criteria.push({ label: 'Above 200-day MA (long-term bull market)',
    met: c1, note: a.ma200 ? `$${f(a.cur)} vs $${f(a.ma200)}` : 'n/a' });
  if (c1) pts++;

  // 2. Short-term uptrend
  const c2 = a.trend === 'UPTREND';
  criteria.push({ label: 'Uptrend (higher highs & higher lows)', met: c2, note: a.trend });
  if (c2) pts++;

  // 3. Pullback to 50MA or support
  const c3 = a.nearMA50 || a.nearSup;
  const nearNote = a.distFromMA50 !== null
    ? `${(a.distFromMA50 * 100 >= 0 ? '+' : '')}${(a.distFromMA50 * 100).toFixed(1)}% from 50MA`
    : 'n/a';
  criteria.push({ label: 'Pulled back to 50-day MA / support',
    met: c3, note: nearNote });
  if (c3) pts++;

  // 4. RSI in entry zone
  const c4 = a.rsi !== null && a.rsi >= RSI_ENTRY_LOW && a.rsi <= RSI_ENTRY_HIGH;
  criteria.push({ label: `RSI in entry zone (${RSI_ENTRY_LOW}–${RSI_ENTRY_HIGH})`,
    met: c4, note: a.rsi !== null ? `RSI ${a.rsi.toFixed(1)}` : 'n/a' });
  if (c4) pts++;

  // 5. Volume above 20-day average
  const c5 = a.vr > 1.0;
  criteria.push({ label: 'Volume above 20-day average',
    met: c5, note: `${(a.vr * 100).toFixed(0)}% of avg` });
  if (c5) pts++;

  const labels = ['DO NOT TRADE', 'DO NOT TRADE', 'WAIT', 'WATCH', 'BUY', 'STRONG BUY'];
  return { signal: labels[pts], pts, total: 5, criteria };
}

function tradeSetup(a) {
  // Suggest entry near the 50MA if it represents a pullback, otherwise current price
  const entry    = a.ma50 && a.ma50 < a.cur ? a.ma50 * 1.005 : a.cur;
  const stop     = a.sup
    ? Math.min(a.sup * 0.97, entry * 0.965)
    : entry * 0.965;
  const riskPct  = (entry - stop) / entry;
  const target   = entry + (entry - stop) * REWARD_RATIO;
  const profitPct = (target - entry) / entry;

  const sizing = ACCOUNT_SIZES.map(account => {
    const riskUSD  = account * RISK_PCT;
    const units    = riskUSD / (entry - stop);
    return { account, riskUSD, investUSD: units * entry };
  });

  return { entry, stop, target, riskPct, profitPct, sizing };
}

// ── Formatting ────────────────────────────────────────────────────────────────

const W = 62;
const f = n => n >= 1000
  ? n.toLocaleString('en-US', { maximumFractionDigits: 0 })
  : n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

const line  = (ch = '─') => ch.repeat(W);
const col   = (label, val) => `  ${label.padEnd(20)}${val}`;
const check = met => met ? '[YES]' : '[NO] ';

function printCoin(coin, a, s, setup) {
  const sign  = a.dayPct >= 0 ? '+' : '';
  const rsiNote = a.rsi === null ? 'n/a'
    : a.rsi < 30 ? '(oversold)'
    : a.rsi > 70 ? '(overbought)'
    : a.rsi >= RSI_ENTRY_LOW && a.rsi <= RSI_ENTRY_HIGH ? '(entry zone ✓)'
    : '(neutral)';

  const signalStr = {
    'STRONG BUY':  '*** STRONG BUY — all conditions met',
    'BUY':         '**  BUY — strong setup',
    'WATCH':       '*   WATCH — setup forming',
    'WAIT':        '    WAIT — not ready yet',
    'DO NOT TRADE':'    DO NOT TRADE',
  }[s.signal];

  console.log();
  console.log(line('─'));
  console.log(`  ${coin.name} (${coin.symbol})    $${f(a.cur)}   ${sign}${a.dayPct.toFixed(2)}% today`);
  console.log(line('─'));

  console.log();
  console.log('  INDICATORS');
  console.log(col('200-day MA:',
    a.ma200 ? `$${f(a.ma200)}   ${a.cur > a.ma200 ? '↑ above (bull market)' : '↓ below (bear market)'}` : 'n/a'));
  console.log(col('50-day MA:',
    a.ma50  ? `$${f(a.ma50)}   (${a.distFromMA50 !== null ? (a.distFromMA50 >= 0 ? '+' : '') + (a.distFromMA50 * 100).toFixed(1) + '% from price' : 'n/a'})` : 'n/a'));
  console.log(col('RSI (14):',
    a.rsi !== null ? `${a.rsi.toFixed(1)}   ${rsiNote}` : 'n/a'));
  console.log(col('Volume:', `${(a.vr * 100).toFixed(0)}% of 20-day avg`));
  console.log(col('Trend:', a.trend));
  console.log(col('Support level:', a.sup
    ? `$${f(a.sup)}   (${((a.cur - a.sup) / a.cur * 100).toFixed(1)}% below current)`
    : 'n/a'));

  console.log();
  console.log('  SIGNAL CRITERIA');
  s.criteria.forEach(c => {
    console.log(`  ${check(c.met)} ${c.label.padEnd(44)} ${c.note}`);
  });

  console.log();
  console.log(`  Score: ${s.pts}/${s.total}   |   Signal: ${signalStr}`);

  if (s.pts >= 3) {
    console.log();
    console.log(`  SUGGESTED TRADE SETUP  (${(RISK_PCT * 100).toFixed(0)}% account risk · ${REWARD_RATIO}:1 reward/risk)`);
    console.log(col('Entry zone:',   `$${f(setup.entry)}`));
    console.log(col('Stop loss:',    `$${f(setup.stop)}   (${(setup.riskPct * 100).toFixed(1)}% below entry)`));
    console.log(col('Take profit:',  `$${f(setup.target)}   (${(setup.profitPct * 100).toFixed(1)}% gain)`));
    console.log();
    setup.sizing.forEach(({ account, riskUSD, investUSD }) => {
      console.log(`  $${account} account  →  invest $${investUSD.toFixed(2)}  |  risk $${riskUSD.toFixed(2)}`);
    });
  } else {
    console.log();
    console.log('  No trade setup — wait for more conditions to align.');
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  console.log();
  console.log(line('═'));
  console.log('  CRYPTO SWING TRADE SCANNER');
  console.log(`  ${new Date().toUTCString()}`);
  console.log(line('═'));

  for (let i = 0; i < COINS.length; i++) {
    const coin = COINS[i];
    try {
      process.stdout.write(`  Fetching ${coin.name} data from CoinGecko...`);
      const data  = await fetchChart(coin.id);
      console.log(' done');
      const a     = analyze(data);
      const s     = buildScore(a);
      const setup = tradeSetup(a);
      printCoin(coin, a, s, setup);
    } catch (err) {
      console.log();
      console.error(`  Error fetching ${coin.name}: ${err.message}`);
    }

    // Rate-limit buffer between requests
    if (i < COINS.length - 1) await new Promise(r => setTimeout(r, 1200));
  }

  console.log();
  console.log(line('─'));
  console.log('  Data: CoinGecko. Educational use only — not financial advice.');
  console.log(line('─'));
  console.log();
}

main().catch(err => { console.error(err.message); process.exit(1); });
