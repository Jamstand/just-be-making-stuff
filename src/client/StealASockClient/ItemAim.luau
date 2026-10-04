-- ItemAim: towel aiming help for this player (ItemClient uses it).
--   * Aim assist (touch screens and gamepads only - ItemClient decides when): a snap turns to the
--     nearest target in reach - a thief first (someone carrying a sock), else the nearest other
--     player - within ItemConfig.TowelAssistCone of where you face or tapped (a cos(): 0 = 90 degrees
--     either side). The server still decides every hit; this only picks the `aim` it is sent.
--   * The towel's reach: the State's `towelReach` if the server sends one, else the Towel Snap
--     level's reach (ShopConfig, EconomyConfig.TowelRange at level 0) x StoreConfig.GoldenTowelMult
--     with the Golden Towel pass - the same numbers Upgrades.TowelRange uses on the server.
--   * The reach arc: while you hold the towel, a faint dotted arc on the floor in front of you shows
--     the hit cone (ItemConfig.TowelCone) and the reach. It turns red while a thief is inside, opens
--     wider and gold when your next crack is the combo finisher (ItemConfig.TowelCombo.cone), and
--     pulses bright on the finisher crack. Pooled flat parts in the camera: only you see it.
-- API: ItemAim.SetState(state), ItemAim.Reach(), ItemAim.Pick(root, dir) -> (Player?, Vector3?, thief),
--   ItemAim.SetFinisherNext(on), ItemAim.Pulse(), ItemAim.Update(dt, show), ItemAim.Tint(),
--   ItemAim.Shown(), ItemAim.Thieves()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local ItemConfig = require(Config:WaitForChild("ItemConfig"))
local ShopConfig = require(Config:WaitForChild("ShopConfig"))
local StoreConfig = require(Config:WaitForChild("StoreConfig"))
local EconomyConfig = require(Config:WaitForChild("EconomyConfig"))

local ItemAim = {}

local EDGE = 11 -- dashes along the reach edge
local SIDE = 4 -- dashes along each side of the cone
local NEAR = 1.4 -- studs from you where the sides start
local FAINT = 0.72 -- the arc's transparency at rest
local PULSE = 0.35 -- seconds of the finisher pulse
local THIEF_CHECK = 0.1 -- seconds between "is a thief inside?" checks
local PLAIN = Color3.fromRGB(205, 235, 255)
local THIEF = Color3.fromRGB(255, 95, 85)
local FINISH = Color3.fromRGB(255, 212, 90)

local me = Players.LocalPlayer
local state: { [string]: any }? = nil
local finisherNext = false
local pulseAt = -math.huge
local tint = "plain"
local lastThiefCheck = -math.huge
local shown = false
local floorY: number? = nil

local folder: Folder? = nil
local dashes: { Part } = {}
local rayParams: RaycastParams? = nil
local rayFor: Model? = nil

-- ---------- reach and targets ----------

function ItemAim.SetState(s: any)
	if type(s) == "table" then
		state = s
	end
end

-- The look's Towel Snap level when there is no State yet (Plain = 0 ... Champion = 5).
local function levelFromLook(): (number?, boolean)
	local character = me and me.Character
	local tool = character and character:FindFirstChild("Item_Towel")
	local look = tool and tool:GetAttribute("Look")
	if look == ItemConfig.TowelRoyal then
		return nil, true
	end
	local i = if type(look) == "string" then table.find(ItemConfig.TowelLooks, look) else nil
	return if i then i - 1 else nil, false
end

