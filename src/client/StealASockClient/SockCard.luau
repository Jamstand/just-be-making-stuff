-- SockCard: the sock pop-up, and the sock pictures the Sockdex shares.
--  * ShowSlot(i): a sock in your drawer - the real 3D sock, animated (SockAnim), on a little
--    sunburst, rarity ribbon, mutation / side / stink chips, income counting up, pair status, the
--    Sockdex halves you have, and a two-tap "Sell for $X" button (SellSock remote; the sock in your
--    drawer waves goodbye first). If the sock leaves your drawer while the card is open (stolen),
--    the card says so and closes itself.
--  * ShowType(typeId): a Sockdex entry - the same card, info only.
-- It is an overlay (Menu.ShowOverlay), so it opens over the Sockdex panel or straight from the HUD's
-- drawer list without closing anything. On short screens the whole card scales down to fit.
--
-- Shared helpers (no image assets anywhere): SockCard.Viewer shows the sock's 3D model (the template
-- in ReplicatedStorage.SockMeshes) in a ViewportFrame, falling back to SockCard.Icon - a cartoon
-- sock drawn from Frames in the type's colours (silhouette + "?" for unfound types) - while the
-- template is missing. SockCard.RarityStyle / Paint give rarity candy colours, SockCard.HalfBadge
-- draws the little L / R / 1 badges.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = require(Shared:WaitForChild("Util"))
local SockConfig = require(Config:WaitForChild("SockConfig"))
local RarityConfig = require(Config:WaitForChild("RarityConfig"))
local MutationConfig = require(Config:WaitForChild("MutationConfig"))
local DexConfig = require(Config:WaitForChild("DexConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))
local Menu = require(script.Parent:WaitForChild("Menu"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local SockCard = {}

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local INK = Theme.Color.Ink
local SILHOUETTE = Color3.fromRGB(56, 42, 78)
local SILHOUETTE_EDGE = Color3.fromRGB(26, 16, 40)
local SHADE = ColorSequence.new(WHITE, Color3.fromRGB(204, 196, 214)) -- fills get darker toward the bottom
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 110, 110)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 220, 90)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 230, 130)),
	ColorSequenceKeypoint.new(0.75, Color3.fromRGB(110, 180, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(210, 130, 255)),
})

local CARD_W = 400
local CARD_H_SELL = 466 -- with the Sell button
local CARD_H_INFO = 424 -- Sockdex entry: a reward line instead
local CONFIRM_TIME = 3 -- seconds the "Tap again to sell" state waits
local REMOTE_TIMEOUT = 12

-- ---------- shared look helpers ----------

-- Candy colours for a rarity (the rarity colour as a glossy gradient). SECRET is dark with a lilac rim.
function SockCard.RarityStyle(rarity: string)
	if rarity == "Secret" then
		return { top = Color3.fromRGB(88, 74, 128), bottom = Color3.fromRGB(26, 20, 44), stroke = Color3.fromRGB(170, 150, 255), text = WHITE }
	end
	local c = Theme.RarityColor(rarity)
	return { top = c:Lerp(WHITE, 0.3), bottom = c:Lerp(BLACK, 0.12), stroke = c:Lerp(INK, 0.62), text = WHITE }
end

-- The candy look from a style table ({top, bottom, stroke}); Theme.candy only takes style names.
function SockCard.Paint(frame: GuiObject, style, radius: number, strokeThickness: number?)
	frame.BackgroundColor3 = WHITE
	frame.BackgroundTransparency = 0
	frame.BorderSizePixel = 0
	Theme.corner(frame, radius)
	Theme.stroke(frame, style.stroke, strokeThickness or 3)
	Theme.gradient(frame, style.top, style.bottom)
end

-- A small "L" / "R" / "1" badge: gold when that half has been found, a faded slot when not.
function SockCard.HalfBadge(parent: Instance?, text: string, lit: boolean, height: number): Frame
	local f = Instance.new("Frame")
	f.Name = "Half_" .. text
	f.Size = UDim2.fromOffset(math.floor(height * 1.3), height)
	local label
	if lit then
		SockCard.Paint(f, Theme.Styles.gold, math.floor(height / 2), 2)
		label = Theme.label(f, text, math.floor(height * 0.7), Theme.Styles.gold.text)
	else
		f.BackgroundColor3 = Theme.Color.InsetDark
		f.BorderSizePixel = 0
		Theme.corner(f, math.floor(height / 2))
		Theme.stroke(f, Theme.Color.Stroke, 1.5, 0.65)
		label = Theme.label(f, text, math.floor(height * 0.7), Theme.Color.Muted)
		label.TextTransparency = 0.25
	end
	label.Size = UDim2.fromScale(1, 1)
	label.ZIndex = 3
	f.Parent = parent
	return f
end

-- ---------- the procedural sock icon ----------

