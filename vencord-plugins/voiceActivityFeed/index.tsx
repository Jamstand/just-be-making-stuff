/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { ChannelStore, React, showToast, Toasts, UserStore } from "@webpack/common";

interface VoiceState {
    userId: string;
    channelId?: string | null;
    oldChannelId?: string | null;
}

interface FeedEntry {
    time: number;
    text: string;
}

const MAX = 50;
const feed: FeedEntry[] = [];

const settings = definePluginSettings({
    showToasts: {
        type: OptionType.BOOLEAN,
        description: "Also pop a toast for each voice join/leave (can get noisy on big servers)",
        default: false
    }
});

function name(userId: string): string {
    const u = UserStore.getUser(userId);
    return u?.globalName || u?.username || "Someone";
}

function channelName(channelId?: string | null): string {
    if (!channelId) return "voice";
    return ChannelStore.getChannel(channelId)?.name || "a channel";
}

function record(text: string) {
    feed.unshift({ time: Date.now(), text });
    if (feed.length > MAX) feed.pop();
    if (settings.store.showToasts) showToast(text, Toasts.Type.MESSAGE);
}

export default definePlugin({
    name: "VoiceActivityFeed",
    description: "Keeps a running log of who joined, left, or moved between voice channels. View it in this plugin's settings.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["voice", "log", "activity", "feed", "history"],

    settings,

    flux: {
        VOICE_STATE_UPDATES({ voiceStates }: { voiceStates: VoiceState[]; }) {
            if (!voiceStates) return;
            for (const { userId, channelId, oldChannelId } of voiceStates) {
                if (channelId && !oldChannelId) record(`${name(userId)} joined ${channelName(channelId)}`);
                else if (!channelId && oldChannelId) record(`${name(userId)} left ${channelName(oldChannelId)}`);
                else if (channelId && oldChannelId && channelId !== oldChannelId) record(`${name(userId)} moved to ${channelName(channelId)}`);
            }
        }
    },

    settingsAboutComponent: () => {
        const [, force] = React.useReducer((x: number) => x + 1, 0);
        React.useEffect(() => {
            const t = setInterval(force, 2000);
            return () => clearInterval(t);
        }, []);

        if (!feed.length) return <div style={{ color: "var(--text-muted)" }}>No voice activity recorded yet.</div>;

        return (
            <div style={{ maxHeight: 320, overflowY: "auto", fontSize: 14 }}>
                {feed.map((e, i) => (
                    <div key={i} style={{ padding: "2px 0", color: "var(--text-normal)" }}>
                        <span style={{ color: "var(--text-muted)" }}>{new Date(e.time).toLocaleTimeString()} </span>
                        {e.text}
                    </div>
                ))}
            </div>
        );
    }
});
