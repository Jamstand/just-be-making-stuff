/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ApplicationCommandInputType, sendBotMessage } from "@api/Commands";
import { showNotification } from "@api/Notifications";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { PresenceStore, RelationshipStore, UserStore } from "@webpack/common";

const settings = definePluginSettings({
    digestMinutes: {
        type: OptionType.SLIDER,
        description: "Send a periodic 'who's online' desktop digest every N minutes (0 = off, command only)",
        markers: [0, 15, 30, 60, 120],
        default: 0,
        stickToMarkers: true,
        restartNeeded: true // the digest interval is (re)armed in start()
    }
});

let digestHandle: ReturnType<typeof setInterval> | null = null;

function onlineFriends(): string[] {
    const ids: string[] = RelationshipStore.getFriendIDs?.() ?? [];
    return ids
        .filter(id => {
            const s = PresenceStore.getStatus(id);
            return s && s !== "offline" && s !== "invisible";
        })
        .map(id => {
            const u = UserStore.getUser(id);
            const status = PresenceStore.getStatus(id);
            return `${u?.globalName || u?.username || id} (${status})`;
        })
        .sort((a, b) => a.localeCompare(b));
}

function startDigest() {
    if (digestHandle != null) { clearInterval(digestHandle); digestHandle = null; }
    const mins = settings.store.digestMinutes;
    if (mins > 0) {
        digestHandle = setInterval(() => {
            const list = onlineFriends();
            if (list.length) showNotification({ title: `${list.length} friends online`, body: list.slice(0, 15).join(", ") });
        }, mins * 60_000);
    }
}

export default definePlugin({
    name: "FriendOnlineDigest",
    description: "Use /online to list which of your friends are online right now, or get a periodic desktop digest.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Friends", "Notifications"],
    searchTerms: ["friends", "online", "digest", "who", "presence"],

    settings,

    commands: [
        {
            name: "online",
            description: "List friends who are currently online",
            inputType: ApplicationCommandInputType.BUILT_IN,
            execute: (_, ctx) => {
                const list = onlineFriends();
                sendBotMessage(ctx.channel.id, {
                    content: list.length ? `**${list.length} online:**\n${list.map(f => `• ${f}`).join("\n")}` : "None of your friends are online right now."
                });
            }
        }
    ],

    start() { startDigest(); },

    stop() {
        if (digestHandle != null) { clearInterval(digestHandle); digestHandle = null; }
    }
});
