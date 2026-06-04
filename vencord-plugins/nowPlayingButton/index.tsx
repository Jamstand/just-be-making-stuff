/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import { Logger } from "@utils/Logger";
import definePlugin, { OptionType } from "@utils/types";
import { FluxDispatcher } from "@webpack/common";

const logger = new Logger("NowPlayingButton");
const SOCKET_ID = "NowPlayingButton";
const ACTIVITY_LISTENING = 2;

interface NowPlaying {
    playing?: boolean;
    title?: string;
    artist?: string;
    url?: string;
}

const settings = definePluginSettings({
    endpoint: {
        type: OptionType.STRING,
        description: "Now-playing JSON feed (this repo serves /now-playing)",
        default: "http://localhost:3000/now-playing"
    },
    buttonLabel: {
        type: OptionType.STRING,
        description: "Text on the profile button",
        default: "Listen along"
    },
    buttonUrl: {
        type: OptionType.STRING,
        description: "Where the button links (leave blank to use the song's own url field if present)",
        default: ""
    },
    pollSeconds: {
        type: OptionType.SLIDER,
        description: "How often to refresh (seconds)",
        markers: [10, 15, 30, 60],
        default: 15,
        stickToMarkers: true
    }
});

let pollHandle: ReturnType<typeof setInterval> | null = null;
let lastKey: string | null = null;
let warned = false;

function setActivity(activity: Record<string, any> | null) {
    FluxDispatcher.dispatch({ type: "LOCAL_ACTIVITY_UPDATE", activity, socketId: SOCKET_ID });
}

async function poll() {
    let data: NowPlaying;
    try {
        const res = await fetch(settings.store.endpoint, { cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        data = await res.json();
        warned = false;
    } catch (err) {
        if (!warned) { warned = true; logger.warn("Couldn't reach the now-playing endpoint:", err); }
        return;
    }

    if (!data?.playing || !data.title) {
        if (lastKey !== null) { lastKey = null; setActivity(null); }
        return;
    }

    const url = (settings.store.buttonUrl || data.url || "").trim();
    const key = `${data.title}::${url}`;
    if (key === lastKey) return;
    lastKey = key;

    const activity: Record<string, any> = {
        application_id: "0",
        name: data.title,
        type: ACTIVITY_LISTENING,
        details: data.artist ? `by ${data.artist}` : undefined,
        flags: 1 << 0,
        timestamps: { start: Date.now() }
    };
    if (url) {
        activity.buttons = [settings.store.buttonLabel || "Listen"];
        activity.metadata = { button_urls: [url] };
    }
    setActivity(activity);
}

export default definePlugin({
    name: "NowPlayingButton",
    description: "Like SongStatus, but adds a clickable button to your profile linking to the current track. (Run only one activity plugin at a time.)",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Appearance"],
    searchTerms: ["now playing", "button", "profile", "song", "link", "rpc"],

    settings,

    start() {
        poll();
        pollHandle = setInterval(poll, settings.store.pollSeconds * 1000);
    },

    stop() {
        if (pollHandle != null) { clearInterval(pollHandle); pollHandle = null; }
        if (lastKey !== null) { lastKey = null; setActivity(null); }
    }
});
