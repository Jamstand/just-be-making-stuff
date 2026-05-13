require('dotenv').config();
const express = require('express');
const axios = require('axios');
const cors = require('cors');
const fs = require('fs');
const path = require('path');
const { Configuration, PlaidApi, PlaidEnvironments, Products, CountryCode } = require('plaid');
const Anthropic = require('@anthropic-ai/sdk');
const { spawn } = require('child_process');
const os = require('os');
const crypto = require('crypto');

const app = express();
const PORT = process.env.PORT || 3000;
const TOKEN_FILE = path.join(__dirname, '.tokens.json');
const PLAID_TOKEN_FILE = path.join(__dirname, '.plaid-tokens.json');

app.use(cors({ origin: process.env.ALLOWED_ORIGIN || true }));
app.use(express.json({ limit: '32mb' }));

const SPOTIFY_AUTH_URL = 'https://accounts.spotify.com/authorize';
const SPOTIFY_TOKEN_URL = 'https://accounts.spotify.com/api/token';
const SCOPES = 'user-read-currently-playing user-read-playback-state';

// ── Token persistence ────────────────────────────────────────────────────────

let tokenData = null;

function loadTokens() {
  try {
    if (fs.existsSync(TOKEN_FILE)) {
      tokenData = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
    }
  } catch {
    tokenData = null;
  }
}

function saveTokens(data) {
  tokenData = data;
  fs.writeFileSync(TOKEN_FILE, JSON.stringify(data), 'utf8');
}

loadTokens();

// ── Plaid token persistence ───────────────────────────────────────────────────

let plaidData = null;

function loadPlaidTokens() {
  try {
    if (fs.existsSync(PLAID_TOKEN_FILE)) {
      plaidData = JSON.parse(fs.readFileSync(PLAID_TOKEN_FILE, 'utf8'));
    }
  } catch {
    plaidData = null;
  }
}

function savePlaidTokens(data) {
  plaidData = data;
  fs.writeFileSync(PLAID_TOKEN_FILE, JSON.stringify(data), 'utf8');
}

function clearPlaidTokens() {
  plaidData = null;
  try { fs.unlinkSync(PLAID_TOKEN_FILE); } catch {}
}

loadPlaidTokens();

let plaidClient = null;
function getPlaidClient() {
  if (plaidClient) return plaidClient;
  const env = (process.env.PLAID_ENV || 'sandbox').toLowerCase();
  if (!PlaidEnvironments[env]) throw new Error(`Unknown PLAID_ENV: ${env}`);
  const config = new Configuration({
    basePath: PlaidEnvironments[env],
    baseOptions: {
      headers: {
        'PLAID-CLIENT-ID': process.env.PLAID_CLIENT_ID,
        'PLAID-SECRET': process.env.PLAID_SECRET,
      },
    },
  });
  plaidClient = new PlaidApi(config);
  return plaidClient;
}

function plaidReady() {
  return !!(process.env.PLAID_CLIENT_ID && process.env.PLAID_SECRET);
}

function plaidFrequencyToCycle(freq) {
  switch ((freq || '').toUpperCase()) {
    case 'WEEKLY': return 'weekly';
    case 'BIWEEKLY': return 'weekly';
    case 'SEMI_MONTHLY': return 'monthly';
    case 'MONTHLY': return 'monthly';
    case 'ANNUALLY': return 'yearly';
    default: return 'monthly';
  }
}

// ── Anthropic (AI subscription detection) ────────────────────────────────────

const AI_MODEL = 'claude-haiku-4-5';
const AI_BACKEND = (process.env.AI_BACKEND || 'sdk').toLowerCase();
const CLAUDE_CODE_BIN = process.env.CLAUDE_CODE_BIN || 'claude';

let anthropicClient = null;
function getAnthropicClient() {
  if (anthropicClient) return anthropicClient;
  anthropicClient = new Anthropic();
  return anthropicClient;
}

function anthropicReady() {
  return !!process.env.ANTHROPIC_API_KEY;
}

const CYCLE_VALUES = ['weekly', 'monthly', 'quarterly', 'biannual', 'yearly'];

