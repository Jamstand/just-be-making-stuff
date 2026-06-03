/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import { showNotification } from "@api/Notifications";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy, findStoreLazy } from "@webpack";
import {
    ChannelStore,
    GuildStore,
    Menu,
    PermissionsBits,
    PermissionStore,
    SelectedChannelStore,
    showToast,
    Toasts,
    UserStore
} from "@webpack/common";

/**
 * Minimal shape of the channel records this plugin touches. Declared locally
 * (instead of importing from discord-types / @vencord/discord-types) so the
 * plugin compiles on both older and current Vencord checkouts.
 */
interface VoiceChannelLike {
    id: string;
    name?: string;
    type: number;
    guild_id?: string;
    userLimit?: number;
}

const GUILD_VOICE = 2;
const GUILD_STAGE_VOICE = 13;

const VoiceStateStore = findStoreLazy("VoiceStateStore");
const ChannelActions = findByPropsLazy("selectChannel", "selectVoiceChannel");

const settings = definePluginSettings({
    autoWatchOnFullClick: {
        type: OptionType.BOOLEAN,
        description: "Start waiting automatically whenever you click a full voice channel (i.e. whenever the \"Channel is full\" popup appears)",
        default: true
    },
    desktopNotification: {
        type: OptionType.BOOLEAN,
        description: "Also show a desktop notification when a spot opens up and you get connected",
        default: true
    },
    cancelOnManualJoin: {
        type: OptionType.BOOLEAN,
        description: "Stop waiting if you manually join a different voice channel in the meantime",
        default: true
    },
    watchTimeoutMinutes: {
        type: OptionType.SLIDER,
        description: "Give up waiting after this many minutes (0 = keep waiting until you get in or cancel)",
        markers: [0, 5, 10, 15, 30, 60, 120],
        default: 30,
        stickToMarkers: true
    }
});

// ─── state ───────────────────────────────────────────────────────────────────

let watchedChannelId: string | null = null;
let lastKnownVoiceChannelId: string | null = null;
let joinPending = false;
let checkQueued = false;
let watchTimeout: ReturnType<typeof setTimeout> | null = null;

// ─── helpers ─────────────────────────────────────────────────────────────────

function isGuildVoiceChannel(channel: VoiceChannelLike | null | undefined): channel is VoiceChannelLike {
    return channel != null && (channel.type === GUILD_VOICE || channel.type === GUILD_STAGE_VOICE);
}

function channelLabel(channel: VoiceChannelLike | null | undefined) {
    return channel?.name ? `"${channel.name}"` : "the voice channel";
}

function connectedUserIds(channelId: string): string[] {
    return Object.keys(VoiceStateStore.getVoiceStatesForChannel(channelId) ?? {});
}

function isFull(channel: VoiceChannelLike): boolean {
    const limit = channel.userLimit ?? 0;
    return limit > 0 && connectedUserIds(channel.id).length >= limit;
}

/** Whether we (the current user) show up in the channel's server-confirmed voice states */
function amIConnectedTo(channelId: string): boolean {
    const myId = UserStore.getCurrentUser()?.id;
    return !!myId && connectedUserIds(channelId).includes(myId);
}

/**
 * Discord only shows the "Channel is full" popup to people who can connect but
 * can't move members; anyone with Move Members may join full channels anyway.
 */
function fullChannelBlocksMe(channel: VoiceChannelLike): boolean {
    return PermissionStore.can(PermissionsBits.CONNECT, channel)
        && !PermissionStore.can(PermissionsBits.MOVE_MEMBERS, channel);
}

// ─── watching ────────────────────────────────────────────────────────────────

function startWatching(channelId: string) {
    if (watchedChannelId === channelId) return;

    const channel: VoiceChannelLike | null = ChannelStore.getChannel(channelId);
    if (!channel) return;

    stopWatching();

    watchedChannelId = channelId;
    lastKnownVoiceChannelId = SelectedChannelStore.getVoiceChannelId() ?? null;

    const minutes = settings.store.watchTimeoutMinutes;
    if (minutes > 0) {
        watchTimeout = setTimeout(() => onWatchTimeout(channelId), minutes * 60_000);
    }

    showToast(`Waiting for a spot in ${channelLabel(channel)} - you'll join automatically. Right-click the channel to cancel.`);

    // In case a spot opened between the click and now
    queueCheck();
}

function stopWatching() {
    watchedChannelId = null;
    joinPending = false;
    if (watchTimeout != null) {
        clearTimeout(watchTimeout);
        watchTimeout = null;
    }
}

function onWatchTimeout(channelId: string) {
    if (watchedChannelId !== channelId) return;

    const channel: VoiceChannelLike | null = ChannelStore.getChannel(channelId);
    stopWatching();
    showToast(`Gave up waiting for a spot in ${channelLabel(channel)}.`, Toasts.Type.FAILURE);

    if (settings.store.desktopNotification) {
        showNotification({
            title: "JoinWhenFree",
            body: `Gave up waiting for a spot in ${channelLabel(channel)} - nobody left in time.`
        });
    }
}

// ─── joining ─────────────────────────────────────────────────────────────────

