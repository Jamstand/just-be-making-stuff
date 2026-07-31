/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ApplicationCommandInputType, ApplicationCommandOptionType, findOption, sendBotMessage } from "@api/Commands";
import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import * as DataStore from "@api/DataStore";
import { showNotification } from "@api/Notifications";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy, findStoreLazy } from "@webpack";
import {
    ChannelStore,
    Menu,
    PresenceStore,
    RestAPI,
    SelectedChannelStore,
    showToast,
    Toasts,
    UserStore
} from "@webpack/common";

interface UserLike {
    id: string;
    bot?: boolean;
    username?: string;
    globalName?: string;
}

/** Minimal shape of the private-channel records we read. */
interface PrivateChannel {
    id: string;
    recipients?: string[];
    isGroupDM?: () => boolean;
}

const WORKING_KEY = "RingSquad_working";
const SAVED_KEY = "RingSquad_saved";
const GROUP_MAX = 9; // group DMs hold 10 incl. you

const VoiceStateStore = findStoreLazy("VoiceStateStore");
const VoiceActions = findByPropsLazy("selectVoiceChannel", "selectChannel");
const CallActions = findByPropsLazy("ring", "stopRinging");

const settings = definePluginSettings({
    mode: {
        type: OptionType.SELECT,
        description: "How to ring the squad",
        options: [
            { label: "Group blast — ring everyone at once in a group call", value: "group", default: true },
            { label: "Round-robin — ring one at a time until someone answers", value: "roundrobin" }
        ]
    },
    intervalSeconds: {
        type: OptionType.SLIDER,
        description: "Group blast: how often to re-ring people who haven't joined yet (seconds)",
        markers: [5, 10, 15, 30, 45, 60],
        default: 20,
        stickToMarkers: true
    },
    rolloverSeconds: {
        type: OptionType.SLIDER,
        description: "Round-robin: how long to ring each person before moving to the next (seconds)",
        markers: [5, 10, 15, 20, 30],
        default: 15,
        stickToMarkers: true
    },
    maxAttempts: {
        type: OptionType.SLIDER,
        description: "Give up after this many rounds if nobody answers (ignored when \"Ring forever\" is on)",
        markers: [3, 5, 10, 15, 25],
        default: 10,
        stickToMarkers: true
    },
    neverGiveUp: {
        type: OptionType.BOOLEAN,
        description: "Ring forever — keep going until someone answers or you stop",
        default: false
    },
    groupStopOnFirst: {
        type: OptionType.BOOLEAN,
        description: "Group blast: stop as soon as the FIRST person joins (off = keep ringing until everyone's in)",
        default: false
    },
    onlyWhenOnline: {
        type: OptionType.BOOLEAN,
        description: "Round-robin: skip people who are currently offline",
        default: true
    },
    createGroupIfMissing: {
        type: OptionType.BOOLEAN,
        description: "Group blast: create a new group DM if one with exactly those members doesn't already exist (this makes a persistent group chat)",
        default: false
    },
    showProgress: {
        type: OptionType.BOOLEAN,
        description: "Show periodic progress toasts while ringing",
        default: true
    },
    desktopNotification: {
        type: OptionType.BOOLEAN,
        description: "Desktop notification when someone answers (or when it gives up)",
        default: true
    }
});

// ─── state ───────────────────────────────────────────────────────────────────

interface Session {
    mode: "group" | "roundrobin";
    members: string[];
    channelId?: string;
    index: number;
    attempts: number;
    interval: ReturnType<typeof setInterval> | null;
}

let session: Session | null = null;
let generation = 0;
let lastProgressAt = 0;
let dmMap: Record<string, string> = {};

// persisted
let working: string[] = [];
let saved: Record<string, string[]> = {};

// ─── helpers ─────────────────────────────────────────────────────────────────

function name(userId: string): string {
    const u = UserStore.getUser(userId);
    return u?.globalName || u?.username || "someone";
}

function displayName(user: UserLike): string {
    return user.globalName || user.username || "them";
}

function isPresent(userId: string): boolean {
    const s = PresenceStore.getStatus(userId);
    return s === "online" || s === "idle" || s === "dnd" || s === "streaming";
}

function saveWorking() { DataStore.set(WORKING_KEY, working).catch(() => { /* best effort */ }); }
function saveSaved() { DataStore.set(SAVED_KEY, saved).catch(() => { /* best effort */ }); }

