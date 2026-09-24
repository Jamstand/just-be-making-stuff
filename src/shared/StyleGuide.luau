--!strict
-- ===================================================================
--  GEODE DEPTHS — shared style guide for "Crack a Geode!"
--  The single source of truth for the game's look. World systems and
--  every UI screen require this so the style stays consistent.
--
--  ART DIRECTION: STYLIZED REALISM (mobile-first)
--    Shape language : chunky faceted crystals and rounded rock forms in
--                     the world; heavily-rounded panels & pill buttons in UI.
--    Palette        : deep slate/indigo rock, TWO saturated crystal
--                     accents (amethyst + teal) and warm gold highlights.
--                     Saturated and slightly cartoon — never photo-real,
--                     never flat neon.
--    Materials      : PBR-first. Rock/floor/props use MaterialVariants
--                     (World.Variants); crystals are Glass — glossy,
--                     low-roughness, slightly translucent, real specular
--                     so they GLINT as the camera moves. Neon is reserved
--                     for TRUE emissives only (cores, seams, transient FX)
--                     so bloom stays rare and meaningful.
--    Lighting mood  : Future lighting, soft shadows. Dark cave BETWEEN
--                     pools of light: warm gold pools at stations, cool
--                     amethyst/teal spill from crystal clusters. Light
--                     haze for depth (low density: mobile), subtle bloom
--                     (high threshold), gentle warm grade, DepthOfField
--                     on distant geometry only.
--    UI feel        : big readable GothamBlack labels, chunky buttons
--                     that scale-punch on press, panels that pop open
--                     with a Back ease and fade-scale closed. Mobile
--                     buttons are >=60px tall (thumb-friendly).
--
--  SEMANTIC EXTENSION (Social Cavern pass) — additive names, all optional:
--    Color.Warn / Info / GoldSoft        : toast + Announce accents (warn/info/soft gold)
--    Color.OwnedFill / TodayFill         : "owned" row fill, Daily ladder "today" fill
--    Color.GreenDim / Scrim              : past-day ladder green, panel scrim (= Bg0)
--    Size.CloseBtnTouch = 48 (was 46), RowHDesk 56, ToastH 44 / ToastHTouch 48,
--    Size.Badge 18, Size.Chip 26
--    SG.KindColor[kind]                  : Announce/Feed kind -> Color3 (see table)
--    SG.kindColor(kind, colorRGB?)       : colorRGB {r,g,b} wins, else KindColor, else Text
--    SG.Type[role] / SG.text(role, props, parent)
--                                        : type roles Display/Heading/Body/Caption/Number with
--                                          font + min/max px (min +1 on touch) -> TextLabel.
--                                          DEFAULT = one fixed line at the role's max px with
--                                          TextTruncate AtEnd (ellipsis, never wrap/overflow);
--                                          props.fit = true = TextScaled + UITextSizeConstraint
--                                          (min..max) for boxes the text must fill / shrink to
--    SG.button(...)                      : label TextScaled between 12 (13 touch) and 22 px
--    SG.IsTouch                          : true on a touch-only client (drives the +1 min rule)
--    SG.row(props, parent)               : Bg2 @0.1 rounded row frame, height Size.RowH
--    SG.setRole(btn, role)               : retint an existing button to a Button role
--    SG.setEnabled(btn, on)              : Active + dimmed look (transparency 0.5, TextDim,
--                                          stroke/gloss hidden) — restores on re-enable
--    SG.badge(parent, text)              : 18 px Red count pill, top-right, hidden when ""
--    SG.chip(text, color, props, parent) : small pill label (status/count chips)
--    SG.Tier(rebirths, ascensions)       : tier colour (asc>0 Gold; <5 Violet, <15 Cyan, else Gold)
--    SG.TierHex(rebirths, ascensions)    : "#RRGGBB" of the same, for chat tags
--    Icons.players / board / sprout = 0  : emoji fallbacks 👥 🏆 🌱 (no uploads yet)
--  Every helper works with both branches of SG.icon (Image* and the emoji Text*
--  fallback): text properties are only touched on Text* classes.
-- ===================================================================

local TweenService = game:GetService("TweenService")

local C = Color3.fromRGB

