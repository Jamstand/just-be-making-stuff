/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import * as DataStore from "@api/DataStore";
import { showNotification } from "@api/Notifications";
import definePlugin from "@utils/types";
import { ChannelStore, Menu, showToast, Toasts } from "@webpack/common";

interface Message {
    id: string;
    channel_id: string;
    content?: string;
    author?: { id: string; globalName?: string; username?: string; };
}

interface Reminder {
    id: string;
    fireAt: number;
    channelId: string;
    author: string;
    snippet: string;
}

const STORE_KEY = "ReminderFromMessage_list";
let reminders: Reminder[] = [];
const timers = new Map<string, ReturnType<typeof setTimeout>>();

const PRESETS: { label: string; ms: number; }[] = [
    { label: "in 15 minutes", ms: 15 * 60_000 },
    { label: "in 1 hour", ms: 60 * 60_000 },
    { label: "in 3 hours", ms: 3 * 60 * 60_000 },
    { label: "tomorrow", ms: 24 * 60 * 60_000 }
];

function persist() {
    DataStore.set(STORE_KEY, reminders).catch(() => { /* best effort */ });
}

function fire(r: Reminder) {
    timers.delete(r.id);
    reminders = reminders.filter(x => x.id !== r.id);
    persist();

    const channelName = ChannelStore.getChannel(r.channelId)?.name;
    showNotification({
        title: "Reminder",
        body: `${r.author}: ${r.snippet}${channelName ? `  (#${channelName})` : ""}`
    });
}

function arm(r: Reminder) {
    timers.set(r.id, setTimeout(() => fire(r), Math.max(0, r.fireAt - Date.now())));
}

function add(message: Message, ms: number, label: string) {
    const author = message.author?.globalName || message.author?.username || "Message";
    const r: Reminder = {
        id: `${Date.now()}-${Math.random().toString(36).slice(2)}`,
        fireAt: Date.now() + ms,
        channelId: message.channel_id,
        author,
        snippet: (message.content || "(no text)").replace(/\s+/g, " ").trim().slice(0, 120)
    };
    reminders.push(r);
    persist();
    arm(r);
    showToast(`I'll remind you ${label}.`, Toasts.Type.SUCCESS);
}

const MessageContextMenuPatch: NavContextMenuPatchCallback = (children, { message }: { message?: Message; }) => {
    if (!message) return;

    children.push(
        <Menu.MenuSeparator key="reminder-separator" />,
        <Menu.MenuItem key="reminder-root" id="reminder-root" label="Remind Me">
            {PRESETS.map(p => (
                <Menu.MenuItem
                    key={`reminder-${p.ms}`}
                    id={`reminder-${p.ms}`}
                    label={p.label.replace(/^in /, "").replace(/^./, c => c.toUpperCase())}
                    action={() => add(message, p.ms, p.label)}
                />
            ))}
        </Menu.MenuItem>
    );
};

export default definePlugin({
    name: "ReminderFromMessage",
    description: "Right-click a message → Remind Me → pick a time, and you'll get a desktop notification later with a snippet of it.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Chat", "Notifications"],
    searchTerms: ["remind", "reminder", "later", "follow up"],

    contextMenus: { "message": MessageContextMenuPatch },

    async start() {
        reminders = (await DataStore.get(STORE_KEY)) ?? [];
        reminders.forEach(arm);
    },

    stop() {
        timers.forEach(t => clearTimeout(t));
        timers.clear();
    }
});
