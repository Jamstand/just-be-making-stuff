/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import * as DataStore from "@api/DataStore";
import definePlugin from "@utils/types";
import { ChannelStore, Menu, PermissionsBits, PermissionStore, RestAPI, SelectedChannelStore } from "@webpack/common";

interface ChannelLike {
    id: string;
    name?: string;
    type: number;
    guild_id?: string;
    userLimit?: number;
}

const GUILD_VOICE = 2;
const STORE_KEY = "SoloChannel_ids";

let soloIds: string[] = [];
const originalLimit: Record<string, number> = {};
const lowered = new Set<string>();

function patchLimit(channelId: string, userLimit: number) {
    RestAPI.patch({ url: `/channels/${channelId}`, body: { user_limit: userLimit } }).catch(() => { /* missing perms / transient */ });
}

function enforce() {
    if (!soloIds.length) return;
    const myVc = SelectedChannelStore.getVoiceChannelId();

    for (const id of soloIds) {
        const ch: ChannelLike | null = ChannelStore.getChannel(id);
        if (!ch?.guild_id) continue;
        if (!PermissionStore.can(PermissionsBits.MANAGE_CHANNELS, ch)) continue;

        const isMine = myVc === id;
        if (isMine && !lowered.has(id)) {
            originalLimit[id] = ch.userLimit ?? 0;
            lowered.add(id);
            patchLimit(id, 1);
        } else if (!isMine && lowered.has(id)) {
            lowered.delete(id);
            patchLimit(id, originalLimit[id] ?? 0);
        }
    }
}

function toggle(channel: ChannelLike) {
    if (soloIds.includes(channel.id)) {
        soloIds = soloIds.filter(id => id !== channel.id);
        if (lowered.has(channel.id)) {
            lowered.delete(channel.id);
            patchLimit(channel.id, originalLimit[channel.id] ?? 0);
        }
    } else {
        soloIds.push(channel.id);
    }
    DataStore.set(STORE_KEY, soloIds).catch(() => { /* best effort */ });
    enforce();
}

const ChannelContextMenuPatch: NavContextMenuPatchCallback = (children, { channel }: { channel?: ChannelLike; }) => {
    if (!channel || channel.type !== GUILD_VOICE) return;
    const active = soloIds.includes(channel.id);

    children.push(
        <Menu.MenuSeparator key="solo-channel-separator" />,
        <Menu.MenuItem
            key="solo-channel-toggle"
            id="solo-channel-toggle"
            label={active ? "Stop Auto-Solo" : "Auto-Solo When I Join (limit 1)"}
            color={active ? "danger" : undefined}
            action={() => toggle(channel)}
        />
    );
};

export default definePlugin({
    name: "SoloChannel",
    description: "Mark a voice channel so it locks to a 1-person limit while you're in it, then reopens when you leave. Needs Manage Channels.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["solo", "user limit", "private", "voice", "lock"],

    contextMenus: { "channel-context": ChannelContextMenuPatch },

    flux: {
        VOICE_STATE_UPDATES() { enforce(); }
    },

    async start() {
        soloIds = (await DataStore.get(STORE_KEY)) ?? [];
        enforce();
    }
});