/** Coalesce bursts of voice events into a single deferred check, run after stores update */
function queueCheck() {
    if (checkQueued || !watchedChannelId) return;
    checkQueued = true;
    setTimeout(() => {
        checkQueued = false;
        checkForOpenSpot();
    }, 0);
}

function checkForOpenSpot() {
    if (!watchedChannelId) return;

    const channelId = watchedChannelId;
    const channel: VoiceChannelLike | null = ChannelStore.getChannel(channelId);

    // Channel was deleted while we were waiting
    if (!channel) {
        stopWatching();
        showToast("The voice channel you were waiting for no longer exists.", Toasts.Type.FAILURE);
        return;
    }

    // We're in! Either our pending join was confirmed or the user got in manually
    if (amIConnectedTo(channelId)) {
        const autoJoined = joinPending;
        stopWatching();
        if (autoJoined) onJoined(channel);
        return;
    }

    // A join attempt is already in flight - let it resolve
    if (joinPending) return;

    // The user moved to a different channel on their own - optionally stop waiting
    const currentVc = SelectedChannelStore.getVoiceChannelId() ?? null;
    if (currentVc !== lastKnownVoiceChannelId) {
        lastKnownVoiceChannelId = currentVc;
        if (currentVc && currentVc !== channelId && settings.store.cancelOnManualJoin) {
            stopWatching();
            showToast(`No longer waiting for ${channelLabel(channel)} - you joined a different voice channel.`);
            return;
        }
    }

    // Still no room - keep waiting
    if (isFull(channel)) return;

    join(channel);
}

function join(channel: VoiceChannelLike) {
    joinPending = true;
    ChannelActions.selectVoiceChannel(channel.id);

    // Failure watchdog: the server is the final authority on who gets the spot.
    // If we aren't in the channel after a few seconds (someone else sniped it),
    // give up on this attempt and keep waiting for the next one.
    setTimeout(() => {
        if (!joinPending || watchedChannelId !== channel.id) return;
        joinPending = false;

        if (!amIConnectedTo(channel.id)) {
            showToast(`Couldn't grab the spot in ${channelLabel(channel)} - someone got there first. Still waiting.`, Toasts.Type.FAILURE);
        }
    }, 5000);
}

function onJoined(channel: VoiceChannelLike) {
    showToast(`A spot opened up - you joined ${channelLabel(channel)}!`, Toasts.Type.SUCCESS);

    if (settings.store.desktopNotification) {
        const guildName = channel.guild_id ? GuildStore.getGuild(channel.guild_id)?.name : undefined;
        showNotification({
            title: "Joined voice channel",
            body: `A spot opened up in ${channelLabel(channel)}${guildName ? ` (${guildName})` : ""} and you were connected.`
        });
    }
}

// ─── context menu ────────────────────────────────────────────────────────────

const ChannelContextMenuPatch: NavContextMenuPatchCallback = (children, { channel }: { channel?: VoiceChannelLike; }) => {
    if (!isGuildVoiceChannel(channel)) return;

    const watching = watchedChannelId === channel.id;

    // Only offer to wait when waiting actually makes sense
    if (!watching) {
        if (!isFull(channel)) return;
        if (amIConnectedTo(channel.id)) return;
        if (!fullChannelBlocksMe(channel)) return;
    }

    children.push(
        <Menu.MenuSeparator key="join-when-free-separator" />,
        watching
            ? <Menu.MenuItem
                key="join-when-free-cancel"
                id="join-when-free-cancel"
                label="Stop Waiting for Spot"
                color="danger"
                action={() => {
                    stopWatching();
                    showToast(`Stopped waiting for ${channelLabel(channel)}.`);
                }}
            />
            : <Menu.MenuItem
                key="join-when-free-start"
                id="join-when-free-start"
                label="Join When a Spot Opens"
                action={() => startWatching(channel.id)}
            />
    );
};

// ─── plugin ──────────────────────────────────────────────────────────────────

export default definePlugin({
    name: "JoinWhenFree",
    description: "When a voice channel is full, wait for someone to leave and join automatically the moment a spot opens up.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["channel is full", "auto join", "voice", "call", "queue"],

    settings,

    contextMenus: {
        "channel-context": ChannelContextMenuPatch
    },

    flux: {
        // Fires whenever anybody joins/leaves/moves voice channels anywhere we can see
        VOICE_STATE_UPDATES() {
            queueCheck();
        },

        // Fires when a channel gets selected - used to detect clicks on full voice
        // channels (the same click that makes Discord show "Channel is full")
        CHANNEL_SELECT({ channelId }: { channelId?: string | null; }) {
            if (!settings.store.autoWatchOnFullClick || !channelId) return;
            if (watchedChannelId === channelId) return;

            const channel: VoiceChannelLike | null = ChannelStore.getChannel(channelId);
            if (!isGuildVoiceChannel(channel)) return;

            if (!isFull(channel)) return;
            if (amIConnectedTo(channelId)) return;
            if (!fullChannelBlocksMe(channel)) return;

            startWatching(channelId);
        },

        CHANNEL_DELETE({ channel }: { channel?: { id?: string; }; }) {
            if (channel?.id && channel.id === watchedChannelId) {
                stopWatching();
                showToast("The voice channel you were waiting for was deleted.", Toasts.Type.FAILURE);
            }
        }
    },

    stop() {
        stopWatching();
    }
});