-- Draws a cartoon sock (leg + foot, cuff and stripe, heel and toe patches, googly eyes and the
-- type's signature bits) in a transparent `size` x `size` frame. Body pieces sit on slightly
-- bigger dark copies of themselves, so the whole silhouette gets one clean outline.
-- side: "L" points the toe left, "R" (default) right, "S" = single unit. unknown = dark silhouette + "?".
function SockCard.Icon(parent: Instance?, typeId: string, size: number, mutation: string?, side: string?, unknown: boolean?): Frame
	local root = Instance.new("Frame")
	root.Name = "SockIcon"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(size, size)
	local sockType = SockConfig.ById[typeId]
	if not sockType then
		root.Parent = parent
		return root
	end
	local look = sockType.look or {}
	local function has(feature: string): boolean
		return table.find(look, feature) ~= nil
	end
	local m = if mutation and not unknown then MutationConfig.Table[mutation] else nil
	local rainbow = mutation == "Rainbow" and not unknown
	local body = if unknown then SILHOUETTE else (if m and m.color then m.color else sockType.color)
	local accent = sockType.accent
	local edgeColor = if unknown then SILHOUETTE_EDGE else INK
	local single = sockType.single == true or side == "S"
	local flip = side == "L" -- the art is drawn toe-right; left socks are mirrored
	local px = size
	local edge = math.max(1.5, size * 0.045)
	local fills = {} :: { Frame }

	local function place(f: GuiObject, x: number, y: number, w: number, h: number)
		local left = if flip then 1 - x - w else x
		f.Position = UDim2.fromOffset(left * px, y * px)
		f.Size = UDim2.fromOffset(w * px, h * px)
	end
	-- a rectangle (x, y, w, h as fractions of the icon) with corner radius r (fraction of the icon)
	local function shape(x: number, y: number, w: number, h: number, color: Color3, r: number?, z: number): Frame
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.ZIndex = z
		place(f, x, y, w, h)
		if r then
			Theme.corner(f, r * px)
		end
		f.Parent = root
		return f
	end
	-- a circle by centre and diameter
	local function dot(cx: number, cy: number, d: number, color: Color3, z: number): Frame
		local f = shape(cx - d / 2, cy - d / 2, d, d, color, nil, z)
		Theme.corner(f, UDim.new(0.5, 0))
		return f
	end
	-- a body piece: dark outline copy behind (z 2), shaded fill (z 3)
	local function piece(x: number, y: number, w: number, h: number, r: number)
		local back = Instance.new("Frame")
		back.BorderSizePixel = 0
		back.BackgroundColor3 = edgeColor
		back.ZIndex = 2
		local left = if flip then 1 - x - w else x
		back.Position = UDim2.fromOffset(left * px - edge, y * px - edge)
		back.Size = UDim2.fromOffset(w * px + edge * 2, h * px + edge * 2)
		Theme.corner(back, r * px + edge)
		back.Parent = root
		local fill = shape(x, y, w, h, if rainbow then WHITE else body, r, 3)
		local g = Instance.new("UIGradient")
		if rainbow then
			g.Color = RAINBOW
			g.Rotation = 35
		else
			g.Color = SHADE
			g.Rotation = 90
		end
		g.Parent = fill
		table.insert(fills, fill)
	end
	local function ring(target: Frame, color: Color3, thickness: number)
		local s = Instance.new("UIStroke")
		s.Color = color
		s.Thickness = thickness
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Parent = target
	end

	-- glow mutations get a soft halo behind the sock
	if m and m.material == Enum.Material.Neon then
		local halo = dot(0.5, 0.52, 1.02, body, 1)
		halo.BackgroundTransparency = 0.82
		local core = dot(0.5, 0.52, 0.78, body, 1)
		core.BackgroundTransparency = 0.72
	end

	-- body
	local top = 0.1
	if has("small") then
		top = 0.3
	elseif has("tall") or has("longneck") then
		top = 0.03
	elseif has("tophat") then
		top = 0.26
	elseif has("lintcrown") or has("puppet") then
		top = 0.17
	end
	local cx = if single then 0.5 else 0.44 -- leg centre
	local legW = if single then 0.4 else 0.36
	if single and has("tentacles") then
		piece(0.3, top, 0.4, 0.66 - top, 0.12)
		for _, x in ipairs({ 0.22, 0.36, 0.5, 0.64 }) do
			piece(x, 0.56, 0.13, 0.34, 0.065)
		end
	elseif single then
		piece(0.3, top, 0.4, 0.8 - top, 0.1)
		piece(0.12, 0.58, 0.76, 0.3, 0.15)
	else
		piece(0.26, top, 0.36, 0.8 - top, 0.1)
		piece(0.26, 0.58, 0.62, 0.3, 0.15)
	end

	if unknown then
		local q = Theme.label(root, "?", math.floor(px * 0.34), Color3.fromRGB(196, 178, 228))
		q.ZIndex = 6
		place(q, cx - 0.2, top + (0.8 - top) / 2 - 0.2, 0.4, 0.4)
		root.Parent = parent
		return root
	end

	-- cuff, stripe, heel and toe
	local cuff = shape(cx - legW / 2 - 0.03, top - 0.02, legW + 0.06, 0.12, accent, 0.05, 4)
	ring(cuff, INK, math.max(1, edge * 0.6))
	if not has("small") then
		shape(cx - legW / 2, top + 0.15, legW, 0.055, accent, nil, 4)
	end
	if not single then
		dot(0.39, 0.75, 0.22, accent, 4) -- heel
		dot(0.73, 0.73, 0.3, accent, 4) -- toe: the same circle as the foot's rounded end
	elseif not has("tentacles") then
		dot(0.27, 0.73, 0.3, accent, 4)
		dot(0.73, 0.73, 0.3, accent, 4)
	end

	-- signature bits (a few of the Factory's FEATURES, drawn flat)
	local eyeY = if has("small") then top + 0.2 else top + 0.3
	local eyes = if single then { 0.43, 0.57 } else { 0.37, 0.51 }
	if has("argyle") then
		local diamond = shape(cx - 0.065, eyeY + 0.15, 0.13, 0.13, accent, 0.02, 5)
		diamond.Rotation = 45
	end
	if has("crusty") then
		dot(cx - 0.09, eyeY + 0.2, 0.07, accent:Lerp(BLACK, 0.25), 5)
		dot(cx + 0.08, 0.68, 0.06, accent:Lerp(BLACK, 0.25), 5)
	end
	if has("gripdots") then
		for _, x in ipairs({ 0.48, 0.58, 0.68 }) do
			dot(x, 0.83, 0.045, WHITE, 5)
		end
	end
	if has("beard") then
		shape(cx - 0.15, eyeY + 0.07, 0.3, 0.2, Color3.fromRGB(178, 178, 186), 0.1, 5)
	end
	if has("puppet") then
		shape(cx - 0.11, eyeY + 0.1, 0.22, 0.08, Color3.fromRGB(150, 24, 44), 0.04, 5)
		shape(cx - 0.2, top - 0.1, 0.4, 0.1, Color3.fromRGB(255, 120, 40), 0.05, 8)
	end
	if has("fangs") then
		for _, x in ipairs({ cx - 0.055, cx + 0.02 }) do
			local fang = shape(x, eyeY + 0.09, 0.035, 0.06, WHITE, 0.01, 5)
			ring(fang, INK, 1)
		end
	end
	if has("sadstripe") then
		shape(cx - legW / 2, top + 0.22, legW, 0.04, accent, nil, 4)
	end
	if has("lost") then
		for _, f in ipairs(fills) do
			f.BackgroundTransparency = 0.3
		end
	end
	if has("lightning") or (m and mutation == "Static") then
		for _, p in ipairs({ { 0.2, 0.3 }, { 0.8, 0.45 }, { 0.16, 0.62 } }) do
			local bolt = shape(p[1] - 0.02, p[2] - 0.05, 0.04, 0.1, Color3.fromRGB(255, 240, 120), 0.01, 8)
			bolt.Rotation = 25
		end
	end
	if mutation == "LintGalaxy" then
		for _, p in ipairs({ { 0.36, top + 0.2 }, { 0.5, 0.52 }, { 0.7, 0.76 }, { 0.32, 0.7 } }) do
			dot(p[1], p[2], 0.035, WHITE, 5)
		end
	end
	if mutation == "Holey" then
		dot(cx + 0.06, 0.62, 0.07, INK, 5)
		dot(0.62, 0.82, 0.05, INK, 5)
	end

	-- googly eyes, looking toward the toe
	for _, x in ipairs(eyes) do
		local white = dot(x, eyeY, 0.13, WHITE, 6)
		ring(white, INK, math.max(1, edge * 0.5))
		dot(x + 0.018, eyeY + 0.012, 0.065, BLACK, 7)
	end
	if has("sadbrows") then
		for i, x in ipairs(eyes) do
			local brow = shape(x - 0.05, eyeY - 0.11, 0.1, 0.025, INK, 0.01, 7)
			local screenLeft = (i == 1) ~= flip
			brow.Rotation = if screenLeft then -16 else 16
		end
	end
	if has("monocle") then
		local glass = dot(eyes[2], eyeY, 0.19, WHITE, 8)
		glass.BackgroundTransparency = 1
		ring(glass, Color3.fromRGB(240, 196, 70), math.max(1.5, edge * 0.8))
	end
	if has("headphones") then
		shape(cx - 0.25, top - 0.06, 0.5, 0.045, accent, 0.02, 8)
		for _, x in ipairs({ cx - 0.25, cx + 0.22 }) do
			shape(x, top - 0.06, 0.03, eyeY - top + 0.06, accent, nil, 8)
		end
		for _, x in ipairs({ cx - 0.235, cx + 0.235 }) do
			ring(dot(x, eyeY, 0.15, accent, 8), INK, math.max(1, edge * 0.6))
		end
	end
	if has("tophat") then
		local hat = Color3.fromRGB(30, 26, 38)
		shape(cx - 0.14, top - 0.24, 0.28, 0.2, hat, 0.03, 8)
		shape(cx - 0.14, top - 0.1, 0.28, 0.04, Color3.fromRGB(255, 215, 0), nil, 9)
		shape(cx - 0.22, top - 0.06, 0.44, 0.06, hat, 0.03, 8)
	end
	if has("lintcrown") then
		local gold = Color3.fromRGB(255, 205, 60)
		for _, x in ipairs({ cx - 0.12, cx, cx + 0.12 }) do
			local point = shape(x - 0.04, top - 0.13, 0.08, 0.08, gold, 0.01, 8)
			point.Rotation = 45
		end
		local band = shape(cx - 0.17, top - 0.08, 0.34, 0.07, gold, 0.02, 9)
		ring(band, INK, 1)
	end

	root.Parent = parent
	return root
end

-- ---------- SockAnim (optional) ----------

-- SockAnim brings the 3D socks to life (bones, or the whole model when a mesh has none). It is
-- optional here: it loads in the background and every call into it is guarded, so if it is missing
-- or broken the menus still work and just show still socks.
local sockAnimModule: any = nil
local sockAnimState = "idle" -- "idle" | "loading" | "ready" | "failed"

local function loadSockAnim()
	if sockAnimState ~= "idle" then
		return
	end
	local module = script.Parent:FindFirstChild("SockAnim")
	if not (module and module:IsA("ModuleScript")) then
		return -- not there (yet): the next sockAnim() looks again
	end
	sockAnimState = "loading"
	local ok, loaded = pcall(require, module)
	if ok and type(loaded) == "table" then
		sockAnimModule = loaded
		sockAnimState = "ready"
	else
		sockAnimState = "failed"
		warn("[SockCard] SockAnim failed to load - menu socks stay still: " .. tostring(loaded))
	end
end

-- The SockAnim module, or nil. Never yields: the first call starts loading it in the background.
local function sockAnim(): any
	if sockAnimState == "idle" then
		task.spawn(loadSockAnim)
	end
	return sockAnimModule
end

-- ---------- the 3D sock viewer ----------

local FOV = 30 -- narrow: little perspective distortion on a small sock
local YAW = math.rad(24) -- the 3/4 view: the camera stands a little toward the toe
local PITCH = math.rad(9) -- and a little above
local AMBIENT = Color3.fromRGB(172, 166, 182) -- soft and even: the textures already carry painted shading
local LIGHT = Color3.fromRGB(128, 120, 110) -- a warm key light from the upper left
local NEON_AMBIENT = Color3.fromRGB(236, 230, 242) -- Glow / Static / Lint Galaxy: lit flat and bright
local NEON_LIGHT = Color3.fromRGB(60, 56, 52)
local UNKNOWN_TEXT = Color3.fromRGB(196, 178, 228)
local TEMPLATE_WAIT = 6 -- seconds a viewer keeps looking for a template that isn't there yet
-- never copied into a menu model: nothing may run or play there (lights and particles don't
-- render in a ViewportFrame anyway)
local STRIP = { "LuaSourceContainer", "Sound", "Light", "ParticleEmitter", "Beam", "Trail", "Fire", "Smoke", "Sparkles", "Highlight", "ProximityPrompt", "ClickDetector" }

type Prepared = { master: Model, minV: Vector3, maxV: Vector3, toe: number }

local preparedCache = {} :: { [Instance]: Prepared }
local gaveUp = {} :: { [string]: boolean } -- "<TypeId>_<Side>" waited for in vain: don't wait again

local function endsWith(name: string, suffix: string): boolean
	return #name >= #suffix and string.sub(name, -#suffix) == suffix
end

local function isMarker(name: string): boolean
	return endsWith(name, "_Base") or endsWith(name, "_Unit") or endsWith(name, "_Pin")
end

-- The rarity's glow colour (SECRET's own colour is near black, so it glows lilac).
local function rarityTint(rarity: string): Color3
	return if rarity == "Secret" then Color3.fromRGB(170, 150, 255) else Theme.RarityColor(rarity)
end

-- World-axis bounds of the parts you see (the outline hull included: it is the visible rim).
local function visibleBounds(model: Model): (Vector3?, Vector3?)
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 and not isMarker(d.Name) then
			local cf, h = d.CFrame, d.Size / 2
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local p = cf * Vector3.new(h.X * sx, h.Y * sy, h.Z * sz)
						minV = if minV then minV:Min(p) else p
						maxV = if maxV then maxV:Max(p) else p
					end
				end
			end
		end
	end
	return minV, maxV
end

-- A menu copy of a template. The templates in ReplicatedStorage.SockMeshes are raw imports, so this
-- does what the server's MeshTemplate.Prepare does: turn the model so its front (_Base -> _Unit)
-- faces +Z, scale 1 unit to 1 stud, and hide the markers. It also stands the floor point (_Base) on
-- the origin with a world-aligned pivot there, and anchors everything. Templates without markers
-- get the Part sock's height and stand on their bounding box. Nil when the template is unusable.
local function prepare(template: Instance): Prepared?
	local ok, clone = pcall(function()
		return template:Clone()
	end)
	if not ok or clone == nil then
		return nil -- Archivable is off
	end
	local model: Model
	if clone:IsA("Model") then
		model = clone
	elseif clone:IsA("BasePart") then
		model = Instance.new("Model")
		model.Name = clone.Name
		clone.Parent = model
		model.PrimaryPart = clone
	else
		clone:Destroy()
		return nil
	end
	for _, d in ipairs(model:GetDescendants()) do
		for _, class in ipairs(STRIP) do
			if d:IsA(class) then
				d:Destroy()
				break
			end
		end
	end
	local base: BasePart? = nil
	local unit: BasePart? = nil
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			if base == nil and endsWith(d.Name, "_Base") then
				base = d
			elseif unit == nil and endsWith(d.Name, "_Unit") then
				unit = d
			end
		end
	end
	local origin: Vector3
	if base and unit then
		local offset = unit.Position - base.Position
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > 1e-4 then
			-- turn about the Base marker so the front points along +Z
			local angle = math.atan2(flat.X, flat.Z)
			local pivot = CFrame.new(base.Position)
			model:PivotTo(pivot * CFrame.Angles(0, -angle, 0) * pivot:Inverse() * model:GetPivot())
		end
		if offset.Magnitude > 1e-4 then
			model:ScaleTo(model:GetScale() / offset.Magnitude)
		end
		origin = base.Position
	else
		local lo, hi = visibleBounds(model)
		local height = if lo and hi then hi.Y - lo.Y else 0
		if height <= 1e-3 then
			model:Destroy()
			return nil
		end
		model:ScaleTo(model:GetScale() * (4.5 / height)) -- leg + foot of the Part sock
		lo, hi = visibleBounds(model)
		if not (lo and hi) then
			model:Destroy()
			return nil
		end
		origin = Vector3.new((lo.X + hi.X) / 2, lo.Y, (lo.Z + hi.Z) / 2)
	end
	model:PivotTo(CFrame.new(-origin) * model:GetPivot())
	-- world-aligned pivot on the floor point (now the origin), like the server's Prepare
	local primary = model.PrimaryPart
	if primary then
		primary.PivotOffset = primary.CFrame:Inverse()
	else
		model.WorldPivot = CFrame.new()
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			if isMarker(d.Name) then
				d.Transparency = 1
			end
		end
	end
	local minV, maxV = visibleBounds(model)
	if not (minV and maxV) then
		model:Destroy()
		return nil
	end
	-- which way the toe points (+1 = +X, a right sock): the 3/4 camera stands on that side
	local midX = (minV.X + maxV.X) / 2
	local toe = if midX < -0.05 * (maxV.X - minV.X) then -1 else 1
	return { master = model, minV = minV, maxV = maxV, toe = toe }
end

-- The template for a sock: "<TypeId>_<Side>", else "<TypeId>" (what the Factory looks for), else
-- the other half (a 3D sock pointing the wrong way still beats the drawn one).
local function findTemplate(typeId: string, side: string?): Instance?
	local folder = ReplicatedStorage:FindFirstChild("SockMeshes")
	if not folder then
		return nil
	end
	local s = side or "R"
	local found = folder:FindFirstChild(typeId .. "_" .. s) or folder:FindFirstChild(typeId)
	if not found and s ~= "S" then
		found = folder:FindFirstChild(typeId .. (if s == "L" then "_R" else "_L"))
	end
	return found
end

local function preparedFor(typeId: string, side: string?): Prepared?
	local template = findTemplate(typeId, side)
	if not template then
		return nil
	end
	local cached = preparedCache[template]
	if not cached then
		local ok, fresh = pcall(prepare, template)
		if not ok then
			warn("[SockCard] couldn't prepare " .. template:GetFullName() .. " for the menus: " .. tostring(fresh))
			return nil
		elseif not fresh then
			return nil
		end
		cached = fresh
		preparedCache[template] = fresh
	end
	return cached
end

-- A camera that fits the box (plus `headroom` x its height on top, room for hops) into a square
-- viewport from the 3/4 angle with `margin` to spare, and centres it.
local function frameCamera(minV: Vector3, maxV: Vector3, yaw: number, margin: number, headroom: number): CFrame
	local top = maxV + Vector3.new(0, (maxV.Y - minV.Y) * headroom, 0)
	local corners = {}
	for _, x in ipairs({ minV.X, top.X }) do
		for _, y in ipairs({ minV.Y, top.Y }) do
			for _, z in ipairs({ minV.Z, top.Z }) do
				table.insert(corners, Vector3.new(x, y, z))
			end
		end
	end
	local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(-PITCH, 0, 0)
	local t = math.tan(math.rad(FOV) / 2) / margin
	local focus = (minV + top) / 2
	local dist = 1
	for pass = 1, 3 do
		-- far enough that every corner fits: |x|, |y| <= (dist - z) * t (camera space, +z toward the camera)
		dist = 1
		for _, c in ipairs(corners) do
			local p = rot:VectorToObjectSpace(c - focus)
			dist = math.max(dist, p.Z + math.max(math.abs(p.X), math.abs(p.Y)) / t, p.Z + 1)
		end
		if pass == 3 then
			break
		end
		-- then aim so the box's picture sits in the middle
		local loX, hiX, loY, hiY = math.huge, -math.huge, math.huge, -math.huge
		for _, c in ipairs(corners) do
			local p = rot:VectorToObjectSpace(c - focus)
			local depth = math.max(dist - p.Z, 1e-3)
			loX = math.min(loX, p.X / depth)
			hiX = math.max(hiX, p.X / depth)
			loY = math.min(loY, p.Y / depth)
			hiY = math.max(hiY, p.Y / depth)
		end
		focus += rot:VectorToWorldSpace(Vector3.new((loX + hiX) / 2, (loY + hiY) / 2, 0) * dist)
	end
	return CFrame.new(focus) * rot * CFrame.new(0, 0, dist)
end

local function circle(parent: Instance, scale: number, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = "Glow"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.52)
	f.Size = UDim2.fromScale(scale, scale)
	f.BackgroundColor3 = WHITE
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.ZIndex = z
	f.Visible = false
	Theme.corner(f, UDim.new(0.5, 0))
	f.Parent = parent
	return f
end

-- SockCard.Viewer(parent, typeId?, side?, opts?) -> viewer: the sock's real 3D model in a
-- ViewportFrame (inside a WorldModel, which bones need to deform), turned to face the camera from a
-- slight 3/4 angle and framed to fill the square.
--   opts: size (px, default 100), iconSize (the drawn fallback, default 83% of size), mutation,
--   silhouette (an unfound type: dark shape + "?"), rarityGlow (a soft glow in the rarity colour
--   behind it), roomy (extra room round the sock for SockAnim's hops and show-offs), zIndex.
--   viewer.Frame: the transparent square to place.
--   viewer:SetSock(typeId?, side?, mutation?), :SetSilhouette(on), :SetAnimated(on) (SockAnim's
--   "ui" idle while on; a still pose when off, with Reduce motion or without SockAnim),
--   :Moment(kind) (a SockAnim one-shot, e.g. "showoff"), :Is3D(), :Destroy().
-- Mutations are approximated (the server's effects aren't on the template): a tint on the render,
-- a coloured halo, sparks / stars, and Rainbow cycles its hue while animated. Until the template is
-- in ReplicatedStorage.SockMeshes (it may still be arriving, or was never imported) the viewer
-- shows the drawn SockCard.Icon instead.
function SockCard.Viewer(parent: Instance?, typeId: string?, side: string?, opts: { [string]: any }?)
	local o = opts or {}
	local size: number = if type(o.size) == "number" then o.size else 100
	local iconSize: number = if type(o.iconSize) == "number" then o.iconSize else math.floor(size * 0.83)
	local roomy = o.roomy == true
	local rarityGlow = o.rarityGlow == true

	local root = Instance.new("Frame")
	root.Name = "SockViewer"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(size, size)
	root.ZIndex = if type(o.zIndex) == "number" then o.zIndex else 1
	local glowOuter = circle(root, 1, 1)
	local glowInner = circle(root, 0.7, 1)
	local decor = Instance.new("Frame") -- sparks / stars over the sock
	decor.Name = "Decor"
	decor.BackgroundTransparency = 1
	decor.Size = UDim2.fromScale(1, 1)
	decor.ZIndex = 4
	decor.Parent = root
	root.Parent = parent

	local vp: ViewportFrame? = nil
	local world: WorldModel? = nil
	local cam: Camera? = nil
	local prep: Prepared? = nil
	local model: Model? = nil
	local fallback: Frame? = nil
	local question: TextLabel? = nil

	local curType: string? = nil
	local curSide: string? = nil
	local curMutation: string? = nil
	local silhouette = o.silhouette == true
	local animated = false
	local loading = false
	local handle: any = nil -- SockAnim.Attach's handle
	local idleConn: RBXScriptConnection? = nil -- the stand-in idle when SockAnim is missing
	local rainbowConn: RBXScriptConnection? = nil
	local pendingMoment: string? = nil
	local pendingAt = 0
	local token = 0
	local destroyed = false

	local function stopRainbow()
		if rainbowConn then
			rainbowConn:Disconnect()
			rainbowConn = nil
		end
	end

	local function paintRainbow(hue: number)
		glowOuter.BackgroundColor3 = Color3.fromHSV(hue, 0.7, 1)
		glowInner.BackgroundColor3 = Color3.fromHSV((hue + 0.15) % 1, 0.7, 1)
		if vp and not silhouette then
			vp.ImageColor3 = Color3.fromHSV(hue, 0.4, 1)
		end
	end

	local function spark(x: number, y: number, w: number, h: number, color: Color3, rotation: number)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(x, y)
		f.Size = UDim2.fromScale(w, h)
		f.BackgroundColor3 = color
		f.BorderSizePixel = 0
		f.Rotation = rotation
		Theme.corner(f, UDim.new(0.2, 0))
		f.Parent = decor
	end

	local function setQuestion(on: boolean)
		if on and not question then
			local q = Theme.label(root, "?", math.floor(iconSize * 0.34), UNKNOWN_TEXT)
			q.Name = "Unknown"
			q.AnchorPoint = Vector2.new(0.5, 0.5)
			q.Position = UDim2.fromScale(0.5, 0.52)
			q.Size = UDim2.fromScale(0.6, 0.6)
			q.ZIndex = 5
			question = q
		elseif not on and question then
			question:Destroy()
			question = nil
		end
	end

	-- glow, tint, lighting and sparks for the current sock / mutation / silhouette state
	local function applyLook()
		stopRainbow()
		decor:ClearAllChildren()
		local sockType = if curType then SockConfig.ById[curType] else nil
		local m = if curMutation and not silhouette then MutationConfig.Table[curMutation] else nil
		if m and m.display == "" then
			m = nil -- "None"
		end
		local glow: Color3? = nil
		local strength = 0
		if m then
			glow = m.color or (if sockType then sockType.color else WHITE)
			strength = if m.material == Enum.Material.Neon then 1 else 0.7
		elseif rarityGlow and sockType and not silhouette then
			glow = rarityTint(sockType.rarity)
			local tier = RarityConfig.Tiers[sockType.rarity]
			strength = if tier then math.clamp((tier.rank - 1) / 6, 0, 1) else 0
		end
		glowOuter.Visible = glow ~= nil
		glowInner.Visible = glow ~= nil
		if glow then
			glowOuter.BackgroundColor3 = glow
			glowInner.BackgroundColor3 = glow
			glowOuter.BackgroundTransparency = 0.9 - 0.12 * strength
			glowInner.BackgroundTransparency = 0.84 - 0.18 * strength
		end
		if vp then
			if silhouette then
				-- black where the sock is, a little see-through: a dark shape on the dark card
				vp.Ambient = AMBIENT
				vp.LightColor = LIGHT
				vp.ImageColor3 = BLACK
				vp.ImageTransparency = 0.35
			else
				local neon = m ~= nil and m.material == Enum.Material.Neon
				vp.Ambient = if neon then NEON_AMBIENT else AMBIENT
				vp.LightColor = if neon then NEON_LIGHT else LIGHT
				vp.ImageColor3 = if m and m.color then WHITE:Lerp(m.color, 0.45) else WHITE
				vp.ImageTransparency = 0
			end
		end
		setQuestion(silhouette and model ~= nil)
		if not m or fallback then
			return -- the drawn icon has its own mutation bits
		end
		if curMutation == "Static" then
			for _, p in ipairs({ { 0.17, 0.3 }, { 0.84, 0.42 }, { 0.14, 0.64 } }) do
				spark(p[1], p[2], 0.035, 0.1, Color3.fromRGB(255, 240, 120), 25) -- lightning
			end
		elseif curMutation == "LintGalaxy" or curMutation == "GoldenThread" then
			local color = if curMutation == "LintGalaxy" then WHITE else Color3.fromRGB(255, 226, 120)
			for _, p in ipairs({ { 0.24, 0.24 }, { 0.78, 0.3 }, { 0.82, 0.72 }, { 0.2, 0.7 } }) do
				spark(p[1], p[2], 0.04, 0.04, color, 45) -- twinkles
			end
		elseif curMutation == "Rainbow" then
			paintRainbow(0.85)
			if animated and not Anim.Reduced then
				local last = 0
				rainbowConn = RunService.Heartbeat:Connect(function()
					local now = os.clock()
					if now - last >= 0.05 then
						last = now
						paintRainbow((now * 0.25) % 1)
					end
				end)
			end
		end
	end

	local function ensureViewport(): (ViewportFrame, WorldModel, Camera)
		if vp and world and cam then
			return vp, world, cam
		end
		local f = Instance.new("ViewportFrame")
		f.Name = "Viewport"
		f.BackgroundTransparency = 1
		f.Size = UDim2.fromScale(1, 1)
		f.ZIndex = 2
		f.Ambient = AMBIENT
		f.LightColor = LIGHT
		f.Parent = root
		local w = Instance.new("WorldModel")
		w.Parent = f
		local c = Instance.new("Camera")
		c.FieldOfView = FOV
		c.Parent = f
		f.CurrentCamera = c
		vp, world, cam = f, w, c
		return f, w, c
	end

	local function clearModel()
		if model then
			model:Destroy()
			model = nil
		end
	end

	-- a fresh copy of the prepared model, in its rest pose
	local function placeModel()
		clearModel()
		if prep and world then
			local copy = prep.master:Clone()
			copy.Parent = world
			model = copy
		end
	end

	local function show3D(p: Prepared)
		prep = p
		local f, _, c = ensureViewport()
		f.Visible = true
		placeModel()
		local cf = frameCamera(p.minV, p.maxV, YAW * p.toe, if roomy then 1.22 else 1.1, if roomy then 0.14 else 0)
		c.CFrame = cf
		f.LightDirection = cf:VectorToWorldSpace(Vector3.new(0.55, -0.8, -0.6)).Unit -- from the upper left, in front
		if fallback then
			fallback:Destroy()
			fallback = nil
		end
		applyLook()
	end

	local function showFallback()
		if fallback then
			fallback:Destroy()
			fallback = nil
		end
		clearModel()
		prep = nil
		if vp then
			vp.Visible = false
		end
		if curType then
			local icon = SockCard.Icon(root, curType, iconSize, curMutation, curSide, silhouette)
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.fromScale(0.5, 0.52)
			icon.ZIndex = 3
			fallback = icon
		end
		applyLook()
	end

	local function playMoment(kind: string)
		local anim = sockAnim()
		if handle and model and anim and type(anim.Moment) == "function" then
			local ok, err = pcall(anim.Moment, model, kind)
			if not ok then
				warn("[SockCard] SockAnim.Moment failed: " .. tostring(err))
			end
		elseif not Anim.Reduced then
			Anim.bump(root, 1.08)
		end
	end

	-- `reset`: put a fresh copy back, so the still pose is the rest pose whatever the animation left
	local function stopMotion(reset: boolean)
		if handle then
			local h = handle
			handle = nil
			local ok, err = pcall(function()
				h:Destroy()
			end)
			if not ok then
				warn("[SockCard] SockAnim handle:Destroy failed: " .. tostring(err))
			end
			if reset then
				placeModel()
			end
		end
		if idleConn then
			idleConn:Disconnect()
			idleConn = nil
			if reset and model then
				model:PivotTo(CFrame.new())
			end
		end
		if fallback then
			Anim.stop(fallback, "sway")
			Anim.stop(fallback, "pulse")
			fallback.Rotation = 0
			Anim.scale(fallback).Scale = 1
		end
	end

	local function startMotion()
		if not animated or destroyed or silhouette or Anim.Reduced or handle or idleConn then
			return
		end
		local m = model
		if m and curType then
			local anim = sockAnim()
			if anim and type(anim.Attach) == "function" then
				local sockType = SockConfig.ById[curType]
				local info = { typeId = curType, side = curSide, rarity = if sockType then sockType.rarity else nil, mutation = curMutation }
				local ok, result = pcall(anim.Attach, m, "ui", info)
				if ok and result ~= nil then
					handle = result
				elseif not ok then
					warn("[SockCard] SockAnim.Attach failed: " .. tostring(result))
				end
			end
			if not handle then
				-- no SockAnim: a gentle rock and bob, so the card still feels alive
				local t0 = os.clock()
				idleConn = RunService.Heartbeat:Connect(function()
					local t = os.clock() - t0
					m:PivotTo(CFrame.new(0, math.abs(math.sin(t * 2.4)) * 0.12, 0) * CFrame.Angles(0, math.sin(t * 1.3) * 0.2, math.sin(t * 2.4) * 0.04))
				end)
			end
			if pendingMoment and os.clock() - pendingAt < 2 then
				playMoment(pendingMoment)
			end
			pendingMoment = nil
		elseif fallback then
			Anim.sway(fallback, 5, 2.6)
			Anim.pulse(fallback, 1.04, 2.2)
		end
	end

	local function cleanup()
		token += 1
		stopMotion(false)
		stopRainbow()
	end

	local viewer = {}
	viewer.Frame = root

	function viewer:SetSock(newType: string?, newSide: string?, newMutation: string?)
		if destroyed then
			return
		end
		token += 1
		local myToken = token
		stopMotion(false)
		pendingMoment = nil
		loading = false
		curType, curSide, curMutation = newType, newSide, newMutation
		if not newType then
			showFallback()
			return
		end
		local id: string = newType
		local p = preparedFor(id, newSide)
		if p then
			show3D(p)
		else
			showFallback()
			local key = id .. "_" .. (newSide or "R")
			if not gaveUp[key] then
				-- the template may still be arriving: keep looking for a few seconds
				loading = true
				task.spawn(function()
					local deadline = os.clock() + TEMPLATE_WAIT
					while os.clock() < deadline do
						task.wait(0.5)
						if destroyed or token ~= myToken then
							return
						end
						local later = preparedFor(id, newSide)
						if later then
							loading = false
							stopMotion(false)
							show3D(later)
							startMotion()
							return
						end
					end
					gaveUp[key] = true
					if token == myToken then
						loading = false
						pendingMoment = nil
					end
				end)
			end
		end
		startMotion()
	end

	function viewer:SetSilhouette(on: boolean)
		if destroyed or silhouette == on then
			return
		end
		silhouette = on
		if on then
			stopMotion(true)
		end
		if fallback then
			showFallback() -- redraw the drawn icon dark (or in colour)
		else
			applyLook()
		end
		startMotion()
	end

	function viewer:SetAnimated(on: boolean)
		if destroyed or animated == on then
			return
		end
		animated = on
		if on then
			startMotion()
		else
			pendingMoment = nil
			stopMotion(true)
		end
		if curMutation == "Rainbow" then
			applyLook() -- the hue only cycles while animated
		end
	end

	function viewer:Moment(kind: string)
		if destroyed or silhouette or Anim.Reduced then
			return
		end
		if loading and animated then
			pendingMoment = kind -- the 3D sock is still on its way: show off when it arrives
			pendingAt = os.clock()
		else
			playMoment(kind)
		end
	end

	function viewer:Is3D(): boolean
		return model ~= nil
	end

	function viewer:Destroy()
		if destroyed then
			return
		end
		destroyed = true
		cleanup()
		root:Destroy()
	end

	root.Destroying:Once(function()
		if not destroyed then
			destroyed = true
			cleanup()
		end
	end)

	if typeId then
		viewer:SetSock(typeId, side, o.mutation)
	else
		applyLook()
	end
	return viewer
end

-- ---------- remotes ----------

-- Calls a menu RemoteFunction without ever erroring, and gives up after REMOTE_TIMEOUT seconds,
-- so a button waiting on it always comes back. Returns a Result-shaped table.
local function invoke(name: string, ...: any): { [string]: any }
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteFunction")) then
		return { ok = false, err = "Not available yet - try again soon" }
	end
	local rf = remote :: RemoteFunction
	local args = table.pack(...)
	local result = nil
	local done = Instance.new("BindableEvent")
	task.spawn(function()
		local ok, res = pcall(function()
			return rf:InvokeServer(table.unpack(args, 1, args.n))
		end)
		if result == nil then
			result = if ok and type(res) == "table" then res else { ok = false, err = "Something went wrong - try again" }
			done:Fire()
		end
	end)
	task.delay(REMOTE_TIMEOUT, function()
		if result == nil then
			result = { ok = false, err = "No answer - try again" }
			done:Fire()
		end
	end)
	if result == nil then
		done.Event:Wait()
	end
	done:Destroy()
	return result
end

-- ---------- the card ----------

local latest = nil -- the last StateView
local holder: Frame -- the overlay frame (Menu pops it in/out with its AnimScale)
local card: Frame -- the visible card (its FitScale shrinks it on short screens)
local fit: UIScale
local ribbon: Frame? = nil
local rays: Frame
local rayBars = {} :: { Frame }
local disc: Frame
local discStroke: UIStroke
local sockView: any = nil -- SockCard.Viewer: the 3D sock on the stage
local nameLabel: TextLabel
local chips: Frame
local rowKeys = {} :: { TextLabel }
local incomeValue: TextLabel
local pairValue: TextLabel
local halves: Frame
local sellButton: TextButton
local sellTimer: Frame
local rewardLabel: TextLabel

local mode: string? = nil -- "slot" | "type" | "gone" while the card is up
local shownUid: number? = nil
local shownType: string? = nil
local isOpen = false
local showToken = 0
local cardHeight = CARD_H_SELL
local sellPrice = 0
local sell = { armed = false, busy = false, token = 0 }

local function incomeText(n: number): string
	return "$" .. Util.FormatRate(n) .. "/s"
end

local function halfIncomeText(n: number): string
	return "$" .. Util.FormatRate(n) .. "/s per half"
end

local function sellText(): string
	return "Sell for $" .. Util.FormatCash(sellPrice)
end

local function slotAt(state, index: number)
	local slots = state and state.slots
	if type(slots) ~= "table" then
		return nil
	end
	return slots[index] or slots[tostring(index)] -- remotes may turn a gappy array's keys into strings
end

local function findUid(state, uid: number?)
	local slots = state and state.slots
	if uid == nil or type(slots) ~= "table" then
		return nil
	end
	for _, view in pairs(slots) do
		if type(view) == "table" and view.uid == uid then
			return view
		end
	end
	return nil
end

local function dexEntry(typeId: string)
	local dex = latest and latest.dex
	if type(dex) ~= "table" then
		return nil
	end
	return dex[typeId]
end

local function updateFit()
	local layer = Menu.Layer()
	local scale = Theme.Scale()
	if not layer or scale <= 0 then
		return
	end
	local refW = layer.AbsoluteSize.X / scale
	local refH = layer.AbsoluteSize.Y / scale
	if refW <= 0 or refH <= 0 then
		return
	end
	fit.Scale = math.clamp(math.min((refH - 24) / cardHeight, (refW - 24) / CARD_W), 0.4, 1)
end

local function chip(text: string, style, order: number, rainbowFill: boolean?)
	local f = Instance.new("Frame")
	f.Name = "Chip"
	f.AutomaticSize = Enum.AutomaticSize.X
	f.Size = UDim2.fromOffset(0, 30)
	f.LayoutOrder = order
	SockCard.Paint(f, style, 15, 2.5)
	if rainbowFill then
		local g = f:FindFirstChildOfClass("UIGradient")
		if g then
			g.Color = RAINBOW
			g.Rotation = 0
		end
	end
	Theme.padding(f, 12, 0, 12, 0)
	local t = Theme.label(f, text, 17, style.text)
	t.AutomaticSize = Enum.AutomaticSize.X
	t.Size = UDim2.fromScale(0, 1)
	t.ZIndex = 3
	if style.text == WHITE then
		Theme.textStroke(t, style.stroke, 2)
	end
	f.Parent = chips
	return f
end

local function styleFrom(color: Color3)
	return { top = color:Lerp(WHITE, 0.25), bottom = color:Lerp(BLACK, 0.12), stroke = color:Lerp(INK, 0.6), text = WHITE }
end

local function setChips(side: string?, mutation: string?, stink: number?, sockType)
	for _, c in ipairs(chips:GetChildren()) do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	if side == "L" then
		chip("LEFT", Theme.Styles.blue, 1)
	elseif side == "R" then
		chip("RIGHT", Theme.Styles.coral, 1)
	elseif side == "S" then
		chip("SINGLE", Theme.Styles.purple, 1)
	elseif sockType then
		chip(if sockType.single then "SINGLE" else "L + R", Theme.Styles.cream, 1)
	end
	local m = if mutation then MutationConfig.Table[mutation] else nil
	if m and m.display ~= "" then
		chip("✨ " .. m.display .. " ×" .. tostring(m.mult), styleFrom(m.color or Color3.fromRGB(176, 132, 220)), 2, mutation == "Rainbow")
	end
	if stink and stink > 0 then
		chip("💨 Stink " .. tostring(stink), styleFrom(Color3.fromRGB(120, 176, 70)), 3)
	end
end

local halvesKey = ""
local function setHalves(typeId: string)
	local sockType = SockConfig.ById[typeId]
	local entry = dexEntry(typeId) or {}
	local key = typeId .. (if entry.L then "L" else "") .. (if entry.R then "R" else "") .. (if entry.S then "S" else "")
	if key == halvesKey then
		return -- unchanged (SetState calls this every second while the card is open)
	end
	halvesKey = key
	for _, c in ipairs(halves:GetChildren()) do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	if sockType and sockType.single then
		SockCard.HalfBadge(halves, "1", entry.S == true, 24).LayoutOrder = 1
	else
		SockCard.HalfBadge(halves, "L", entry.L == true, 24).LayoutOrder = 1
		SockCard.HalfBadge(halves, "R", entry.R == true, 24).LayoutOrder = 2
	end
end

local function setPair(sockType, paired: boolean, perfect: boolean, side: string?)
	local text, color
	if perfect then
		text, color = "★★ Perfect pair!", Theme.Color.Gold2
	elseif paired then
		text = if sockType and sockType.alwaysPaired then "★ Always paired" else "★ Paired"
		color = Theme.Color.Money
	elseif sockType and sockType.noMatch then
		text, color = "Never pairs", Theme.Color.Muted
	elseif side == "L" then
		text, color = "Needs a RIGHT", Theme.Color.Muted
	elseif side == "R" then
		text, color = "Needs a LEFT", Theme.Color.Muted
	else
		text, color = "Not paired yet", Theme.Color.Muted
	end
	if pairValue.Text ~= text and isOpen and mode ~= nil and pairValue.Text ~= "" then
		Anim.bump(pairValue, 1.15)
		if (paired or perfect) and sockView then
			sockView:Moment("paired") -- it just found its other half while you watch
		end
	end
	pairValue.Text = text
	pairValue.TextColor3 = color
end

local function buildRibbon(rarity: string)
	if ribbon then
		ribbon:Destroy()
	end
	local style = SockCard.RarityStyle(rarity)
	local r = Instance.new("Frame")
	r.Name = "Ribbon"
	r.AnchorPoint = Vector2.new(0.5, 0.5)
	r.Position = UDim2.new(0.5, 0, 0, 0)
	r.Size = UDim2.fromOffset(250, 48)
	r.ZIndex = 10
	SockCard.Paint(r, style, 18, 3)
	Theme.gloss(r, 18)
	local title = Theme.label(r, string.upper(Theme.RarityName(rarity)), 28, style.text)
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 1)
	title.ZIndex = 13
	Theme.textStroke(title, style.stroke, 2.5)
	r.Parent = card
	Anim.sway(r, 1.2, 3)
	if rarity == "Secret" then
		Anim.shine(r, 2)
	end
	ribbon = r
end

local function disarm()
	sell.armed = false
	sell.token += 1
	sellTimer.Visible = false
	if not sell.busy and mode == "slot" then
		sellButton.Text = sellText()
	end
end

local function arm()
	sell.armed = true
	sell.token += 1
	local token = sell.token
	sellButton.Text = "Tap again to sell"
	sellTimer.Size = UDim2.new(1, -24, 0, 6)
	sellTimer.Visible = true
	-- a plain timer, not decoration: it must last exactly CONFIRM_TIME even with Reduce motion on
	TweenService:Create(sellTimer, TweenInfo.new(CONFIRM_TIME, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 6) }):Play()
	Anim.wiggle(sellButton, 5)
	task.delay(CONFIRM_TIME, function()
		if sell.armed and sell.token == token then
			disarm()
		end
	end)
