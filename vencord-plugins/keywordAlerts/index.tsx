/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { showNotification } from "@api/Notifications";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { ChannelStore, showToast, Toasts, UserStore } from "@webpack/common";

interface Message {
    id: string;
    channel_id: string;
    content?: string;
    author?: { id: string; globalName?: string; username?: string; bot?: boolean; };
}

const settings = definePluginSettings({
    keywords: {
        type: OptionType.STRING,
        description: "Comma-separated words/phrases to watch for (case-insensitive)",
        default: ""
    },
    includeOwn: {
        type: OptionType.BOOLEAN,
        description: "Also alert on your own messages (usually off)",
        default: false
    },
    desktopNotification: {
        type: OptionType.BOOLEAN,
        description: "Show a desktop notification (plus an in-app toast)",
        default: true
    }
});

function keywordList(): string[] {
    return settings.store.keywords.split(",").map(k => k.trim().toLowerCase()).filter(Boolean);
}

export default definePlugin({
    name: "KeywordAlerts",
    description: "Get notified whenever a word or phrase you care about is said in any channel you can see.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Notifications"],
    searchTerms: ["keyword", "alert", "notify", "watch", "mention", "highlight"],

    settings,

    flux: {
        MESSAGE_CREATE({ message, optimistic }: { message: Message; optimistic: boolean; }) {
            if (optimistic || !message?.content) return;

            const me = UserStore.getCurrentUser()?.id;
            if (!settings.store.includeOwn && message.author?.id === me) return;

            const words = keywordList();
            if (!words.length) return;

            const content = message.content.toLowerCase();
            const hit = words.find(w => content.includes(w));
            if (!hit) return;

            const author = message.author?.globalName || message.author?.username || "Someone";
            const channelName = ChannelStore.getChannel(message.channel_id)?.name;
            const where = channelName ? ` in #${channelName}` : "";
            const snippet = message.content.replace(/\s+/g, " ").trim().slice(0, 140);

            showToast(`🔔 "${hit}"${where}: ${snippet}`, Toasts.Type.MESSAGE);
            if (settings.store.desktopNotification) {
                showNotification({ title: `Keyword "${hit}"${where}`, body: `${author}: ${snippet}` });
            }
        }
    }
});
