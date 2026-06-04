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
    Menu,
    SelectedChannelStore,
    showToast,
    Toasts,
    UserStore
} from "@webpack/common";

/** Minimal shape of the user records the user-context menu hands us. */
interface UserLike {
    id: string;
    bot?: boolean;
    username?: string;
    globalName?: string;
}

const VoiceStateStore = findStoreLazy("VoiceStateStore");
// selectVoiceChannel(dmId) starts + joins a DM call (and rings the recipient);
// ring(dmId) re-rings the recipient while you stay in the call.
const VoiceActions = findByPropsLazy("selectVoiceChannel", "selectChannel");
const CallActions = findByPropsLazy("ring", "stopRinging");
const PrivateChannelActions = findByPropsLazy("openPrivateChannel");

const settings = definePluginSettings({
    intervalSeconds: {
        type: OptionType.SLIDER,
        description: "How often to ring again while you wait for them to answer (seconds). Lower = rings faster, but very short intervals can hit Discord's rate limits.",
        markers: [3, 5, 10, 15, 30, 45, 60, 90],
        default: 30,
        stickToMarkers: true
    },
    maxAttempts: {
        type: OptionType.SLIDER,
        description: "Give up after this many rings if they never answer (ignored when \"Ring forever\" is on below)",
        markers: [5, 10, 15, 25, 50, 100],
        default: 15,
        stickToMarkers: true
    },
    neverGiveUp: {
        type: OptionType.BOOLEAN,
        description: "Ring forever — never give up, keep calling until they answer or you press Stop Calling (ignores Max Attempts)",
        default: false
    },
    desktopNotification: {
        type: OptionType.BOOLEAN,
        description: "Show a desktop notification when they finally answer (or when it gives up)",
        default: true
    }
});

// ─── state ───────────────────────────────────────────────────────────────────

interface Target {
    userId: string;
    channelId: string;
    name: string;
}

let target: Target | null = null;
let attempts = 0;
let intervalHandle: ReturnType<typeof setInterval> | null = null;

// ─── helpers ─────────────────────────────────────────────────────────────────

function displayName(user: UserLike): string {
    return user.globalName || user.username || "them";
}

/** Resolve (creating if needed) the 1:1 DM channel id for a user. */
function getDMChannelId(userId: string): string | undefined {
    const existing = ChannelStore.getDMFromUserId(userId);
    if (existing) return existing;
    // Kick off DM creation; it won't be ready this tick, so the caller retries.
    PrivateChannelActions.openPrivateChannel(userId);
    return ChannelStore.getDMFromUserId(userId);
}

function targetJoined(): boolean {
    if (!target) return false;
    return VoiceStateStore.getVoiceStateForUser(target.userId)?.channelId === target.channelId;
}

function inTargetCall(): boolean {
    return !!target && SelectedChannelStore.getVoiceChannelId() === target.channelId;
}

// ─── ringing loop ────────────────────────────────────────────────────────────

function startCalling(user: UserLike) {
    const userId = user.id;

    // Switching targets: tear down the previous loop first
    if (target) stopCalling({ silent: true });

    const channelId = getDMChannelId(userId);
    const name = displayName(user);

    if (!channelId) {
        // DM is being opened; give it a moment, then try once more
        setTimeout(() => {
            const retryId = ChannelStore.getDMFromUserId(userId);
            if (retryId) {
                beginLoop({ userId, channelId: retryId, name });
            } else {
                showToast(`Couldn't open a DM with ${name} to start the call.`, Toasts.Type.FAILURE);
            }
        }, 1200);
        return;
    }

    beginLoop({ userId, channelId, name });
}

function beginLoop(t: Target) {
    target = t;
    attempts = 0;

    showToast(`Calling ${t.name} — will keep ringing until they answer. Right-click them to stop.`);

    makeAttempt();
    intervalHandle = setInterval(makeAttempt, settings.store.intervalSeconds * 1000);
}

