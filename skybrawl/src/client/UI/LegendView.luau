--[[
    The menus' 3D legends (menus design 5.5): a transparent ViewportFrame
    showing a legend's rig (LegendRig) holding its menu weapon, or your own
    avatar's look from ReplicatedStorage.AvatarModels.<UserId> (built by the
    server, since only it can make a model from a HumanoidDescription),
    animated by FighterAnimator as a preview (previews survive matches and
    always play at 1x).

    view:set(spec) never yields: it shows the cached model for the spec at
    once, else builds it in a task.spawn (waiting for AvatarModels if it
    must) and shows the coloured placeholder meanwhile. A build that
    finishes after a newer set() is cached but not shown, so a slow avatar
    can never replace a newer pick. Models are cached per view by
    legend|ownLook|userId|weapon and swapped by Parent (the old one leaves
    and is untracked), so key-repeat across a legend grid builds nothing
    twice; destroy() destroys the cache.

    Framing ("height" below is the body height, feet to head top):
      Full  the frame is height / 0.66 tall and 0.8x as wide; the feet sit
            4% above its bottom and 30% of it is headroom for raised
            weapons (FOV 30). LegendView.fullFrame works out the frame.
      Bust  chest up (FOV 22). Head: head and shoulders (FOV 14).
    Facing: Left = yaw -30 (faces screen-left), Right = +30, Front = 0.

    Portraits (LegendView.portrait) are always still: Config.Art.Portraits'
    image when set, your avatar's headshot for Avatar / own look, else one
    still head-framed model in its own ViewportFrame, reused per legend.
    LegendView.group puts several animated legends in one ViewportFrame
    (the title screen).

    Before the first LegendRig call the client waits (once) for the game to
    finish loading (game.Loaded: the initial replication, FighterModels and
    every model in it, is complete) and then up to 3 s for
    ReplicatedStorage.FighterModels, so LegendRig's permanent miss cache
    can't lock in placeholders while the art is still replicating, however
    early a view is made (the menu, built before the title, makes some).

    A legend that can't be built shows the coloured placeholder (its colour,
    its name, "3D model not imported") in every kind of view, groups too.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local LegendRig = require(Shared.LegendRig)
local Legends = require(Shared.Legends)
local Util = require(Shared.Util)
local WeaponModels = require(Shared.WeaponModels)

