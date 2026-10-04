-- ItemIcon: an item's picture for the item bar, the Item Shop and the unlock celebration - its 3D
-- model (ReplicatedStorage.ItemMeshes.<model>, from tools/blender/items) in a ViewportFrame, framed
-- from a slight 3/4 angle (long items like the towel from the side). Until the model is there the
-- icon shows the ItemConfig emoji, and the towel a little drawn towel in its look's colours.
--
-- A max-level (golden) item shows its `<model>_Gold` model; until that one is imported it shows the
-- regular model, and until that one the emoji.
--
-- Models may arrive late or never: one listener on the ItemMeshes folder swaps every icon still
-- waiting for a (better) model over the moment it appears. Icons are still pictures (no per-frame
-- work, except a Spin while it plays); each model is prepared once and cloned per icon.
--
-- ItemIcon.new(parent, opts?) -> icon. opts: size (px; default fills the parent), key, look, gold,
-- zIndex. icon.Frame (a transparent square), icon:Set(key?, look?, gold?) (nil = blank),
-- icon:Is3D(), icon:Shown() (the model name on screen, nil for the fallback), icon:Spin(seconds?)
-- (a one-turn turntable spin that settles facing front - the caller checks Reduce motion),
-- icon:Destroy(). ItemIcon.Looks[look] = { name, color, trim }: each towel look's colours, for
-- swatches.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ItemConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("ItemConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))

local ItemIcon = {}

local rgb = Color3.fromRGB
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local FOLDER = "ItemMeshes"
local GOLD = "_Gold" -- the golden (max level) version of a model: `<model>_Gold`
local FOV = 30
local PITCH = math.rad(14) -- the camera stands a little above
local YAW = math.rad(28) -- the 3/4 view
local YAW_SIDE = math.rad(68) -- long items (front-to-back) are seen from the side
local MARGIN = 1.12
-- models that read badly from the usual 3/4 view: pitch = how far the camera looks down, roll = turns
-- the picture (the long thin towel lies diagonally across its square), top = frame only this top
-- share of the model (the balloon, not its long string)
local VIEWS = {
	BananaPeel = { pitch = math.rad(42) },
	DryerSheet = { pitch = math.rad(34) },
	StaticBalloon = { top = 0.48 },
} :: { [string]: { pitch: number?, roll: number?, top: number? } }
local TOWEL_VIEW = { pitch = math.rad(50), roll = math.rad(-38) } -- a flat towel: from above, not edge-on
local AMBIENT = rgb(172, 166, 182) -- soft and even, like the sock pictures (SockCard)
local LIGHT = rgb(128, 120, 110)
local MARKERS = { "_Base", "_Unit", "_Grip", "_Tip", "_Pin" }
-- never copied into a picture: nothing may run or play there
local STRIP = { "LuaSourceContainer", "Sound", "Light", "ParticleEmitter", "Beam", "Trail", "Fire", "Smoke", "Sparkles", "Highlight", "ProximityPrompt", "ClickDetector" }

-- The towel looks (ItemConfig.TowelLooks + TowelRoyal): a name for the Item Shop and the colours
-- of the drawn towel shown until the 3D towel is there.
ItemIcon.Looks = {
	Plain    = { name = "Plain Blue",   color = rgb(150, 205, 255), trim = WHITE },
	Striped  = { name = "Candy Stripe", color = rgb(250, 250, 255), trim = rgb(232, 72, 88) },
	Beach    = { name = "Beach",        color = rgb(255, 196, 64),  trim = rgb(40, 196, 190) },
	Spa      = { name = "Fluffy Spa",   color = rgb(255, 250, 246), trim = rgb(255, 160, 196) },
	Sports   = { name = "Sports",       color = rgb(60, 176, 92),   trim = WHITE },
	Champion = { name = "Champion",     color = rgb(196, 36, 52),   trim = rgb(255, 206, 70) },
	Royal    = { name = "Royal",        color = rgb(124, 64, 196),  trim = rgb(255, 206, 70) },
} :: { [string]: { name: string, color: Color3, trim: Color3 } }

function ItemIcon.LookName(look: string?): string
	local l = if look then ItemIcon.Looks[look] else nil
	return if l then l.name else tostring(look or "Plain")
end

-- The ItemMeshes model an item shows (the towel: one per look; gold: the max-level `<model>_Gold`).
function ItemIcon.ModelName(key: string, look: string?, gold: boolean?): string?
	if key == "Towel" then
		return "Towel_" .. (look or ItemConfig.TowelLooks[1])
	end
	local item = ItemConfig.Items[key]
	local model = if item then item.model else nil
	if model and gold then
		return model .. GOLD
	end
	return model
end

-- ---------- preparing a model ----------

type Prepared = { master: Model, minV: Vector3, maxV: Vector3, name: string }

local prepared = {} :: { [Instance]: Prepared | false } -- false: that template can't be used

local function endsWith(name: string, suffix: string): boolean
	return #name >= #suffix and string.sub(name, -#suffix) == suffix
end

local function isMarker(name: string): boolean
	for _, suffix in ipairs(MARKERS) do
		if endsWith(name, suffix) then
			return true
		end
	end
	return false
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

-- A picture copy of a template: front (_Base -> _Unit) turned to +Z like the server's
-- MeshTemplate.Prepare, markers hidden, glow parts Neon, everything anchored. Nil if unusable.
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
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			if isMarker(d.Name) then
				d.Transparency = 1
			elseif endsWith(d.Name, "_Glow") then
				d.Material = Enum.Material.Neon
			end
		end
	end
	if base and unit then
		local offset = unit.Position - base.Position
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > 1e-4 then
			local angle = math.atan2(flat.X, flat.Z)
			local pivot = CFrame.new(base.Position)
			model:PivotTo(pivot * CFrame.Angles(0, -angle, 0) * pivot:Inverse() * model:GetPivot())
		end
	end
	local minV, maxV = visibleBounds(model)
	if not (minV and maxV) or (maxV - minV).Magnitude < 1e-3 then
		model:Destroy()
		return nil
	end
	return { master = model, minV = minV, maxV = maxV, name = template.Name }
end

local function folder(): Instance?
	return ReplicatedStorage:FindFirstChild(FOLDER)
end

local function preparedFor(name: string): Prepared?
	local f = folder()
	local template = if f then f:FindFirstChild(name) else nil
	if not template then
		return nil
	end
	local cached = prepared[template]
	if cached == nil then
		local ok, fresh = pcall(prepare, template)
		if not ok then
			warn("[ItemIcon] couldn't prepare " .. template:GetFullName() .. " for the menus: " .. tostring(fresh))
		end
		cached = if ok and fresh then fresh else false
		prepared[template] = cached
	end
	return if cached then cached else nil
end

-- A camera that fits the box into a square viewport and centres its picture. Returns the camera
-- and the point it looks at (a Spin turns the camera around it).
local function frameCamera(minV: Vector3, maxV: Vector3, name: string?): (CFrame, Vector3)
	-- a golden model is framed like its regular one
	local viewName = if name and endsWith(name, GOLD) then string.sub(name, 1, #name - #GOLD) else name
	local view = (viewName and (VIEWS[viewName] or (string.sub(viewName, 1, 6) == "Towel_" and TOWEL_VIEW))) or {}
	if view.top then
		minV = Vector3.new(minV.X, maxV.Y - (maxV.Y - minV.Y) * view.top, minV.Z)
	end
	local size = maxV - minV
	local yaw = if size.Z > size.X * 1.4 then YAW_SIDE else YAW
	local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(-(view.pitch or PITCH), 0, 0) * CFrame.Angles(0, 0, view.roll or 0)
	local corners = {}
	for _, x in ipairs({ minV.X, maxV.X }) do
		for _, y in ipairs({ minV.Y, maxV.Y }) do
			for _, z in ipairs({ minV.Z, maxV.Z }) do
				table.insert(corners, Vector3.new(x, y, z))
			end
		end
	end
	local t = math.tan(math.rad(FOV) / 2) / MARGIN
	local focus = (minV + maxV) / 2
	local dist = 1
	for pass = 1, 2 do
		-- far enough that every corner fits: |x|, |y| <= (dist - z) * t in camera space
		dist = 1
		for _, c in ipairs(corners) do
			local p = rot:VectorToObjectSpace(c - focus)
			dist = math.max(dist, p.Z + math.max(math.abs(p.X), math.abs(p.Y)) / t, p.Z + 1)
		end
		if pass == 2 then
			break
		end
		-- then aim so the picture sits in the middle
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
	return CFrame.new(focus) * rot * CFrame.new(0, 0, dist), focus
end

-- ---------- late models ----------

local waiting = {} :: { [string]: { [any]: boolean } } -- model name -> icons that would show it (a fallback or a lesser model is up)

local function notify(name: string?)
	-- gather first: a refresh changes what the icons wait for
	local due = {} :: { [any]: boolean }
	for modelName, icons in pairs(waiting) do
		if name == nil or modelName == name then
			for icon in pairs(icons) do
				due[icon] = true
			end
		end
	end
	for icon in pairs(due) do
		task.spawn(icon.Refresh, icon)
	end
end

local function watchFolder(f: Instance)
	f.ChildAdded:Connect(function(child)
		task.delay(0.3, notify, child.Name) -- a moment for its parts to finish arriving
	end)
end

do
	local existing = folder()
	if existing then
		watchFolder(existing)
	end
	ReplicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == FOLDER then
			watchFolder(child)
			task.delay(0.3, notify, nil)
		end
	end)
end

-- ---------- the drawn fallbacks ----------

-- A rolled towel lying at an angle: the look's colour, two hem stripes, a gloss.
local function drawnTowel(parent: Instance, look: string?): Frame
	local l = ItemIcon.Looks[look or "Plain"] or ItemIcon.Looks.Plain
	local holder = Instance.new("Frame")
	holder.Name = "DrawnTowel"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = parent
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.52)
	body.Size = UDim2.fromScale(0.84, 0.3)
	body.Rotation = -32
	body.BackgroundColor3 = WHITE
	body.BorderSizePixel = 0
	Theme.corner(body, UDim.new(0.5, 0))
	Theme.stroke(body, l.color:Lerp(BLACK, 0.5), 2.5)
	Theme.gradient(body, l.color:Lerp(WHITE, 0.3), l.color:Lerp(BLACK, 0.08))
	body.Parent = holder
	for _, x in ipairs({ 0.2, 0.8 }) do
		local stripe = Instance.new("Frame")
		stripe.Name = "Stripe"
		stripe.AnchorPoint = Vector2.new(0.5, 0.5)
		stripe.Position = UDim2.fromScale(x, 0.5)
		stripe.Size = UDim2.fromScale(0.09, 1)
		stripe.BackgroundColor3 = l.trim
		stripe.BorderSizePixel = 0
		stripe.Parent = body
	end
	Theme.gloss(body, 8)
	return holder
