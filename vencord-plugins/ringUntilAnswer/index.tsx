/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ApplicationCommandInputType, ApplicationCommandOptionType, findOption, sendBotMessage } from "@api/Commands";
import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import { showNotification } from "@api/Notifications";
import { definePluginSettings } from "@api/Settings";
import { sendMessage } from "@utils/discord";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy, findStoreLazy } from "@webpack";
import {
    ChannelStore,
    Menu,
    PresenceStore,
    SelectedChannelStore,
    showToast,
    Toasts,
    UserStore
} from "@webpack/common";

/** Minimal shape of the user records the user-context menu / command hands us. */
interface UserLike {
    id: string;
    bot?: boolean;
    username?: string;
    globalName?: string;
}

const VoiceStateStore = findStoreLazy("VoiceStateStore");
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
        description: "Give up after this many rings if they never answer (ignored when \"Ring forever\" is on)",
        markers: [5, 10, 15, 25, 50, 100],
        default: 15,
        stickToMarkers: true
    },
    maxMinutes: {
        type: OptionType.SLIDER,
        description: "Also give up this many minutes after ringing starts (0 = no time limit; ignored when \"Ring forever\" is on)",
        markers: [0, 1, 2, 5, 10, 15, 30, 60],
        default: 0,
        stickToMarkers: true
    },
    neverGiveUp: {
        type: OptionType.BOOLEAN,
        description: "Ring forever — never give up, keep calling until they answer or you press Stop Calling (ignores both limits above)",
        default: false
    },
    onlyWhenOnline: {
        type: OptionType.BOOLEAN,
        description: "Only ring while they're online — pause if they go offline/invisible, and if they're offline when you start, wait and begin the moment they appear",
        default: true
    },
    skipDnd: {
        type: OptionType.BOOLEAN,
        description: "Don't ring while they're on Do Not Disturb (pauses until they're available)",
        default: false
    },
    stopWhenTyping: {
        type: OptionType.BOOLEAN,
        description: "Stop ringing if they start typing a reply in the DM (they're clearly responding)",
        default: true
    },
    stopWhenILeave: {
        type: OptionType.BOOLEAN,
        description: "Stop ringing if you leave/hang up the call yourself",
        default: true
    },
    quietHours: {
        type: OptionType.BOOLEAN,
        description: "Enable quiet hours — never ring during the window below (your local time)",
        default: false
    },
    quietStart: {
        type: OptionType.SLIDER,
        description: "Quiet hours start (hour, 24h local time)",
        markers: [0, 6, 12, 18, 23],
        default: 23,
        stickToMarkers: false
    },
    quietEnd: {
        type: OptionType.SLIDER,
        description: "Quiet hours end (hour, 24h local time)",
        markers: [0, 6, 12, 18, 23],
        default: 8,
        stickToMarkers: false
    },
    giveUpMessage: {
        type: OptionType.STRING,
        description: "Optionally DM this message when it gives up without an answer (leave blank to send nothing)",
        default: ""
    },
    showProgress: {
        type: OptionType.BOOLEAN,
        description: "Show a periodic toast with the current attempt count while ringing",
        default: true
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
// Bumped on every start/stop so a pending DM-open retry can tell if it's stale
let generation = 0;
// when the first real ring happened (for the time cap)
let ringStartAt = 0;
// dedupes interval + presence-triggered rings
let lastRingAt = 0;
// throttles the progress toast
let lastProgressAt = 0;
// were we connected on the previous voice update
let wasInCall = false;
let announcedPause = false;

// ─── helpers ─────────────────────────────────────────────────────────────────

function displayName(user: UserLike): string {
    return user.globalName || user.username || "them";
}

/** Resolve (creating if needed) the 1:1 DM channel id for a user. */
function getDMChannelId(userId: string): string | undefined {
    const existing = ChannelStore.getDMFromUserId(userId);
    if (existing) return existing;
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

function isPresent(userId: string): boolean {
    const s = PresenceStore.getStatus(userId);
    return s === "online" || s === "idle" || s === "dnd" || s === "streaming";
}

function inQuietHours(): boolean {
    if (!settings.store.quietHours) return false;
    const h = new Date().getHours();
    const s = Math.round(settings.store.quietStart) % 24;
    const e = Math.round(settings.store.quietEnd) % 24;
    if (s === e) return false;
    // window may wrap past midnight (e.g. 23 → 8)
    return s < e ? (h >= s && h < e) : (h >= s || h < e);
}

/** Why we shouldn't ring right now (null = go ahead). */
function pauseReason(): string | null {
    if (!target) return "stopped";
    if (inQuietHours()) return "quiet hours";
    if (settings.store.onlyWhenOnline && !isPresent(target.userId)) return "they're offline";
    if (settings.store.skipDnd && PresenceStore.getStatus(target.userId) === "dnd") return "they're on Do Not Disturb";
    return null;
}

// ─── ringing loop ────────────────────────────────────────────────────────────

function startCalling(user: UserLike) {
    const userId = user.id;

    // Switching targets: tear down the previous loop first (also bumps the
    // generation, invalidating any pending retry from an earlier click)
    if (target) stopCalling({ silent: true });
    const gen = ++generation;

    const channelId = getDMChannelId(userId);
    const name = displayName(user);

    if (!channelId) {
        // DM is being opened; give it a moment, then try once more
        setTimeout(() => {
            if (gen !== generation) return; // superseded by a newer start/stop
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
    ringStartAt = 0;
    lastRingAt = 0;
    lastProgressAt = 0;
    wasInCall = false;
    announcedPause = false;

    const waiting = pauseReason();
    showToast(waiting
        ? `Waiting to call ${t.name} (${waiting}) — will start automatically. Right-click them to stop.`
        : `Calling ${t.name} — will keep ringing until they answer. Right-click them to stop.`);

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

    // Time cap (measured from the first actual ring, so waiting-for-online
    // doesn't burn the clock)
    const maxMs = settings.store.neverGiveUp ? 0 : settings.store.maxMinutes * 60_000;
    if (maxMs > 0 && ringStartAt > 0 && Date.now() - ringStartAt >= maxMs) {
        giveUp(`no answer after ${settings.store.maxMinutes} min`);
        return;
    }

    // Presence / DND / quiet-hours gating — pause without counting the tick
    const reason = pauseReason();
    if (reason) {
        if (!announcedPause) {
            announcedPause = true;
            showToast(`Paused calling ${target.name} (${reason}) — will resume automatically.`);
        }
        return;
    }
    if (announcedPause) {
        announcedPause = false;
        showToast(`Resuming calls to ${target.name}.`);
    }

    attempts++;

    const cap = settings.store.neverGiveUp ? 0 : settings.store.maxAttempts;
    if (cap > 0 && attempts > cap) {
        giveUp(`no answer after ${attempts - 1} rings`);
        return;
    }

    ring();
    showProgress();
}

function ring() {
    if (!target) return;
    // Dedupe rings that land close together (interval + a presence-triggered wake)
    if (Date.now() - lastRingAt < 1500) return;
    lastRingAt = Date.now();
    if (ringStartAt === 0) ringStartAt = Date.now();

    // Make sure we're in the DM call (this creates/joins it), then ring
    // explicitly every attempt. Wrapped because fast intervals can trip
    // Discord's rate limit, which we just skip and retry next tick.
    try {
        if (!inTargetCall()) VoiceActions.selectVoiceChannel(target.channelId);
        CallActions.ring(target.channelId);
    } catch { /* rate-limited or transient; try again next interval */ }
}

function showProgress() {
    if (!settings.store.showProgress || !target) return;
    if (Date.now() - lastProgressAt < 8000) return;
    lastProgressAt = Date.now();
    const cap = settings.store.neverGiveUp ? 0 : settings.store.maxAttempts;
    showToast(`Ringing ${target.name}… attempt ${attempts}${cap > 0 ? `/${cap}` : ""}`);
}

function onAnswered() {
    const t = target!;
    stopCalling({ silent: true, stopRing: false });

    showToast(`${t.name} answered the call!`, Toasts.Type.SUCCESS);
    if (settings.store.desktopNotification) {
        showNotification({ title: "Call answered", body: `${t.name} joined the call.` });
    }
}

function giveUp(reason: string) {
    const { name, channelId } = target!;
    stopCalling({ silent: true });

    showToast(`${name} didn't answer (${reason}) — gave up.`, Toasts.Type.FAILURE);
    if (settings.store.desktopNotification) {
        showNotification({ title: "No answer", body: `${name} — ${reason}.` });
    }

    const message = settings.store.giveUpMessage.trim();
    if (message) sendMessage(channelId, { content: message }).catch(() => { /* channel gone */ });
}

/**
 * Stop the redial loop.
 * @param silent   don't show the "stopped" toast (used by success/give-up which show their own)
 * @param stopRing also cancel the outgoing ring (default true; false when they already answered)
 */
function stopCalling({ silent = false, stopRing = true }: { silent?: boolean; stopRing?: boolean; } = {}) {
    generation++; // cancel any pending DM-open retry
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
    announcedPause = false;

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
    description: "Right-click someone → 'Call Until They Answer' (or /calluntil) to keep ringing them in DMs until they pick up. Stops the moment they join, and can wait for them to come online, respect Do Not Disturb / quiet hours, and back off when they start replying.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["call", "redial", "ring", "auto call", "until answer", "keep calling"],

    settings,

    contextMenus: {
        "user-context": UserContextMenuPatch
    },

    commands: [
        {
            name: "calluntil",
            description: "Keep ringing someone in DMs until they answer",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                { name: "user", description: "Who to call", type: ApplicationCommandOptionType.USER, required: true }
            ],
            execute: (args, ctx) => {
                const id = findOption<string>(args, "user", "");
                const user = id ? UserStore.getUser(id) : undefined;
                if (!user) return sendBotMessage(ctx.channel.id, { content: "Couldn't find that user." });
                if (user.bot) return sendBotMessage(ctx.channel.id, { content: "You can't call a bot." });
                if (user.id === UserStore.getCurrentUser()?.id) return sendBotMessage(ctx.channel.id, { content: "You can't call yourself." });
                startCalling(user);
            }
        },
        {
            name: "stopcalling",
            description: "Stop the RingUntilAnswer redial",
            inputType: ApplicationCommandInputType.BUILT_IN,
            execute: (_, ctx) => {
                if (!target) return sendBotMessage(ctx.channel.id, { content: "Not calling anyone right now." });
                stopCalling();
            }
        }
    ],

    flux: {
        VOICE_STATE_UPDATES() {
            if (!target) return;

            // They picked up
            if (targetJoined()) {
                onAnswered();
                return;
            }

            // You hung up / were moved out after having joined → stop
            const inCall = inTargetCall();
            if (settings.store.stopWhenILeave && wasInCall && !inCall) {
                const { name } = target;
                stopCalling({ silent: true });
                showToast(`You left the call — stopped calling ${name}.`);
                return;
            }
            wasInCall = inCall;
        },

        TYPING_START({ channelId, userId }: { channelId: string; userId: string; }) {
            if (!settings.store.stopWhenTyping || !target) return;
            if (channelId === target.channelId && userId === target.userId) {
                const { name } = target;
                stopCalling({ silent: true });
                showToast(`${name} is replying — stopped calling.`, Toasts.Type.SUCCESS);
            }
        },

        PRESENCE_UPDATES() {
            // Only relevant while we're paused waiting for them to become
            // available — ring immediately when they do (interval drives the
            // rest, and ring() dedupes any near-overlap).
            if (target && announcedPause) makeAttempt();
        }
    },

    stop() {
        stopCalling({ silent: true });
    }
});
