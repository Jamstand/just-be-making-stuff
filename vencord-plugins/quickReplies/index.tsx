/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ApplicationCommandInputType, ApplicationCommandOptionType, findOption, sendBotMessage } from "@api/Commands";
import * as DataStore from "@api/DataStore";
import { sendMessage } from "@utils/discord";
import definePlugin from "@utils/types";

const STORE_KEY = "QuickReplies_snippets";
let snippets: Record<string, string> = {};

function persist() {
    DataStore.set(STORE_KEY, snippets).catch(() => { /* best effort */ });
}

export default definePlugin({
    name: "QuickReplies",
    description: "Save reusable text snippets and fire them off with /qr <name>. Manage with /qr-save, /qr-list, /qr-delete.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Chat"],
    searchTerms: ["quick", "reply", "snippet", "canned", "macro", "template"],

    commands: [
        {
            name: "qr",
            description: "Send a saved quick reply",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                { name: "name", description: "Name of the saved snippet", type: ApplicationCommandOptionType.STRING, required: true }
            ],
            execute: (args, ctx) => {
                const key = findOption<string>(args, "name", "").trim();
                const text = snippets[key];
                if (!text) {
                    sendBotMessage(ctx.channel.id, { content: `No quick reply named "${key}". Use /qr-list to see them.` });
                    return;
                }
                // BUILT_IN commands don't auto-send their return value — send it ourselves
                sendMessage(ctx.channel.id, { content: text });
            }
        },
        {
            name: "qr-save",
            description: "Save (or overwrite) a quick reply",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                { name: "name", description: "Name to save it under", type: ApplicationCommandOptionType.STRING, required: true },
                { name: "text", description: "The text to send when used", type: ApplicationCommandOptionType.STRING, required: true }
            ],
            execute: (args, ctx) => {
                const key = findOption<string>(args, "name", "").trim();
                const text = findOption<string>(args, "text", "");
                if (!key || !text) {
                    sendBotMessage(ctx.channel.id, { content: "Need both a name and some text." });
                    return;
                }
                snippets[key] = text;
                persist();
                sendBotMessage(ctx.channel.id, { content: `Saved quick reply "${key}".` });
            }
        },
        {
            name: "qr-list",
            description: "List your saved quick replies",
            inputType: ApplicationCommandInputType.BUILT_IN,
            execute: (_, ctx) => {
                const keys = Object.keys(snippets);
                sendBotMessage(ctx.channel.id, { content: keys.length ? `Saved: ${keys.map(k => `\`${k}\``).join(", ")}` : "No quick replies saved yet." });
            }
        },
        {
            name: "qr-delete",
            description: "Delete a saved quick reply",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                { name: "name", description: "Name of the snippet to delete", type: ApplicationCommandOptionType.STRING, required: true }
            ],
            execute: (args, ctx) => {
                const key = findOption<string>(args, "name", "").trim();
                if (snippets[key]) {
                    delete snippets[key];
                    persist();
                    sendBotMessage(ctx.channel.id, { content: `Deleted "${key}".` });
                } else {
                    sendBotMessage(ctx.channel.id, { content: `No quick reply named "${key}".` });
                }
            }
        }
    ],

    async start() {
        snippets = (await DataStore.get(STORE_KEY)) ?? {};
    }
});