const CANDIDATES_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['candidates'],
  properties: {
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'amount', 'currency', 'cycle', 'nextDate', 'category', 'notes', 'samples', 'confidence'],
        properties: {
          name:     { type: 'string', description: 'Clean merchant name, e.g. "Netflix"' },
          amount:   { type: 'number', description: 'Per-period charge amount, positive number' },
          currency: { type: 'string', description: 'ISO 4217 currency code, e.g. "USD"' },
          cycle:    { type: 'string', enum: CYCLE_VALUES },
          nextDate: { type: 'string', description: 'Predicted next bill date, YYYY-MM-DD' },
          category: { type: 'string', description: 'e.g. Streaming, Music, Cloud, News' },
          notes:    { type: 'string', description: 'Short reasoning, e.g. "Detected from 3 PYP*HULU charges"' },
          samples:  { type: 'integer', description: 'Number of source transactions' },
          confidence: { type: 'number', description: '0.0–1.0 confidence' },
        },
      },
    },
  },
};

const DETECT_SYSTEM = `You are a subscription detector for a personal-finance app. The user uploads card-statement transactions; a deterministic heuristic detector has already grouped the obvious recurring charges by normalized merchant name.

Your job: find any RECURRING subscriptions the heuristic missed. Recurring means billed on a fixed schedule (weekly, monthly, quarterly, biannual, yearly). Examples the heuristic typically misses:
- Variant descriptions of the same merchant (e.g. "NETFLIX.COM" and "PYP*NETFLIX*4087245252" — the heuristic groups them differently because of digit/prefix noise)
- Obfuscated processor prefixes (PYP*, SQ*, SP*, TST*, AUT*)
- Merchant names that span multiple words with varying store IDs

Rules:
- Only return subscriptions NOT already in the heuristicNames list (case-insensitive substring match).
- Exclude one-time purchases, gas, groceries, restaurants, and other variable spending.
- Require at least 2 transactions of the same merchant at a consistent cadence to flag as recurring.
- Use the median amount and predict nextDate as last_charge_date + median_interval; if that's in the past, roll forward.
- Be conservative — false negatives are fine, false positives waste the user's time.
- Output JSON matching the provided schema. Set samples = number of source transactions; confidence between 0 and 1.`;

const EXTRACT_SYSTEM = `You are extracting recurring subscriptions from a screenshot of a bank or credit-card statement.

Identify only RECURRING SUBSCRIPTIONS — services billed on a fixed schedule (weekly, monthly, quarterly, biannual, yearly). Examples: Netflix, Spotify, iCloud, gym memberships, software subscriptions, newspapers.

Rules:
- Skip one-time purchases, retail, restaurants, gas, groceries, transfers, and variable spending.
- For each subscription, read the most recent charge and infer cycle and next bill date.
- If you can read multiple charges of the same merchant, use the median amount and the median interval to predict nextDate.
- Don't invent transactions you can't see. If you can't read a value clearly, omit that candidate.
- Output JSON matching the provided schema. samples = how many of this merchant's charges you saw in the image; confidence 0–1 based on how clearly you could read the transaction.`;

async function callAnthropicJson({ system, userContent, maxTokens = 2048 }) {
  const client = getAnthropicClient();
  const response = await client.messages.create({
    model: AI_MODEL,
    max_tokens: maxTokens,
    system: [{ type: 'text', text: system, cache_control: { type: 'ephemeral' } }],
    output_config: { format: { type: 'json_schema', schema: CANDIDATES_SCHEMA } },
    messages: [{ role: 'user', content: userContent }],
  });
  const text = response.content.find((b) => b.type === 'text')?.text;
  if (!text) throw new Error('Empty response from Anthropic');
  return JSON.parse(text);
}

function normalizeCandidate(c) {
  return {
    name: String(c.name || '').trim(),
    amount: Math.round((Number(c.amount) || 0) * 100) / 100,
    currency: String(c.currency || 'USD').toUpperCase(),
    cycle: CYCLE_VALUES.includes(c.cycle) ? c.cycle : 'monthly',
    nextDate: /^\d{4}-\d{2}-\d{2}$/.test(c.nextDate || '') ? c.nextDate : new Date().toISOString().slice(0, 10),
    cardLast4: '',
    category: String(c.category || ''),
    notes: String(c.notes || ''),
    _samples: Number.isFinite(c.samples) ? Math.max(1, Math.round(c.samples)) : 1,
    _confidence: typeof c.confidence === 'number' ? Math.min(1, Math.max(0, c.confidence)) : 0.7,
    _source: 'ai',
  };
}

