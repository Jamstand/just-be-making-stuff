require('dotenv').config();
const express = require('express');
const axios = require('axios');
const cors = require('cors');
const fs = require('fs');
const path = require('path');
const { Configuration, PlaidApi, PlaidEnvironments, Products, CountryCode } = require('plaid');

const app = express();
const PORT = process.env.PORT || 3000;
const TOKEN_FILE = path.join(__dirname, '.tokens.json');
const PLAID_TOKEN_FILE = path.join(__dirname, '.plaid-tokens.json');

app.use(cors({ origin: process.env.ALLOWED_ORIGIN || true }));
app.use(express.json());

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
