/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import * as DataStore from "@api/DataStore";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy, findStoreLazy } from "@webpack";
import {
    ChannelStore,
    Menu,
    PermissionsBits,
    PermissionStore,
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

const STORE_KEY = "FollowVC_target";

const VoiceStateStore = findStoreLazy("VoiceStateStore");
const VoiceActions = findByPropsLazy("selectVoiceChannel", "selectChannel");

const settings = definePluginSettings({
    leaveWhenTheyLeave: {
        type: OptionType.BOOLEAN,
        description: "Disconnect yourself when the person you're following leaves voice",
        default: false
    },
    showToasts: {
        type: OptionType.BOOLEAN,
        description: "Show a toast when you follow them into a channel",
        default: true
    }
});

let target: { userId: string; name: string; } | null = null;

function displayName(user: UserLike): string {
    return user.globalName || user.username || "them";
}

function notify(message: string, type: string = Toasts.Type.MESSAGE) {
    if (settings.store.showToasts) showToast(message, type);
}

function follow() {
    if (!target) return;

    const theirVc = VoiceStateStore.getVoiceStateForUser(target.userId)?.channelId;
    const myVc = SelectedChannelStore.getVoiceChannelId();

    if (!theirVc) {
        if (settings.store.leaveWhenTheyLeave && myVc) {
            try { VoiceActions.selectVoiceChannel(null); } catch { /* best effort */ }
        }
        return;
    }

    if (theirVc === myVc) return; // already together

    const channel = ChannelStore.getChannel(theirVc);
    if (!channel?.guild_id) return; // can't follow into a DM/group call
    if (!PermissionStore.can(PermissionsBits.CONNECT, channel)) return;

    VoiceActions.selectVoiceChannel(theirVc);
    notify(`Following ${target.name} into ${channel.name}.`);
}

function toggle(user: UserLike) {
    if (target?.userId === user.id) {
        target = null;
        DataStore.del(STORE_KEY);
        notify(`Stopped following ${displayName(user)}.`);
        return;
    }

    target = { userId: user.id, name: displayName(user) };
    DataStore.set(STORE_KEY, target);
    notify(`Now following ${target.name} — you'll join their voice channel.`);
    follow();
}

const UserContextMenuPatch: NavContextMenuPatchCallback = (children, { user }: { user?: UserLike; }) => {
    if (!user || user.bot) return;
    if (user.id === UserStore.getCurrentUser()?.id) return;

    const active = target?.userId === user.id;

    children.push(
        <Menu.MenuSeparator key="follow-vc-separator" />,
        <Menu.MenuItem
            key="follow-vc-toggle"
            id="follow-vc-toggle"
            label={active ? "Stop Following Into Voice" : "Follow Into Voice"}
            color={active ? "danger" : undefined}
            action={() => toggle(user)}
        />
    );
};

export default definePlugin({
    name: "FollowVC",
    description: "Pick a person and automatically join whatever voice channel they hop into.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["follow", "voice", "join", "stalk", "move with"],

    settings,

    contextMenus: {
        "user-context": UserContextMenuPatch
    },

    flux: {
        VOICE_STATE_UPDATES() {
            follow();
        }
    },

    async start() {
        target = (await DataStore.get(STORE_KEY)) ?? null;
        follow();
    }
});
