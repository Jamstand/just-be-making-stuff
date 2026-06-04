/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ApplicationCommandInputType, ApplicationCommandOptionType, findOption, sendBotMessage } from "@api/Commands";
import definePlugin from "@utils/types";

const CLIP_RE = /^https?:\/\/(clips\.twitch\.tv\/|(www\.)?twitch\.tv\/\S+\/clip\/|(www\.)?youtube\.com\/clip\/)\S+/i;

export default definePlugin({
    name: "ClipDropper",
    description: "/clip <url> [caption] — quickly drop a Twitch/YouTube clip with an optional caption. (Discord, not clients, generates the rich embed, so this just posts a clean caption + link.)",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Chat"],
    searchTerms: ["clip", "twitch", "youtube", "drop", "share"],

    commands: [
        {
            name: "clip",
            description: "Post a clip link with an optional caption",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                { name: "url", description: "The clip URL", type: ApplicationCommandOptionType.STRING, required: true },
                { name: "caption", description: "Optional text above the clip", type: ApplicationCommandOptionType.STRING, required: false }
            ],
            execute: (args, ctx) => {
                const url = findOption<string>(args, "url", "").trim();
                const caption = findOption<string>(args, "caption", "").trim();

                if (!CLIP_RE.test(url)) {
                    sendBotMessage(ctx.channel.id, { content: "That doesn't look like a Twitch/YouTube clip URL." });
                    return;
                }
                return { content: caption ? `${caption}\n${url}` : url };
            }
        }
    ]
});