// ── Claude Code routing (uses your Max plan via the Claude Code CLI) ─────────

function runClaudeCode(prompt, timeoutMs = 120000) {
  return new Promise((resolve, reject) => {
    const args = [
      '-p', prompt,
      '--output-format', 'json',
      '--permission-mode', 'bypassPermissions',
    ];
    const proc = spawn(CLAUDE_CODE_BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    const t = setTimeout(() => { try { proc.kill('SIGKILL'); } catch {} reject(new Error('claude timed out')); }, timeoutMs);
    proc.stdout.on('data', (d) => { stdout += d.toString(); });
    proc.stderr.on('data', (d) => { stderr += d.toString(); });
    proc.on('error', (err) => { clearTimeout(t); reject(new Error(`spawn claude failed: ${err.message}`)); });
    proc.on('close', (code) => {
      clearTimeout(t);
      if (code !== 0) return reject(new Error(`claude exited ${code}: ${(stderr || stdout).slice(0, 500)}`));
      try {
        const meta = JSON.parse(stdout);
        if (meta.is_error || meta.subtype === 'error') return reject(new Error(meta.result || JSON.stringify(meta)));
        resolve(meta.result || '');
      } catch (err) {
        reject(new Error(`could not parse claude output: ${err.message}\n${stdout.slice(0, 500)}`));
      }
    });
  });
}

function extractJsonObject(text) {
  try { return JSON.parse(text); } catch {}
  const m = text.match(/\{[\s\S]*\}/);
  if (m) { try { return JSON.parse(m[0]); } catch {} }
  throw new Error('No valid JSON object in Claude output');
}

async function claudeCodeDetect({ transactions, heuristicNames, today, currency }) {
  const payload = { today, currency, heuristicNames, transactions };
  const prompt = `${DETECT_SYSTEM}

Schema you must follow:
${JSON.stringify(CANDIDATES_SCHEMA, null, 2)}

Output ONLY the JSON object — no prose, no markdown fences.

Data to analyze:
${JSON.stringify(payload)}`;
  const text = await runClaudeCode(prompt);
  return extractJsonObject(text);
}

async function claudeCodeExtractFile(mediaType, b64, today, currency) {
  const ext = mediaType === 'application/pdf' ? 'pdf' : (mediaType.split('/')[1] || 'bin');
  const tmpFile = path.join(os.tmpdir(), `subs-${crypto.randomUUID()}.${ext}`);
  fs.writeFileSync(tmpFile, Buffer.from(b64, 'base64'));
  try {
    const isPdf = mediaType === 'application/pdf';
    const prompt = `${EXTRACT_SYSTEM}

Use the Read tool to view the file at ${tmpFile} (it is ${isPdf ? 'a PDF bank statement' : 'a screenshot of a statement'}). today=${today} default_currency=${currency}.

Schema you must follow:
${JSON.stringify(CANDIDATES_SCHEMA, null, 2)}

Output ONLY the JSON object — no prose, no markdown fences.`;
    const text = await runClaudeCode(prompt, 180000);
    return extractJsonObject(text);
  } finally {
    try { fs.unlinkSync(tmpFile); } catch {}
  }
}

function checkClaudeCodeAvailable() {
  return new Promise((resolve) => {
    const proc = spawn(CLAUDE_CODE_BIN, ['--version'], { stdio: ['ignore', 'pipe', 'pipe'] });
    proc.on('error', () => resolve(false));
    proc.on('close', (code) => resolve(code === 0));
  });
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function getRedirectUri() {
  return process.env.REDIRECT_URI || `http://localhost:${PORT}/callback`;
}

function getAuthHeader() {
  const creds = `${process.env.SPOTIFY_CLIENT_ID}:${process.env.SPOTIFY_CLIENT_SECRET}`;
  return `Basic ${Buffer.from(creds).toString('base64')}`;
}

async function getAccessToken() {
  if (!tokenData) return null;

  const needsRefresh = Date.now() >= tokenData.expires_at - 60_000;
  if (!needsRefresh) return tokenData.access_token;

  const res = await axios.post(
    SPOTIFY_TOKEN_URL,
    new URLSearchParams({ grant_type: 'refresh_token', refresh_token: tokenData.refresh_token }),
    { headers: { Authorization: getAuthHeader(), 'Content-Type': 'application/x-www-form-urlencoded' } }
  );

  saveTokens({
    access_token: res.data.access_token,
    refresh_token: res.data.refresh_token || tokenData.refresh_token,
    expires_at: Date.now() + res.data.expires_in * 1000,
  });

  return tokenData.access_token;
}

// ── Routes ───────────────────────────────────────────────────────────────────

app.get('/login', (req, res) => {
  if (!process.env.SPOTIFY_CLIENT_ID) {
    return res.status(500).send('SPOTIFY_CLIENT_ID is not set. Check your .env file.');
  }
  const params = new URLSearchParams({
    client_id: process.env.SPOTIFY_CLIENT_ID,
    response_type: 'code',
    redirect_uri: getRedirectUri(),
    scope: SCOPES,
    show_dialog: 'true',
  });
  res.redirect(`${SPOTIFY_AUTH_URL}?${params}`);
});

app.get('/callback', async (req, res) => {
  const { code, error } = req.query;
  if (error) return res.redirect('/setup?error=' + error);

  try {
    const response = await axios.post(
      SPOTIFY_TOKEN_URL,
      new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: getRedirectUri(),
      }),
      { headers: { Authorization: getAuthHeader(), 'Content-Type': 'application/x-www-form-urlencoded' } }
    );

    saveTokens({
      access_token: response.data.access_token,
      refresh_token: response.data.refresh_token,
      expires_at: Date.now() + response.data.expires_in * 1000,
    });

    res.redirect('/setup?connected=1');
  } catch (err) {
    console.error('OAuth error:', err.response?.data || err.message);
    res.redirect('/setup?error=oauth_failed');
  }
});

