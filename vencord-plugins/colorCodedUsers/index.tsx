/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NavContextMenuPatchCallback } from "@api/ContextMenu";
import * as DataStore from "@api/DataStore";
import definePlugin from "@utils/types";
import { Menu } from "@webpack/common";

interface UserLike {
    id: string;
    username?: string;
    globalName?: string;
}

const STORE_KEY = "ColorCodedUsers_colors";
const COLORS: [string, string][] = [
    ["Red", "#ed4245"],
    ["Orange", "#e67e22"],
    ["Yellow", "#f1c40f"],
    ["Green", "#2ecc71"],
    ["Blue", "#3498db"],
    ["Purple", "#9b59b6"],
    ["Pink", "#e91e63"]
];

let colors: Record<string, string> = {};
let styleEl: HTMLStyleElement | null = null;

function rebuild() {
    if (!styleEl) return;
    styleEl.textContent = Object.entries(colors)
        .map(([id, c]) => `img[src*="/avatars/${id}/"]{outline:2px solid ${c} !important;outline-offset:1px;border-radius:50%}`)
        .join("\n");
}

function setColor(id: string, color: string | null) {
    if (color) colors[id] = color;
    else delete colors[id];
    DataStore.set(STORE_KEY, colors).catch(() => { /* best effort */ });
    rebuild();
}

const UserContextMenuPatch: NavContextMenuPatchCallback = (children, { user }: { user?: UserLike; }) => {
    if (!user) return;
    const current = colors[user.id];

    children.push(
        <Menu.MenuSeparator key="color-coded-separator" />,
        <Menu.MenuItem key="color-coded-root" id="color-coded-root" label="Highlight Color">
            {COLORS.map(([name, hex]) => (
                <Menu.MenuItem
                    key={`color-${hex}`}
                    id={`color-${hex}`}
                    label={current === hex ? `${name} ✓` : name}
                    action={() => setColor(user.id, hex)}
                />
            ))}
            <Menu.MenuSeparator key="color-coded-clear-sep" />
            <Menu.MenuItem
                key="color-clear"
                id="color-clear"
                label="Clear"
                color="danger"
                action={() => setColor(user.id, null)}
            />
        </Menu.MenuItem>
    );
};

export default definePlugin({
    name: "ColorCodedUsers",
    description: "Tint specific people's avatars with a color so they pop in chat and the member list. (Tints custom avatars; recoloring names would need code patches.)",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Appearance"],
    searchTerms: ["color", "highlight", "tint", "avatar", "user"],

    contextMenus: { "user-context": UserContextMenuPatch },

    async start() {
        styleEl = document.createElement("style");
        styleEl.id = "vc-color-coded-users";
        document.head.appendChild(styleEl);
        colors = (await DataStore.get(STORE_KEY)) ?? {};
        rebuild();
    },

    stop() {
        styleEl?.remove();
        styleEl = null;
    }
});
