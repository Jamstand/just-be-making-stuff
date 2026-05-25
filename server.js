require('dotenv').config();
const express = require('express');
const axios = require('axios');
const cors = require('cors');
const fs = require('fs');
const path = require('path');
const { Configuration, PlaidApi, PlaidEnvironments, Products, CountryCode } = require('plaid');
const Anthropic = require('@anthropic-ai/sdk');
const { spawn } = require('child_process');
const spawnCli = require('cross-spawn');
const os = require('os');
const crypto = require('crypto');
const WebSocket = require('ws');
const dns = require('dns');
const net = require('net');
const http = require('http');
const https = require('https');

const app = express();
const PORT = process.env.PORT || 3000;
const TOKEN_FILE = path.join(__dirname, '.tokens.json');
const PLAID_TOKEN_FILE = path.join(__dirname, '.plaid-tokens.json');
const TWITCH_TOKEN_FILE = path.join(__dirname, '.twitch-tokens.json');

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
    // Windows cmd.exe truncates command-line args at embedded newlines, so
    // passing a long multi-line prompt via -p drops everything after the
    // first \n — including the trailing flags (--output-format json,
    // --permission-mode), which makes claude return conversational text
    // instead of the JSON wrapper we parse. Collapse newlines to spaces on
    // Windows; the model still reads the prompt fine without them.
    const flatPrompt = process.platform === 'win32'
      ? prompt.replace(/\r\n|\n|\r/g, ' ')
      : prompt;
    const args = [
      '-p', flatPrompt,
      '--output-format', 'json',
      '--permission-mode', 'bypassPermissions',
    ];
    // cross-spawn handles Windows `.cmd`/`.bat` shims (`claude` is installed
    // as `claude.cmd` by npm on Windows). Node's built-in spawn refuses to
    // execute those directly since the CVE-2024-27980 fix in Node 22+, and
    // spawn({ shell: true }) would let the user-controlled prompt inject
    // shell metacharacters. cross-spawn does the safe escape internally.
    const proc = spawnCli(CLAUDE_CODE_BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] });
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

async function claudeCodePhotoEdit(mediaType, b64, userPrompt) {
  const ext = mediaType.split('/')[1] || 'jpg';
  const tmpFile = path.join(os.tmpdir(), `photoai-${crypto.randomUUID()}.${ext}`);
  fs.writeFileSync(tmpFile, Buffer.from(b64, 'base64'));
  try {
    const instruction = userPrompt
      ? `User prompt: ${userPrompt}\n\nLook at the snapshot and choose filter parameters that produce this feel.`
      : `No prompt given — choose a tasteful, flattering look for what you see in this snapshot.`;
    const prompt = `${EDIT_SYSTEM}

Use the Read tool to view the snapshot at ${tmpFile}. ${instruction}

Schema you must follow:
${JSON.stringify(LOOK_SCHEMA, null, 2)}

Output ONLY the JSON object — no prose, no markdown fences.`;
    const text = await runClaudeCode(prompt, 120000);
    return extractJsonObject(text);
  } finally {
    try { fs.unlinkSync(tmpFile); } catch {}
  }
}

function checkClaudeCodeAvailable() {
  return new Promise((resolve) => {
    const proc = spawnCli(CLAUDE_CODE_BIN, ['--version'], { stdio: ['ignore', 'pipe', 'pipe'] });
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

// ── Twitch integration ────────────────────────────────────────────────────────
//
// Powers the OBS widget pack:
//   - /twitch/login + /twitch/callback   user OAuth (PKCE-less code flow)
//   - /twitch/status                     connected? user info?
//   - /twitch/stream-status              channel, game, viewers, followers, uptime
//   - /widget-events                     Server-Sent Events stream for sub/cheer/follow
//   - /webhook/tip                       generic tip webhook (StreamElements/Ko-fi/etc)
//
// Live events come from a Twitch EventSub WebSocket subscription managed by
// this process; we re-broadcast them to all connected widget clients over SSE.

let twitchData = null;
let twitchUser = null;          // { id, login, display_name }
let twitchStatusCache = null;   // { live, game, viewers, startedAt, fetchedAt }
let twitchFollowerCache = null; // { count, fetchedAt }
let twitchEventSubWs = null;
let twitchEventSubSessionId = null;
let twitchEventSubReconnectTimer = null;
let twitchEventSubReconnectAttempts = 0;

const TWITCH_AUTH_URL  = 'https://id.twitch.tv/oauth2/authorize';
const TWITCH_TOKEN_URL = 'https://id.twitch.tv/oauth2/token';
const TWITCH_HELIX     = 'https://api.twitch.tv/helix';
const TWITCH_EVENTSUB_WS_URL = 'wss://eventsub.wss.twitch.tv/ws';
const TWITCH_SCOPES = [
  'channel:read:subscriptions',
  'bits:read',
  'moderator:read:followers',
].join(' ');

function loadTwitchTokens() {
  try {
    if (fs.existsSync(TWITCH_TOKEN_FILE)) {
      twitchData = JSON.parse(fs.readFileSync(TWITCH_TOKEN_FILE, 'utf8'));
      twitchUser = twitchData.user || null;
    }
  } catch { twitchData = null; }
}

function saveTwitchTokens(data) {
  twitchData = data;
  twitchUser = data.user || twitchUser;
  fs.writeFileSync(TWITCH_TOKEN_FILE, JSON.stringify(data), 'utf8');
}

function clearTwitchTokens() {
  twitchData = null;
  twitchUser = null;
  twitchStatusCache = null;
  twitchFollowerCache = null;
  try { fs.unlinkSync(TWITCH_TOKEN_FILE); } catch {}
}

loadTwitchTokens();

function twitchReady() {
  return !!(process.env.TWITCH_CLIENT_ID && process.env.TWITCH_CLIENT_SECRET);
}

function getTwitchRedirectUri() {
  return process.env.TWITCH_REDIRECT_URI || `http://localhost:${PORT}/twitch/callback`;
}

async function getTwitchAccessToken() {
  if (!twitchData) return null;
  if (Date.now() < twitchData.expires_at - 60_000) return twitchData.access_token;

  const res = await axios.post(
    TWITCH_TOKEN_URL,
    new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: twitchData.refresh_token,
      client_id: process.env.TWITCH_CLIENT_ID,
      client_secret: process.env.TWITCH_CLIENT_SECRET,
    }),
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
  );
  saveTwitchTokens({
    ...twitchData,
    access_token: res.data.access_token,
    refresh_token: res.data.refresh_token || twitchData.refresh_token,
    expires_at: Date.now() + res.data.expires_in * 1000,
  });
  return twitchData.access_token;
}

async function helix(pathname, params = {}) {
  const token = await getTwitchAccessToken();
  if (!token) throw new Error('not connected');
  const res = await axios.get(`${TWITCH_HELIX}${pathname}`, {
    params,
    headers: {
      Authorization: `Bearer ${token}`,
      'Client-Id': process.env.TWITCH_CLIENT_ID,
    },
  });
  return res.data;
}

async function fetchTwitchUserInfo() {
  const data = await helix('/users');
  return data.data?.[0] || null;
}

async function fetchTwitchStreamStatus() {
  if (!twitchUser) return null;
  const data = await helix('/streams', { user_id: twitchUser.id });
  const s = data.data?.[0];
  if (!s) {
    return { live: false, game: null, viewers: 0, startedAt: null };
  }
  return {
    live: true,
    game: s.game_name || null,
    viewers: s.viewer_count || 0,
    startedAt: s.started_at,
  };
}

async function fetchTwitchFollowerCount() {
  if (!twitchUser) return 0;
  const data = await helix('/channels/followers', { broadcaster_id: twitchUser.id });
  return data.total || 0;
}

// ── SSE event bus ────────────────────────────────────────────────────────────
const sseClients = new Set();

function broadcast(event, data) {
  const payload = `data: ${JSON.stringify({ event, data })}\n\n`;
  for (const res of sseClients) {
    try { res.write(payload); } catch {}
  }
}

app.get('/widget-events', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.write('retry: 4000\n\n');
  res.write(`data: ${JSON.stringify({ event: 'hello', data: { t: Date.now() } })}\n\n`);

  sseClients.add(res);
  const keepAlive = setInterval(() => {
    try { res.write(': ping\n\n'); } catch {}
  }, 25000);

  req.on('close', () => {
    clearInterval(keepAlive);
    sseClients.delete(res);
  });
});

// ── Twitch OAuth routes ──────────────────────────────────────────────────────

app.get('/twitch/login', (req, res) => {
  if (!twitchReady()) {
    return res.status(500).send('TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET are not set.');
  }
  const params = new URLSearchParams({
    client_id: process.env.TWITCH_CLIENT_ID,
    redirect_uri: getTwitchRedirectUri(),
    response_type: 'code',
    scope: TWITCH_SCOPES,
    force_verify: 'true',
  });
  res.redirect(`${TWITCH_AUTH_URL}?${params}`);
});