app.get('/logout', (req, res) => {
  tokenData = null;
  try { fs.unlinkSync(TOKEN_FILE); } catch {}
  res.redirect('/setup');
});

app.get('/status', (req, res) => {
  res.json({ connected: !!tokenData });
});

app.get('/now-playing', async (req, res) => {
  const token = await getAccessToken().catch(() => null);
  if (!token) return res.json({ playing: false });

  try {
    const response = await axios.get('https://api.spotify.com/v1/me/player/currently-playing', {
      headers: { Authorization: `Bearer ${token}` },
    });

    if (response.status === 204 || !response.data) {
      return res.json({ playing: false });
    }

    const { item, is_playing, progress_ms } = response.data;
    if (!item) return res.json({ playing: false });

    res.json({
      playing: is_playing,
      title: item.name,
      artist: item.artists.map((a) => a.name).join(', '),
      album: item.album.name,
      albumArt: item.album.images[0]?.url || null,
      duration: item.duration_ms,
      progress: progress_ms,
      id: item.id,
    });
  } catch (err) {
    if (err.response?.status === 204) return res.json({ playing: false });
    console.error('Spotify API error:', err.response?.data || err.message);
    res.json({ playing: false });
  }
});

// ── Plaid routes ──────────────────────────────────────────────────────────────

app.get('/plaid/status', (req, res) => {
  res.json({
    ready: plaidReady(),
    connected: !!plaidData,
    env: (process.env.PLAID_ENV || 'sandbox').toLowerCase(),
  });
});

app.post('/plaid/link-token', async (req, res) => {
  if (!plaidReady()) return res.status(400).json({ error: 'Plaid not configured' });
  try {
    const result = await getPlaidClient().linkTokenCreate({
      user: { client_user_id: 'subs-local-user' },
      client_name: 'Subs',
      products: [Products.Transactions],
      country_codes: [CountryCode.Us],
      language: 'en',
    });
    res.json({ link_token: result.data.link_token });
  } catch (err) {
    console.error('Plaid link-token error:', err.response?.data || err.message);
    res.status(500).json({ error: 'link_token_failed', detail: err.response?.data || err.message });
  }
});

