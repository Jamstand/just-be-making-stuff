-- PickaxeFX: client-side pickaxe FEEL and the SINGLE owner of the RightGrip weld.
-- Plays the swing the instant any crack input happens (mobile CRACK button,
-- desktop node click, Tool.Activated, Auto-Crack), lands an impact moment
-- (sound + camera nudge) when the server confirms the crack, keeps a subtle idle
-- sway so the tool never looks frozen, and animates OTHER players' swings from
-- their confirmed cracks. Zero perceived input delay: the swing never waits on
-- the server; validation continues server-side as before.
--
-- Cooldown gate: PickaxeFX.SetCooldownSource(fn) takes UI.CrackReadyAt; a local
-- INPUT swing early-returns while os.clock() < fn(), so a held CRACK button or
-- click spam plays at most one swing + whoosh per real crack. A confirmed crack
-- (CrackFX) bypasses the gate. The whoosh routes through Audio.Play (GeodeSFX).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")
local SG = require(game:GetService("ReplicatedStorage"):WaitForChild("StyleGuide")) -- highlight colour token

local PickaxeFX = {}
local player = Players.LocalPlayer

local SWING_DUR = 0.3
local SWING_GAP = 0.14 -- min time between swing starts (hold-loop spam guard)

local swings = {} -- [character] = { t0, base = grip C1 at rest, weld }
local nudge = 0   -- camera impact nudge (decays fast)
local idleBase, idleWeld = nil, nil
local cooldownSource = nil -- function() -> os.clock() when the next crack is allowed

-- audio routing (bounded wait: a missing Audio module must never park boot)
local Audio = nil
do
	local m = script.Parent:FindFirstChild("Audio") or script.Parent:WaitForChild("Audio", 5)
	if m then
		local ok, mod = pcall(require, m)
		if ok then Audio = mod end
	end
end
local WHOOSH = "rbxasset://sounds/swordslash.wav" -- built-in asset, no upload needed
local function whoosh(parent)
	local speed = 1.25 + math.random() * 0.15
	if Audio then
		Audio.Play(WHOOSH, 0.3, speed, parent)
		return
	end
	local snd = Instance.new("Sound")
	snd.SoundId = WHOOSH
	snd.Volume = 0.3
	snd.PlaybackSpeed = speed
	snd.Parent = parent or workspace
	snd:Play()
	Debris:AddItem(snd, 1.2)
end

local function gripWeld(char)
	local hand = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
	return hand and hand:FindFirstChild("RightGrip")
end

-- swing curve: windup (raise back), fast strike forward, settle
local function swingAngle(s)
	if s < 0.35 then
		local k = s / 0.35
		return -0.9 * (k * k)
	elseif s < 0.6 then
		local k = (s - 0.35) / 0.25
		return -0.9 + 2.1 * (k * (2 - k))
	else
		local k = (s - 0.6) / 0.4
		return 1.2 * (1 - k * k)
	end
end

-- The UI arms a 0.25 s provisional lock on every press (UI-6). If it does so
-- BEFORE calling UI.OnCrackInput, a literal "os.clock() < readyAt" would swallow
-- the legitimate press swing, so a remaining lock inside that window is let
-- through; a real cooldown (>= CrackCooldownMin 0.4 s) still blocks.
local PROVISIONAL_GRACE = 0.26
local function cooldownBlocks()
	if not cooldownSource then return false end
	local ok, readyAt = pcall(cooldownSource)
	if not (ok and type(readyAt) == "number" and readyAt == readyAt) then return false end
	return (readyAt - os.clock()) > PROVISIONAL_GRACE
end

-- force = true bypasses the cooldown gate (confirmed cracks)
local function startSwing(char, force)
	if not char then return end
	if char == player.Character and not force and cooldownBlocks() then return end
	local weld = gripWeld(char)
	if not weld then return end
	local st = swings[char]
	if st and os.clock() - st.t0 < SWING_GAP then return end
	if not st or st.weld ~= weld then
		st = { weld = weld, base = weld.C1 }
		if char == player.Character and idleWeld == weld and idleBase then
			st.base = idleBase -- don't bake the current sway offset into the swing
		end
	end
	st.t0 = os.clock()
	swings[char] = st
	whoosh(char:FindFirstChild("HumanoidRootPart"))
end

-- public: local instant swing — call on any crack INPUT (cooldown-gated)
function PickaxeFX.Swing()
	startSwing(player.Character, false)
