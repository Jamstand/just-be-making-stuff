--!strict
-- SettingsConfig: every player setting. Saved in the profile (only the ones changed from the
-- default), sent down in the State, applied on the client (ClientSettings.luau). The server's
-- SaveSettings handler accepts only the keys, kinds and choices listed here.
export type Setting = {
	key: string,
	kind: string, -- "toggle" | "slider" (0..1) | "choice"
	default: any,
	display: string,
	desc: string,
	section: string,
	choices: { string }?,
}

local SettingsConfig = {
	Sections = { "Sound", "Display", "Performance" },
	Order = { "musicVolume", "sfxVolume", "uiScale", "reduceMotion", "notifications", "announcements", "sockLabels", "lowGraphics", "hideOthersFX" },
	Settings = {} :: { [string]: Setting },
	UIScales = { Small = 0.85, Normal = 1, Large = 1.15 },
}

SettingsConfig.Settings = {
	musicVolume   = { key = "musicVolume",   kind = "slider", default = 0.5,      section = "Sound",       display = "Music",               desc = "Background music volume." },
	sfxVolume     = { key = "sfxVolume",     kind = "slider", default = 0.8,      section = "Sound",       display = "Sound effects",       desc = "Clicks, pops, coins and whooshes." },
	uiScale       = { key = "uiScale",       kind = "choice", default = "Normal", section = "Display",     display = "UI size",             desc = "Make the menus smaller or bigger.", choices = { "Small", "Normal", "Large" } },
	reduceMotion  = { key = "reduceMotion",  kind = "toggle", default = false,    section = "Display",     display = "Reduce motion",       desc = "Calmer UI: fewer bounces, wiggles and confetti." },
	notifications = { key = "notifications", kind = "toggle", default = true,     section = "Display",     display = "Pop-up messages",     desc = "Little messages like 'Bought...' and '+$500 collected'." },
	announcements = { key = "announcements", kind = "toggle", default = true,     section = "Display",     display = "Server announcements", desc = "Banners when someone steals or finds a rare sock." },
	sockLabels    = { key = "sockLabels",    kind = "choice", default = "All",    section = "Display",     display = "Sock name tags",      desc = "Names over socks: everyone's, only yours, or none.", choices = { "All", "Mine", "Off" } },
	lowGraphics   = { key = "lowGraphics",   kind = "toggle", default = false,    section = "Performance", display = "Low graphics",        desc = "Fewer lights, particles and shadows for smoother play." },
	hideOthersFX  = { key = "hideOthersFX",  kind = "toggle", default = false,    section = "Performance", display = "Hide others' effects", desc = "No bursts or outlines from other players' socks." },
}

return SettingsConfig
