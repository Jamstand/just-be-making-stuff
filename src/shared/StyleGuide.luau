--!strict
-- ===================================================================
--  NEON GEODE — shared style guide for "Crack a Geode!"
--  The single source of truth for the game's look. World systems and
--  every UI screen require this so the style stays consistent.
--
--  DEFINING TRAITS
--    Shape language : faceted angular crystals in the world; chunky,
--                     heavily-rounded panels & pill/rounded buttons in UI.
--    Palette        : deep indigo base, electric violet primary, with
--                     cyan / magenta / gold neon accents.
--    Materials      : Neon (glow) crystals over Glass cores; dark Slate/
--                     Rock terrain; flat UI (no textures), glow via bloom.
--    Outline        : UI uses a 2px neon border by default (3px on
--                     buttons); world glow comes from Neon + Bloom.
--    Lighting mood  : dark, hazy-but-clear cave; violet ambient; punchy
--                     bloom on neon; gentle warm color grade.
--    UI feel        : big readable GothamBlack labels, chunky buttons
--                     that scale-punch on press, panels that pop open
--                     with a Back ease and fade-scale closed. Mobile
--                     buttons are >=60px tall (thumb-friendly).
-- ===================================================================

local TweenService = game:GetService("TweenService")

local C = Color3.fromRGB

local Color = {
	Bg0   = C(18, 10, 34),   -- deepest background
	Bg1   = C(26, 16, 48),   -- panel body
	Bg2   = C(39, 26, 71),   -- raised row / card
	Track = C(14, 8, 30),    -- progress track / inset
	Violet       = C(123, 77, 255),  -- primary
	VioletBright = C(154, 107, 255),
	Cyan    = C(72, 224, 255),   -- secondary accent
	Magenta = C(255, 90, 230),
	Gold    = C(255, 194, 77),
	Green   = C(70, 227, 154),   -- success / buy
	Red     = C(255, 107, 122),  -- danger
	Text    = C(242, 239, 255),
	TextDim = C(169, 162, 200),
	TextInk = C(16, 10, 30),     -- dark text on bright fills
	Outline = C(150, 110, 255),
}

local StyleGuide = {}
StyleGuide.Name = "Neon Geode"
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

-- ---- world ----
StyleGuide.World = {
	RockColor = C(74, 68, 96),
	CrystalMaterial = Enum.Material.Neon,
	CoreMaterial = Enum.Material.Glass,
	Crystals = { C(123, 77, 255), C(72, 224, 255), C(255, 90, 230), C(150, 220, 255) },
	Vein = Color.Cyan,
	Station = {
		leaderboards = Color.Gold, upgrades = C(255, 165, 70), ascend = Color.Violet,
		gardens = Color.Green, crater = Color.Cyan,
	},
	Lighting = {
		Ambient = C(66, 60, 88), Brightness = 2.6, Exposure = 0.12,
		Atmosphere = C(150, 140, 200), Density = 0.2, Haze = 1.0, Glare = 0.1,
		Bloom = 1.0, BloomThreshold = 1.0, BloomSize = 20,
		Tint = C(240, 234, 255), CCBrightness = 0.05, Contrast = 0.08, Saturation = 0.12,
		ClockTime = 0,
	},
}

-- ---- ICON ASSETS ----
-- Paste each uploaded decal/image id here (number only). 0 = unset — and
-- StyleGuide.icon() then falls back to the emoji so the UI never shows a blank box.
StyleGuide.Icons = {
	logo = 0, gem = 0, geodeClosed = 0, geodeOpen = 0, paw = 0,
	rebirth = 0, shop = 0, pickaxe = 0, gift = 0, gear = 0, quest = 0,
	panelBg = 0,
}
StyleGuide.IconFallback = {
	gem = "💎", geodeClosed = "🥚", geodeOpen = "💠", paw = "🐾",
	rebirth = "🌌", shop = "🛒", pickaxe = "⛏️", gift = "🎁",
	gear = "⚙️", quest = "📋", logo = "✨", panelBg = "",
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

-- a chunky button. role = primary|buy|premium|danger|ghost
function StyleGuide.button(text, role, props, parent)
	local r = StyleGuide.Button[role] or StyleGuide.Button.primary
	local b = new("TextButton", merge({
		BackgroundColor3 = r.fill, AutoButtonColor = false, BorderSizePixel = 0,
		Text = text, TextColor3 = r.text, Font = StyleGuide.Font.Display, TextScaled = true,
		TextStrokeTransparency = 0.6,
	}, props), parent)
	StyleGuide.corner(b, "md")
	StyleGuide.stroke(b, r.stroke, "bold", 0.05)
	StyleGuide.gradient(b, lighten(r.fill, 0.2), r.fill, 90)
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

-- pop-open / fade-close for a panel (adds a UIScale it animates)
function StyleGuide.open(panel)
	local s = panel:FindFirstChildOfClass("UIScale") or new("UIScale", {}, panel)
	s.Scale = 0.82
	panel.Visible = true
	TweenService:Create(s, StyleGuide.Motion.open, { Scale = 1 }):Play()
end

function StyleGuide.close(panel, after)
	local s = panel:FindFirstChildOfClass("UIScale") or new("UIScale", {}, panel)
	local t = TweenService:Create(s, StyleGuide.Motion.close, { Scale = 0.82 })
	t.Completed:Once(function()
		panel.Visible = false
		s.Scale = 1
		if after then after() end
	end)
	t:Play()
end

-- push the world lighting mood to the guide's values (server or client)
function StyleGuide.applyLighting(Lighting)
	local L = StyleGuide.World.Lighting
	Lighting.Ambient = L.Ambient
	Lighting.OutdoorAmbient = L.Ambient
	Lighting.Brightness = L.Brightness
	Lighting.ExposureCompensation = L.Exposure
	local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmo then atmo.Color = L.Atmosphere; atmo.Density = L.Density; atmo.Haze = L.Haze; atmo.Glare = L.Glare end
	local bloom = Lighting:FindFirstChild("GeodeBloom") or Lighting:FindFirstChildOfClass("BloomEffect")
	if bloom then bloom.Intensity = L.Bloom; bloom.Threshold = L.BloomThreshold; bloom.Size = L.BloomSize end
	local cc = Lighting:FindFirstChild("GeodeColor") or Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if cc then cc.TintColor = L.Tint; cc.Brightness = L.CCBrightness; cc.Contrast = L.Contrast; cc.Saturation = L.Saturation end
end

return StyleGuide
