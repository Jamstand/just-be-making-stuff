/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { MessageActions, showToast, Toasts, UserStore } from "@webpack/common";

const settings = definePluginSettings({
    announceChannelId: {
        type: OptionType.STRING,
        description: "Channel ID to post in when you start a Go Live stream (right-click a channel → Copy Channel ID)",
        default: ""
    },
    message: {
        type: OptionType.STRING,
        description: "What to post when you go live",
        default: "🔴 I'm live! Come hang out."
    }
});

let lastAnnounce = 0;

export default definePlugin({
    name: "GoLiveAnnouncer",
    description: "Automatically posts a message to a channel of your choice whenever you start a Go Live stream.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Chat"],
    searchTerms: ["go live", "stream", "announce", "live", "twitch"],

    settings,

    flux: {
        STREAM_CREATE({ streamKey }: { streamKey?: string; }) {
            const me = UserStore.getCurrentUser()?.id;
            // streamKey looks like "guild:<g>:<c>:<userId>" or "call:<c>:<userId>"
            if (!me || !streamKey?.endsWith(me)) return;

            const channelId = settings.store.announceChannelId.trim();
            if (!channelId) return;

            // guard against duplicate dispatches
            if (Date.now() - lastAnnounce < 10_000) return;
            lastAnnounce = Date.now();

            // sendMessage is async — a bad/inaccessible channel rejects the
            // promise, so catch it there rather than in a synchronous try/catch.
            MessageActions.sendMessage(channelId, { content: settings.store.message })
                .catch(() => showToast("GoLiveAnnouncer: couldn't post (check the channel ID).", Toasts.Type.FAILURE));
        }
    }
});