app.post('/plaid/exchange', async (req, res) => {
  if (!plaidReady()) return res.status(400).json({ error: 'Plaid not configured' });
  const { public_token } = req.body || {};
  if (!public_token) return res.status(400).json({ error: 'missing public_token' });
  try {
    const result = await getPlaidClient().itemPublicTokenExchange({ public_token });
    savePlaidTokens({
      access_token: result.data.access_token,
      item_id: result.data.item_id,
      connected_at: Date.now(),
    });
    res.json({ ok: true });
  } catch (err) {
    console.error('Plaid exchange error:', err.response?.data || err.message);
    res.status(500).json({ error: 'exchange_failed', detail: err.response?.data || err.message });
  }
});

app.get('/plaid/recurring', async (req, res) => {
  if (!plaidReady()) return res.status(400).json({ error: 'Plaid not configured' });
  if (!plaidData) return res.status(400).json({ error: 'not_connected' });
  try {
    const result = await getPlaidClient().transactionsRecurringGet({
      access_token: plaidData.access_token,
    });
    const today = new Date(); today.setHours(0,0,0,0);
    const streams = (result.data.outflow_streams || [])
      .filter((s) => s.status !== 'TERMINATED' && s.status !== 'EARLY_DETECTION')
      .map((s) => {
        const amt = Math.abs(s.average_amount?.amount ?? s.last_amount?.amount ?? 0);
        let nextDate = s.predicted_next_date || s.last_date;
        if (!nextDate) nextDate = today.toISOString().slice(0, 10);
        return {
          name: s.merchant_name || s.description || 'Unknown',
          amount: Math.round(amt * 100) / 100,
          currency: s.average_amount?.iso_currency_code || s.last_amount?.iso_currency_code || 'USD',
          cycle: plaidFrequencyToCycle(s.frequency),
          nextDate,
          cardLast4: '',
          category: (s.personal_finance_category?.primary || s.category?.[0] || '').replace(/_/g, ' ').toLowerCase(),
          notes: `Plaid: ${s.frequency || 'unknown frequency'}, ${s.transaction_ids?.length || 0} transactions`,
          _confidence: s.is_active ? 0.9 : 0.5,
          _samples: s.transaction_ids?.length || 0,
        };
      });
    res.json({ streams });
  } catch (err) {
    console.error('Plaid recurring error:', err.response?.data || err.message);
    res.status(500).json({ error: 'recurring_failed', detail: err.response?.data || err.message });
  }
});

app.post('/plaid/disconnect', async (req, res) => {
  if (plaidReady() && plaidData) {
    try { await getPlaidClient().itemRemove({ access_token: plaidData.access_token }); }
    catch (err) { console.warn('Plaid itemRemove failed (continuing):', err.response?.data || err.message); }
  }
  clearPlaidTokens();
  res.json({ ok: true });
});

// ── AI routes ─────────────────────────────────────────────────────────────────

app.get('/ai/status', async (req, res) => {
  if (AI_BACKEND === 'claude-code') {
    const ok = await checkClaudeCodeAvailable();
    return res.json({ ready: ok, model: 'claude-code', backend: 'claude-code' });
  }
  res.json({ ready: anthropicReady(), model: AI_MODEL, backend: 'sdk' });
});

app.post('/ai/detect', async (req, res) => {
  const { transactions, heuristicNames, today, currency } = req.body || {};
  if (!Array.isArray(transactions)) return res.status(400).json({ error: 'missing transactions' });

  const args = {
    today: today || new Date().toISOString().slice(0, 10),
    currency: currency || 'USD',
    heuristicNames: Array.isArray(heuristicNames) ? heuristicNames : [],
    transactions: transactions.slice(0, 800),
  };

  try {
    let result;
    if (AI_BACKEND === 'claude-code') {
      result = await claudeCodeDetect(args);
    } else {
      if (!anthropicReady()) return res.status(400).json({ error: 'AI not configured' });
      result = await callAnthropicJson({
        system: DETECT_SYSTEM,
        userContent: JSON.stringify(args),
        maxTokens: 2048,
      });
    }
    const candidates = (result.candidates || []).map(normalizeCandidate);
    res.json({ candidates });
  } catch (err) {
    const status = err instanceof Anthropic.APIError ? err.status || 500 : 500;
    console.error('AI detect error:', err.message);
    res.status(status).json({ error: 'ai_failed', detail: err.message });
  }
});