app.get('/twitch/callback', async (req, res) => {
  const { code, error } = req.query;
  if (error) return res.redirect('/setup?twitch_error=' + error);
  try {
    const tokenRes = await axios.post(
      TWITCH_TOKEN_URL,
      new URLSearchParams({
        client_id: process.env.TWITCH_CLIENT_ID,
        client_secret: process.env.TWITCH_CLIENT_SECRET,
        code: String(code),
        grant_type: 'authorization_code',
        redirect_uri: getTwitchRedirectUri(),
      }),
      { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
    );
    saveTwitchTokens({
      access_token:  tokenRes.data.access_token,
      refresh_token: tokenRes.data.refresh_token,
      expires_at:    Date.now() + tokenRes.data.expires_in * 1000,
    });
    const user = await fetchTwitchUserInfo();
    if (user) {
      saveTwitchTokens({ ...twitchData, user });
    }
    // Re-init EventSub now that we have a token
    startTwitchEventSub();
    res.redirect('/setup?twitch_connected=1');
  } catch (err) {
    console.error('Twitch OAuth error:', err.response?.data || err.message);
    res.redirect('/setup?twitch_error=oauth_failed');
  }
});

app.get('/twitch/logout', (req, res) => {
  stopTwitchEventSub();
  clearTwitchTokens();
  res.redirect('/setup');
});

app.get('/twitch/status', (req, res) => {
  res.json({
    ready: twitchReady(),
    connected: !!twitchData,
    user: twitchUser ? { login: twitchUser.login, display_name: twitchUser.display_name } : null,
    eventsub: !!twitchEventSubSessionId,
  });
});

app.get('/twitch/stream-status', async (req, res) => {
  if (!twitchData || !twitchUser) {
    return res.json({ connected: false });
  }
  try {
    // Status: cache 15s. Followers: cache 60s.
    const now = Date.now();
    if (!twitchStatusCache || now - twitchStatusCache.fetchedAt > 15_000) {
      const s = await fetchTwitchStreamStatus();
      twitchStatusCache = { ...s, fetchedAt: now };
    }
    if (!twitchFollowerCache || now - twitchFollowerCache.fetchedAt > 60_000) {
      const c = await fetchTwitchFollowerCount().catch(() => null);
      if (c != null) twitchFollowerCache = { count: c, fetchedAt: now };
    }
    res.json({
      connected: true,
      channel:   twitchUser.display_name || twitchUser.login,
      live:      twitchStatusCache.live,
      game:      twitchStatusCache.game,
      viewers:   twitchStatusCache.viewers,
      startedAt: twitchStatusCache.startedAt,
      followers: twitchFollowerCache?.count ?? 0,
    });
  } catch (err) {
    console.error('Twitch stream-status error:', err.response?.data || err.message);
    res.status(500).json({ connected: true, error: 'twitch_api_failed' });
  }
});

// Generic tip webhook — point StreamElements / Streamlabs / Ko-fi here.
// Accepts loose shapes; pull common fields out and broadcast.
app.post('/webhook/tip', (req, res) => {
  const b = req.body || {};
  const name = b.name || b.from_name || b.username || b.user || b.donor || 'anonymous';
  const amount = Number(
    b.amount ?? b.tip?.amount ?? b.donation?.amount ?? b.data?.amount ?? 0
  );
  const currency = b.currency || b.tip?.currency || 'USD';
  const message = b.message || b.tip?.message || '';
  if (amount > 0) {
    broadcast('tip', { name, amount, currency, message });
  }
  res.json({ ok: true });
});

// Manual event emitter — handy for testing widgets without real triggers.
app.post('/events/emit', (req, res) => {
  const { event, data } = req.body || {};
  if (!event) return res.status(400).json({ error: 'missing event' });
  broadcast(event, data || {});
  res.json({ ok: true });
});

// ── Twitch EventSub WebSocket ────────────────────────────────────────────────

async function subscribeToEventSub(type, version, condition) {
  const token = await getTwitchAccessToken();
  await axios.post(
    `${TWITCH_HELIX}/eventsub/subscriptions`,
    {
      type, version, condition,
      transport: { method: 'websocket', session_id: twitchEventSubSessionId },
    },
    {
      headers: {
        Authorization: `Bearer ${token}`,
        'Client-Id': process.env.TWITCH_CLIENT_ID,
        'Content-Type': 'application/json',
      },
    }
  );
}

async function registerEventSubSubscriptions() {
  if (!twitchUser) return;
  const broadcaster_user_id = twitchUser.id;
  const moderator_user_id   = twitchUser.id;
  const subs = [
    ['channel.subscribe',         '1', { broadcaster_user_id }],
    ['channel.subscription.gift', '1', { broadcaster_user_id }],
    ['channel.cheer',             '1', { broadcaster_user_id }],
    ['channel.follow',            '2', { broadcaster_user_id, moderator_user_id }],
  ];
  for (const [type, version, condition] of subs) {
    try {
      await subscribeToEventSub(type, version, condition);
    } catch (err) {
      console.warn(`EventSub subscribe ${type} failed:`,
        err.response?.data?.message || err.message);
    }
  }
}

function handleEventSubNotification(payload) {
  const subType = payload.subscription?.type;
  const event   = payload.event || {};

  switch (subType) {
    case 'channel.subscribe':
      broadcast('sub', { name: event.user_name, tier: event.tier, gift: !!event.is_gift });
      break;
    case 'channel.subscription.gift':
      broadcast('sub', { name: event.user_name, tier: event.tier, gift: true, total: event.total });
      break;
    case 'channel.cheer':
      broadcast('cheer', {
        name: event.is_anonymous ? 'anonymous' : event.user_name,
        amount: event.bits,
        message: event.message,
      });
      break;
    case 'channel.follow':
      broadcast('follow', { name: event.user_name });
      break;
    default:
      // Unknown event type — ignore
  }
}

function stopTwitchEventSub() {
  clearTimeout(twitchEventSubReconnectTimer);
  twitchEventSubReconnectTimer = null;
  twitchEventSubSessionId = null;
  if (twitchEventSubWs) {
    try { twitchEventSubWs.removeAllListeners(); twitchEventSubWs.close(); } catch {}
    twitchEventSubWs = null;
  }
}

function startTwitchEventSub(wsUrl = TWITCH_EVENTSUB_WS_URL) {
  if (!twitchReady() || !twitchData || !twitchUser) return;
  stopTwitchEventSub();

  const ws = new WebSocket(wsUrl);
  twitchEventSubWs = ws;

  ws.on('open', () => { twitchEventSubReconnectAttempts = 0; });

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }

    const type = msg.metadata?.message_type;
    if (type === 'session_welcome') {
      twitchEventSubSessionId = msg.payload?.session?.id;
      registerEventSubSubscriptions().catch((e) =>
        console.warn('EventSub register error:', e.message));
    } else if (type === 'session_reconnect') {
      const newUrl = msg.payload?.session?.reconnect_url;
      if (newUrl) startTwitchEventSub(newUrl);
    } else if (type === 'notification') {
      handleEventSubNotification(msg.payload || {});
    }
  });

  ws.on('close', () => {
    twitchEventSubWs = null;
    twitchEventSubSessionId = null;
    if (!twitchData) return;
    const delay = Math.min(60_000, 1000 * Math.pow(2, twitchEventSubReconnectAttempts++));
    twitchEventSubReconnectTimer = setTimeout(() => startTwitchEventSub(), delay);
  });

  ws.on('error', (err) => {
    console.warn('Twitch EventSub WS error:', err.message);
  });
}