function resolveMembers(ids: string[]): string[] {
    const me = UserStore.getCurrentUser()?.id;
    const seen = new Set<string>();
    const out: string[] = [];
    for (const id of ids) {
        if (!id || id === me || seen.has(id)) continue;
        if (UserStore.getUser(id)?.bot) continue;
        seen.add(id);
        out.push(id);
    }
    return out;
}

function sameMembers(a: string[], b: string[]): boolean {
    if (a.length !== b.length) return false;
    const set = new Set(a);
    return b.every(x => set.has(x));
}

function findGroupDM(memberIds: string[]): string | undefined {
    return (ChannelStore.getSortedPrivateChannels() as PrivateChannel[])
        .find(c => c.isGroupDM?.() && sameMembers(c.recipients ?? [], memberIds))?.id;
}

async function createGroupDM(memberIds: string[]): Promise<string> {
    const { body } = await RestAPI.post({ url: "/users/@me/channels", body: { recipients: memberIds } });
    return body.id as string;
}

async function ensureDM(userId: string): Promise<string | undefined> {
    const existing = ChannelStore.getDMFromUserId(userId);
    if (existing) return existing;
    try {
        const { body } = await RestAPI.post({ url: "/users/@me/channels", body: { recipients: [userId] } });
        return body.id as string;
    } catch {
        return undefined;
    }
}

function membersInCall(channelId: string): string[] {
    const me = UserStore.getCurrentUser()?.id;
    const inCall = Object.keys(VoiceStateStore.getVoiceStatesForChannel(channelId) ?? {});
    return session ? session.members.filter(id => id !== me && inCall.includes(id)) : [];
}

function progress(message: string) {
    if (!settings.store.showProgress) return;
    if (Date.now() - lastProgressAt < 6000) return;
    lastProgressAt = Date.now();
    showToast(message);
}

// ─── lifecycle ─────────────────────────────────────────────────────────────

function stop({ silent = false, stopRing = true }: { silent?: boolean; stopRing?: boolean; } = {}) {
    generation++;
    if (session?.interval != null) clearInterval(session.interval);
    if (stopRing && session?.channelId) {
        try { CallActions.stopRinging(session.channelId); } catch { /* best effort */ }
    }
    const had = session;
    session = null;
    if (!silent && had) showToast("Stopped ringing the squad.");
}

function finish(message: string, ok: boolean) {
    stop({ silent: true });
    showToast(message, ok ? Toasts.Type.SUCCESS : Toasts.Type.FAILURE);
    if (settings.store.desktopNotification) showNotification({ title: "Squad call", body: message });
}

/** Returns true if it ended the session (someone answered per the mode's rule). */
function checkAnswered(): boolean {
    if (!session?.channelId) return false;
    const joined = membersInCall(session.channelId);

    if (session.mode === "roundrobin") {
        if (joined.length) { finish(`${name(joined[0])} answered!`, true); return true; }
        return false;
    }
    // group
    if (settings.store.groupStopOnFirst && joined.length) {
        finish(`${name(joined[0])} joined the call!`, true);
        return true;
    }
    if (session.members.length && joined.length === session.members.length) {
        finish("Everyone joined the call!", true);
        return true;
    }
    return false;
}

function capReached(): boolean {
    if (!session) return true;
    const cap = settings.store.neverGiveUp ? 0 : settings.store.maxAttempts;
    return cap > 0 && session.attempts > cap;
}

// ─── group blast ───────────────────────────────────────────────────────────

function ringGroup() {
    if (!session?.channelId) return;
    if (checkAnswered()) return;

    session.attempts++;
    if (capReached()) {
        const n = membersInCall(session.channelId).length;
        finish(`Gave up — ${n}/${session.members.length} joined after ${settings.store.maxAttempts} rings.`, false);
        return;
    }

    try {
        if (SelectedChannelStore.getVoiceChannelId() !== session.channelId) VoiceActions.selectVoiceChannel(session.channelId);
        CallActions.ring(session.channelId);
    } catch { /* rate-limited/transient */ }

    progress(`Ringing group… ${membersInCall(session.channelId).length}/${session.members.length} in.`);
}

// ─── round-robin ───────────────────────────────────────────────────────────

