/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { sendBotMessage } from "@api/Commands";
import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { Menu } from "@webpack/common";

interface Message {
    id: string;
    channel_id: string;
    content?: string;
}

const settings = definePluginSettings({
    targetLang: {
        type: OptionType.STRING,
        description: "Language code to translate into (e.g. en, es, fr, de, ja)",
        default: "en"
    }
});

async function translate(text: string): Promise<string> {
    const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${encodeURIComponent(settings.store.targetLang || "en")}&dt=t&q=${encodeURIComponent(text)}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    // data[0] is an array of [translatedChunk, originalChunk, ...]
    return (data[0] as any[]).map(part => part[0]).join("");
}

const MessageContextMenuPatch: NavContextMenuPatchCallback = (children, { message }: { message?: Message; }) => {
    if (!message?.content) return;

    children.push(
        <Menu.MenuSeparator key="translate-separator" />,
        <Menu.MenuItem
            key="translate-message"
            id="translate-message"
            label="Translate"
            action={async () => {
                try {
                    const result = await translate(message.content!);
                    sendBotMessage(message.channel_id, { content: `🌐 ${result}` });
                } catch {
                    sendBotMessage(message.channel_id, { content: "Translation failed (the endpoint may be blocked). Vencord's built-in Translate plugin is a sturdier option." });
                }
            }}
        />
    );
};

export default definePlugin({
    name: "MessageTranslate",
    description: "Right-click any message → Translate. Shows the translation privately (only you see it).",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Chat"],
    searchTerms: ["translate", "language", "translation"],

    settings,

    contextMenus: { "message": MessageContextMenuPatch }
});
