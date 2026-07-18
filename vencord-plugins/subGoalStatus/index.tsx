/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import { Logger } from "@utils/Logger";
import definePlugin, { OptionType } from "@utils/types";
import { FluxDispatcher } from "@webpack/common";

const logger = new Logger("SubGoalStatus");
const SOCKET_ID = "SubGoalStatus";
const ACTIVITY_PLAYING = 0;

const settings = definePluginSettings({
    endpoint: {
        type: OptionType.STRING,
        description: "URL returning JSON with your counts, e.g. { count, goal, label }",
        default: ""
    },
    template: {
        type: OptionType.STRING,
        description: "Status text. Placeholders: {count} {goal} {label}",
        default: "{count}/{goal} subs"
    },
    pollSeconds: {
        type: OptionType.SLIDER,
        description: "How often to refresh (seconds)",
        markers: [15, 30, 60, 120, 300],
        default: 60,
        stickToMarkers: true,
        restartNeeded: true // interval is created in start()
    }
});

let pollHandle: ReturnType<typeof setInterval> | null = null;
let lastText: string | null = null;
let warned = false;

function setActivity(activity: Record<string, any> | null) {
    FluxDispatcher.dispatch({ type: "LOCAL_ACTIVITY_UPDATE", activity, socketId: SOCKET_ID });
}

async function poll() {
    const { endpoint, template } = settings.store;
    if (!endpoint) return;

    let data: Record<string, any>;
    try {
        const res = await fetch(endpoint, { cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        data = await res.json();
        warned = false;
    } catch (err) {
        if (!warned) { warned = true; logger.warn("Couldn't reach the goal endpoint:", err); }
        return;
    }

    const text = template
        .replaceAll("{count}", String(data.count ?? "?"))
        .replaceAll("{goal}", String(data.goal ?? "?"))
        .replaceAll("{label}", String(data.label ?? ""))
        .trim();

    if (!text || text === lastText) return;
    lastText = text;
    setActivity({ application_id: "0", name: text, type: ACTIVITY_PLAYING, flags: 1 << 0 });
}

export default definePlugin({
    name: "SubGoalStatus",
    description: "Polls a counts endpoint (subs/followers/etc.) and shows it as your Discord status. Set the endpoint in settings.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Appearance"],
    searchTerms: ["sub", "goal", "follower", "count", "status", "stream"],

    settings,

    start() {
        poll();
        pollHandle = setInterval(poll, settings.store.pollSeconds * 1000);
    },

    stop() {
        if (pollHandle != null) { clearInterval(pollHandle); pollHandle = null; }
        if (lastText !== null) { lastText = null; setActivity(null); }
    }
});
