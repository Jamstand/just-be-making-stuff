/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ApplicationCommandInputType, ApplicationCommandOptionType, findOption, sendBotMessage } from "@api/Commands";
import * as DataStore from "@api/DataStore";
import { sendMessage } from "@utils/discord";
import definePlugin from "@utils/types";

interface Job {
    id: string;
    channelId: string;
    content: string;
    fireAt: number;
}

const STORE_KEY = "ScheduledMessages_jobs";
// setTimeout delays are clamped to a signed 32-bit int; anything larger fires
// immediately, so we re-arm in chunks for schedules further out than ~24 days.
const MAX_DELAY = 2_147_483_647;
let jobs: Job[] = [];
const timers = new Map<string, ReturnType<typeof setTimeout>>();

function persist() {
    DataStore.set(STORE_KEY, jobs).catch(() => { /* best effort */ });
}

function fire(job: Job) {
    timers.delete(job.id);
    jobs = jobs.filter(j => j.id !== job.id);
    persist();
    // sendMessage is async and fills the message defaults; swallow send errors
    sendMessage(job.channelId, { content: job.content }).catch(() => { /* channel gone */ });
}

function arm(job: Job) {
    const delay = Math.max(0, job.fireAt - Date.now());
    // Chunk long delays so they don't overflow setTimeout and fire early
    if (delay > MAX_DELAY) {
        timers.set(job.id, setTimeout(() => arm(job), MAX_DELAY));
    } else {
        timers.set(job.id, setTimeout(() => fire(job), delay));
    }
}

function schedule(channelId: string, content: string, minutes: number) {
    const job: Job = { id: `${Date.now()}-${Math.random().toString(36).slice(2)}`, channelId, content, fireAt: Date.now() + minutes * 60_000 };
    jobs.push(job);
    persist();
    arm(job);
}

export default definePlugin({
    name: "ScheduledMessages",
    description: "Queue a message to send later with /schedule. Great for stream announcements. /scheduled lists pending ones.",
    authors: [{ name: "joshiott", id: 0n }],
    tags: ["Chat"],
    searchTerms: ["schedule", "delay", "later", "announcement", "timer"],

    commands: [
        {
            name: "schedule",
            description: "Send a message in this channel after a delay",
            inputType: ApplicationCommandInputType.BUILT_IN,
            options: [
                { name: "minutes", description: "Minutes from now to send it", type: ApplicationCommandOptionType.INTEGER, required: true },
                { name: "message", description: "The message to send", type: ApplicationCommandOptionType.STRING, required: true }
            ],
            execute: (args, ctx) => {
                const minutes = findOption<number>(args, "minutes", 0);
                const content = findOption<string>(args, "message", "");
                if (minutes <= 0 || !content) {
                    sendBotMessage(ctx.channel.id, { content: "Give me a positive number of minutes and a message." });
                    return;
                }
                schedule(ctx.channel.id, content, minutes);
                sendBotMessage(ctx.channel.id, { content: `⏰ Scheduled to send in ${minutes} minute(s).` });
            }
        },
        {
            name: "scheduled",
            description: "List your pending scheduled messages",
            inputType: ApplicationCommandInputType.BUILT_IN,
            execute: (_, ctx) => {
                const mine = jobs.filter(j => j.channelId === ctx.channel.id);
                const content = mine.length
                    ? mine.map(j => `• in ${Math.max(0, Math.round((j.fireAt - Date.now()) / 60_000))}m: ${j.content}`).join("\n")
                    : "Nothing scheduled in this channel.";
                sendBotMessage(ctx.channel.id, { content });
            }
        }
    ],

    async start() {
        jobs = (await DataStore.get(STORE_KEY)) ?? [];
        jobs.forEach(arm);
    },

    stop() {
        timers.forEach(t => clearTimeout(t));
        timers.clear();
    }
});