// Boot EventSub if already connected from a previous run
if (twitchData && twitchUser) {
  setTimeout(() => startTwitchEventSub(), 500);
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

// ── Generative image editing providers ───────────────────────────────────────
// Claude can't generate images, so generative edits route to a separate
// vendor (Gemini / Replicate / OpenAI). Each adapter takes a base64 image
// + a text prompt + an optional mask (white = area to change), returns a
// new image as { mediaType, data }. Pricing & model defaults are read from
// env vars so the user can swap without code changes.

const GEN_PROVIDERS = {
  gemini: {
    envKey: 'GEMINI_API_KEY',
    defaultModel: 'gemini-2.5-flash-image',
    estCostUsd: 0.039,
    label: 'Google Gemini Image',
  },
  replicate: {
    envKey: 'REPLICATE_API_TOKEN',
    defaultModel: 'black-forest-labs/flux-kontext-pro',
    estCostUsd: 0.04,
    label: 'Replicate',
  },
  openai: {
    envKey: 'OPENAI_API_KEY',
    defaultModel: 'gpt-image-1',
    estCostUsd: 0.05,
    label: 'OpenAI gpt-image-1',
  },
};

function genProviderStatus() {
  const out = {};
  for (const [id, p] of Object.entries(GEN_PROVIDERS)) {
    out[id] = {
      ready: !!process.env[p.envKey],
      model: process.env[`${id.toUpperCase()}_IMAGE_MODEL`] || p.defaultModel,
      estCostUsd: p.estCostUsd,
      label: p.label,
    };
  }
  return out;
}

async function geminiEdit({ image, prompt, mask, mediaType }) {
  const key = process.env.GEMINI_API_KEY;
  if (!key) throw new Error('GEMINI_API_KEY not set');
  const model = process.env.GEMINI_IMAGE_MODEL || GEN_PROVIDERS.gemini.defaultModel;
  const parts = [
    { text: mask
        ? `${prompt}\n\nThe attached mask marks (in white) the area you should change. Keep everything else identical.`
        : prompt },
    { inline_data: { mime_type: mediaType, data: image } },
  ];
  if (mask) parts.push({ inline_data: { mime_type: 'image/png', data: mask } });
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(key)}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      contents: [{ parts }],
      generationConfig: { responseModalities: ['IMAGE'] },
    }),
  });
  if (!res.ok) throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 400)}`);
  const data = await res.json();
  const part = data.candidates?.[0]?.content?.parts?.find((p) => p.inline_data || p.inlineData);
  const id = part?.inline_data || part?.inlineData;
  if (!id?.data) throw new Error('Gemini returned no image');
  return { mediaType: id.mime_type || id.mimeType || 'image/png', data: id.data };
}

async function replicateEdit({ image, prompt, mask, mediaType }) {
  const token = process.env.REPLICATE_API_TOKEN;
  if (!token) throw new Error('REPLICATE_API_TOKEN not set');
  const model = process.env.REPLICATE_IMAGE_MODEL || GEN_PROVIDERS.replicate.defaultModel;
  const input = {
    prompt,
    input_image: `data:${mediaType};base64,${image}`,
    output_format: 'png',
  };
  if (mask) input.mask = `data:image/png;base64,${mask}`;

  const createRes = await fetch(`https://api.replicate.com/v1/models/${model}/predictions`, {
    method: 'POST',
    headers: {
      'authorization': `Bearer ${token}`,
      'content-type': 'application/json',
      'prefer': 'wait=60',
    },
    body: JSON.stringify({ input }),
  });
  if (!createRes.ok) throw new Error(`Replicate ${createRes.status}: ${(await createRes.text()).slice(0, 400)}`);
  let pred = await createRes.json();

  const deadline = Date.now() + 180_000;
  while ((pred.status === 'starting' || pred.status === 'processing') && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 1500));
    const pollRes = await fetch(`https://api.replicate.com/v1/predictions/${pred.id}`, {
      headers: { 'authorization': `Bearer ${token}` },
    });
    pred = await pollRes.json();
  }
  if (pred.status !== 'succeeded') throw new Error(`Replicate ${pred.status}: ${pred.error || 'timeout'}`);
  const outUrl = Array.isArray(pred.output) ? pred.output[0] : pred.output;
  if (typeof outUrl !== 'string') throw new Error('Replicate returned no image URL');
  const imgRes = await fetch(outUrl);
  if (!imgRes.ok) throw new Error(`Replicate output fetch ${imgRes.status}`);
  const buf = Buffer.from(await imgRes.arrayBuffer());
  return { mediaType: imgRes.headers.get('content-type') || 'image/png', data: buf.toString('base64') };
}

async function openaiEdit({ image, prompt, mask, mediaType }) {
  const key = process.env.OPENAI_API_KEY;
  if (!key) throw new Error('OPENAI_API_KEY not set');
  const model = process.env.OPENAI_IMAGE_MODEL || GEN_PROVIDERS.openai.defaultModel;
  const ext = mediaType === 'image/jpeg' ? 'jpg' : mediaType === 'image/webp' ? 'webp' : 'png';
  const form = new FormData();
  form.append('model', model);
  form.append('prompt', prompt);
  form.append('image', new Blob([Buffer.from(image, 'base64')], { type: mediaType }), `image.${ext}`);
  if (mask) form.append('mask', new Blob([Buffer.from(mask, 'base64')], { type: 'image/png' }), 'mask.png');
  const res = await fetch('https://api.openai.com/v1/images/edits', {
    method: 'POST',
    headers: { 'authorization': `Bearer ${key}` },
    body: form,
  });
  if (!res.ok) throw new Error(`OpenAI ${res.status}: ${(await res.text()).slice(0, 400)}`);
  const data = await res.json();
  const b64 = data.data?.[0]?.b64_json;
  if (!b64) throw new Error('OpenAI returned no image');
  return { mediaType: 'image/png', data: b64 };
}

app.post('/ai/photo-generate', async (req, res) => {
  const { image, prompt, mask, provider } = req.body || {};
  if (typeof image !== 'string' || !image.startsWith('data:image/')) {
    return res.status(400).json({ error: 'image must be a data URL' });
  }
  if (typeof prompt !== 'string' || !prompt.trim()) {
    return res.status(400).json({ error: 'prompt required' });
  }
  if (!GEN_PROVIDERS[provider]) {
    return res.status(400).json({ error: `unknown provider: ${provider}` });
  }
  const m = image.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
  if (!m) return res.status(400).json({ error: 'invalid image data URL' });
  let maskData;
  if (mask) {
    const mm = mask.match(/^data:image\/[a-zA-Z0-9.+-]+;base64,(.+)$/);
    if (!mm) return res.status(400).json({ error: 'invalid mask data URL' });
    maskData = mm[1];
  }
  try {
    const args = { image: m[2], prompt: prompt.trim(), mask: maskData, mediaType: m[1] };
    let result;
    if (provider === 'gemini') result = await geminiEdit(args);
    else if (provider === 'replicate') result = await replicateEdit(args);
    else if (provider === 'openai') result = await openaiEdit(args);
    res.json({ image: `data:${result.mediaType};base64,${result.data}`, provider });
  } catch (err) {
    console.error('photo-generate error:', err.message);
    res.status(500).json({ error: 'gen_failed', detail: err.message });
  }
});

// ── Polish / upscale (Magnific via Freepik API, Clarity via Replicate) ──────
// Different from gen-edit: no prompt, no mask — pure detail enhancement.
// Magnific: async POST → poll task_id → fetch URL.
// Clarity: same Replicate /predictions pattern as flux-kontext.
const POLISH_PROVIDERS = {
  magnific_2k: {
    envKey: 'FREEPIK_API_KEY',
    estCostUsd: 0.08,
    label: 'Magnific 2K',
    maxInputDim: 1024,
  },
  magnific_4k: {
    envKey: 'FREEPIK_API_KEY',
    estCostUsd: 0.16,
    label: 'Magnific 4K',
    maxInputDim: 2048,
  },
  clarity: {
    envKey: 'REPLICATE_API_TOKEN',
    defaultModel: 'philz1337x/clarity-upscaler',
    estCostUsd: 0.03,
    label: 'Clarity (Replicate)',
    maxInputDim: 2048,
  },
};

function polishProviderStatus() {
  const out = {};
  for (const [id, p] of Object.entries(POLISH_PROVIDERS)) {
    out[id] = {
      ready: !!process.env[p.envKey],
      estCostUsd: p.estCostUsd,
      label: p.label,
      maxInputDim: p.maxInputDim,
    };
  }
  return out;
}

async function magnificPolish({ image }) {
  const key = process.env.FREEPIK_API_KEY;
  if (!key) throw new Error('FREEPIK_API_KEY not set');
  const createRes = await fetch('https://api.freepik.com/v1/ai/image-upscaler', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'accept': 'application/json',
      'x-freepik-api-key': key,
    },
    body: JSON.stringify({
      image,
      scale_factor: '2x',
      sharpen: 50,
      smart_grain: 7,
      ultra_detail: 30,
    }),
  });
  if (!createRes.ok) throw new Error(`Magnific ${createRes.status}: ${(await createRes.text()).slice(0, 400)}`);
  const created = await createRes.json();
  const taskId = created?.data?.task_id;
  if (!taskId) throw new Error('Magnific returned no task_id');

  const deadline = Date.now() + 240_000; // 4 min cap — Magnific edits typically finish in 30–90s
  let task = created.data;
  while (task.status !== 'COMPLETED' && task.status !== 'FAILED' && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 2500));
    const pollRes = await fetch(`https://api.freepik.com/v1/ai/image-upscaler/${taskId}`, {
      headers: { 'x-freepik-api-key': key, 'accept': 'application/json' },
    });
    if (!pollRes.ok) throw new Error(`Magnific poll ${pollRes.status}`);
    task = (await pollRes.json())?.data;
    if (!task) throw new Error('Magnific poll returned no data');
  }
  if (task.status !== 'COMPLETED') throw new Error(`Magnific ${task.status || 'timeout'}`);
  const outUrl = Array.isArray(task.generated) ? task.generated[0] : null;
  if (!outUrl) throw new Error('Magnific returned no image URL');
  const imgRes = await fetch(outUrl);
  if (!imgRes.ok) throw new Error(`Magnific output fetch ${imgRes.status}`);
  const buf = Buffer.from(await imgRes.arrayBuffer());
  return { mediaType: imgRes.headers.get('content-type') || 'image/jpeg', data: buf.toString('base64') };
}

