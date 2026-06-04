/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { FluxDispatcher } from "@webpack/common";

const SOCKET_ID = "StatusRotator";
const ACTIVITY_PLAYING = 0;

const settings = definePluginSettings({
    statuses: {
        type: OptionType.STRING,
        description: "Statuses to cycle through, separated by | (e.g. Building stuff | brb | gaming)",
        default: "just be making stuff | brb soon | building plugins"
    },
    intervalSeconds: {
        type: OptionType.SLIDER,
        description: "How long to show each status (seconds)",
        markers: [30, 60, 120, 300, 600],
        default: 120,
        stickToMarkers: true
    }
});

let handle: ReturnType<typeof setInterval> | null = null;
let index = 0;

function list(): string[] {
    return settings.store.statuses.split("|").map(s => s.trim()).filter(Boolean);
}

function setActivity(activity: Record<string, any> | null) {
    FluxDispatcher.dispatch({ type: "LOCAL_ACTIVITY_UPDATE", activity, socketId: SOCKET_ID });
}

function show(text: string) {
    setActivity({ application_id: "0", name: text, type: ACTIVITY_PLAYING, flags: 1 << 0 });
}

function tick() {
    const items = list();
    if (!items.length) return;
    index = (index + 1) % items.length;
    show(items[index]);
}

export default definePlugin({
    name: "StatusRotator",
    description: "Cycle your status (game activity) through a list of messages on a timer. (Run only one activity plugin at a time.)",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Appearance"],
    searchTerms: ["status", "rotate", "rotator", "rpc", "activity", "cycle"],

    settings,

    start() {
        const items = list();
        index = 0;
        if (items.length) show(items[0]);
        handle = setInterval(tick, settings.store.intervalSeconds * 1000);
    },

    stop() {
        if (handle != null) { clearInterval(handle); handle = null; }
        setActivity(null);
    }
});