local Color = {
	Bg0   = C(15, 14, 24),   -- deepest background (slate ink)
	Bg1   = C(24, 22, 38),   -- panel body
	Bg2   = C(36, 33, 56),   -- raised row / card
	Track = C(12, 11, 20),   -- progress track / inset
	Violet       = C(146, 92, 255),  -- primary (amethyst — matches World.Crystals[1])
	VioletBright = C(172, 126, 255),
	Cyan    = C(74, 210, 222),   -- secondary accent (teal — matches World.Crystals[2])
	Magenta = C(222, 110, 196),  -- muted orchid; rarity accent only, no longer neon
	Gold    = C(255, 196, 96),   -- warm highlight (matches World.Gold)
	Green   = C(96, 210, 148),   -- success / buy
	Red     = C(255, 107, 122),  -- danger
	Text    = C(242, 240, 250),
	TextDim = C(164, 160, 190),
	TextInk = C(18, 16, 28),     -- dark text on bright fills
	Outline = C(128, 100, 200),
	-- semantic accents (toasts / Announce kinds / panel states)
	Warn      = C(255, 180, 120),  -- caution: locked gates, meteor warning
	Info      = C(150, 205, 255),  -- neutral information
	GoldSoft  = C(255, 222, 130),  -- soft gold for secondary highlights
	OwnedFill = C(60, 90, 70),     -- fill for an owned / completed row
	TodayFill = C(58, 108, 78),    -- Daily ladder: today's cell
	GreenDim  = C(60, 160, 90),    -- Daily ladder: past days, muted success
}
Color.Scrim = Color.Bg0            -- panel backdrop (rendered @0.45 transparency)

local StyleGuide = {}
StyleGuide.Name = "Geode Depths"
StyleGuide.Color = Color

-- true on a touch-only client (phones/tablets); false on desktop and on the server.
-- Drives the "+1 px minimum text size on touch" rule in StyleGuide.text.
do
	local isTouch = false
	local RunService = game:GetService("RunService")
	if RunService:IsClient() then
		local ok, UIS = pcall(game.GetService, game, "UserInputService")
		if ok and UIS then
			isTouch = UIS.TouchEnabled and not UIS.MouseEnabled
		end
	end
	StyleGuide.IsTouch = isTouch
end

-- ---- shape ----
StyleGuide.Radius = { sm = 8, md = 14, lg = 20, xl = 26, pill = "pill" }
StyleGuide.StrokeW = { hair = 1, base = 2, bold = 3, chunk = 4 }
StyleGuide.Pad = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 }

-- ---- type ----
StyleGuide.Font = {
	Display = Enum.Font.GothamBlack,   -- big headings / numbers
	Heading = Enum.Font.GothamBold,
	Body    = Enum.Font.GothamMedium,
	Number  = Enum.Font.GothamBlack,
}

-- ---- sizes (mobile-first, thumb-friendly) ----
StyleGuide.Size = {
	BtnH = 52, BtnHTouch = 60, MinTouch = 48,
	PanelW = 480, CloseBtn = 40, CloseBtnTouch = 48,
	RowH = 64, RowHDesk = 56,
	ToastH = 44, ToastHTouch = 48,
	Badge = 18, Chip = 26,
}

-- ---- type roles (font + px range; StyleGuide.text adds +1 to min on touch) ----
StyleGuide.Type = {
	Display = { font = StyleGuide.Font.Display, min = 16, max = 28 },
	Heading = { font = StyleGuide.Font.Heading, min = 13, max = 18 },
	Body    = { font = StyleGuide.Font.Body,    min = 12, max = 14 },
	Caption = { font = StyleGuide.Font.Body,    min = 11, max = 12 },
	Number  = { font = StyleGuide.Font.Number,  min = 14, max = 26 },
}

-- ---- motion ----
StyleGuide.Motion = {
	open  = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	close = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	press = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	pop   = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	pulse = TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
}

-- ---- button roles (fill / stroke / text) ----
StyleGuide.Button = {
	primary = { fill = Color.Violet, stroke = Color.Cyan,          text = Color.Text },
	buy     = { fill = Color.Green,  stroke = C(160, 255, 205),    text = Color.TextInk },
	premium = { fill = Color.Gold,   stroke = C(255, 226, 150),    text = Color.TextInk },
	danger  = { fill = Color.Red,    stroke = C(255, 175, 185),    text = Color.Text },
	ghost   = { fill = Color.Bg2,    stroke = Color.Violet,        text = Color.Text },
}