async function clarityPolish({ image, mediaType }) {
  const token = process.env.REPLICATE_API_TOKEN;
  if (!token) throw new Error('REPLICATE_API_TOKEN not set');
  const model = process.env.CLARITY_MODEL || POLISH_PROVIDERS.clarity.defaultModel;
  const createRes = await fetch(`https://api.replicate.com/v1/models/${model}/predictions`, {
    method: 'POST',
    headers: {
      'authorization': `Bearer ${token}`,
      'content-type': 'application/json',
      'prefer': 'wait=60',
    },
    body: JSON.stringify({
      input: {
        image: `data:${mediaType};base64,${image}`,
        scale_factor: 2,
        creativity: 0.35,
        resemblance: 0.6,
        dynamic: 6,
        output_format: 'png',
      },
    }),
  });
  if (!createRes.ok) throw new Error(`Clarity ${createRes.status}: ${(await createRes.text()).slice(0, 400)}`);
  let pred = await createRes.json();
  const deadline = Date.now() + 240_000;
  while ((pred.status === 'starting' || pred.status === 'processing') && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 2000));
    const pollRes = await fetch(`https://api.replicate.com/v1/predictions/${pred.id}`, {
      headers: { 'authorization': `Bearer ${token}` },
    });
    pred = await pollRes.json();
  }
  if (pred.status !== 'succeeded') throw new Error(`Clarity ${pred.status}: ${pred.error || 'timeout'}`);
  const outUrl = Array.isArray(pred.output) ? pred.output[0] : pred.output;
  if (typeof outUrl !== 'string') throw new Error('Clarity returned no image URL');
  const imgRes = await fetch(outUrl);
  if (!imgRes.ok) throw new Error(`Clarity output fetch ${imgRes.status}`);
  const buf = Buffer.from(await imgRes.arrayBuffer());
  return { mediaType: imgRes.headers.get('content-type') || 'image/png', data: buf.toString('base64') };
}

app.post('/ai/photo-polish', async (req, res) => {
  const { image, provider } = req.body || {};
  const p = provider || 'magnific';
  if (typeof image !== 'string' || !image.startsWith('data:image/')) {
    return res.status(400).json({ error: 'image must be a data URL' });
  }
  if (!POLISH_PROVIDERS[p]) return res.status(400).json({ error: `unknown polish provider: ${p}` });
  const m = image.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
  if (!m) return res.status(400).json({ error: 'invalid image data URL' });
  try {
    let result;
    if (p.startsWith('magnific')) result = await magnificPolish({ image: m[2] });
    else if (p === 'clarity') result = await clarityPolish({ image: m[2], mediaType: m[1] });
    res.json({ image: `data:${result.mediaType};base64,${result.data}`, provider: p });
  } catch (err) {
    console.error('photo-polish error:', err.message);
    res.status(500).json({ error: 'polish_failed', detail: err.message });
  }
});

app.get('/ai/status', async (req, res) => {
  const gen = genProviderStatus();
  const polish = polishProviderStatus();
  if (AI_BACKEND === 'claude-code') {
    const ok = await checkClaudeCodeAvailable();
    return res.json({ ready: ok, model: 'claude-code', backend: 'claude-code', gen, polish });
  }
  res.json({ ready: anthropicReady(), model: AI_MODEL, backend: 'sdk', gen, polish });
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

// ── Live Photo AI ────────────────────────────────────────────────────────────
//
// Webcam editor at /photo-ai. Claude looks at a snapshot from the camera + the
// user's prompt, and returns filter / overlay parameters that the canvas
// applies to every frame in real time. Vision-language model picks the look;
// the browser does the actual pixel work.

const LOOK_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: [
    'caption','brightness','contrast','saturate','hueRotate','sepia','grayscale',
    'blur','invert','vignette','grain','tintColor','tintAlpha','glow',
  ],
  properties: {
    caption:    { type: 'string', description: 'Short name of the look, 2–6 words.' },
    brightness: { type: 'number', minimum: 0.4, maximum: 1.8, description: '1 = neutral.' },
    contrast:   { type: 'number', minimum: 0.4, maximum: 1.8, description: '1 = neutral.' },
    saturate:   { type: 'number', minimum: 0,   maximum: 2.5, description: '1 = neutral. 0 = grayscale.' },
    hueRotate:  { type: 'number', minimum: -180, maximum: 180, description: 'Degrees.' },
    sepia:      { type: 'number', minimum: 0,   maximum: 1 },
    grayscale:  { type: 'number', minimum: 0,   maximum: 1 },
    blur:       { type: 'number', minimum: 0,   maximum: 4, description: 'Pixels. Subtle softening only.' },
    invert:     { type: 'number', minimum: 0,   maximum: 1, description: 'Usually 0.' },
    vignette:   { type: 'number', minimum: 0,   maximum: 1, description: 'Dark corners.' },
    grain:      { type: 'number', minimum: 0,   maximum: 1, description: 'Film grain overlay.' },
    tintColor:  { type: 'string', pattern: '^#[0-9a-fA-F]{6}$', description: 'Hex color of soft-light tint overlay.' },
    tintAlpha:  { type: 'number', minimum: 0,   maximum: 0.6, description: 'Strength of tint. Usually 0–0.3.' },
    glow:       { type: 'number', minimum: 0,   maximum: 1, description: 'Soft halation around highlights.' },
  },
};

const EDIT_SYSTEM = `You are a virtual colorist for a live webcam photo app. You can't repaint pixels — you choose a set of filter and overlay parameters that the browser will apply to every frame in real time.

You receive:
1. A snapshot of the current camera frame.
2. A short user prompt describing the desired feel (it may be empty — in that case pick something tasteful and flattering for what you see).

Return a JSON object matching the schema. Guidelines:
- 1.0 means neutral for brightness / contrast / saturate. Don't push values to the extremes unless the prompt clearly calls for it.
- For black-and-white looks, set saturate to 0 OR grayscale to 1 (not both).
- For warm looks, use a small positive hueRotate (5–15) or a tintColor in the orange/amber range with tintAlpha 0.1–0.25.
- For cool looks, negative hueRotate or a blue/teal tintColor.
- Sepia is heavy — use 0.2–0.5 for vintage, only above 0.6 for very strong sepia.
- vignette 0.2–0.5 reads as cinematic. 0.7+ is theatrical.
- grain 0.1–0.3 is filmic; above 0.6 is heavy grain.
- glow 0.1–0.3 adds soft halation; above 0.5 gets dreamy/hazy. glow ≥ 0.7 washes the frame out — only use that for explicit "dreamy / foggy / hazy" prompts. NEVER use glow for "smooth", "polish", "clean", or "denoise" — that's what blur is for.
- blur is the right tool for "smooth", "polish", "soft", "remove noise", "denoise", "clean up" requests — use 0.5–1.5 for those. For other looks keep blur at 0 or under 1.
- Don't stack multiple lightening effects: brightness > 1.2 + glow > 0.4 + a light tintColor with tintAlpha > 0.2 together will produce a near-white, washed-out frame. Pick one lightening tool and keep the others restrained.
- CRITICAL — DO NOT DARKEN DIM PHOTOS. If the source is already dim (showroom, garage, indoor low-light, night scene, underexposed) then brightness MUST be ≥ 1.05 and vignette MUST be ≤ 0.3. Cinematic mood on a dim photo comes from contrast (1.15–1.35) + a tintColor (teal/orange/amber with tintAlpha 0.15–0.25), NOT from lowering brightness or piling on vignette. A "cinematic" look on an already-dark photo with brightness 0.7 + vignette 0.7 makes it unreadable — never do that.
- Only LOWER brightness (< 1.0) on photos that are clearly OVER-exposed: blown highlights, washed-out scenes, harsh midday sun. If the photo looks normally exposed or dim, keep brightness ≥ 1.0.
- caption is a 2–6 word name for the look (e.g. "warm 70s film", "noir contrast", "neon dream").
- Consider the actual scene: a dim indoor shot wants brightness 1.05–1.2 + contrast bump; a blown-out window scene wants contrast up and brightness down (0.85–0.95).

Output ONLY the JSON object matching the schema. No prose, no markdown.`;

app.post('/ai/photo-edit', async (req, res) => {
  const { image, prompt } = req.body || {};
  if (typeof image !== 'string' || !image.startsWith('data:image/')) {
    return res.status(400).json({ error: 'image must be a data URL (data:image/...;base64,...)' });
  }
  const m = image.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
  if (!m) return res.status(400).json({ error: 'invalid image data URL' });

  const userPrompt = (typeof prompt === 'string' ? prompt : '').trim();

  try {
    let look;
    if (AI_BACKEND === 'claude-code') {
      look = await claudeCodePhotoEdit(m[1], m[2], userPrompt);
    } else {
      if (!anthropicReady()) {
        return res.status(400).json({ error: 'ai_not_configured', detail: 'Set ANTHROPIC_API_KEY or AI_BACKEND=claude-code to enable.' });
      }
      const userText = userPrompt
        ? `User prompt: ${userPrompt}\n\nLook at the snapshot and choose filter parameters that produce this feel.`
        : `No prompt given — choose a tasteful, flattering look for what you see in this snapshot.`;
      const response = await getAnthropicClient().messages.create({
        model: AI_MODEL,
        max_tokens: 512,
        system: [{ type: 'text', text: EDIT_SYSTEM, cache_control: { type: 'ephemeral' } }],
        output_config: { format: { type: 'json_schema', schema: LOOK_SCHEMA } },
        messages: [{
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: m[1], data: m[2] } },
            { type: 'text', text: userText },
          ],
        }],
      });
      const text = response.content.find((b) => b.type === 'text')?.text;
      look = text ? JSON.parse(text) : null;
    }
    if (!look) return res.status(502).json({ error: 'ai_empty', detail: 'no JSON returned' });
    res.json({ look: softenDarkLook(look, !!userPrompt) });
  } catch (err) {
    const status = err.status || (err instanceof Anthropic.APIError ? err.status || 500 : 500);
    console.error('photo-edit error:', err.message);
    res.status(status).json({ error: 'ai_failed', detail: err.message });
  }
});