end

local function sold(cash: number)
	mode = nil
	local at = Anim.centerOf(card)
	local target = Anim.CashTarget()
	if target then
		Anim.flyCoins(at, target, 10)
	end
	Anim.numberPop("+$" .. Util.FormatCash(cash), at, Theme.Color.Gold, 40)
	UISound.Play("sell")
	-- the card tips and lifts away while the overlay shrinks
	Anim.tween(card, 0.2, { Rotation = -10, Position = UDim2.new(0.5, 0, 0.5, -50) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	Menu.HideOverlay()
end

local function sellFailed(err: any)
	Anim.wiggle(sellButton)
	UISound.Play("error")
	sellButton.Text = if type(err) == "string" and err ~= "" then err else "Couldn't sell - try again"
	local token = showToken
	task.delay(1.8, function()
		if token == showToken and mode == "slot" and not sell.armed and not sell.busy then
			sellButton.Text = sellText()
		end
	end)
end

local function doSell()
	if sell.busy or mode ~= "slot" or shownUid == nil then
		return
	end
	sell.busy = true
	sell.armed = false
	sell.token += 1
	sellTimer.Visible = false
	sellButton.Text = "Selling…"
	local uid = shownUid
	local token = showToken
	local price = sellPrice
	-- the real sock in your drawer waves goodbye and poofs (SockAnim, optional) as it is sold
	local anim = sockAnim()
	if anim and type(anim.Goodbye) == "function" then
		task.spawn(function()
			local ok, err = pcall(anim.Goodbye, uid)
			if not ok then
				warn("[SockCard] SockAnim.Goodbye failed: " .. tostring(err))
			end
		end)
	end
	task.spawn(function()
		local res = invoke("SellSock", uid)
		sell.busy = false
		if token ~= showToken or not isOpen then
			return -- closed (or showing another sock) while waiting
		end
		if res.ok == true then
			sold(if type(res.cash) == "number" then res.cash else price)
		else
			sellFailed(res.err)
		end
	end)
end

-- the sock left the drawer while its card was open (stolen, or moved by the server)
local function gone()
	mode = "gone"
	sell.armed = false
	sell.token += 1
	sellTimer.Visible = false
	Theme.restyle(sellButton, "grey")
	sellButton.Text = "It left your drawer!"
	Anim.wiggle(card, 5)
	UISound.Play("error")
	local token = showToken
	task.delay(1.2, function()
		if isOpen and token == showToken then
			Menu.HideOverlay()
		end
	end)
end

local function onHidden(token: number)
	if token ~= showToken then
		return
	end
	isOpen = false
	mode = nil
	sell.armed = false
	sell.token += 1
	sellTimer.Visible = false
	if sockView then
		sockView:SetAnimated(false) -- no animation while nobody can see the card
	end
end

-- Shared part of ShowSlot / ShowType: rebuilds the look and pops the card up.
local function present(typeId: string, rarity: string, displayName: string, mutation: string?, side: string?, withSell: boolean)
	showToken += 1
	local token = showToken
	sell.armed = false
	sell.token += 1
	sellTimer.Visible = false
	card.Rotation = 0
	card.Position = UDim2.fromScale(0.5, 0.5)

	cardHeight = if withSell then CARD_H_SELL else CARD_H_INFO
	holder.Size = UDim2.fromOffset(CARD_W, cardHeight)
	updateFit()

	buildRibbon(rarity)
	local tint = rarityTint(rarity)
	for _, bar in ipairs(rayBars) do
		bar.BackgroundColor3 = tint
	end
	discStroke.Color = tint:Lerp(INK, 0.25)
	Anim.sway(rays, 12, 9)

	nameLabel.Text = displayName
	pairValue.Text = ""
	sellButton.Visible = withSell
	rewardLabel.Visible = not withSell
	if withSell then
		Theme.restyle(sellButton, "red")
	end

	isOpen = true
	Menu.ShowOverlay(holder, function()
		onHidden(token)
	end)
	-- the real sock: its idle animation while the card is up, and a show-off as it opens (after the
	-- card is up, so nothing SockAnim does can hold the card back)
	if sockView then
		sockView:SetSock(typeId, side, mutation)
		sockView:SetAnimated(true)
		sockView:Moment("showoff")
	end
	-- a hide animation still finishing could hide the card again; make sure it stays up
	task.delay(0.25, function()
		if isOpen and token == showToken then
			holder.Visible = true
		end
	end)
end

local function fillSlot(view, fresh: boolean)
	local sockType = SockConfig.ById[view.typeId]
	if fresh then
		Anim.countTo(incomeValue, 0, incomeText, 0)
	end
	Anim.countTo(incomeValue, tonumber(view.income) or 0, incomeText, if fresh then 0.9 else 0.5)
	setPair(sockType, view.paired == true, view.perfect == true, view.side)
	setHalves(view.typeId)
	sellPrice = tonumber(view.sellPrice) or 0
	if not sell.armed and not sell.busy and mode == "slot" then
		sellButton.Text = sellText()
	end
end

local function fillType(sockType)
	local entry = dexEntry(sockType.id) or {}
	local base = sockType.income or 0
	local fmt = if sockType.single then incomeText else halfIncomeText
	Anim.countTo(incomeValue, 0, fmt, 0)
	Anim.countTo(incomeValue, base, fmt, 0.9)
	setPair(sockType, entry.paired == true or sockType.alwaysPaired == true and entry.S == true, entry.perfect == true, nil)
	setHalves(sockType.id)
	local reward = DexConfig.NewReward[sockType.rarity]
	rewardLabel.Text = if reward then "🎁 First find paid $" .. Util.FormatCash(reward) else ""
end

-- ---------- public API ----------

function SockCard.Init()
	holder = Instance.new("Frame")
	holder.Name = "SockCard"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(0.5, 0, 0.5, 10)
	holder.Size = UDim2.fromOffset(CARD_W, CARD_H_SELL)
	holder.ZIndex = 42
	holder.Visible = false
	holder.Parent = Menu.Layer()

	card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(1, 1)
	Theme.candy(card, "cream", 24, 4)
	card.Active = true -- taps on the card don't fall through to the backdrop
	card.Parent = holder
	fit = Instance.new("UIScale")
	fit.Name = "FitScale"
	fit.Parent = card

	local close = Theme.closeButton(card)
	close.ZIndex = 20
	Anim.button(close, "close")
	close.Activated:Connect(function()
		Menu.HideOverlay()
	end)

	-- the stage: a slow sunburst in the rarity colour behind a round spotlight with the sock
	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.BackgroundTransparency = 1
	stage.AnchorPoint = Vector2.new(0.5, 0)
	stage.Position = UDim2.new(0.5, 0, 0, 32)
	stage.Size = UDim2.fromOffset(150, 150)
	stage.Parent = card
	rays = Instance.new("Frame")
	rays.Name = "Rays"
	rays.BackgroundTransparency = 1
	rays.AnchorPoint = Vector2.new(0.5, 0.5)
	rays.Position = UDim2.fromScale(0.5, 0.5)
	rays.Size = UDim2.fromOffset(196, 196)
	rays.ZIndex = 1
	rays.Parent = stage
	for i = 0, 7 do
		local bar = Instance.new("Frame")
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.new(1, 0, 0, 24)
		bar.Rotation = i * 22.5
		bar.BackgroundTransparency = 0.55
		Theme.corner(bar, 12)
		local fade = Instance.new("UIGradient")
		fade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.3, 0.5),
			NumberSequenceKeypoint.new(0.5, 0.35),
			NumberSequenceKeypoint.new(0.7, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		})
		fade.Parent = bar
		bar.Parent = rays
		table.insert(rayBars, bar)
	end
	disc = Instance.new("Frame")
	disc.Name = "Disc"
	disc.AnchorPoint = Vector2.new(0.5, 0.5)
	disc.Position = UDim2.fromScale(0.5, 0.5)
	disc.Size = UDim2.fromScale(1, 1)
	disc.BackgroundColor3 = Theme.Color.Inset
	disc.BorderSizePixel = 0
	disc.ZIndex = 2
	Theme.corner(disc, UDim.new(0.5, 0))
	Theme.gradient(disc, WHITE, Color3.fromRGB(236, 224, 206))
	discStroke = Theme.stroke(disc, Theme.Color.Stroke, 4)
	disc.Parent = stage
	-- the 3D sock stands in front of the disc, a little bigger than it so a hop can peek out
	sockView = SockCard.Viewer(stage, nil, nil, { size = 176, iconSize = 124, roomy = true, zIndex = 3 })
	sockView.Frame.AnchorPoint = Vector2.new(0.5, 0.5)
	sockView.Frame.Position = UDim2.fromScale(0.5, 0.5)
	task.defer(loadSockAnim) -- load SockAnim now, so it is ready when the first card opens

	nameLabel = Theme.label(card, "", 30, Theme.Color.Text)
	nameLabel.Name = "SockName"
	nameLabel.Position = UDim2.fromOffset(20, 188)
	nameLabel.Size = UDim2.new(1, -40, 0, 36)
	nameLabel.TextScaled = true
	local nameMax = Instance.new("UITextSizeConstraint")
	nameMax.MaxTextSize = 30
	nameMax.Parent = nameLabel

	chips = Instance.new("Frame")
	chips.Name = "Chips"
	chips.BackgroundTransparency = 1
	chips.Position = UDim2.fromOffset(12, 228)
	chips.Size = UDim2.new(1, -24, 0, 30)
	chips.Parent = card
	Theme.list(chips, 8, true)

	-- the stats box: Income / Pair / Sockdex halves
	local stats = Instance.new("Frame")
	stats.Name = "Stats"
	stats.AnchorPoint = Vector2.new(0.5, 0)
	stats.Position = UDim2.new(0.5, 0, 0, 268)
	stats.Size = UDim2.new(1, -48, 0, 102)
	stats.BackgroundColor3 = Theme.Color.Inset
	stats.BorderSizePixel = 0
	Theme.corner(stats, 14)
	Theme.stroke(stats, Theme.Color.Stroke, 2, 0.55)
	Theme.padding(stats, 14, 3, 14, 3)
	stats.Parent = card
	Theme.list(stats, 0)
	local values = {}
	for i, key in ipairs({ "Income", "Pair", "Sockdex" }) do
		local row = Instance.new("Frame")
		row.Name = key
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 32)
		row.LayoutOrder = i
		row.Parent = stats
		local k = Theme.label(row, key, 16, Theme.Color.Muted, Theme.FontBody)
		k.TextXAlignment = Enum.TextXAlignment.Left
		k.Size = UDim2.new(0.38, 0, 1, 0)
		table.insert(rowKeys, k)
		if i < 3 then
			local v = Theme.label(row, "", 21, Theme.Color.Text)
			v.AnchorPoint = Vector2.new(1, 0.5)
			v.Position = UDim2.new(1, 0, 0.5, 0)
			v.Size = UDim2.new(0.62, 0, 0, 28)
			v.TextXAlignment = Enum.TextXAlignment.Right
			v.TextScaled = true
			local vMax = Instance.new("UITextSizeConstraint")
			vMax.MaxTextSize = 21
			vMax.Parent = v
			values[i] = v
		else
			halves = Instance.new("Frame")
			halves.Name = "Halves"
			halves.BackgroundTransparency = 1
			halves.AnchorPoint = Vector2.new(1, 0.5)
			halves.Position = UDim2.new(1, 0, 0.5, 0)
			halves.Size = UDim2.new(0.62, 0, 0, 26)
			halves.Parent = row
			local hl = Theme.list(halves, 6, true)
			hl.HorizontalAlignment = Enum.HorizontalAlignment.Right
		end
	end
	incomeValue = values[1]
	incomeValue.TextColor3 = Theme.Color.Money
	pairValue = values[2]

	sellButton = Theme.button(card, "Sell", "red", UDim2.fromOffset(300, 64), 26)
	sellButton.Name = "Sell"
	sellButton.AnchorPoint = Vector2.new(0.5, 0)
	sellButton.Position = UDim2.new(0.5, 0, 0, 384)
	sellButton.TextScaled = true
	local sellMax = Instance.new("UITextSizeConstraint")
	sellMax.MaxTextSize = 26
	sellMax.Parent = sellButton:FindFirstChild("Label") or sellButton -- Theme.button shows its text in Label
	sellTimer = Instance.new("Frame")
	sellTimer.Name = "Timer"
	sellTimer.AnchorPoint = Vector2.new(0, 1)
	sellTimer.Position = UDim2.new(0, 12, 1, -5)
	sellTimer.Size = UDim2.new(1, -24, 0, 6)
	sellTimer.BackgroundColor3 = WHITE
	sellTimer.BackgroundTransparency = 0.1
	sellTimer.BorderSizePixel = 0
	sellTimer.ZIndex = sellButton.ZIndex + 3
	sellTimer.Visible = false
	Theme.corner(sellTimer, 3)
	sellTimer.Parent = sellButton
	Anim.button(sellButton, "click")
	sellButton.Activated:Connect(function()
		if sell.busy or mode ~= "slot" then
			return
		end
		if sell.armed then
			doSell()
		else
			arm()
		end
	end)

	rewardLabel = Theme.label(card, "", 18, Theme.Color.Muted, Theme.FontBody)
	rewardLabel.Name = "Reward"
	rewardLabel.Position = UDim2.fromOffset(20, 380)
	rewardLabel.Size = UDim2.new(1, -40, 0, 30)
	rewardLabel.Visible = false

	Menu.Layer():GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if isOpen then
			updateFit()
		end
	end)