function ringCurrent() {
    if (!session) return;
    const uid = session.members[session.index];
    const dm = dmMap[uid];
    if (!dm) return;
    session.channelId = dm;
    try {
        if (SelectedChannelStore.getVoiceChannelId() !== dm) VoiceActions.selectVoiceChannel(dm);
        CallActions.ring(dm);
    } catch { /* rate-limited/transient */ }
    progress(`Ringing ${name(uid)} (${session.index + 1}/${session.members.length})…`);
}

function advanceRoundRobin() {
    if (!session) return;
    if (checkAnswered()) return;

    // stop ringing the person we're leaving
    if (session.channelId) {
        try { CallActions.stopRinging(session.channelId); } catch { /* best effort */ }
    }

    const n = session.members.length;
    let next = session.index;
    let guard = 0;
    do {
        next = (next + 1) % n;
        guard++;
    } while (settings.store.onlyWhenOnline && !isPresent(session.members[next]) && guard < n);

    // completed a full loop back to (or past) where we were
    const wrapped = next <= session.index;
    session.index = next;

    if (wrapped) {
        session.attempts++;
        if (capReached()) {
            finish(`Gave up — nobody answered after ${settings.store.maxAttempts} rounds.`, false);
            return;
        }
    }
    ringCurrent();
}

// ─── start ─────────────────────────────────────────────────────────────────

async function start(rawIds: string[]) {
    const members = resolveMembers(rawIds);
    if (!members.length) {
        showToast("That squad has nobody to ring.", Toasts.Type.FAILURE);
        return;
    }

    stop({ silent: true });
    const gen = ++generation;

    // Group mode with a single person is just a 1:1 ring — fall back to round-robin
    const mode: "group" | "roundrobin" =
        settings.store.mode === "group" && members.length >= 2 ? "group" : "roundrobin";
    session = { mode, members, index: 0, attempts: 0, interval: null };

    if (mode === "group") {
        let group = members;
        if (group.length > GROUP_MAX) {
            showToast(`Group DMs max out at 10 (you + ${GROUP_MAX}); ringing the first ${GROUP_MAX}.`);
            group = group.slice(0, GROUP_MAX);
            session.members = group;
        }

        let channelId = findGroupDM(group);
        if (!channelId) {
            if (!settings.store.createGroupIfMissing) {
                showToast(`No existing group DM with exactly those ${group.length} people. Enable "Create group DM if missing" in settings, or make the group once.`, Toasts.Type.FAILURE);
                session = null;
                return;
            }
            try {
                channelId = await createGroupDM(group);
            } catch {
                showToast("Couldn't create the group DM.", Toasts.Type.FAILURE);
                session = null;
                return;
            }
        }
        if (gen !== generation || !session) return; // superseded while awaiting

        session.channelId = channelId;
        VoiceActions.selectVoiceChannel(channelId);
        ringGroup();
        session.interval = setInterval(ringGroup, settings.store.intervalSeconds * 1000);
        showToast(`Ringing ${session.members.length} people in a group call. /stopsquad to stop.`);
        return;
    }

    // round-robin: resolve everyone's DM channel up front
    dmMap = {};
    for (const id of members) dmMap[id] = (await ensureDM(id)) ?? "";
    if (gen !== generation || !session) return;

    session.members = members.filter(id => dmMap[id]);
    if (!session.members.length) {
        showToast("Couldn't open DMs for anyone in the squad.", Toasts.Type.FAILURE);
        session = null;
        return;
    }
    session.index = 0;
    ringCurrent();
    session.interval = setInterval(advanceRoundRobin, settings.store.rolloverSeconds * 1000);
    showToast(`Round-robin calling ${session.members.length} people, one at a time. /stopsquad to stop.`);
}

// ─── squad management ────────────────────────────────────────────────────────

function toggleMember(user: UserLike) {
    if (working.includes(user.id)) {
        working = working.filter(id => id !== user.id);
        showToast(`Removed ${displayName(user)} from your ring squad (${working.length} now).`);
    } else {
        working.push(user.id);
        showToast(`Added ${displayName(user)} to your ring squad (${working.length} now).`);
    }
    saveWorking();
}

// ─── context menu ────────────────────────────────────────────────────────────