// Guardrail: even with the system-prompt warning, Claude occasionally pairs
// brightness < 1.0 with vignette > 0.4 on dim source photos, or applies a
// dark tintColor at high tintAlpha — both crush the image to near-black.
// AUTO-grade gets aggressive caps so the user always sees a readable photo.
// When the user explicitly prompts (e.g. "moody noir"), we relax everything
// because they've asked for the dark mood.
function softenDarkLook(look, hasUserPrompt) {
  if (!look) return look;
  const before = { ...look };

  if (typeof look.brightness === 'number') {
    if (!hasUserPrompt && look.brightness < 1.0) look.brightness = 1.0;
  }
  if (typeof look.contrast === 'number') {
    if (!hasUserPrompt && look.contrast > 1.2) look.contrast = 1.2;
    if (hasUserPrompt && look.contrast > 1.4) look.contrast = 1.4;
  }
  if (typeof look.vignette === 'number') {
    if (!hasUserPrompt && look.vignette > 0.2) look.vignette = 0.2;
    if (hasUserPrompt && look.vignette > 0.5) look.vignette = 0.5;
  }
  if (typeof look.tintColor === 'string' && typeof look.tintAlpha === 'number') {
    const m = look.tintColor.match(/^#([0-9a-f]{6})$/i);
    if (m) {
      const r = parseInt(m[1].slice(0, 2), 16);
      const g = parseInt(m[1].slice(2, 4), 16);
      const b = parseInt(m[1].slice(4, 6), 16);
      const luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
      const cap = !hasUserPrompt ? (luma < 0.5 ? 0.12 : 0.25)
                                 : (luma < 0.3 ? 0.2 : luma < 0.5 ? 0.35 : 0.5);
      if (look.tintAlpha > cap) look.tintAlpha = cap;
    }
  }
  if (typeof look.grain === 'number') {
    if (!hasUserPrompt && look.grain > 0.3) look.grain = 0.3;
  }

  const diffs = [];
  for (const k of ['brightness', 'contrast', 'vignette', 'tintAlpha', 'grain']) {
    if (before[k] !== look[k]) diffs.push(`${k}: ${before[k]} → ${look[k]}`);
  }
  const mode = hasUserPrompt ? 'prompt' : 'auto';
  // Log every field so we can spot any extreme value (invert, glow, blur,
  // grayscale, sepia, hueRotate, saturate) that could be darkening.
  const full = `bright=${look.brightness} contrast=${look.contrast} sat=${look.saturate} hue=${look.hueRotate} sepia=${look.sepia} gray=${look.grayscale} blur=${look.blur} invert=${look.invert} vign=${look.vignette} grain=${look.grain} glow=${look.glow} tint=${look.tintColor}@${look.tintAlpha}`;
  if (diffs.length) console.log(`[guardrail/${mode}] softened "${look.caption}":`, diffs.join(', '), '|', full);
  else console.log(`[grade/${mode}] "${look.caption}":`, full);
  return look;
}

app.get('/photo-ai', (req, res) => res.sendFile(path.join(__dirname, 'public', 'photo-ai.html')));
app.get('/lumen', (req, res) => res.sendFile(path.join(__dirname, 'public', 'lumen.html')));
app.get('/aperture', (req, res) => res.sendFile(path.join(__dirname, 'public', 'aperture.html')));
app.get('/garage', (req, res) => {
  // Force the browser to revalidate /garage every load — without this,
  // Chrome aggressively caches the HTML and users running through
  // multiple iterations of edit-mode fixes were stuck on stale JS.
  res.set('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
  res.sendFile(path.join(__dirname, 'public', 'garage.html'));
});

// ── Smarter auto-grade: analyze + propose 4 tailored looks in one call ───────
// Replaces the fan-out of 4 separate /ai/photo-edit calls with a single
// richer call. Claude reads the photo, identifies subject / lighting /
// mood, then proposes 4 distinct looks NAMED for what suits THIS photo
// (e.g. "Showroom Polish" / "Track Day" / "Magazine Editorial" / "Noir
// Concept" instead of generic "Natural / Cinematic / Film / Vivid").
//
// Each variant comes with a one-sentence rationale so the user
// understands why Claude is suggesting it. Cheaper than 4 separate
// calls (1 image transfer instead of 4) and noticeably smarter.

const LOOK_PROPS = LOOK_SCHEMA.properties;
const GRADE_PACK_SCHEMA = {
  type: 'object',
  required: ['analysis', 'variants'],
  additionalProperties: false,
  properties: {
    analysis: {
      type: 'object',
      required: ['subject', 'lighting', 'mood'],
      additionalProperties: false,
      properties: {
        subject:  { type: 'string', description: '1–4 words for what the photo is of (e.g. "car detail", "portrait", "landscape").' },
        lighting: { type: 'string', description: '1–6 words on lighting condition + quality (e.g. "indoor showroom · warm", "golden hour outdoor").' },
        mood:     { type: 'string', description: '1–4 words for the overall vibe (e.g. "polished, premium", "moody, dark").' },
        notes:    { type: 'string', description: 'Optional: 1 sentence on what could be improved or preserved.' },
      },
    },
    variants: {
      type: 'array', minItems: 4, maxItems: 4,
      items: {
        type: 'object',
        required: ['name', 'rationale', 'look'],
        additionalProperties: false,
        properties: {
          name:      { type: 'string', description: '2–4 word name tailored to this specific photo. Avoid generic words like "Natural" or "Cinematic" unless they\'re truly the best fit.' },
          rationale: { type: 'string', description: 'One sentence explaining why this look suits the shot.' },
          look:      { type: 'object', required: LOOK_SCHEMA.required, additionalProperties: false, properties: LOOK_PROPS },
        },
      },
    },
  },
};

const GRADE_PACK_SYSTEM = `${EDIT_SYSTEM}

You are now in PACK mode — instead of returning ONE look, return an ANALYSIS of the photo plus FOUR distinct looks that suit it.

The 4 variants should be:
- VISUALLY DIFFERENT from each other (don't return 4 similar warm grades)
- NAMED for what makes them right for THIS photo (a car shot variant could be "Showroom Polish"; a portrait could be "Window Light Soft"; a landscape could be "Golden Hour Lift"). Avoid the generic words "Natural", "Cinematic", "Film", "Vivid" unless one of those is genuinely the perfect description.
- Each accompanied by a one-sentence rationale explaining the choice.

The analysis fields (subject, lighting, mood) should be specific and concise — a single line each. Notes is optional, only include if there's something useful to flag.

All look-parameter rules from the regular EDIT_SYSTEM apply to every variant — especially the dim-photo brightness/vignette/contrast rules.

Output ONLY the JSON object matching the pack schema. No prose, no markdown.`;

async function claudeCodeGradePack(mediaType, b64) {
  const ext = mediaType.split('/')[1] || 'jpg';
  const id = crypto.randomUUID();
  const imgFile = path.join(os.tmpdir(), `gradepack-${id}.${ext}`);
  const instFile = path.join(os.tmpdir(), `gradepack-${id}.txt`);
  fs.writeFileSync(imgFile, Buffer.from(b64, 'base64'));
  // The pack system prompt + schema together exceed Windows cmd.exe's 8K
  // command-line limit. Write the long instructions to a tmp file and have
  // Claude Read both files — keeps the spawn args tiny.
  fs.writeFileSync(instFile, `${GRADE_PACK_SYSTEM}

Schema you must follow:
${JSON.stringify(GRADE_PACK_SCHEMA, null, 2)}

Output ONLY the JSON object — no prose, no markdown fences.`);
  try {
    const prompt = `Read the instructions at ${instFile} and the photo at ${imgFile}, then return the JSON pack per the schema.`;
    const text = await runClaudeCode(prompt, 240000);
    return extractJsonObject(text);
  } finally {
    try { fs.unlinkSync(imgFile); } catch {}
    try { fs.unlinkSync(instFile); } catch {}
  }
}

app.post('/ai/photo-grade-pack', async (req, res) => {
  const { image } = req.body || {};
  if (typeof image !== 'string' || !image.startsWith('data:image/')) {
    return res.status(400).json({ error: 'image must be a data URL' });
  }
  const m = image.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
  if (!m) return res.status(400).json({ error: 'invalid image data URL' });
  try {
    let pack;
    if (AI_BACKEND === 'claude-code') {
      pack = await claudeCodeGradePack(m[1], m[2]);
    } else {
      if (!anthropicReady()) {
        return res.status(400).json({ error: 'ai_not_configured', detail: 'Set ANTHROPIC_API_KEY or AI_BACKEND=claude-code.' });
      }
      const response = await getAnthropicClient().messages.create({
        model: process.env.AI_GRADE_MODEL || 'claude-opus-4-7',
        max_tokens: 2048,
        system: [{ type: 'text', text: GRADE_PACK_SYSTEM, cache_control: { type: 'ephemeral' } }],
        output_config: { format: { type: 'json_schema', schema: GRADE_PACK_SCHEMA } },
        messages: [{
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: m[1], data: m[2] } },
            { type: 'text', text: 'Analyze this photo and return 4 tailored grade variants per the schema.' },
          ],
        }],
      });
      const text = response.content.find((b) => b.type === 'text')?.text;
      pack = text ? JSON.parse(text) : null;
    }
    if (!pack?.variants?.length) return res.status(502).json({ error: 'ai_empty' });
    // Run each variant through the dim-photo guardrail (auto mode).
    pack.variants = pack.variants.map((v) => ({ ...v, look: softenDarkLook(v.look, false) }));
    res.json(pack);
  } catch (err) {
    console.error('photo-grade-pack error:', err.message);
    res.status(500).json({ error: 'gradepack_failed', detail: err.message });
  }
});