-- ---- Announce / Feed kind -> accent colour ----
-- Broadcast + personal kinds share one table so toasts, banners and feed rows agree.
StyleGuide.KindColor = {
	warn = Color.Warn, meteor = Color.Warn, golden = Color.Gold, goal = Color.Green,
	rare = Color.Text, rebirth = Color.Violet, ascend = Color.Gold, pet = Color.Cyan,
	pass = Color.Gold, zone = Color.Cyan, zoneFirst = Color.Cyan, join = Color.TextDim, leave = Color.TextDim,
	cheer = Color.Magenta, gift = Color.Green, giftReceived = Color.Green,
	mvp = Color.Gold, ach = Color.Gold, vip = Color.Gold, onboard = Color.Green, daily = Color.Gold,
	quest = Color.Info, region = Color.Cyan, locked = Color.Warn, meteorPayout = Color.Gold,
	garden = Color.Green, shard = Color.Cyan, unlock = Color.Cyan, welcome = Color.Green,
	info = Color.Info, error = Color.Red, ok = Color.Green,
}

-- ---- world (stylized realism) ----
StyleGuide.World = {
	-- rock family: deep slate/indigo, PBR via MaterialVariants below
	RockColor     = C(58, 54, 78),   -- cave rock base
	RockColorDark = C(38, 35, 54),   -- crevices / rubble / shadow forms
	FloorColor    = C(44, 40, 62),
	RockMaterial  = Enum.Material.Slate,

	-- crystals: Glass with real specular, NOT emissive. Restrained palette:
	-- exactly two saturated accents + warm gold for highlights/rewards.
	CrystalMaterial = Enum.Material.Glass,
	CoreMaterial    = Enum.Material.Neon,   -- true emissives ONLY (cores/seams/FX)
	Crystals = { C(158, 96, 255), C(64, 214, 224) },  -- amethyst, teal
	CrystalGlass = { Reflectance = 0.08, Transparency = 0.16 }, -- glint params
	Gold = C(255, 196, 96),      -- warm gold highlight
	Vein = C(108, 156, 196),     -- dimmed mineral vein (was neon cyan)

	Station = {
		leaderboards = C(255, 196, 96), upgrades = C(255, 158, 74), ascend = C(168, 110, 255),
		gardens = C(112, 204, 130), crater = C(255, 206, 120),
	},

	-- MaterialVariant names (authored in Studio; a part opts in by setting
	-- Material = <base> and MaterialVariant = <name>)
	Variants = {
		Rock  = { base = Enum.Material.Slate, name = "GeodeRockPBR" },
		Floor = { base = Enum.Material.Rock,  name = "GeodeFloorPBR" },
	},

	-- lights: warm gold pools at stations, cool crystal spill, dark in between
	StationLight = { Color = C(255, 190, 120), Range = 22, Brightness = 1.2 },
	CrystalLight = { Range = 14, Brightness = 0.8 },

	Lighting = {
		Ambient = C(38, 36, 54), OutdoorAmbient = C(32, 30, 48),
		Brightness = 1.7, Exposure = 0.0,
		EnvDiffuse = 0.32, EnvSpecular = 1.0,   -- gems pick up bounce light
		ClockTime = 14.4,
		Atmosphere = C(96, 92, 128), Density = 0.24, Haze = 1.1, Glare = 0.0, Decay = C(56, 52, 80),
		Bloom = 0.35, BloomThreshold = 2.4, BloomSize = 24,  -- only true emissives bloom
		Tint = C(255, 248, 240), CCBrightness = 0.02, Contrast = 0.1, Saturation = 0.06,
		DoFFar = 0.25, DoFFocus = 45, DoFRadius = 40,        -- distant geometry only
	},
}

