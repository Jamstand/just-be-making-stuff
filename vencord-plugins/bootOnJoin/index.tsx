/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import * as DataStore from "@api/DataStore";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import {
    ChannelStore,
    Constants,
    Menu,
    PermissionsBits,
    PermissionStore,
    RestAPI,
    SelectedChannelStore,
    showToast,
    Toasts,
    UserStore,
    VoiceStateStore
} from "@webpack/common";

/** Minimal shape of the user records the user-context menu hands us. */
interface UserLike {
    id: string;
    bot?: boolean;
    username?: string;
    globalName?: string;
}

const STORE_KEY = "BootOnJoin_targets";

const settings = definePluginSettings({
    showToasts: {
        type: OptionType.BOOLEAN,
        description: "Show a toast each time someone gets booted (or a boot fails)",
        default: true
    }
});

// ─── state ───────────────────────────────────────────────────────────────────

// userId -> display name, persisted across restarts
let targets: Record<string, string> = {};
// users we've just sent a disconnect for, to avoid hammering the API while the
// voice state catches up
const booting = new Set<string>();

// ─── helpers ─────────────────────────────────────────────────────────────────

function displayName(user: UserLike): string {
    return user.globalName || user.username || "them";
}

function notify(message: string, type: string = Toasts.Type.MESSAGE) {
    if (settings.store.showToasts) showToast(message, type);
}

function save() {
    DataStore.set(STORE_KEY, targets).catch(() => { /* best effort */ });
}

// ─── core ────────────────────────────────────────────────────────────────────

/** Boot any targeted users who share your current voice channel. */
function enforce() {
    if (!Object.keys(targets).length) return;

    const myVcId = SelectedChannelStore.getVoiceChannelId();
    if (!myVcId) return;

    const channel = ChannelStore.getChannel(myVcId);
    // Force-disconnect only works in guild voice channels (not DM/group calls)
    if (!channel?.guild_id) return;
    // Discord enforces this server-side too, but skip quietly if we can't move members
    if (!PermissionStore.can(PermissionsBits.MOVE_MEMBERS, channel)) return;

    for (const userId of Object.keys(targets)) {
        if (booting.has(userId)) continue;
        if (VoiceStateStore.getVoiceStateForUser(userId)?.channelId !== myVcId) continue;
        boot(channel.guild_id, userId, targets[userId]);
    }
}

function boot(guildId: string, userId: string, name: string) {
    booting.add(userId);

    RestAPI.patch({
        url: Constants.Endpoints.GUILD_MEMBER(guildId, userId),
        body: { channel_id: null }
    })
        .then(() => notify(`Booted ${name} from the channel.`, Toasts.Type.SUCCESS))
        .catch(() => notify(`Couldn't boot ${name} - do you have Move Members here?`, Toasts.Type.FAILURE))
        .finally(() => setTimeout(() => booting.delete(userId), 3000));
}

function toggle(user: UserLike) {
    const { id } = user;
    const name = displayName(user);

    if (targets[id]) {
        delete targets[id];
        notify(`No longer auto-booting ${name}.`);
    } else {
        targets[id] = name;
        notify(`Will boot ${name} whenever you share a voice channel (needs Move Members there).`);
    }

    save();
    enforce(); // boot right away if you're already together
}

// ─── context menu ────────────────────────────────────────────────────────────

const UserContextMenuPatch: NavContextMenuPatchCallback = (children, { user }: { user?: UserLike; }) => {
    if (!user || user.bot) return;
    if (user.id === UserStore.getCurrentUser()?.id) return;

    const active = !!targets[user.id];

    children.push(
        <Menu.MenuSeparator key="boot-on-join-separator" />,
        <Menu.MenuItem
            key="boot-on-join-toggle"
            id="boot-on-join-toggle"
            label={active ? "Stop Booting On Join" : "Boot When I Join"}
            color={active ? "danger" : undefined}
            action={() => toggle(user)}
        />
    );
};

// ─── plugin ──────────────────────────────────────────────────────────────────

export default definePlugin({
    name: "BootOnJoin",
    description: "Automatically disconnect chosen users from voice the moment you share a channel with them. Requires the Move Members permission in that server.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["kick", "disconnect", "boot", "voice", "move members", "auto kick"],

    settings,

    contextMenus: {
        "user-context": UserContextMenuPatch
    },

    flux: {
        // Covers both "you joined a channel they're in" and "they joined yours"
        VOICE_STATE_UPDATES() {
            enforce();
        }
    },

    async start() {
        targets = (await DataStore.get(STORE_KEY)) ?? {};
        enforce();
    }
});