-- The towel's reach in studs (the server's Upgrades.TowelRange).
function ItemAim.Reach(): number
	local s = state
	if s and type(s.towelReach) == "number" and s.towelReach > 0 then
		return s.towelReach
	end
	local level: number? = nil
	local golden = false
	if s then
		local ups = s.upgrades
		level = if type(ups) == "table" and type(ups.Towel) == "number" then ups.Towel else 0
		golden = type(s.passes) == "table" and s.passes.GoldenTowel == true
	else
		level, golden = levelFromLook()
	end
	local towel = ShopConfig.Upgrades.Towel
	local entry = if level and level > 0 then towel.levels[math.min(level, #towel.levels)] else nil
	local range = if entry then entry.value else EconomyConfig.TowelRange
	if golden then
		range *= StoreConfig.GoldenTowelMult
	end
	return range
end

-- Who carries a sock right now (by UserId).
function ItemAim.Thieves(): { [number]: boolean }
	local out = {}
	local root = workspace:FindFirstChild("StealASock")
	local carried = root and root:FindFirstChild("Carried")
	if carried then
		for _, model in ipairs(carried:GetChildren()) do
			local id = model:GetAttribute("CarrierId")
			if type(id) == "number" then
				out[id] = true
			end
		end
	end
	return out
end

local function flat(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else nil
end

-- The target a snap toward `dir` (horizontal) should turn to: the nearest thief within `cone` (a
-- cos()) and the reach, else the nearest other player. Returns the player, the flat direction to
-- them and whether they're a thief.
function ItemAim.Pick(root: BasePart, dir: Vector3, cone: number?): (Player?, Vector3?, boolean)
	local base = flat(dir)
	if not base then
		return nil, nil, false
	end
	local minDot = if type(cone) == "number" then cone else ItemConfig.TowelAssistCone
	local reach = ItemAim.Reach()
	local thieves = ItemAim.Thieves()
	local best: Player?, bestDir: Vector3?, bestDist, bestThief = nil, nil, math.huge, false
	for _, p in ipairs(Players:GetPlayers()) do
		local character = p.Character
		local theirs = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if p ~= me and theirs and theirs:IsA("BasePart") and humanoid and humanoid.Health > 0 then
			local offset = theirs.Position - root.Position
			local dist = offset.Magnitude
			local f = flat(offset)
			local inCone = f == nil or base:Dot(f) >= minDot
			if dist <= reach and inCone then
				local thief = thieves[p.UserId] == true
				-- a thief beats anyone; then the nearest
				if (thief and not bestThief) or (thief == bestThief and dist < bestDist) then
					best, bestDir, bestDist, bestThief = p, f or base, dist, thief
				end
			end
		end
	end
	return best, bestDir, bestThief
end

-- ---------- the reach arc ----------

function ItemAim.SetFinisherNext(on: boolean)
	finisherNext = on
end

function ItemAim.Pulse()
	pulseAt = os.clock()
end

function ItemAim.Tint(): string
	return tint
end

function ItemAim.Shown(): boolean
	return shown
end

local function build(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "ItemReachArc"
	dashes = {}
	for i = 1, EDGE + SIDE * 2 do
		local p = Instance.new("Part")
		p.Name = "Dash" .. i
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = PLAIN
		p.Transparency = FAINT
		p.Size = Vector3.new(0.14, 0.04, 0.6)
		p.Parent = made
		table.insert(dashes, p)
	end
	folder = made
	return made
end

local function hide()
	if shown then
		shown = false
		local f = folder
		if f then
			f.Parent = nil
		end
	end
end

local function floorUnder(character: Model, root: BasePart): number
	local params = rayParams
	if not params or rayFor ~= character then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character, workspace.CurrentCamera }
		rayParams = params
		rayFor = character
	end
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -12, 0), params)
	local y = if hit then hit.Position.Y else root.Position.Y - 3
	local last = floorY
	floorY = if last and math.abs(last - y) < 1.5 then last + (y - last) * 0.35 else y
	return floorY :: number
end

-- Every frame (ItemClient): `show` = the towel is in your hand.
function ItemAim.Update(_dt: number, show: boolean)
	local character = me and me.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not show or not character or not root or not root:IsA("BasePart") then
		hide()
		return
	end
	local forward = flat(root.CFrame.LookVector)
	if not forward then
		hide()
		return
	end
	local f = build()
	if not shown then
		shown = true
		f.Parent = workspace.CurrentCamera
	end
	local reach = ItemAim.Reach()
	local cone = if finisherNext then ItemConfig.TowelCombo.cone else ItemConfig.TowelCone
	local half = math.acos(math.clamp(cone, -1, 1))
	local t = os.clock()
	-- a thief inside the cone? (10 times a second)
	if t - lastThiefCheck >= THIEF_CHECK then
		lastThiefCheck = t
		local _, _, thief = ItemAim.Pick(root, forward, cone)
		tint = if thief then "thief" elseif finisherNext then "finisher" else "plain"
	end
	local color = if tint == "thief" then THIEF elseif tint == "finisher" then FINISH else PLAIN
	local pulse = t - pulseAt
	local glow = if pulse < PULSE then 1 - pulse / PULSE else 0
	local transparency = FAINT - (FAINT - 0.15) * glow - (if tint == "thief" then 0.15 else 0)
	local width = 0.14 + 0.12 * glow
	local y = floorUnder(character, root) + 0.05
	local centre = Vector3.new(root.Position.X, y, root.Position.Z)
	local right = forward:Cross(Vector3.new(0, 1, 0))
	local edgeLen = math.max(0.25, reach * 2 * half / EDGE * 0.55)
	for i = 1, EDGE do
		local a = -half + 2 * half * (i - 0.5) / EDGE
		local out = forward * math.cos(a) + right * math.sin(a)
		local tangent = right * math.cos(a) - forward * math.sin(a)
		local p = centre + out * reach
		local dash = dashes[i]
		dash.Size = Vector3.new(width, 0.04, edgeLen)
		dash.CFrame = CFrame.lookAt(p, p + tangent)
		dash.Color = color
		dash.Transparency = transparency
	end
	local sideLen = math.max(0.25, (reach - NEAR) / SIDE * 0.5)
	for s = 0, 1 do
		local a = if s == 0 then -half else half
		local out = forward * math.cos(a) + right * math.sin(a)
		for j = 1, SIDE do
			local d = NEAR + (reach - NEAR) * (j - 0.5) / SIDE
			local p = centre + out * d
			local dash = dashes[EDGE + s * SIDE + j]
			dash.Size = Vector3.new(width, 0.04, sideLen)
			dash.CFrame = CFrame.lookAt(p, p + out)
			dash.Color = color
			dash.Transparency = transparency + 0.08
		end
	end
end

return ItemAim
