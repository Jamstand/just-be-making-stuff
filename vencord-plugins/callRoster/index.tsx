/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import { copyWithToast } from "@utils/discord";
import definePlugin from "@utils/types";
import { findStoreLazy } from "@webpack";
import { Menu, UserStore } from "@webpack/common";

interface ChannelLike {
    id: string;
    name?: string;
    type: number;
}

const GUILD_VOICE = 2;
const GUILD_STAGE_VOICE = 13;
const VoiceStateStore = findStoreLazy("VoiceStateStore");

function roster(channel: ChannelLike): string {
    const states = VoiceStateStore.getVoiceStatesForChannel(channel.id) ?? {};
    const names = Object.keys(states)
        .map(uid => {
            const u = UserStore.getUser(uid);
            return u?.globalName || u?.username || uid;
        })
        .sort((a, b) => a.localeCompare(b));

    const header = `${channel.name || "Voice channel"} — ${names.length} in call`;
    return names.length ? `${header}\n${names.map(n => `• ${n}`).join("\n")}` : `${header}\n(empty)`;
}

const ChannelContextMenuPatch: NavContextMenuPatchCallback = (children, { channel }: { channel?: ChannelLike; }) => {
    if (!channel || (channel.type !== GUILD_VOICE && channel.type !== GUILD_STAGE_VOICE)) return;

    children.push(
        <Menu.MenuSeparator key="call-roster-separator" />,
        <Menu.MenuItem
            key="call-roster-copy"
            id="call-roster-copy"
            label="Copy Call Roster"
            action={() => copyWithToast(roster(channel), "Copied the call roster!")}
        />
    );
};

export default definePlugin({
    name: "CallRoster",
    description: "Right-click a voice channel to copy a tidy list of everyone currently in the call. (A true video screenshot isn't possible from a plugin, so this copies the roster instead.)",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["roster", "participants", "members", "call", "list", "screenshot", "copy"],

    contextMenus: { "channel-context": ChannelContextMenuPatch }
});