function makeAttempt() {
    if (!target) return;

    // They picked up between rings
    if (targetJoined()) {
        onAnswered();
        return;
    }

    attempts++;

    // "Ring forever" disables the cap entirely; otherwise honour Max Attempts.
    const cap = settings.store.neverGiveUp ? 0 : settings.store.maxAttempts;
    if (cap > 0 && attempts > cap) {
        giveUp();
        return;
    }

    ring();
}

function ring() {
    if (!target) return;

    // If we're connected to the call, just re-ring; otherwise (re)start the
    // call, which rings them on its own. Wrapped because fast intervals can
    // trip Discord's rate limit, which we just skip and retry next tick.
    try {
        if (inTargetCall()) {
            CallActions.ring(target.channelId);
        } else {
            VoiceActions.selectVoiceChannel(target.channelId);
        }
    } catch { /* rate-limited or transient; try again next interval */ }
}

function onAnswered() {
    const t = target!;
    stopCalling({ silent: true, stopRing: false });

    showToast(`${t.name} answered the call!`, Toasts.Type.SUCCESS);
    if (settings.store.desktopNotification) {
        showNotification({
            title: "Call answered",
            body: `${t.name} joined the call.`
        });
    }
}

function giveUp() {
    const t = target!;
    stopCalling({ silent: true });

    showToast(`${t.name} didn't answer after ${attempts - 1} rings — gave up.`, Toasts.Type.FAILURE);
    if (settings.store.desktopNotification) {
        showNotification({
            title: "No answer",
            body: `${t.name} didn't pick up after ${attempts - 1} rings.`
        });
    }
}

/**
 * Stop the redial loop.
 * @param silent      don't show the "stopped" toast (used by success/give-up which show their own)
 * @param stopRing    also cancel the outgoing ring (default true; false when they already answered)
 */
function stopCalling({ silent = false, stopRing = true }: { silent?: boolean; stopRing?: boolean; } = {}) {
    if (intervalHandle != null) {
        clearInterval(intervalHandle);
        intervalHandle = null;
    }

    if (stopRing && target) {
        try { CallActions.stopRinging(target.channelId); } catch { /* best effort */ }
    }

    const stopped = target;
    target = null;
    attempts = 0;

    if (!silent && stopped) {
        showToast(`Stopped calling ${stopped.name}.`);
    }
}

// ─── context menu ────────────────────────────────────────────────────────────

const UserContextMenuPatch: NavContextMenuPatchCallback = (children, { user }: { user?: UserLike; }) => {
    if (!user) return;
    if (user.bot) return; // bots can't be called
    if (user.id === UserStore.getCurrentUser()?.id) return;

    const calling = target?.userId === user.id;

    children.push(
        <Menu.MenuSeparator key="ring-until-answer-separator" />,
        calling
            ? <Menu.MenuItem
                key="ring-until-answer-stop"
                id="ring-until-answer-stop"
                label="Stop Calling"
                color="danger"
                action={() => stopCalling()}
            />
            : <Menu.MenuItem
                key="ring-until-answer-start"
                id="ring-until-answer-start"
                label="Call Until They Answer"
                action={() => startCalling(user)}
            />
    );
};

// ─── plugin ──────────────────────────────────────────────────────────────────

export default definePlugin({
    name: "RingUntilAnswer",
    description: "Right-click someone → 'Call Until They Answer' to keep ringing them in DMs until they pick up. Stops automatically the moment they join.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["call", "redial", "ring", "auto call", "until answer", "keep calling"],

    settings,

    contextMenus: {
        "user-context": UserContextMenuPatch
    },

    flux: {
        // Pick up the instant they join, instead of waiting for the next ring tick
        VOICE_STATE_UPDATES() {
            if (target && targetJoined()) onAnswered();
        }
    },

    stop() {
        stopCalling({ silent: true });
    }
});
