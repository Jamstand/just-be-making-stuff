/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { showNotification } from "@api/Notifications";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { ChannelStore, GuildStore, showToast, Toasts, UserStore } from "@webpack/common";

interface Message {
    id: string;
    channel_id: string;
    guild_id?: string;
    content?: string;
    author?: { id: string; globalName?: string; username?: string; };
    mention_roles?: string[];
}

const settings = definePluginSettings({
    roleId: {
        type: OptionType.STRING,
        description: "Role ID whose pings you want alerted on, e.g. your @Moderators role (right-click role → Copy Role ID)",
        default: ""
    },
    keywords: {
        type: OptionType.STRING,
        description: "Extra comma-separated keywords that should also alert (e.g. report, help, raid)",
        default: ""
    },
    desktopNotification: {
        type: OptionType.BOOLEAN,
        description: "Show a desktop notification (plus an in-app toast)",
        default: true
    }
});

export default definePlugin({
    name: "ModQueuePings",
    description: "Alerts you when a chosen role (like @Moderators) is pinged or a report keyword shows up, so nothing in the mod queue slips by.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Notifications"],
    searchTerms: ["mod", "moderator", "queue", "ping", "role", "report", "alert"],

    settings,

    flux: {
        MESSAGE_CREATE({ message, optimistic }: { message: Message; optimistic: boolean; }) {
            if (optimistic || !message?.id) return;
            if (message.author?.id === UserStore.getCurrentUser()?.id) return;

            const roleId = settings.store.roleId.trim();
            const words = settings.store.keywords.split(",").map(k => k.trim().toLowerCase()).filter(Boolean);
            const content = (message.content || "").toLowerCase();

            const roleHit = !!roleId && Array.isArray(message.mention_roles) && message.mention_roles.includes(roleId);
            const wordHit = words.find(w => content.includes(w));
            if (!roleHit && !wordHit) return;

            const author = message.author?.globalName || message.author?.username || "Someone";
            const channelName = ChannelStore.getChannel(message.channel_id)?.name;
            const guildName = message.guild_id ? GuildStore.getGuild(message.guild_id)?.name : undefined;
            const where = [channelName && `#${channelName}`, guildName].filter(Boolean).join(" · ");
            const reason = roleHit ? "Role pinged" : `Keyword "${wordHit}"`;
            const snippet = (message.content || "").replace(/\s+/g, " ").trim().slice(0, 140);

            showToast(`🛡️ ${reason}${where ? ` (${where})` : ""}`, Toasts.Type.MESSAGE);
            if (settings.store.desktopNotification) {
                showNotification({ title: `${reason}${where ? ` — ${where}` : ""}`, body: `${author}: ${snippet}` });
            }
        }
    }
});