end

-- public: fn() -> os.clock() timestamp when the next crack is allowed (UI.CrackReadyAt).
-- nil clears the gate.
function PickaxeFX.SetCooldownSource(fn)
	cooldownSource = (type(fn) == "function") and fn or nil
end

-- public: a confirmed crack (server CrackFX event)
function PickaxeFX.OnCrack(data, isMine)
	if isMine then
		-- impact moment. If no swing is in flight (Auto-Crack, or a desktop click
		-- the mouse hook missed), play one now so the hit still reads.
		local st = swings[player.Character]
		if not (st and os.clock() - st.t0 < SWING_DUR) then
			startSwing(player.Character, true)
		end
		nudge = 1
	else
		local other = type(data) == "table" and data.userId and Players:GetPlayerByUserId(data.userId)
		if other and other ~= player and other.Character then
			startSwing(other.Character, true)
		end
	end
end

function PickaxeFX.Init()
	-- run AFTER the camera controller so the impact nudge isn't overwritten
	RunService:BindToRenderStep("PickaxeFX", Enum.RenderPriority.Camera.Value + 1, function(dt)
		local t = os.clock()
		for char, st in pairs(swings) do
			if not char.Parent or not st.weld.Parent then
				swings[char] = nil
			else
				local s = (t - st.t0) / SWING_DUR
				local idle = 0
				if char == player.Character then
					idle = math.sin(t * 1.3) * 0.04 + math.sin(t * 0.7) * 0.02
				end
				st.weld.C1 = st.base * CFrame.Angles((s >= 1 and 0 or swingAngle(s)) + idle, 0, 0)
			end
		end
		-- idle sway before the first swing (afterwards the swing state owns it)
		local char = player.Character
		if char and not swings[char] then
			local weld = gripWeld(char)
			if weld then
				if idleWeld ~= weld then idleBase, idleWeld = weld.C1, weld end
				weld.C1 = idleBase * CFrame.Angles(math.sin(t * 1.3) * 0.04 + math.sin(t * 0.7) * 0.02, 0, math.sin(t * 0.9) * 0.02)
			end
		end
		if nudge > 0.01 then
			local cam = workspace.CurrentCamera
			if cam then cam.CFrame = cam.CFrame * CFrame.Angles(-0.012 * nudge, 0.006 * nudge, 0) end
			nudge *= math.max(0, 1 - dt * 14)
		else
			nudge = 0
		end
	end)

	-- proximity highlight: gold-outline the nearest crackable node in range so
	-- players always know geodes are interactable (QA affordance fix)
	task.spawn(function()
		local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
		local range = (Config.Balance and Config.Balance.ClickRange or 24) + 4
		local hl = Instance.new("Highlight")
		hl.Name = "NodeHint"
		hl.FillColor = SG.World.Station.crater -- same warm gold as the crater station
		hl.FillTransparency = 0.92
		hl.OutlineColor = SG.World.Station.crater
		hl.OutlineTransparency = 0.15
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.Enabled = false
		hl.Parent = workspace.CurrentCamera
		while true do
			task.wait(0.2)
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local cag = workspace:FindFirstChild("CrackAGeode")
			local nodes = cag and cag:FindFirstChild("Nodes")
			if hrp and nodes then
				local best, bd = nil, range
				for _, m in ipairs(nodes:GetChildren()) do
					local rock = m:FindFirstChild("Rock")
					if rock and rock.CanCollide then
						local d = (rock.Position - hrp.Position).Magnitude
						if d < bd then bd = d; best = m end
					end
				end
				if best then
					hl.Adornee = best
					hl.Enabled = true
				else
					hl.Enabled = false
				end
			else
				hl.Enabled = false
			end
		end
	end)

	-- desktop: swing the instant a geode node is clicked (the server's
	-- ClickDetector still does the real crack — this is pure input feedback)
	if UserInputService.MouseEnabled then
		local mouse = player:GetMouse()
		mouse.Button1Down:Connect(function()
			local target = mouse.Target
			if not target then return end
			local cag = workspace:FindFirstChild("CrackAGeode")
			local nodesFolder = cag and cag:FindFirstChild("Nodes")
			if nodesFolder and target:IsDescendantOf(nodesFolder) then
				PickaxeFX.Swing()
			end
		end)
	end
end

return PickaxeFX