const UserContextMenuPatch: NavContextMenuPatchCallback = (children, { user }: { user?: UserLike; }) => {
    if (!user || user.bot) return;
    if (user.id === UserStore.getCurrentUser()?.id) return;

    const inSquad = working.includes(user.id);
    children.push(
        <Menu.MenuSeparator key="ring-squad-separator" />,
        <Menu.MenuItem
            key="ring-squad-toggle"
            id="ring-squad-toggle"
            label={inSquad ? "Remove from Ring Squad" : "Add to Ring Squad"}
            color={inSquad ? "danger" : undefined}
            action={() => toggleMember(user)}
        />
    );
};

// ─── plugin ──────────────────────────────────────────────────────────────────

export default definePlugin({
    name: "RingSquad",
    description: "Ring several people at once — a group blast (one group call, everyone rings together) or round-robin (ring one at a time until someone answers). Build a squad by right-clicking users, then /ringsquad.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["ring", "squad", "group", "call", "multiple", "everyone", "round robin", "blast"],

    settings,

    contextMenus: {
        "user-context": UserContextMenuPatch
    },

    commands: [
        {
            name: "ringsquad",
            description: "Ring your squad (working squad, or a saved one by name)",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                { name: "squad", description: "Name of a saved squad (leave blank for your current working squad)", type: ApplicationCommandOptionType.STRING, required: false }
            ],
            execute: (args, ctx) => {
                const squadName = findOption<string>(args, "squad", "").trim();
                const ids = squadName ? saved[squadName] : working;
                if (squadName && !saved[squadName]) return sendBotMessage(ctx.channel.id, { content: `No saved squad named "${squadName}". Use /squad to list them.` });
                if (!ids?.length) return sendBotMessage(ctx.channel.id, { content: "That squad is empty. Right-click people → Add to Ring Squad first." });
                start(ids);
            }
        },
        {
            name: "stopsquad",
            description: "Stop ringing the squad",
            inputType: ApplicationCommandInputType.BUILT_IN,
            execute: (_, ctx) => {
                if (!session) return sendBotMessage(ctx.channel.id, { content: "Not ringing a squad right now." });
                stop();
            }
        },
        {
            name: "squad",
            description: "Show your working squad and saved squads",
            inputType: ApplicationCommandInputType.BUILT_IN,
            execute: (_, ctx) => {
                const workingList = working.length ? working.map(name).join(", ") : "(empty)";
                const savedList = Object.keys(saved).length
                    ? Object.entries(saved).map(([k, v]) => `• **${k}** — ${v.length} people`).join("\n")
                    : "(none)";
                sendBotMessage(ctx.channel.id, { content: `**Working squad (${working.length}):** ${workingList}\n**Saved squads:**\n${savedList}` });
            }
        },
        {
            name: "squad-save",
            description: "Save your working squad under a name",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                { name: "name", description: "Name to save it as", type: ApplicationCommandOptionType.STRING, required: true }
            ],
            execute: (args, ctx) => {
                const key = findOption<string>(args, "name", "").trim();
                if (!key) return sendBotMessage(ctx.channel.id, { content: "Give the squad a name." });
                if (!working.length) return sendBotMessage(ctx.channel.id, { content: "Your working squad is empty — nothing to save." });
                saved[key] = [...working];
                saveSaved();
                sendBotMessage(ctx.channel.id, { content: `Saved squad "${key}" with ${working.length} people.` });
            }
        },
        {
            name: "squad-load",
            description: "Load a saved squad into your working squad",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                { name: "name", description: "Name of the saved squad", type: ApplicationCommandOptionType.STRING, required: true }
            ],
            execute: (args, ctx) => {
                const key = findOption<string>(args, "name", "").trim();
                if (!saved[key]) return sendBotMessage(ctx.channel.id, { content: `No saved squad named "${key}".` });
                working = [...saved[key]];
                saveWorking();
                sendBotMessage(ctx.channel.id, { content: `Loaded "${key}" (${working.length} people) into your working squad.` });
            }
        },
        {
            name: "squad-clear",
            description: "Empty your working squad",
            inputType: ApplicationCommandInputType.BUILT_IN,
            execute: (_, ctx) => {
                working = [];
                saveWorking();
                sendBotMessage(ctx.channel.id, { content: "Cleared your working squad." });
            }
        }
    ],

    flux: {
        VOICE_STATE_UPDATES() {
            if (session) checkAnswered();
        }
    },

    async start() {
        working = (await DataStore.get(WORKING_KEY)) ?? [];
        saved = (await DataStore.get(SAVED_KEY)) ?? {};
    },

    stop() {
        stop({ silent: true });
    }
});
