/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import * as DataStore from "@api/DataStore";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy } from "@webpack";
import { ChannelStore, Menu, SelectedChannelStore, showToast, Toasts } from "@webpack/common";

interface ChannelLike {
    id: string;
    name?: string;
    type: number;
    guild_id?: string;
}

const GUILD_VOICE = 2;
const GUILD_STAGE_VOICE = 13;
const STORE_KEY = "AutoRejoin_pinned";

const VoiceActions = findByPropsLazy("selectVoiceChannel", "selectChannel");

const settings = definePluginSettings({
    maxTries: {
        type: OptionType.SLIDER,
        description: "How many times to try rejoining in a row before giving up (in case you got banned from the channel or it's full)",
        markers: [3, 5, 10, 20],
        default: 5,
        stickToMarkers: true
    },
    showToasts: {
        type: OptionType.BOOLEAN,
        description: "Show a toast when you get auto-rejoined",
        default: true
    }
});

let pinned: { channelId: string; name: string; } | null = null;
let tries = 0;
let windowStart = 0;
let rejoinPending = false;
let rejoinTimer: ReturnType<typeof setTimeout> | null = null;
let confirmTimer: ReturnType<typeof setTimeout> | null = null;

function clearTimers() {
    if (rejoinTimer != null) { clearTimeout(rejoinTimer); rejoinTimer = null; }
    if (confirmTimer != null) { clearTimeout(confirmTimer); confirmTimer = null; }
    rejoinPending = false;
}

function isGuildVoice(channel: ChannelLike | null | undefined): channel is ChannelLike {
    return channel != null && (channel.type === GUILD_VOICE || channel.type === GUILD_STAGE_VOICE);
}

function notify(message: string, type: string = Toasts.Type.MESSAGE) {
    if (settings.store.showToasts) showToast(message, type);
}

function enforce() {
    if (!pinned || rejoinPending || confirmTimer != null) return;

    if (SelectedChannelStore.getVoiceChannelId() === pinned.channelId) {
        tries = 0; // we're where we should be
        return;
    }

    const channel: ChannelLike | null = ChannelStore.getChannel(pinned.channelId);
    if (!channel) {
        const { name } = pinned;
        unpin();
        notify(`Stopped auto-rejoining ${name} — the channel no longer exists.`, Toasts.Type.FAILURE);
        return;
    }

    // Reset the attempt counter once a minute so a single bad streak doesn't
    // permanently disable rejoining.
    if (Date.now() - windowStart > 60_000) {
        windowStart = Date.now();
        tries = 0;
    }

    if (tries >= settings.store.maxTries) {
        const { name } = pinned;
        unpin();
        notify(`Gave up auto-rejoining ${name} after ${tries} tries.`, Toasts.Type.FAILURE);
        return;
    }

    tries++;
    rejoinPending = true;
    rejoinTimer = setTimeout(() => {
        rejoinTimer = null;
        rejoinPending = false;
        if (!pinned || SelectedChannelStore.getVoiceChannelId() === pinned.channelId) return;

        const targetId = pinned.channelId;
        const targetName = pinned.name;
        VoiceActions.selectVoiceChannel(targetId);

        // Only claim success once the reconnect is actually confirmed, so a
        // failed join (banned/full) doesn't produce a false "Rejoined!" toast
        confirmTimer = setTimeout(() => {
            confirmTimer = null;
            if (pinned?.channelId === targetId && SelectedChannelStore.getVoiceChannelId() === targetId) {
                notify(`Rejoined ${targetName}.`, Toasts.Type.SUCCESS);
            }
        }, 2000);
    }, 500);
}

function pin(channel: ChannelLike) {
    pinned = { channelId: channel.id, name: channel.name || "the channel" };
    tries = 0;
    windowStart = Date.now();
    DataStore.set(STORE_KEY, pinned);
    notify(`Staying connected to ${pinned.name} — you'll auto-rejoin if disconnected. Right-click to stop.`);
    enforce();
}

function unpin() {
    clearTimers();
    pinned = null;
    tries = 0;
    DataStore.del(STORE_KEY);
}

const ChannelContextMenuPatch: NavContextMenuPatchCallback = (children, { channel }: { channel?: ChannelLike; }) => {
    if (!isGuildVoice(channel)) return;

    const active = pinned?.channelId === channel.id;

    children.push(
        <Menu.MenuSeparator key="auto-rejoin-separator" />,
        active
            ? <Menu.MenuItem
                key="auto-rejoin-stop"
                id="auto-rejoin-stop"
                label="Stop Staying Connected"
                color="danger"
                action={() => {
                    const name = pinned?.name;
                    unpin();
                    if (name) notify(`No longer staying connected to ${name}.`);
                }}
            />
            : <Menu.MenuItem
                key="auto-rejoin-start"
                id="auto-rejoin-start"
                label="Stay Connected (Auto-Rejoin)"
                action={() => pin(channel)}
            />
    );
};

export default definePlugin({
    name: "AutoRejoin",
    description: "Pin a voice channel and snap right back into it if you ever get disconnected or booted. Use 'Stop Staying Connected' to actually leave.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["rejoin", "reconnect", "stay", "anti kick", "anti boot", "voice"],

    settings,

    contextMenus: {
        "channel-context": ChannelContextMenuPatch
    },

    flux: {
        VOICE_STATE_UPDATES() {
            enforce();
        }
    },

    async start() {
        pinned = (await DataStore.get(STORE_KEY)) ?? null;
        windowStart = Date.now();
        enforce();
    },

    stop() {
        clearTimers();
    }
});
