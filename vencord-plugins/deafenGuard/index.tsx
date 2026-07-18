/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy } from "@webpack";
import { MediaEngineStore, UserStore } from "@webpack/common";

interface VoiceState {
    userId: string;
    channelId?: string | null;
    oldChannelId?: string | null;
}

// The self mute/deafen toggle actions (MediaEngineStore only exposes the isSelf* getters)
const AudioActions = findByPropsLazy("toggleSelfMute", "toggleSelfDeaf");

const settings = definePluginSettings({
    mode: {
        type: OptionType.SELECT,
        description: "What to force when you join a voice channel",
        options: [
            { label: "Deafen (also mutes)", value: "deafen", default: true },
            { label: "Mute only", value: "mute" }
        ]
    }
});

export default definePlugin({
    name: "DeafenGuard",
    description: "Automatically deafen (or mute) yourself the moment you join any voice channel, so you never forget.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Voice"],
    searchTerms: ["deafen", "mute", "auto", "voice", "join"],

    settings,

    flux: {
        VOICE_STATE_UPDATES({ voiceStates }: { voiceStates: VoiceState[]; }) {
            const me = UserStore.getCurrentUser()?.id;
            if (!me || !voiceStates) return;

            for (const vs of voiceStates) {
                if (vs.userId !== me) continue;
                // only when freshly joining voice, so you can still un-deafen afterwards
                if (!vs.channelId || vs.oldChannelId) continue;

                // Check current state via the store, then toggle only if needed
                if (settings.store.mode === "mute") {
                    if (!MediaEngineStore.isSelfMute()) AudioActions.toggleSelfMute();
                } else if (!MediaEngineStore.isSelfDeaf()) {
                    AudioActions.toggleSelfDeaf();
                }
            }
        }
    }
});