async function callAnthropicExtract(mediaType, b64, today, currency) {
  const isPdf = mediaType === 'application/pdf';
  const userText = `Statement ${isPdf ? 'PDF' : 'screenshot'} attached. today=${today || new Date().toISOString().slice(0, 10)} default_currency=${currency || 'USD'}. Extract recurring subscriptions only.`;
  const block = isPdf
    ? { type: 'document', source: { type: 'base64', media_type: mediaType, data: b64 } }
    : { type: 'image',    source: { type: 'base64', media_type: mediaType, data: b64 } };

  const response = await getAnthropicClient().messages.create({
    model: AI_MODEL,
    max_tokens: 2048,
    system: [{ type: 'text', text: EXTRACT_SYSTEM, cache_control: { type: 'ephemeral' } }],
    output_config: { format: { type: 'json_schema', schema: CANDIDATES_SCHEMA } },
    messages: [{ role: 'user', content: [block, { type: 'text', text: userText }] }],
  });
  const text = response.content.find((b) => b.type === 'text')?.text;
  const parsed = text ? JSON.parse(text) : { candidates: [] };
  return (parsed.candidates || []).map(normalizeCandidate);
}

async function extractDispatch(mediaType, b64, today, currency) {
  const t = today || new Date().toISOString().slice(0, 10);
  const c = currency || 'USD';
  if (AI_BACKEND === 'claude-code') {
    const parsed = await claudeCodeExtractFile(mediaType, b64, t, c);
    return (parsed.candidates || []).map(normalizeCandidate);
  }
  if (!anthropicReady()) { const e = new Error('AI not configured'); e.status = 400; throw e; }
  return callAnthropicExtract(mediaType, b64, t, c);
}

app.post('/ai/extract', async (req, res) => {
  const { file, today, currency } = req.body || {};
  if (typeof file !== 'string' || !file.startsWith('data:')) {
    return res.status(400).json({ error: 'file must be a data URL (data:image/...;base64,... or data:application/pdf;base64,...)' });
  }
  const m = file.match(/^data:(image\/[a-zA-Z0-9.+-]+|application\/pdf);base64,(.+)$/);
  if (!m) return res.status(400).json({ error: 'unsupported file type (image/* or application/pdf only)' });
  try {
    const candidates = await extractDispatch(m[1], m[2], today, currency);
    res.json({ candidates });
  } catch (err) {
    const status = err.status || (err instanceof Anthropic.APIError ? err.status || 500 : 500);
    console.error('AI extract error:', err.message);
    res.status(status).json({ error: 'ai_failed', detail: err.message });
  }
});

app.post('/ai/extract-image', async (req, res) => {
  const { image, today, currency } = req.body || {};
  if (typeof image !== 'string' || !image.startsWith('data:image/')) {
    return res.status(400).json({ error: 'image must be a data URL (data:image/...;base64,...)' });
  }
  const m = image.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
  if (!m) return res.status(400).json({ error: 'invalid image data URL' });
  try {
    const candidates = await extractDispatch(m[1], m[2], today, currency);
    res.json({ candidates });
  } catch (err) {
    const status = err.status || (err instanceof Anthropic.APIError ? err.status || 500 : 500);
    console.error('AI extract-image error:', err.message);
    res.status(status).json({ error: 'ai_failed', detail: err.message });
  }
});

app.get('/subs', (req, res) => res.sendFile(path.join(__dirname, 'public', 'subs.html')));

app.use(express.static(path.join(__dirname, 'public')));

// ── Start ────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`
  ╔══════════════════════════════════════╗
  ║        OBS Now Playing Widget        ║
  ╠══════════════════════════════════════╣
  ║  Setup:   http://localhost:${PORT}/setup  ║
  ║  Widget:  http://localhost:${PORT}/widget ║
  ╚══════════════════════════════════════╝
  `);
});