// ── Compose (auto-group photos into Instagram-ready sets) ────────────────────
// Sends a batch of thumbnails to Claude with vision and asks for:
//   - themed groups (subject/style clusters)
//   - profile_grids (3 / 6 / 9 photos that look cohesive in a 3-col feed)
//   - carousels (3–10 photos in best swipe order)
// Photos are referenced by client-supplied id so the response stays small
// and the client can map back to its IDB records.

const COMPOSE_MAX_PHOTOS = 30;
const COMPOSE_MODEL = process.env.AI_COMPOSE_MODEL || 'claude-opus-4-7';

const COMPOSE_SYSTEM = `You are an Instagram art director with an eye for cohesive visual sets.

You will receive a batch of photos, each tagged with an ID like "p1", "p2", "p3". Your job:

1. CLUSTER the photos into themed groups based on subject, lighting, palette, and mood. Each group should feel like it belongs in the same post or feed section.
2. PROPOSE PROFILE_GRIDS — groups of exactly 3, 6, or 9 photos that would look clean as a 3-column Instagram profile grid (so visual flow across rows matters).
3. PROPOSE CAROUSELS — sets of 3 to 10 photos in best swipe order for a single carousel post (open with a hero, vary pacing, close strong).

Rules:
- Only use the photo IDs given to you. Never invent IDs.
- A photo may appear in multiple proposals (e.g. cluster + grid + carousel) but inside ONE proposal it must appear at most once.
- Skip blurry / duplicate / weak photos rather than padding a group with them.
- Titles are 1–4 words, concrete (e.g. "Track day", "Garage moody"), not generic ("Cool shots").
- Rationales are one sentence, specific to THESE photos — call out what makes them cohesive (palette, subject, lighting).

Output ONLY the JSON object matching the schema. No prose, no markdown fences.`;

const COMPOSE_SCHEMA = {
  type: 'object',
  required: ['groups', 'profile_grids', 'carousels'],
  properties: {
    groups: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'rationale', 'photo_ids'],
        properties: {
          title: { type: 'string' },
          rationale: { type: 'string' },
          photo_ids: { type: 'array', items: { type: 'string' }, minItems: 2 },
        },
      },
    },
    profile_grids: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'rationale', 'photo_ids'],
        properties: {
          title: { type: 'string' },
          rationale: { type: 'string' },
          photo_ids: {
            type: 'array', items: { type: 'string' },
            minItems: 3, maxItems: 9,
          },
        },
      },
    },
    carousels: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'rationale', 'photo_ids'],
        properties: {
          title: { type: 'string' },
          rationale: { type: 'string' },
          photo_ids: {
            type: 'array', items: { type: 'string' },
            minItems: 3, maxItems: 10,
          },
        },
      },
    },
  },
};

function validateComposeResponse(parsed, validIds) {
  const ids = new Set(validIds);
  const filterValid = (arr) => arr.filter((id) => ids.has(id));
  const out = { groups: [], profile_grids: [], carousels: [] };
  for (const g of parsed.groups || []) {
    const photo_ids = filterValid(g.photo_ids || []);
    if (photo_ids.length >= 2) out.groups.push({ ...g, photo_ids });
  }
  for (const g of parsed.profile_grids || []) {
    const photo_ids = filterValid(g.photo_ids || []);
    if (photo_ids.length >= 3) out.profile_grids.push({ ...g, photo_ids: photo_ids.slice(0, 9) });
  }
  for (const c of parsed.carousels || []) {
    const photo_ids = filterValid(c.photo_ids || []);
    if (photo_ids.length >= 3) out.carousels.push({ ...c, photo_ids: photo_ids.slice(0, 10) });
  }
  return out;
}

async function claudeCodeCompose(photos) {
  const tmpFiles = [];
  try {
    const fileLines = photos.map((p, i) => {
      const ext = (p.mediaType || 'image/jpeg').split('/')[1] || 'jpg';
      const tmpFile = path.join(os.tmpdir(), `compose-${crypto.randomUUID()}.${ext}`);
      fs.writeFileSync(tmpFile, Buffer.from(p.image, 'base64'));
      tmpFiles.push(tmpFile);
      return `  ${p.id} → ${tmpFile}`;
    }).join('\n');

    const prompt = `${COMPOSE_SYSTEM}

Read each photo with the Read tool. Photos and their IDs:
${fileLines}

Schema you must follow:
${JSON.stringify(COMPOSE_SCHEMA, null, 2)}

Output ONLY the JSON object — no prose, no markdown fences.`;
    const text = await runClaudeCode(prompt, 240000);
    return extractJsonObject(text);
  } finally {
    for (const f of tmpFiles) { try { fs.unlinkSync(f); } catch {} }
  }
}

app.post('/ai/photo-compose', async (req, res) => {
  const { photos } = req.body || {};
  if (!Array.isArray(photos) || photos.length < 3) {
    return res.status(400).json({ error: 'need at least 3 photos to compose' });
  }
  if (photos.length > COMPOSE_MAX_PHOTOS) {
    return res.status(400).json({ error: `too many photos — cap is ${COMPOSE_MAX_PHOTOS}` });
  }

  const parsed = [];
  for (const p of photos) {
    if (typeof p.id !== 'string' || !p.id) return res.status(400).json({ error: 'each photo needs an id' });
    if (typeof p.image !== 'string' || !p.image.startsWith('data:image/')) {
      return res.status(400).json({ error: 'each photo needs an image data URL' });
    }
    const m = p.image.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
    if (!m) return res.status(400).json({ error: 'invalid image data URL' });
    parsed.push({ id: p.id, mediaType: m[1], image: m[2] });
  }
  const validIds = parsed.map((p) => p.id);

  try {
    let raw;
    if (AI_BACKEND === 'claude-code') {
      raw = await claudeCodeCompose(parsed);
    } else {
      if (!anthropicReady()) {
        return res.status(400).json({ error: 'ai_not_configured', detail: 'Set ANTHROPIC_API_KEY or AI_BACKEND=claude-code.' });
      }
      const content = [];
      for (const p of parsed) {
        content.push({ type: 'text', text: `[id: ${p.id}]` });
        content.push({ type: 'image', source: { type: 'base64', media_type: p.mediaType, data: p.image } });
      }
      content.push({ type: 'text', text: 'Group these photos into themed clusters, propose profile grids (3/6/9 photos), and carousel posts (3–10 photos in swipe order). Output JSON matching the schema.' });
      const response = await getAnthropicClient().messages.create({
        model: COMPOSE_MODEL,
        max_tokens: 4096,
        system: [{ type: 'text', text: COMPOSE_SYSTEM, cache_control: { type: 'ephemeral' } }],
        output_config: { format: { type: 'json_schema', schema: COMPOSE_SCHEMA } },
        messages: [{ role: 'user', content }],
      });
      const text = response.content.find((b) => b.type === 'text')?.text;
      raw = text ? JSON.parse(text) : null;
    }
    if (!raw) return res.status(502).json({ error: 'ai_empty' });
    const cleaned = validateComposeResponse(raw, validIds);
    res.json(cleaned);
  } catch (err) {
    console.error('photo-compose error:', err.message);
    res.status(500).json({ error: 'compose_failed', detail: err.message });
  }
});

// ── Claude Design (Max ed.) ──────────────────────────────────────────────────
//
// A small single-player clone of the iteration loop at claude.ai/design:
//   POST /design/ingest    — read a URL / image / paste, extract brand tokens
//   POST /design/generate  — produce an HTML design themed with those tokens
//   GET  /design/tokens    — currently saved brand tokens
//   POST /design/tokens    — save tokens (after live tweaking)
//   GET  /design           — serve the editor page