-- ---- ICON ASSETS ----
-- Paste each uploaded decal/image id here (number only). 0 = unset — and
-- StyleGuide.icon() then falls back to the emoji so the UI never shows a blank box.
StyleGuide.Icons = {
	logo = 130116409991982, gem = 118034174480000, geodeClosed = 73913767236341,
	geodeOpen = 100628389884789, paw = 72740320362411, rebirth = 133377818198048,
	shop = 87230954989187, pickaxe = 140427653141147, gift = 107813403344843,
	gear = 127172470376236, quest = 73915319787637, panelBg = 105278033775912,
	trophy = 123461681611640, index = 96147210191570,
	-- social pass: no uploads yet, emoji fallbacks render (see IconFallback)
	players = 0, board = 0, sprout = 0,
}
StyleGuide.IconFallback = {
	gem = "💎", geodeClosed = "🥚", geodeOpen = "💠", paw = "🐾",
	rebirth = "🌌", shop = "🛒", pickaxe = "⛏️", gift = "🎁",
	gear = "⚙️", quest = "📋", logo = "✨", panelBg = "",
	trophy = "🏅", index = "📖",
	players = "👥", board = "🏆", sprout = "🌱",
}

-- ===================================================================
--  HELPERS — UI factories so every screen is built the same way
-- ===================================================================

local function merge(base, extra)
	local out = {}
	for k, v in pairs(base) do out[k] = v end
	if extra then for k, v in pairs(extra) do out[k] = v end end
	return out
end

local function lighten(c, amt) return c:Lerp(Color3.new(1, 1, 1), amt) end
StyleGuide.lighten = lighten

local function darken(c, amt) return c:Lerp(Color3.new(0, 0, 0), amt) end
StyleGuide.darken = darken

local function new(class, props, parent)
	local i = Instance.new(class)
	for k, v in pairs(props or {}) do i[k] = v end
	if parent then i.Parent = parent end
	return i
end
StyleGuide.new = new

function StyleGuide.corner(el, key)
	local r
	if key == "pill" then r = UDim.new(1, 0)
	else r = UDim.new(0, StyleGuide.Radius[key] or (type(key) == "number" and key) or StyleGuide.Radius.lg) end
	return new("UICorner", { CornerRadius = r }, el)
end

function StyleGuide.stroke(el, colorKey, weightKey, transparency)
	return new("UIStroke", {
		Color = (typeof(colorKey) == "Color3" and colorKey) or Color[colorKey] or Color.Outline,
		Thickness = StyleGuide.StrokeW[weightKey] or (type(weightKey) == "number" and weightKey) or StyleGuide.StrokeW.base,
		Transparency = transparency or 0.15,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, el)
end

function StyleGuide.gradient(el, cTop, cBottom, rotation)
	return new("UIGradient", { Color = ColorSequence.new(cTop, cBottom), Rotation = rotation or 90 }, el)
end

-- neutral top-light → bottom-dark shading. Unlike a colored gradient this doesn't
-- hue-shift the button's own text (UIGradient tints text too), just adds depth.
function StyleGuide.shade(el)
	return new("UIGradient", {
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(172, 172, 188)),
		Rotation = 90,
	}, el)
end

-- a styled panel body (glass, rounded, neon border, subtle vertical gradient)
function StyleGuide.panel(props, parent)
	local f = new("Frame", merge({
		BackgroundColor3 = Color.Bg1, BackgroundTransparency = 0.04, BorderSizePixel = 0,
	}, props), parent)
	StyleGuide.corner(f, "xl")
	StyleGuide.stroke(f, Color.Violet, "base", 0.2)
	StyleGuide.gradient(f, Color.Bg2, Color.Bg1, 90)
	return f
end

-- press punch (scale down on press, Back-ease back) using a UIScale so layout is untouched
function StyleGuide.pressFX(btn)
	local s = btn:FindFirstChildOfClass("UIScale") or new("UIScale", {}, btn)
	btn.MouseButton1Down:Connect(function()
		TweenService:Create(s, StyleGuide.Motion.press, { Scale = 0.93 }):Play()
	end)
	local function up() TweenService:Create(s, StyleGuide.Motion.pop, { Scale = 1 }):Play() end
	btn.MouseButton1Up:Connect(up)
	btn.MouseLeave:Connect(up)
	return btn
end

-- glossy top highlight strip for chunky candy buttons
function StyleGuide.gloss(el, radiusKey, topTransparency, heightScale)
	local g = new("Frame", {
		Name = "Gloss", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
		Position = UDim2.new(0, 3, 0, 2), Size = UDim2.new(1, -6, heightScale or 0.42, 0),
		ZIndex = el.ZIndex + 1,
	}, el)
	StyleGuide.corner(g, radiusKey or "sm")
	new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, topTransparency or 0.62),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, g)
	return g