end

local function emoji(parent: Instance, text: string): TextLabel
	local t = Theme.label(parent, text, 40, WHITE)
	t.Name = "Emoji"
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Position = UDim2.fromScale(0.5, 0.5)
	t.Size = UDim2.fromScale(0.78, 0.78)
	t.TextScaled = true
	return t
end

-- ---------- the icon ----------

function ItemIcon.new(parent: Instance?, opts: { [string]: any }?)
	local o = opts or {}
	local root = Instance.new("Frame")
	root.Name = "ItemIcon"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = if type(o.size) == "number" then UDim2.fromOffset(o.size, o.size) else UDim2.fromScale(1, 1)
	if type(o.zIndex) == "number" then
		root.ZIndex = o.zIndex
	end
	root.Parent = parent

	local icon = { Frame = root }
	local curKey: string? = nil
	local curLook: string? = nil
	local curGold = false
	local names = {} :: { string } -- the models this icon would show, best first (gold, then regular)
	local shown: Prepared? = nil -- the prepared model on screen (nil: the fallback)
	local vp: ViewportFrame? = nil
	local world: WorldModel? = nil
	local model: Model? = nil
	local fallback: GuiObject? = nil
	local destroyed = false
	local shownCF: CFrame? = nil -- the camera framing the model on screen, and the point it looks at
	local shownFocus: Vector3? = nil
	local spinConn: RBXScriptConnection? = nil

	local function stopSpin()
		if spinConn then
			spinConn:Disconnect()
			spinConn = nil
		end
	end

	local function unwait()
		for _, name in ipairs(names) do
			local list = waiting[name]
			if list then
				list[icon] = nil
				if next(list) == nil then
					waiting[name] = nil
				end
			end
		end
	end

	-- waits for names[1..upTo] (the models better than the one on screen)
	local function waitFor(upTo: number)
		for i = 1, math.min(upTo, #names) do
			local name = names[i]
			local list = waiting[name]
			if not list then
				list = {}
				waiting[name] = list
			end
			list[icon] = true
		end
	end

	local function clear()
		stopSpin()
		if model then
			model:Destroy()
			model = nil
		end
		if fallback then
			fallback:Destroy()
			fallback = nil
		end
		if vp then
			vp.Visible = false
		end
		shown = nil
	end

	local function show3D(p: Prepared)
		clear()
		if not vp then
			local f = Instance.new("ViewportFrame")
			f.Name = "Viewport"
			f.BackgroundTransparency = 1
			f.Size = UDim2.fromScale(1, 1)
			f.Ambient = AMBIENT
			f.LightColor = LIGHT
			f.Parent = root
			local w = Instance.new("WorldModel") -- skinned meshes (the towel) need one to show their bones' pose
			w.Parent = f
			local cam = Instance.new("Camera")
			cam.FieldOfView = FOV
			cam.Parent = f
			f.CurrentCamera = cam
			vp = f
			world = w
		end
		local f = vp :: ViewportFrame
		local cam = f.CurrentCamera
		local copy = p.master:Clone()
		copy.Parent = world
		model = copy
		local cf, focus = frameCamera(p.minV, p.maxV, p.name)
		if cam then
			cam.CFrame = cf
		end
		f.LightDirection = cf:VectorToWorldSpace(Vector3.new(0.55, -0.8, -0.6)).Unit -- from the upper left, in front
		f.Visible = true
		shown = p
		shownCF, shownFocus = cf, focus
	end

	local function showFallback()
		clear()
		local key = curKey
		if not key then
			return
		end
		if key == "Towel" then
			fallback = drawnTowel(root, curLook)
		else
			local item = ItemConfig.Items[key]
			fallback = emoji(root, if item then item.icon else "❔")
		end
	end

	-- The best model that is there now (it keeps waiting for the better ones), else the fallback.
	local function apply()
		unwait()
		for rank, name in ipairs(names) do
			local p = preparedFor(name)
			if p then
				if shown ~= p then
					show3D(p)
				end
				waitFor(rank - 1)
				return
			end
		end
		if shown or not fallback then
			showFallback()
		end
		waitFor(#names)
	end

	-- Shows the best model there now (waiting icons are refreshed by the folder listener).
	function icon.Refresh(_self)
		if destroyed or not curKey then
			return
		end
		apply()
	end

	function icon:Set(key: string?, look: string?, gold: boolean?)
		if destroyed then
			return
		end
		local g = gold == true and key ~= nil and key ~= "Towel"
		if key == curKey and look == curLook and g == curGold then
			return
		end
		unwait()
		curKey, curLook, curGold = key, look, g
		names = {}
		clear()
		if not key then
			return
		end
		local name = ItemIcon.ModelName(key, look)
		if name then
			if g then
				table.insert(names, name .. GOLD)
			end
			table.insert(names, name)
		end
		apply()
	end

	function icon:Is3D(): boolean
		return shown ~= nil
	end

	function icon:Shown(): string?
		return if shown then shown.name else nil
	end

	-- One turntable turn that slows down and settles facing front (the golden flourish). The
	-- fallback emoji spins flat instead.
	function icon:Spin(seconds: number?)
		if destroyed then
			return
		end
		local length = math.max(seconds or 1, 0.1)
		stopSpin()
		local f = vp
		local cam = if f then f.CurrentCamera else nil
		local baseCF, focus = shownCF, shownFocus
		if shown and cam and baseCF and focus then
			local pivot = CFrame.new(focus)
			local start = os.clock()
			local conn
			conn = RunService.RenderStepped:Connect(function()
				local a = math.clamp((os.clock() - start) / length, 0, 1)
				local turn = (1 - a) ^ 3 * math.pi * 2 -- fast at first, easing into place
				cam.CFrame = pivot * CFrame.Angles(0, turn, 0) * pivot:Inverse() * baseCF
				if a >= 1 then
					conn:Disconnect()
					if spinConn == conn then
						spinConn = nil
					end
				end
			end)
			spinConn = conn
		elseif fallback then
			fallback.Rotation = -360
			TweenService:Create(fallback, TweenInfo.new(length, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), { Rotation = 0 }):Play()
		end
	end

	function icon:Destroy()
		if destroyed then
			return
		end
		destroyed = true
		stopSpin()
		unwait()
		root:Destroy()
	end

	root.Destroying:Once(function()
		if not destroyed then
			destroyed = true
			stopSpin()
			unwait()
		end
	end)

	if type(o.key) == "string" then
		icon:Set(o.key, if type(o.look) == "string" then o.look else nil, o.gold == true)
	end
	return icon
end

return ItemIcon
