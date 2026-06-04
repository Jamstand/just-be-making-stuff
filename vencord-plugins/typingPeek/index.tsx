/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { showNotification } from "@api/Notifications";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { ChannelStore, RelationshipStore, SelectedChannelStore, showToast, Toasts, UserStore } from "@webpack/common";

const DM = 1;
const GROUP_DM = 3;
const THROTTLE_MS = 30_000;
const lastSeen = new Map<string, number>();

const settings = definePluginSettings({
    onlyFriends: {
        type: OptionType.BOOLEAN,
        description: "Only peek at friends typing",
        default: false
    },
    onlyDMs: {
        type: OptionType.BOOLEAN,
        description: "Only peek in DMs / group DMs (ignore servers)",
        default: false
    },
    desktopNotification: {
        type: OptionType.BOOLEAN,
        description: "Use a desktop notification instead of just a toast",
        default: false
    }
});

export default definePlugin({
    name: "TypingPeek",
    description: "Get a heads-up when someone starts typing in a channel you're not currently looking at.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Notifications"],
    searchTerms: ["typing", "peek", "indicator", "started typing"],

    settings,

    flux: {
        TYPING_START({ channelId, userId }: { channelId: string; userId: string; }) {
            if (!channelId || !userId) return;
            if (userId === UserStore.getCurrentUser()?.id) return;
            if (channelId === SelectedChannelStore.getChannelId()) return; // you're already looking

            if (settings.store.onlyFriends && !RelationshipStore.isFriend(userId)) return;

            const channel = ChannelStore.getChannel(channelId);
            if (settings.store.onlyDMs && channel?.type !== DM && channel?.type !== GROUP_DM) return;

            const key = `${userId}:${channelId}`;
            const now = Date.now();
            if (now - (lastSeen.get(key) ?? 0) < THROTTLE_MS) return;
            lastSeen.set(key, now);

            const u = UserStore.getUser(userId);
            const who = u?.globalName || u?.username || "Someone";
            const where = channel?.name ? ` in ${channel.type === DM ? "your DM" : `#${channel.name}`}` : "";
            const text = `${who} is typing${where}…`;

            showToast(text, Toasts.Type.MESSAGE);
            if (settings.store.desktopNotification) showNotification({ title: "Typing…", body: text });
        }
    }
});