local Client = script.Parent.Parent
local FighterAnimator = require(Client:WaitForChild("Controllers"):WaitForChild("FighterAnimator"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Layout = require(script.Parent:WaitForChild("Layout"))

local LegendView = {}

local T = UIKit.Theme
local make = UIKit.make

local AMBIENT = Color3.fromRGB(170, 170, 185)
local LIGHT_COLOR = Color3.fromRGB(255, 250, 240)
local LIGHT_DIRECTION = Vector3.new(-0.4, -1, 0.6)
local YAW = { Left = -30, Right = 30, Front = 0 }
local PORTRAIT_YAW = -18
local AVATAR_WAIT = 10

-- What part of the body each framing shows, as fractions of the body height, and its vertical FOV.
local FRAMINGS = {
	Full = { bottom = -0.04 / 0.66, top = 0.96 / 0.66, fov = 30 },
	Bust = { bottom = 0.5, top = 1.12, fov = 22 },
	Head = { bottom = 0.66, top = 1.08, fov = 14 },
}

-- FighterModels ------------------------------------------------------------------

local modelsReady = false
local modelsWaiters = nil

-- Waits (once per client) for the game to load, then up to 3 s for the imported fighter art.
local function waitForModels()
	if modelsReady then
		return
	end
	if modelsWaiters then
		table.insert(modelsWaiters, coroutine.running())
		coroutine.yield()
		return
	end
	modelsWaiters = {}
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	ReplicatedStorage:WaitForChild("FighterModels", 3)
	modelsReady = true
	local waiters = modelsWaiters
	for _, thread in waiters do
		task.spawn(thread)
	end
end

-- Building ------------------------------------------------------------------------

-- The weapon a legend holds in the menus (nil for Avatar).
function LegendView.weaponFor(legendId)
	local menuWeapon = Config.Art.MenuWeapons[legendId]
	if menuWeapon then
		return menuWeapon
	end
	local weapons = Legends.get(legendId).Weapons
	return weapons and weapons[1] or nil
end

local function specKey(spec)
	local userId = spec.userId or Players.LocalPlayer.UserId
	local ownLook = spec.ownLook == true or Legends.usesAvatar(spec.legend)
	return table.concat({
		tostring(spec.legend),
		tostring(ownLook),
		if ownLook then tostring(userId) else "",
		tostring(spec.weapon or ""),
	}, "|")
end

local function strip(model)
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("BillboardGui") or d:IsA("Sound") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
end

local function holdWeapon(model, legendId, weaponId)
	if weaponId then
		pcall(WeaponModels.attach, model, weaponId, nil, Legends.weaponSkin(legendId, weaponId))
	end
end

--[[
    Builds the model for a spec, feet at the origin, facing -Z, `height`
    studs tall for a legend rig (avatars keep their own size). spec.weapon =
    false builds it empty-handed. May yield (art and avatar waits). Returns
    { model, height, pivotY (the pivot's height above the feet), legend,
    weapon } or nil.
]]
local function buildModel(spec, height)
	local legendId = spec.legend
	if not Legends.isValid(legendId) then
		return nil
	end
	local avatarLook = Legends.usesAvatar(legendId) or spec.ownLook == true
	local weaponId = spec.weapon
	if weaponId == nil and not Legends.usesAvatar(legendId) then
		weaponId = LegendView.weaponFor(legendId)
	end
	if avatarLook then
		local folder = ReplicatedStorage:WaitForChild("AvatarModels", AVATAR_WAIT)
		local userId = spec.userId or Players.LocalPlayer.UserId
		local source = folder and folder:WaitForChild(tostring(userId), AVATAR_WAIT)
		if not source then
			return nil
		end
		local ok, model = pcall(function()
			return source:Clone()
		end)
		local root = ok and model and model:FindFirstChild("HumanoidRootPart")
		if not root then
			return nil
		end
		strip(model)
		root.Anchored = true
		model.PrimaryPart = root
		local feet = Util.feetOffset(model)
		model:PivotTo(CFrame.new(0, feet, 0))
		local cf, size = model:GetBoundingBox()
		holdWeapon(model, legendId, weaponId)
		return {
			model = model,
			height = math.max(1, cf.Position.Y + size.Y / 2),
			pivotY = feet,
			legend = legendId,
			weapon = weaponId,
		}
	end
	waitForModels()
	local rig = LegendRig.build(legendId, height or Config.Art.FighterHeight)
	if not rig then
		return nil
	end
	strip(rig)
	rig.PrimaryPart.Anchored = true
	holdWeapon(rig, legendId, weaponId)
	return {
		model = rig,
		height = height or Config.Art.FighterHeight,
		pivotY = 0,
		legend = legendId,
		weapon = weaponId,
	}
end

-- Camera for one model `height` tall at the origin, framed for `framing`.
local function frameCamera(camera, height, framing)
	local f = FRAMINGS[framing] or FRAMINGS.Full
	local bottom, top = f.bottom * height, f.top * height
	local view = top - bottom
	local distance = view / (2 * math.tan(math.rad(f.fov) / 2))
	local centre = (bottom + top) / 2
	camera.FieldOfView = f.fov
	camera.CFrame = CFrame.lookAt(Vector3.new(0, centre, -distance), Vector3.new(0, centre, 0))
end

local function newViewport(name, parent, opts)
	local frame = make("ViewportFrame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Ambient = AMBIENT,
		LightColor = LIGHT_COLOR,
		LightDirection = LIGHT_DIRECTION,
	})
	local brightness = opts and opts.brightness or 1
	frame.ImageColor3 = Color3.new(brightness, brightness, brightness)
	if opts then
		frame.Position = opts.position or frame.Position
		if typeof(opts.size) == "UDim2" then
			frame.Size = opts.size
		end
		frame.AnchorPoint = opts.anchor or frame.AnchorPoint
		frame.ZIndex = opts.zIndex or frame.ZIndex
		frame.LayoutOrder = opts.layoutOrder or frame.LayoutOrder
		frame.Name = opts.name or frame.Name
	end
	local world = make("WorldModel", { Parent = frame })
	local camera = make("Camera", { Parent = frame })
	frame.CurrentCamera = camera
	frame.Parent = parent or (opts and opts.parent)
	return frame, world, camera
end

-- The coloured card shown while a model builds or when there is no 3D art (`props` place it; default: centred
-- in `frame`). Returns show(spec, visible, building).
local function newPlaceholder(frame, props)
	local holder = make("Frame", {
		Name = "Placeholder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.56),
		Size = UDim2.fromScale(0.62, 0.36),
		ZIndex = frame.ZIndex + 1,
		Visible = false,
	})
	for key, value in props or {} do
		holder[key] = value
	end
	holder.Parent = frame
	local card = UIKit.slantFrame({ parent = holder, fill = T.Raised, outline = 4, zIndex = holder.ZIndex })
	local name = make("TextLabel", {
		Name = "LegendName",
		BackgroundTransparency = 1,
		Font = T.HeadFont,
		TextColor3 = T.Text,
		Size = UDim2.fromScale(1, 0.6),
		ZIndex = holder.ZIndex + 6,
		Parent = card.Content,
	})
	Layout.bindText(name, 48)
	local note = make("TextLabel", {
		Name = "Note",
		BackgroundTransparency = 1,
		Font = T.BoldFont,
		Text = "3D model not imported",
		TextColor3 = T.Text,
		TextTransparency = 0.25,
		TextWrapped = true,
		Position = UDim2.fromScale(0, 0.58),
		Size = UDim2.fromScale(1, 0.34),
		ZIndex = holder.ZIndex + 6,
		Parent = card.Content,
	})
	Layout.bindText(note, 16)
	return function(spec, visible, building)
		holder.Visible = visible
		if visible and spec then
			local legend = Legends.get(spec.legend)
			UIKit.setSlantFill(card, legend.Color)
			name.Text = string.upper(legend.Name)
			note.Text = if building then "Loading..." else "3D model not imported"
		end
	end
end

local function trackModel(entry, animated, flourish)
	local opts = { preview = true, legend = entry.legend, weapon = entry.weapon }
	if animated then
		FighterAnimator.track(entry.model, opts)
		FighterAnimator.setLocomotion(entry.model, "Idle")
		if flourish then
			FighterAnimator.playClip(entry.model, "Loco.Awaken", 1.1)
		end
	else
		FighterAnimator.still(entry.model, opts)
	end
end

-- Views ----------------------------------------------------------------------------

--[[
    The frame for a Full-framed legend whose feet sit at (x, feetY) of the
    parent with body height `bodyHeight` (fractions of the parent's height):
    returns position, size, anchor for LegendView.new (the view keeps a 0.8
    width : height aspect).
]]
function LegendView.fullFrame(x, feetY, bodyHeight)
	local height = bodyHeight / 0.66
	return UDim2.fromScale(x, feetY + 0.04 * height), UDim2.fromScale(height * 0.8, height), Vector2.new(0.5, 1)
end

--[[
    opts = { framing: "Full" | "Bust" | "Head"?, facing: "Left" | "Right" | "Front"?,
    brightness: number?, animated: boolean? (default true) } & Common. Returns
    { frame: ViewportFrame, set(self, spec), clear(self), destroy(self) } with
    spec = { legend, userId?, ownLook?, weapon?, flourish? }.
]]
function LegendView.new(parent, opts)
	opts = opts or {}
	local framing = opts.framing or "Full"
	local frame, world, camera = newViewport("LegendView", parent, opts)
	if framing == "Full" then
		make("UIAspectRatioConstraint", {
			AspectRatio = 0.8,
			DominantAxis = Enum.DominantAxis.Height,
			Parent = frame,
		})
	end
	local showPlaceholder = newPlaceholder(frame)
	local animated = opts.animated ~= false
	local yaw = YAW[opts.facing or "Front"] or 0
	local view = { frame = frame }
	local cache = {} -- [key] = entry
	local building = {} -- [key] = true while its build runs
	local shown = nil
	local shownKey = nil
	local wantedKey = nil -- the latest set()'s key: a build that finishes only shows if it is still wanted
	local destroyed = false

	local function hideShown()
		if shown then
			FighterAnimator.untrack(shown.model)
			shown.model.Parent = nil
			shown = nil
		end
		shownKey = nil
	end

	local function show(entry, key, spec)
		if shown ~= entry then
			hideShown()
		end
		shown, shownKey = entry, key
		showPlaceholder(nil, false)
		entry.model:PivotTo(CFrame.new(0, entry.pivotY, 0) * CFrame.Angles(0, math.rad(yaw), 0))
		entry.model.Parent = world
		frameCamera(camera, entry.height, framing)
		trackModel(entry, animated, spec.flourish)
	end

	function view:set(spec)
		if destroyed or type(spec) ~= "table" then
			return
		end
		local key = specKey(spec)
		wantedKey = key
		if key == shownKey and shown then
			if spec.flourish and animated then
				FighterAnimator.playClip(shown.model, "Loco.Awaken", 1.1)
			end
			return
		end
		local cached = cache[key]
		if cached then
			show(cached, key, spec)
			return
		end
		if not building[key] then
			building[key] = true
			task.spawn(function()
				local ok, entry = pcall(buildModel, spec, nil)
				building[key] = nil
				if not ok then
					warn("[LegendView]", entry)
					entry = nil
				end
				if destroyed then
					if entry then
						entry.model:Destroy()
					end
					return
				end
				if entry then
					cache[key] = entry
				end
				if wantedKey ~= key then
					return
				end
				if entry then
					show(entry, key, spec)
				else
					hideShown()
					showPlaceholder(spec, true, false)
				end
			end)
		end
		if building[key] then
			-- still building (waiting for the art or the avatar)
			hideShown()
			showPlaceholder(spec, true, true)
		end
	end

	function view:clear()
		wantedKey = nil
		hideShown()
		showPlaceholder(nil, false)
	end

	function view:destroy()
		if destroyed then
			return
		end
		destroyed = true
		wantedKey = nil
		for _, entry in cache do
			FighterAnimator.untrack(entry.model)
			entry.model:Destroy()
		end
		table.clear(cache)
		shown = nil
		frame:Destroy()
	end

	return view
end

-- Portraits ------------------------------------------------------------------------------

local headshots = {} -- [userId] = image content

local function headshot(userId, apply)
	if headshots[userId] then
		apply(headshots[userId])
		return
	end
	if type(userId) ~= "number" or userId <= 0 then
		return
	end
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if ok and type(content) == "string" then
			headshots[userId] = content
			apply(content)
		end
	end)
end

--[[
    A still head-and-shoulders portrait: { frame, set(spec), destroy() } with
    spec = { legend, userId?, ownLook? }. set() only changes what changed.
]]
function LegendView.portrait(parent, spec, opts)
	opts = opts or {}
	local frame = make("Frame", {
		Name = "Portrait",
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
	})
	if opts.position then
		frame.Position = opts.position
	end
	if typeof(opts.size) == "UDim2" then
		frame.Size = opts.size
	end
	frame.AnchorPoint = opts.anchor or frame.AnchorPoint
	frame.ZIndex = opts.zIndex or frame.ZIndex
	frame.LayoutOrder = opts.layoutOrder or frame.LayoutOrder
	frame.Name = opts.name or frame.Name
	frame.Parent = parent or opts.parent
	local zIndex = frame.ZIndex
	local image = make("ImageLabel", {
		Name = "Image",
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Crop,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex + 1,
		Visible = false,
		Parent = frame,
	})
	local viewport, world, camera = newViewport("Head", frame, { zIndex = zIndex + 1 })
	viewport.Visible = false
	local models = {} -- [legendId] = entry
	local currentKey = nil
	local generation = 0
	local destroyed = false

	local function showModel(legendId)
		for id, entry in models do
			if id ~= legendId and entry.model.Parent then
				FighterAnimator.untrack(entry.model)
				entry.model.Parent = nil
			end
		end
		local entry = models[legendId]
		if entry then
			if entry.model.Parent ~= world then
				entry.model.Parent = world
				FighterAnimator.still(entry.model, { legend = legendId, weapon = entry.weapon })
			end
			frameCamera(camera, entry.height, "Head")
			viewport.Visible = true
		end
	end

	local function set(newSpec)
		if destroyed or type(newSpec) ~= "table" then
			return
		end
		local legendId = newSpec.legend
		local userId = newSpec.userId or Players.LocalPlayer.UserId
		local avatarLook = Legends.usesAvatar(legendId) or newSpec.ownLook == true
		local key = if avatarLook then "user" .. tostring(userId) else tostring(legendId)
		frame.BackgroundColor3 = Legends.get(legendId).Color
		if key == currentKey then
			return
		end
		currentKey = key
		generation += 1
		local gen = generation
		local art = Config.Art.Portraits[legendId]
		local imageId = if avatarLook then "" else UIKit.assetId(art)
		image.Visible = false
		viewport.Visible = false
		if avatarLook then
			headshot(userId, function(content)
				if not destroyed and gen == generation then
					image.Image = content
					image.Visible = true
				end
			end)
		elseif imageId ~= "" then
			image.Image = imageId
			image.Visible = true
		elseif models[legendId] then
			showModel(legendId)
		else
			task.spawn(function()
				local ok, entry = pcall(buildModel, { legend = legendId, weapon = false }, nil)
				if not ok or not entry or destroyed then
					if ok and entry then
						entry.model:Destroy()
					end
					return
				end
				entry.model:PivotTo(CFrame.Angles(0, math.rad(PORTRAIT_YAW), 0))
				models[legendId] = entry
				if gen == generation then
					showModel(legendId)
				end
			end)
		end
	end

	local function destroy()
		destroyed = true
		for _, entry in models do
			FighterAnimator.untrack(entry.model)
			entry.model:Destroy()
		end
		table.clear(models)
		frame:Destroy()
	end

	set(spec)
	return { frame = frame, set = set, destroy = destroy }
end

-- Groups ---------------------------------------------------------------------------------

--[[
    Several animated legends in one ViewportFrame (the title screen).
    opts = { brightness?, zIndex? }; entries = { { spec, x, height, facing } }:
    each legend's feet sit on the frame's bottom edge at fraction x of its
    width, its body `height` a fraction of the frame's height. Returns
    { frame, destroy() }.
]]
function LegendView.group(parent, opts, entries)
	opts = opts or {}
	local frame, world, camera = newViewport("LegendGroup", parent, {
		brightness = opts.brightness,
		zIndex = opts.zIndex,
	})
	local fov = 20
	local viewHeight = 10 -- studs at the models' plane
	local distance = viewHeight / (2 * math.tan(math.rad(fov) / 2))
	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(Vector3.new(0, viewHeight / 2, -distance), Vector3.new(0, viewHeight / 2, 0))
	local built = {} -- { { entry, x } }
	local destroyed = false
	-- placeholders for legends that can't be built, in a plain frame over the view (not inside the ViewportFrame)
	local cards = make("Frame", {
		Name = "LegendGroupCards",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = frame.ZIndex,
		Parent = parent,
	})

	local function place()
		local size = frame.AbsoluteSize
		local aspect = if size.Y > 0 then size.X / size.Y else 16 / 9
		for _, item in built do
			-- the camera looks along +Z, so screen right is world -X
			local worldX = -(item.x - 0.5) * viewHeight * aspect
			local yaw = YAW[item.facing or "Front"] or 0
			item.entry.model:PivotTo(CFrame.new(worldX, item.entry.pivotY, 0) * CFrame.Angles(0, math.rad(yaw), 0))
		end
	end
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)

	for _, item in entries do
		task.spawn(function()
			local ok, entry = pcall(buildModel, item.spec, item.height * viewHeight)
			if not ok then
				warn("[LegendView]", entry)
				entry = nil
			end
			if destroyed then
				if entry then
					entry.model:Destroy()
				end
				return
			end
			if not entry then
				-- the coloured card where the legend would stand: its middle at half its body height
				local show = newPlaceholder(cards, {
					Position = UDim2.fromScale(item.x, 1 - item.height * 0.45),
					Size = UDim2.fromScale(item.height * 0.5, item.height * 0.28),
					SizeConstraint = Enum.SizeConstraint.RelativeYY,
					ZIndex = cards.ZIndex,
				})
				show(item.spec, true, false)
				return
			end
			-- avatars keep their own height: scale them to the wanted body height
			local wanted = item.height * viewHeight
			if math.abs(entry.height - wanted) > 0.05 then
				pcall(function()
					local factor = wanted / entry.height
					entry.model:ScaleTo(entry.model:GetScale() * factor)
					entry.pivotY *= factor
					entry.height = wanted
				end)
			end
			table.insert(built, { entry = entry, x = item.x, facing = item.facing })
			place()
			entry.model.Parent = world
			trackModel(entry, true, false)
		end)
	end

	return {
		frame = frame,
		destroy = function()
			destroyed = true
			for _, item in built do
				FighterAnimator.untrack(item.entry.model)
			end
			frame:Destroy()
			cards:Destroy()
		end,
	}
end

return LegendView