end

-- pulsing gold glow ring for a button with something claimable. setGlow(btn, on)
function StyleGuide.setGlow(btn, on)
	local s = btn:FindFirstChild("GlowStroke")
	if on then
		if not s then
			s = new("UIStroke", {
				Name = "GlowStroke", Color = Color.Gold, Thickness = 3, Transparency = 0.1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}, btn)
			TweenService:Create(s, StyleGuide.Motion.pulse, { Thickness = 6, Transparency = 0.5 }):Play()
		end
		s.Enabled = true
	elseif s then
		s.Enabled = false
	end
end

-- a chunky button. role = primary|buy|premium|danger|ghost
function StyleGuide.button(text, role, props, parent)
	local r = StyleGuide.Button[role] or StyleGuide.Button.primary
	local b = new("TextButton", merge({
		BackgroundColor3 = lighten(r.fill, 0.12), AutoButtonColor = false, BorderSizePixel = 0,
		Text = text, TextColor3 = r.text, Font = StyleGuide.Font.Display, TextScaled = true,
		TextStrokeTransparency = 0.35,
	}, props), parent)
	StyleGuide.corner(b, "md")
	StyleGuide.stroke(b, r.stroke, "bold", 0.05)
	StyleGuide.shade(b)
	StyleGuide.gloss(b, "sm", 0.8, 0.3)
	-- floor the label so a narrow button (3-up modal row, toast action pill) never scales
	-- its text below the 12 px (13 on touch) readability floor
	new("UITextSizeConstraint", { MinTextSize = StyleGuide.IsTouch and 13 or 12, MaxTextSize = 22 }, b)
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, b)
	StyleGuide.pressFX(b)
	return b
end

-- a text label with house defaults
function StyleGuide.label(props, parent)
	return new("TextLabel", merge({
		BackgroundTransparency = 1, TextColor3 = Color.Text, Font = StyleGuide.Font.Heading,
		TextScaled = true, TextStrokeTransparency = 0.7,
	}, props), parent)
end

-- An icon element. If StyleGuide.Icons[key] is set (>0) you get an ImageLabel/
-- ImageButton that PRESERVES ASPECT RATIO (ScaleType.Fit); otherwise a Text*
-- element with the emoji fallback so the layout never breaks. asButton -> clickable.
function StyleGuide.icon(key, props, parent, asButton)
	props = props or {}
	local id = StyleGuide.Icons[key]
	if id and id ~= 0 then
		local base = {
			Image = "rbxassetid://" .. tostring(id),
			ScaleType = Enum.ScaleType.Fit, -- keep aspect ratio
			BackgroundTransparency = 1, BorderSizePixel = 0,
		}
		if asButton then base.AutoButtonColor = false end
		return new(asButton and "ImageButton" or "ImageLabel", merge(base, props), parent)
	end
	local base = {
		Text = StyleGuide.IconFallback[key] or "",
		TextScaled = true, BackgroundTransparency = 1, BorderSizePixel = 0,
		Font = StyleGuide.Font.Display, TextColor3 = Color.Text,
	}
	if asButton then base.AutoButtonColor = false end
	return new(asButton and "TextButton" or "TextLabel", merge(base, props), parent)
end

-- ===================================================================
--  SEMANTIC HELPERS (Social Cavern pass)
-- ===================================================================

-- Text* classes carry Text/TextColor3; Image* classes (the icon path with an
-- uploaded id) do not. Every helper below checks before touching text props.
local function isTextClass(el)
	return el:IsA("TextLabel") or el:IsA("TextButton") or el:IsA("TextBox")
end

local function isImageClass(el)
	return el:IsA("ImageLabel") or el:IsA("ImageButton")
end

-- Announce/Feed colour precedence: explicit colorRGB ({r,g,b} keyed or array, or a
-- Color3) > KindColor[kind] > Color.Text. Bad / partial tables fall through.
function StyleGuide.kindColor(kind, colorRGB)
	if typeof(colorRGB) == "Color3" then return colorRGB end
	if type(colorRGB) == "table" then
		local r = tonumber(colorRGB.r or colorRGB[1])
		local g = tonumber(colorRGB.g or colorRGB[2])
		local b = tonumber(colorRGB.b or colorRGB[3])
		if r and g and b and r == r and g == g and b == b then
			return C(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255))
		end
	end
	return (kind ~= nil and StyleGuide.KindColor[kind]) or Color.Text
