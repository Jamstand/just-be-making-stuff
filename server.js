require('dotenv').config();
const express = require('express');
const axios = require('axios');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;
const TOKEN_FILE = path.join(__dirname, '.tokens.json');

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
