/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import * as DataStore from "@api/DataStore";
import definePlugin from "@utils/types";
import { Menu, RestAPI, showToast, Toasts, UserStore } from "@webpack/common";

interface ChannelLike {
    id: string;
    name?: string;
    type: number;
}

interface Message {
    id: string;
    channel_id: string;
    author?: { id: string; };
    content?: string;
}

const GUILD_TEXT = 0;
const STORE_KEY = "AutoThreadReplies_channels";
let channels: string[] = [];

function threadName(content?: string): string {
    const trimmed = (content || "").replace(/\s+/g, " ").trim();
    return trimmed ? trimmed.slice(0, 60) : "New thread";
}

const ChannelContextMenuPatch: NavContextMenuPatchCallback = (children, { channel }: { channel?: ChannelLike; }) => {
    if (!channel || channel.type !== GUILD_TEXT) return;
    const active = channels.includes(channel.id);

    children.push(
        <Menu.MenuSeparator key="auto-thread-separator" />,
        <Menu.MenuItem
            key="auto-thread-toggle"
            id="auto-thread-toggle"
            label={active ? "Stop Auto-Threading My Posts" : "Auto-Thread My Posts Here"}
            color={active ? "danger" : undefined}
            action={() => {
                channels = active ? channels.filter(id => id !== channel.id) : [...channels, channel.id];
                DataStore.set(STORE_KEY, channels).catch(() => { /* best effort */ });
                showToast(active ? `No longer auto-threading in ${channel.name}.` : `Auto-threading your posts in ${channel.name}.`);
            }}
        />
    );
};

export default definePlugin({
    name: "AutoThreadReplies",
    description: "In channels you choose, automatically start a thread on each message you send. Right-click a text channel to toggle.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Chat"],
    searchTerms: ["thread", "auto", "reply", "channel"],

    contextMenus: { "channel-context": ChannelContextMenuPatch },

    flux: {
        MESSAGE_CREATE({ message, optimistic }: { message: Message; optimistic: boolean; }) {
            if (optimistic || !message?.id) return;
            if (!channels.includes(message.channel_id)) return;
            if (message.author?.id !== UserStore.getCurrentUser()?.id) return;

            RestAPI.post({
                url: `/channels/${message.channel_id}/messages/${message.id}/threads`,
                body: { name: threadName(message.content), auto_archive_duration: 1440 }
            }).catch(() => showToast("Couldn't start a thread (need Create Threads permission?)", Toasts.Type.FAILURE));
        }
    },

    async start() {
        channels = (await DataStore.get(STORE_KEY)) ?? [];
    }
});