end

-- A TextLabel in a type role (font + px range from StyleGuide.Type, min/max +1 on touch,
-- 0.7 stroke). Two modes:
--   default      ONE fixed line at the role's max px, TextTruncate AtEnd, no wrapping: a
--                string that cannot fit ends in an ellipsis. (Roblox ignores TextTruncate
--                while TextScaled is on — a scaled label wraps at MinTextSize and the extra
--                lines draw past a 16-18 px row onto its neighbours.) Pass TextWrapped = true
--                for a multi-line paragraph box; the ellipsis then lands on the last line.
--   fit = true   TextScaled + UITextSizeConstraint(min, max): for a box the text must fill
--                or shrink into (HUD numbers, emoji icon cells, rarity cells, banners, the
--                meteor bar) — the caller keeps the string short enough not to wrap.
-- props override any default (Size, TextXAlignment, TextColor3, TextWrapped, ...).
function StyleGuide.text(role, props, parent)
	local t = StyleGuide.Type[role] or StyleGuide.Type.Body
	local bump = StyleGuide.IsTouch and 1 or 0
	local fit = false
	if type(props) == "table" and props.fit ~= nil then
		fit = props.fit == true
		local copy = {}
		for k, v in pairs(props) do
			if k ~= "fit" then copy[k] = v end
		end
		props = copy
	end
	local base = {
		BackgroundTransparency = 1, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, t.max + bump),
		TextColor3 = Color.Text, Font = t.font,
		TextStrokeTransparency = 0.7, TextTruncate = Enum.TextTruncate.AtEnd,
	}
	if fit then
		base.TextScaled = true
	else
		base.TextScaled = false
		base.TextSize = t.max + bump
		base.TextWrapped = false
	end
	local l = new("TextLabel", merge(base, props), parent)
	if fit then
		new("UITextSizeConstraint", { MinTextSize = t.min + bump, MaxTextSize = t.max + bump }, l)
	end
	return l
end

-- A raised list row (Bg2 @0.1, md corners). Default height Size.RowH; pass
-- Size = UDim2.new(1, 0, 0, SG.Size.RowHDesk) for the desktop height.
function StyleGuide.row(props, parent)
	local f = new("Frame", merge({
		BackgroundColor3 = Color.Bg2, BackgroundTransparency = 0.1, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, StyleGuide.Size.RowH),
	}, props), parent)
	StyleGuide.corner(f, "md")
	return f
end

-- Retint an existing button (built by SG.button, SG.icon or by hand) to a role:
-- fill, non-glow strokes and text colour follow SG.Button[role]; the gloss strip
-- and shade gradient are re-shown if present. Safe on Image* buttons (no text).
-- While the button is disabled (SG.setEnabled false) the text colour is stored and
-- applied on re-enable, so setRole + setEnabled can be called in either order.
function StyleGuide.setRole(btn, role)
	local r = StyleGuide.Button[role] or StyleGuide.Button.primary
	btn:SetAttribute("Role", StyleGuide.Button[role] and role or "primary")
	btn.BackgroundColor3 = lighten(r.fill, 0.12)
	local disabled = btn:GetAttribute("SGDisabled") == true
	if isTextClass(btn) then
		if disabled then btn:SetAttribute("SGTextC", r.text) else btn.TextColor3 = r.text end
	end
	for _, c in ipairs(btn:GetChildren()) do
		if c:IsA("UIStroke") and c.Name ~= "GlowStroke" then
			c.Color = r.stroke
			if not disabled then c.Enabled = true end
		elseif c.Name == "Gloss" and c:IsA("GuiObject") then
			if not disabled then c.Visible = true end
		elseif c:IsA("UIGradient") then
			c.Enabled = true
		end
	end
end

