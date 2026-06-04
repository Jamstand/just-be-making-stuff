/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import * as DataStore from "@api/DataStore";
import { showNotification } from "@api/Notifications";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import {
    ChannelStore,
    GuildStore,
    Menu,
    PresenceStore,
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

interface VoiceState {
    userId: string;
    channelId?: string | null;
    oldChannelId?: string | null;
}

const STORE_KEY = "VoiceJoinAlert_targets";

const settings = definePluginSettings({
    alertOnVoice: {
        type: OptionType.BOOLEAN,
        description: "Notify when a watched person joins a voice channel",
        default: true
    },
    alertOnOnline: {
        type: OptionType.BOOLEAN,
        description: "Notify when a watched person comes online (from offline)",
        default: false
    },
    desktopNotification: {
        type: OptionType.BOOLEAN,
        description: "Use a desktop notification (in addition to an in-app toast)",
        default: true
    }
});

let targets: Record<string, string> = {};
const lastStatus: Record<string, string> = {};

function displayName(user: UserLike): string {
    return user.globalName || user.username || "them";
}

function alert(title: string, body: string) {
    showToast(`${title} ${body}`, Toasts.Type.MESSAGE);
    if (settings.store.desktopNotification) showNotification({ title, body });
}

function toggle(user: UserLike) {
    const { id } = user;
    const name = displayName(user);

    if (targets[id]) {
        delete targets[id];
        delete lastStatus[id];
        showToast(`No longer alerting for ${name}.`);
    } else {
        targets[id] = name;
        lastStatus[id] = PresenceStore.getStatus(id) ?? "offline";
        showToast(`Will alert you when ${name} joins voice${settings.store.alertOnOnline ? " or comes online" : ""}.`);
    }

    DataStore.set(STORE_KEY, targets).catch(() => { /* best effort */ });
}

const UserContextMenuPatch: NavContextMenuPatchCallback = (children, { user }: { user?: UserLike; }) => {
    if (!user || user.bot) return;
    if (user.id === UserStore.getCurrentUser()?.id) return;

    const active = !!targets[user.id];

    children.push(
        <Menu.MenuSeparator key="voice-join-alert-separator" />,
        <Menu.MenuItem
            key="voice-join-alert-toggle"
            id="voice-join-alert-toggle"
            label={active ? "Stop Alerting" : "Alert When They Join Voice"}
            color={active ? "danger" : undefined}
            action={() => toggle(user)}
        />
    );
};

export default definePlugin({
    name: "VoiceJoinAlert",
    description: "Get a notification when chosen people join a voice channel (or optionally come online), so you know when to hop in.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice", "Notifications"],
    searchTerms: ["alert", "notify", "voice", "join", "online", "friend"],

    settings,

    contextMenus: {
        "user-context": UserContextMenuPatch
    },

    flux: {
        VOICE_STATE_UPDATES({ voiceStates }: { voiceStates: VoiceState[]; }) {
            if (!settings.store.alertOnVoice || !voiceStates) return;

            for (const { userId, channelId, oldChannelId } of voiceStates) {
                const name = targets[userId];
                if (!name) continue;
                // Fresh voice join (wasn't in any channel before)
                if (!channelId || oldChannelId) continue;

                const channel = ChannelStore.getChannel(channelId);
                const guildName = channel?.guild_id ? GuildStore.getGuild(channel.guild_id)?.name : undefined;
                const where = channel?.name
                    ? ` in ${channel.name}${guildName ? ` (${guildName})` : ""}`
                    : "";
                alert("Joined voice", `${name} joined voice${where}.`);
            }
        },

        PRESENCE_UPDATES() {
            if (!settings.store.alertOnOnline) return;

            for (const userId of Object.keys(targets)) {
                const status = PresenceStore.getStatus(userId) ?? "offline";
                const prev = lastStatus[userId];
                lastStatus[userId] = status;
                if (prev === "offline" && status !== "offline") {
                    alert("Came online", `${targets[userId]} is now ${status}.`);
                }
            }
        }
    },

    async start() {
        targets = (await DataStore.get(STORE_KEY)) ?? {};
        for (const userId of Object.keys(targets)) {
            lastStatus[userId] = PresenceStore.getStatus(userId) ?? "offline";
        }
    }
});