const DESIGN_MODEL = process.env.AI_DESIGN_MODEL || 'claude-opus-4-7';
const BRAND_TOKENS_FILE = path.join(__dirname, '.brand-tokens.json');

const DEFAULT_TOKENS = {
  colors: {
    bg:      '#F0EEE6',
    surface: '#FAF9F5',
    ink:     '#1F1F1E',
    muted:   '#6B6A65',
    accent:  '#CC785C',
    accent2: '#6B6A48',
  },
  fonts: { display: 'Fraunces', body: 'Inter', mono: 'JetBrains Mono' },
  radius: { sm: '4px', md: '10px', lg: '18px' },
  notes: 'default Anthropic-style ivory + coral system',
};

function loadBrandTokens() {
  try {
    if (fs.existsSync(BRAND_TOKENS_FILE)) {
      return JSON.parse(fs.readFileSync(BRAND_TOKENS_FILE, 'utf8'));
    }
  } catch {}
  return DEFAULT_TOKENS;
}
function saveBrandTokens(t) {
  fs.writeFileSync(BRAND_TOKENS_FILE, JSON.stringify(t, null, 2), 'utf8');
}

function parseLooseJson(text) {
  if (!text) throw new Error('empty model output');
  let t = String(text).trim();
  // strip ```json … ``` fences if present
  t = t.replace(/^```(?:json)?\s*/i, '').replace(/\s*```\s*$/i, '').trim();
  try { return JSON.parse(t); } catch {}
  const m = t.match(/\{[\s\S]*\}/);
  if (m) { try { return JSON.parse(m[0]); } catch {} }
  throw new Error('no valid JSON object in model output');
}

async function callDesignModel({ system, user, maxTokens = 16000 }) {
  if (AI_BACKEND === 'claude-code') {
    const prompt = `${system}\n\n${user}\n\nOutput ONLY the JSON object — no prose, no markdown fences.`;
    const text = await runClaudeCode(prompt, 240000);
    return parseLooseJson(text);
  }
  if (!anthropicReady()) { const e = new Error('AI not configured (set ANTHROPIC_API_KEY or AI_BACKEND=claude-code)'); e.status = 400; throw e; }
  const response = await getAnthropicClient().messages.create({
    model: DESIGN_MODEL,
    max_tokens: maxTokens,
    system: [{ type: 'text', text: system, cache_control: { type: 'ephemeral' } }],
    messages: [{ role: 'user', content: user }],
  });
  const text = response.content.find((b) => b.type === 'text')?.text;
  return parseLooseJson(text);
}

async function callDesignVisionModel({ system, instruction, mediaType, b64, maxTokens = 4000 }) {
  if (AI_BACKEND === 'claude-code') {
    const ext = mediaType.split('/')[1] || 'png';
    const tmpFile = path.join(os.tmpdir(), `brand-${crypto.randomUUID()}.${ext}`);
    fs.writeFileSync(tmpFile, Buffer.from(b64, 'base64'));
    try {
      const prompt = `${system}\n\nUse the Read tool to view the image at ${tmpFile}. ${instruction}\n\nOutput ONLY the JSON object — no prose, no markdown fences.`;
      const text = await runClaudeCode(prompt, 180000);
      return parseLooseJson(text);
    } finally {
      try { fs.unlinkSync(tmpFile); } catch {}
    }
  }
  if (!anthropicReady()) { const e = new Error('AI not configured'); e.status = 400; throw e; }
  const response = await getAnthropicClient().messages.create({
    model: DESIGN_MODEL,
    max_tokens: maxTokens,
    system: [{ type: 'text', text: system, cache_control: { type: 'ephemeral' } }],
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: mediaType, data: b64 } },
        { type: 'text', text: instruction },
      ],
    }],
  });
  const text = response.content.find((b) => b.type === 'text')?.text;
  return parseLooseJson(text);
}

const INGEST_SYSTEM = `You are a brand-system extractor. From the input (a website's HTML, a pasted style guide, or an image), infer a minimal design token set that, applied to a fresh page, would feel like the same brand.

Return exactly this JSON shape — no extra fields:
{
  "colors":  { "bg": "#hex", "surface": "#hex", "ink": "#hex", "muted": "#hex", "accent": "#hex", "accent2": "#hex" },
  "fonts":   { "display": "Google Fonts family name", "body": "Google Fonts family name", "mono": "Google Fonts family name" },
  "radius":  { "sm": "Xpx", "md": "Xpx", "lg": "Xpx" },
  "notes":   "one short sentence summarizing the system"
}

Guidance:
- bg = dominant page background; surface = card/panel; ink = primary text; muted = secondary text.
- accent = the brand's signal color (usually the CTA / link / brand mark). accent2 = a complementary secondary.
- Pick fonts that are on Google Fonts. If the brand uses a closed font (SF, Söhne, Styrene), choose a close Google Fonts substitute and say so in notes.
- Radii should reflect the brand's softness (sharp = 0/2/6, soft = 6/14/24, very soft = 12/22/36).
- Output ONLY the JSON object. No prose, no markdown fences.`;

const GENERATE_SYSTEM = `You are a senior visual designer producing complete, polished single-file HTML pages — the kind of "specimen" output you'd see at claude.ai/design.

You MUST output exactly this JSON shape:
{
  "html":    "<a complete standalone HTML5 document as a single string>",
  "tokens":  { same shape as the input tokens, possibly tweaked to fit the design },
  "summary": "one short sentence describing what you made"
}

Hard rules for the HTML:
- Complete document: <!doctype html><html><head>…</head><body>…</body></html>.
- Pull fonts from Google Fonts using the families in tokens.fonts (display, body, mono).
- Define ALL of these CSS custom properties on :root and USE them everywhere:
    --brand-bg, --brand-surface, --brand-ink, --brand-muted, --brand-accent, --brand-accent2,
    --brand-font-display, --brand-font-body, --brand-font-mono,
    --brand-radius-sm, --brand-radius-md, --brand-radius-lg
- Set them from the supplied tokens. Never hardcode brand colors or fonts elsewhere — always use the variables. This is critical: a live tweak panel will mutate those variables and the page must reflect the changes.
- Give every top-level structural element (section, header, footer, etc.) a stable id, so partial-refine edits can target it.
- One file, no external assets besides Google Fonts and inline SVG.
- Editorial, designed, generous whitespace. Multiple sections. Real (illustrative) content — not lorem ipsum.
- Mobile responsive with a single @media (max-width: 900px) breakpoint.
- No JavaScript unless the design genuinely needs it.

Output ONLY the JSON object — no prose, no markdown fences.`;

const REFINE_SYSTEM = `You are doing surgical edits inside an already-generated design page. You receive ONE region of HTML and an instruction describing how to change it. Return a replacement for that region only — the rest of the page is untouched.

Output exactly this JSON shape:
{
  "html":    "<replacement region as a single HTML string>",
  "summary": "one short sentence describing what changed"
}

Hard rules:
- Replace the WHOLE region. Your output must be valid HTML that can replace the input verbatim in the parent document.
- Preserve the root element type and its id: a <section id="quotas"> must come back as <section id="quotas">. Keep major classes if they were present.
- Continue using the same CSS custom properties (--brand-bg, --brand-surface, --brand-ink, --brand-muted, --brand-accent, --brand-accent2, --brand-font-display, --brand-font-body, --brand-font-mono, --brand-radius-sm/md/lg). Never hardcode brand colors or font families.
- Inline <style> blocks are fine and may be embedded inside the region; do NOT add <link> tags or <script>. The host page already loads fonts.
- Do not include <html>, <head>, or <body> wrappers. Just the region.

Output ONLY the JSON object — no prose, no markdown fences.`;

app.get('/design', (req, res) => res.sendFile(path.join(__dirname, 'public', 'claude-design.html')));

app.get('/design/tokens', (req, res) => {
  res.json({ tokens: loadBrandTokens() });
});

app.post('/design/tokens', (req, res) => {
  const t = req.body?.tokens;
  if (!t || typeof t !== 'object') return res.status(400).json({ error: 'missing tokens' });
  saveBrandTokens(t);
  res.json({ ok: true, tokens: t });
});

