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
// Runtime lock state, persisted so a channel isn't left stuck at limit 1 if
// Discord is quit while it's locked (and so we never recapture the lowered
// value as the "original").
const STATE_KEY = "SoloChannel_state";

let soloIds: string[] = [];
let originalLimit: Record<string, number> = {};
const lowered = new Set<string>();

function persistState() {
    DataStore.set(STATE_KEY, { originalLimit, lowered: [...lowered] }).catch(() => { /* best effort */ });
}

function patchLimit(channelId: string, userLimit: number) {
    RestAPI.patch({ url: `/channels/${channelId}`, body: { user_limit: userLimit } }).catch(() => { /* missing perms / transient */ });
}

function restore(id: string) {
    lowered.delete(id);
    const orig = originalLimit[id] ?? 0;
    delete originalLimit[id];
    patchLimit(id, orig);
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
            // Only capture the true original the first time we lower it
            if (!(id in originalLimit)) originalLimit[id] = ch.userLimit ?? 0;
            lowered.add(id);
            persistState();
            patchLimit(id, 1);
        } else if (!isMine && lowered.has(id)) {
            restore(id);
            persistState();
        }
    }
}

function toggle(channel: ChannelLike) {
    if (soloIds.includes(channel.id)) {
        soloIds = soloIds.filter(id => id !== channel.id);
        if (lowered.has(channel.id)) {
            restore(channel.id);
            persistState();
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
        const state = (await DataStore.get(STATE_KEY)) ?? {};
        originalLimit = state.originalLimit ?? {};
        const persistedLowered: string[] = state.lowered ?? [];

        // Reconcile channels we left locked: keep the lock if we're still in the
        // channel, otherwise reopen it (Discord was quit while it was locked).
        const myVc = SelectedChannelStore.getVoiceChannelId();
        for (const id of persistedLowered) {
            if (myVc === id) lowered.add(id);
            else restore(id);
        }
        persistState();
        enforce();
    },

    stop() {
        // Reopen any channel we'd narrowed to 1 so disabling the plugin doesn't
        // leave a channel stuck at a 1-person limit.
        for (const id of [...lowered]) restore(id);
        persistState();
    }
});
