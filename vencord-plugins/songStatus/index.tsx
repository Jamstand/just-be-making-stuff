/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import { Logger } from "@utils/Logger";
import definePlugin, { OptionType } from "@utils/types";
import { FluxDispatcher } from "@webpack/common";

const logger = new Logger("SongStatus");
const SOCKET_ID = "SongStatus";
const ACTIVITY_LISTENING = 2;

/** Shape returned by the repo's /now-playing endpoint (server.js). */
interface NowPlaying {
    playing?: boolean;
    title?: string;
    artist?: string;
    album?: string;
}

const settings = definePluginSettings({
    endpoint: {
        type: OptionType.STRING,
        description: "URL of your now-playing JSON feed (the repo's server serves this at /now-playing)",
        default: "http://localhost:3000/now-playing"
    },
    pollSeconds: {
        type: OptionType.SLIDER,
        description: "How often to refresh the current song (seconds)",
        markers: [5, 10, 15, 30, 60],
        default: 15,
        stickToMarkers: true
    },
    clearWhenPaused: {
        type: OptionType.BOOLEAN,
        description: "Clear your status when nothing is playing (otherwise the last song stays up)",
        default: true
    }
});

let pollHandle: ReturnType<typeof setInterval> | null = null;
let lastKey: string | null = null;
let warnedFetch = false;

function setActivity(activity: Record<string, any> | null) {
    FluxDispatcher.dispatch({
        type: "LOCAL_ACTIVITY_UPDATE",
        activity,
        socketId: SOCKET_ID
    });
}

function clearActivity() {
    if (lastKey === null) return;
    lastKey = null;
    setActivity(null);
}

async function poll() {
    let data: NowPlaying;
    try {
        const res = await fetch(settings.store.endpoint, { cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        data = await res.json();
        warnedFetch = false;
    } catch (err) {
        // Network/CORS failure — don't spam the console, warn once
        if (!warnedFetch) {
            warnedFetch = true;
            logger.warn("Couldn't reach the now-playing endpoint:", err);
        }
        return;
    }

    if (!data?.playing || !data.title) {
        if (settings.store.clearWhenPaused) clearActivity();
        return;
    }

    const key = `${data.title}::${data.artist ?? ""}`;
    if (key === lastKey) return; // unchanged, avoid redundant dispatches
    lastKey = key;

    setActivity({
        application_id: "0",
        name: data.title,
        type: ACTIVITY_LISTENING,
        details: data.artist ? `by ${data.artist}` : undefined,
        state: data.album || undefined,
        flags: 1 << 0,
        timestamps: { start: Date.now() }
    });
}

export default definePlugin({
    name: "SongStatus",
    description: "Shows the track from your now-playing feed (e.g. this repo's OBS widget / Spotify endpoint) as your Discord status.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Appearance"],
    searchTerms: ["song", "status", "now playing", "spotify", "rpc", "music"],

    settings,

    start() {
        poll();
        pollHandle = setInterval(poll, settings.store.pollSeconds * 1000);
    },

    stop() {
        if (pollHandle != null) {
            clearInterval(pollHandle);
            pollHandle = null;
        }
        clearActivity();
    }
});
