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
}

local StyleGuide = {}
StyleGuide.Name = "Geode Depths"
StyleGuide.Color = Color

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
	PanelW = 480, CloseBtn = 40, CloseBtnTouch = 46,
	RowH = 64,
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
}
StyleGuide.IconFallback = {
	gem = "💎", geodeClosed = "🥚", geodeOpen = "💠", paw = "🐾",
	rebirth = "🌌", shop = "🛒", pickaxe = "⛏️", gift = "🎁",
	gear = "⚙️", quest = "📋", logo = "✨", panelBg = "",
	trophy = "🏅", index = "📖",
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
	new("UITextSizeConstraint", { MaxTextSize = 22 }, b)
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