end

function SockCard.SetState(state)
	if type(state) ~= "table" then
		return
	end
	latest = state
	if not isOpen then
		return
	end
	if mode == "slot" then
		if sell.busy then
			return -- the answer decides; a State that already lacks the sold sock must not say "stolen"
		end
		local view = findUid(state, shownUid)
		if view then
			fillSlot(view, false)
		else
			gone()
		end
	elseif mode == "type" and shownType then
		local sockType = SockConfig.ById[shownType]
		if sockType then
			local entry = dexEntry(shownType) or {}
			setPair(sockType, entry.paired == true or sockType.alwaysPaired == true and entry.S == true, entry.perfect == true, nil)
			setHalves(shownType)
		end
	end
end

-- True while the card is up (the Sockdex keeps its own socks still under it).
function SockCard.IsOpen(): boolean
	return isOpen
end

-- A sock in your drawer, by slot number (does nothing for an empty slot).
function SockCard.ShowSlot(slotIndex: number)
	if not holder or type(slotIndex) ~= "number" then
		return
	end
	local view = slotAt(latest, slotIndex)
	if type(view) ~= "table" or type(view.typeId) ~= "string" then
		return
	end
	local sockType = SockConfig.ById[view.typeId]
	mode = "slot"
	shownUid = view.uid
	shownType = view.typeId
	sellPrice = tonumber(view.sellPrice) or 0
	present(view.typeId, view.rarity or (sockType and sockType.rarity) or "Common", view.name or (sockType and sockType.name) or "Sock", view.mutation, view.side, true)
	rowKeys[1].Text = "Income"
	rowKeys[3].Text = "Sockdex"
	setChips(view.side, view.mutation, tonumber(view.stink), sockType)
	fillSlot(view, true)
	sellButton.Text = sellText()
end

-- A Sockdex entry (info only).
function SockCard.ShowType(typeId: string)
	local sockType = if type(typeId) == "string" then SockConfig.ById[typeId] else nil
	if not holder or not sockType then
		return
	end
	mode = "type"
	shownUid = nil
	shownType = typeId
	present(typeId, sockType.rarity, sockType.name, nil, if sockType.single then "S" else "R", false)
	rowKeys[1].Text = if sockType.single then "Income" else "Base income"
	rowKeys[3].Text = "Found"
	setChips(nil, nil, nil, sockType)
	fillType(sockType)
end

return SockCard