-- Enable/disable look + hit-testing. Off: Active=false, BackgroundTransparency 0.5,
-- TextDim text (Text* only) / half-faded image (Image* only), strokes + gloss hidden.
-- On: restores the exact previous transparency, text/image state and strokes.
-- Idempotent — repeated calls with the same value are no-ops.
function StyleGuide.setEnabled(btn, on)
	on = on and true or false
	local wasDisabled = btn:GetAttribute("SGDisabled") == true
	btn.Active = on
	if btn:IsA("GuiButton") then btn.Selectable = on end
	if on then
		if not wasDisabled then return end
		btn:SetAttribute("SGDisabled", nil)
		btn.BackgroundTransparency = btn:GetAttribute("SGBgT") or 0
		btn:SetAttribute("SGBgT", nil)
		if isTextClass(btn) then
			btn.TextColor3 = btn:GetAttribute("SGTextC") or Color.Text
			btn:SetAttribute("SGTextC", nil)
		end
		if isImageClass(btn) then
			btn.ImageTransparency = btn:GetAttribute("SGImgT") or 0
			btn:SetAttribute("SGImgT", nil)
		end
		for _, c in ipairs(btn:GetChildren()) do
			if c:IsA("UIStroke") and c.Name ~= "GlowStroke" then c.Enabled = true
			elseif c.Name == "Gloss" and c:IsA("GuiObject") then c.Visible = true end
		end
	else
		if wasDisabled then return end
		btn:SetAttribute("SGDisabled", true)
		btn:SetAttribute("SGBgT", btn.BackgroundTransparency)
		btn.BackgroundTransparency = 0.5
		if isTextClass(btn) then
			btn:SetAttribute("SGTextC", btn.TextColor3)
			btn.TextColor3 = Color.TextDim
		end
		if isImageClass(btn) then
			btn:SetAttribute("SGImgT", btn.ImageTransparency)
			btn.ImageTransparency = 0.5
		end
		for _, c in ipairs(btn:GetChildren()) do
			if c:IsA("UIStroke") and c.Name ~= "GlowStroke" then c.Enabled = false
			elseif c.Name == "Gloss" and c:IsA("GuiObject") then c.Visible = false end
		end
	end
end

-- Count pill pinned to a parent's top-right corner (rail buttons, tabs). One per
-- parent (Name "Badge"); calling again updates it. Hidden when text == "".
-- Fixed 11 px GothamBlack (not TextScaled) so "9+" stays legible; grows sideways.
function StyleGuide.badge(parent, text)
	local s = text == nil and "" or tostring(text)
	local b = parent:FindFirstChild("Badge")
	if not (b and b:IsA("TextLabel")) then
		local sz = StyleGuide.Size.Badge
		local z = (parent:IsA("GuiObject") and parent.ZIndex or 1) + 2
		b = new("TextLabel", {
			Name = "Badge", BackgroundColor3 = Color.Red, BorderSizePixel = 0,
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 4, 0, -4),
			Size = UDim2.new(0, sz, 0, sz), AutomaticSize = Enum.AutomaticSize.X,
			Text = "", TextColor3 = Color.Text, Font = StyleGuide.Font.Number, TextSize = 11,
			TextStrokeTransparency = 1, ZIndex = z,
		}, parent)
		StyleGuide.corner(b, "pill")
		new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, b)
		new("UISizeConstraint", { MinSize = Vector2.new(sz, sz) }, b)
	end
	b.Text = s
	b.Visible = s ~= ""
	return b
end

-- Small pill label for status / counts ("✅ OWNED", "Normal 0 · Golden 3").
-- color = Color3 or a Color key; tints the text and hairline stroke on a Bg2 pill.
-- Auto-sizes horizontally to its text; height Size.Chip; 13 px text (>= touch floor).
function StyleGuide.chip(text, color, props, parent)
	local c = (typeof(color) == "Color3" and color) or (type(color) == "string" and Color[color]) or Color.Cyan
	local l = new("TextLabel", merge({
		Name = "Chip", BackgroundColor3 = Color.Bg2, BackgroundTransparency = 0.1, BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 0, StyleGuide.Size.Chip), AutomaticSize = Enum.AutomaticSize.X,
		Text = text or "", TextColor3 = c, Font = StyleGuide.Font.Heading, TextSize = 13,
		TextStrokeTransparency = 0.8,
	}, props), parent)
	StyleGuide.corner(l, "pill")
	StyleGuide.stroke(l, c, "hair", 0.4)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, l)
	return l
end