// SSRF guard for /design/ingest URL fetches. Block loopback, private,
// link-local (incl. cloud metadata at 169.254.169.254), multicast, ULA.
// Applied at the DNS-lookup layer via custom http(s) Agents so it also
// catches redirects and DNS rebinding.
function isBlockedIp(ip) {
  if (!ip || typeof ip !== 'string') return true;
  if (net.isIPv4(ip)) {
    const [a, b] = ip.split('.').map(Number);
    if (a === 0) return true;                                  // 0/8 unspecified
    if (a === 10) return true;                                 // 10/8 private
    if (a === 127) return true;                                // 127/8 loopback
    if (a === 169 && b === 254) return true;                   // 169.254/16 link-local (cloud metadata)
    if (a === 172 && b >= 16 && b <= 31) return true;          // 172.16/12 private
    if (a === 192 && b === 168) return true;                   // 192.168/16 private
    if (a >= 224) return true;                                 // 224/4 multicast + 240/4 reserved
    return false;
  }
  if (net.isIPv6(ip)) {
    const v = ip.toLowerCase();
    if (v === '::' || v === '::1') return true;                // unspecified / loopback
    if (/^fe[89ab]/.test(v)) return true;                      // fe80::/10 link-local
    if (/^f[cd]/.test(v)) return true;                         // fc00::/7 unique-local
    if (/^ff/.test(v)) return true;                            // ff00::/8 multicast
    const m = v.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);        // IPv4-mapped
    if (m) return isBlockedIp(m[1]);
    return false;
  }
  return true;
}
function safeLookup(hostname, options, cb) {
  if (typeof options === 'function') { cb = options; options = {}; }
  dns.lookup(hostname, options || {}, (err, addressOrList, family) => {
    if (err) return cb(err);
    // Node may return a string (default) or an array of {address,family} (autoSelectFamily / all:true).
    const records = Array.isArray(addressOrList)
      ? addressOrList
      : [{ address: addressOrList, family }];
    for (const rec of records) {
      if (isBlockedIp(rec.address)) {
        return cb(Object.assign(
          new Error('refused: host resolves to a private/loopback/link-local address (' + rec.address + ')'),
          { code: 'EBLOCKEDHOST', status: 400 }
        ));
      }
    }
    cb(null, addressOrList, family);
  });
}
const safeHttpAgent  = new http.Agent({ lookup: safeLookup, keepAlive: false });
const safeHttpsAgent = new https.Agent({ lookup: safeLookup, keepAlive: false });

const INGEST_MAX_BYTES = 200_000;

app.post('/design/ingest', async (req, res) => {
  const { url, image, paste } = req.body || {};
  try {
    let tokens;
    if (typeof url === 'string' && url.trim()) {
      const u = url.trim();
      let parsed;
      try { parsed = new URL(u); } catch { return res.status(400).json({ error: 'invalid url' }); }
      if (!/^https?:$/.test(parsed.protocol)) return res.status(400).json({ error: 'url must be http or https' });
      // Reject IP literals in blocked ranges before any network IO (clearer error).
      if (net.isIP(parsed.hostname) && isBlockedIp(parsed.hostname)) {
        return res.status(400).json({ error: 'refused: host is private/loopback/link-local' });
      }
      const r = await axios.get(u, {
        timeout: 15000,
        maxRedirects: 3,
        maxContentLength: INGEST_MAX_BYTES,
        maxBodyLength:    INGEST_MAX_BYTES,
        httpAgent:  safeHttpAgent,
        httpsAgent: safeHttpsAgent,
        headers: { 'User-Agent': 'Mozilla/5.0 (claude-design ingest)' },
        responseType: 'text',
        transformResponse: [(d) => d],
      });
      const html = String(r.data || '').slice(0, 120_000);
      tokens = await callDesignModel({
        system: INGEST_SYSTEM,
        user: `Source: ${u}\n\nFetched HTML (possibly truncated):\n\n${html}`,
        maxTokens: 1500,
      });
    } else if (typeof image === 'string' && image.startsWith('data:image/')) {
      const m = image.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
      if (!m) return res.status(400).json({ error: 'invalid image data URL' });
      tokens = await callDesignVisionModel({
        system: INGEST_SYSTEM,
        instruction: 'Extract the brand tokens that would let me design a new page that feels like this image.',
        mediaType: m[1], b64: m[2],
      });
    } else if (typeof paste === 'string' && paste.trim()) {
      tokens = await callDesignModel({
        system: INGEST_SYSTEM,
        user: `Pasted brand material (style guide, tailwind config, CSS, notes):\n\n${paste.slice(0, 60_000)}`,
        maxTokens: 1500,
      });
    } else {
      return res.status(400).json({ error: 'provide one of: url, image (data URL), paste' });
    }
    saveBrandTokens(tokens);
    res.json({ tokens });
  } catch (err) {
    // Surface SSRF blocks and oversize responses as 4xx (axios wraps the underlying error).
    const blockedHost = err.code === 'EBLOCKEDHOST' || err.cause?.code === 'EBLOCKEDHOST';
    const tooLarge    = err.code === 'ERR_FR_MAX_CONTENT_LENGTH_EXCEEDED' || err.code === 'ERR_FR_MAX_BODY_LENGTH_EXCEEDED';
    const status = blockedHost || tooLarge ? 400
                 : err.status
                 || (err instanceof Anthropic.APIError ? err.status || 500 : 500);
    console.error('design/ingest error:', err.message);
    res.status(status).json({ error: 'ingest_failed', detail: err.message });
  }
});

app.post('/design/refine', async (req, res) => {
  const { html, instruction, tokens } = req.body || {};
  if (typeof html !== 'string' || !html.trim()) return res.status(400).json({ error: 'missing html region' });
  if (typeof instruction !== 'string' || !instruction.trim()) return res.status(400).json({ error: 'missing instruction' });
  const t = (tokens && typeof tokens === 'object') ? tokens : loadBrandTokens();
  try {
    const out = await callDesignModel({
      system: REFINE_SYSTEM,
      user: `Brand tokens in use:\n${JSON.stringify(t, null, 2)}\n\nRegion to refine:\n${html.slice(0, 40000)}\n\nInstruction:\n${instruction.trim()}`,
      maxTokens: 8000,
    });
    if (!out || typeof out.html !== 'string') return res.status(502).json({ error: 'bad model output', detail: 'missing html field' });
    res.json({ html: out.html, summary: out.summary || '' });
  } catch (err) {
    const status = err.status || (err instanceof Anthropic.APIError ? err.status || 500 : 500);
    console.error('design/refine error:', err.message);
    res.status(status).json({ error: 'refine_failed', detail: err.message });
  }
});

app.post('/design/generate', async (req, res) => {
  const { prompt, tokens } = req.body || {};
  if (typeof prompt !== 'string' || !prompt.trim()) return res.status(400).json({ error: 'missing prompt' });
  const t = (tokens && typeof tokens === 'object') ? tokens : loadBrandTokens();
  try {
    const out = await callDesignModel({
      system: GENERATE_SYSTEM,
      user: `Brand tokens to use:\n${JSON.stringify(t, null, 2)}\n\nDesign brief:\n${prompt.trim()}`,
      maxTokens: 16000,
    });
    if (!out || typeof out.html !== 'string') {
      return res.status(502).json({ error: 'bad model output', detail: 'missing html field' });
    }
    res.json({ html: out.html, tokens: out.tokens || t, summary: out.summary || '' });
  } catch (err) {
    const status = err.status || (err instanceof Anthropic.APIError ? err.status || 500 : 500);
    console.error('design/generate error:', err.message);
    res.status(status).json({ error: 'generate_failed', detail: err.message });
  }
});

app.use(express.static(path.join(__dirname, 'public')));

// ── Dev hot-reload ───────────────────────────────────────────────────────────
// SSE endpoint + fs.watch on /public so the browser auto-refreshes whenever
// you edit / git-pull a page. Page reload script lives in public/hot-reload.js
// and is included with a single <script src> tag (see garage.html, etc.).
const reloadClients = new Set();
let lastChangeAt = Date.now();
try {
  fs.watch(path.join(__dirname, 'public'), { recursive: true }, (evt, filename) => {
    if (!filename) return;
    lastChangeAt = Date.now();
    for (const res of reloadClients) {
      try { res.write('data: ' + JSON.stringify({ t: lastChangeAt, file: filename }) + '\n\n'); } catch {}
    }
  });
  console.log('[hot-reload] watching public/ for changes');
} catch (err) {
  console.warn('[hot-reload] fs.watch failed:', err.message);
}
app.get('/dev/live', (req, res) => {
  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders?.();
  res.write(': connected\n\n');
  reloadClients.add(res);
  const ping = setInterval(() => { try { res.write(': ping\n\n'); } catch {} }, 25000);
  req.on('close', () => { clearInterval(ping); reloadClients.delete(res); });
});
// Trigger `git pull` from the browser — call POST /dev/pull and the page
// will reload moments later when fs.watch fires.
app.post('/dev/pull', (req, res) => {
  const { exec } = require('child_process');
  exec('git pull --ff-only', { cwd: __dirname }, (err, stdout, stderr) => {
    if (err) return res.status(500).json({ ok: false, error: stderr || err.message });
    res.json({ ok: true, output: stdout.trim() });
  });
});

// ── Start ────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`
  ╔════════════════════════════════════════════════╗
  ║           vans_it OBS Widget Pack              ║
  ╠════════════════════════════════════════════════╣
  ║  Directory:  http://localhost:${PORT}/widgets/     ║
  ║  Setup:      http://localhost:${PORT}/setup        ║
  ║                                                ║
  ║  Spotify:    ${tokenData       ? 'connected   ' : 'not connected'}                     ║
  ║  Twitch:     ${twitchData      ? 'connected   ' : 'not connected'}                     ║
  ╚════════════════════════════════════════════════╝
  `);
});