-- Progression tier colour shared by nameplates, Players rows and chat tags.
-- Any ascension -> Gold; otherwise rebirths < 5 Violet, < 15 Cyan, else Gold.
function StyleGuide.Tier(rebirths, ascensions)
	local a = tonumber(ascensions) or 0
	if a == a and a > 0 then return Color.Gold end
	local r = tonumber(rebirths) or 0
	if r ~= r or r < 5 then return Color.Violet end
	if r < 15 then return Color.Cyan end
	return Color.Gold
end

-- "#RRGGBB" for rich-text chat tags (TextChatService wants a hex colour).
function StyleGuide.TierHex(rebirths, ascensions)
	return "#" .. string.upper(StyleGuide.Tier(rebirths, ascensions):ToHex())
end

-- pop-open / fade-close for a panel (adds a UIScale it animates). The panel's
-- FitScale attribute (set by responsive layout) is the "resting" scale, so the
-- pop animation lands on the size the current screen needs, not always 1.
function StyleGuide.open(panel)
	local s = panel:FindFirstChildOfClass("UIScale") or new("UIScale", {}, panel)
	local fit = panel:GetAttribute("FitScale") or 1
	s.Scale = 0.82 * fit
	panel.Visible = true
	TweenService:Create(s, StyleGuide.Motion.open, { Scale = fit }):Play()
end

function StyleGuide.close(panel, after)
	local s = panel:FindFirstChildOfClass("UIScale") or new("UIScale", {}, panel)
	local fit = panel:GetAttribute("FitScale") or 1
	local t = TweenService:Create(s, StyleGuide.Motion.close, { Scale = 0.82 * fit })
	t.Completed:Once(function()
		panel.Visible = false
		s.Scale = fit
		if after then after() end
	end)
	t:Play()
end

-- push the world lighting mood to the guide's values (server or client).
-- Keeps the instance names GeodeAtmosphere/GeodeBloom/GeodeColor — Meteor,
-- Buffs and client RegionFX find them by those names.
function StyleGuide.applyLighting(Lighting)
	local L = StyleGuide.World.Lighting
	-- Future lighting: settable only in Studio/plugin contexts; harmless no-op live
	pcall(function() Lighting.Technology = Enum.Technology.Future end)
	Lighting.Ambient = L.Ambient
	Lighting.OutdoorAmbient = L.OutdoorAmbient
	Lighting.Brightness = L.Brightness
	Lighting.ExposureCompensation = L.Exposure
	Lighting.EnvironmentDiffuseScale = L.EnvDiffuse
	Lighting.EnvironmentSpecularScale = L.EnvSpecular
	Lighting.GlobalShadows = true
	Lighting.ClockTime = L.ClockTime
	-- neon-era leftover: sun-ray shafts have no place in stylized realism
	local sun = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if sun then sun:Destroy() end
	local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmo then atmo = Instance.new("Atmosphere"); atmo.Name = "GeodeAtmosphere"; atmo.Parent = Lighting end
	atmo.Color = L.Atmosphere; atmo.Density = L.Density; atmo.Haze = L.Haze; atmo.Glare = L.Glare
	atmo.Decay = L.Decay
	local bloom = Lighting:FindFirstChild("GeodeBloom") or Lighting:FindFirstChildOfClass("BloomEffect")
	if not bloom then bloom = Instance.new("BloomEffect"); bloom.Name = "GeodeBloom"; bloom.Parent = Lighting end
	bloom.Intensity = L.Bloom; bloom.Threshold = L.BloomThreshold; bloom.Size = L.BloomSize
	local cc = Lighting:FindFirstChild("GeodeColor") or Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if not cc then cc = Instance.new("ColorCorrectionEffect"); cc.Name = "GeodeColor"; cc.Parent = Lighting end
	cc.TintColor = L.Tint; cc.Brightness = L.CCBrightness; cc.Contrast = L.Contrast; cc.Saturation = L.Saturation
	-- gentle DoF on distant geometry only (NearIntensity 0 keeps gameplay crisp)
	local dof = Lighting:FindFirstChild("GeodeDoF") or Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if not dof then dof = Instance.new("DepthOfFieldEffect"); dof.Parent = Lighting end
	dof.Name = "GeodeDoF"
	dof.NearIntensity = 0
	dof.FarIntensity = L.DoFFar
	dof.FocusDistance = L.DoFFocus
	dof.InFocusRadius = L.DoFRadius
end

return StyleGuide
