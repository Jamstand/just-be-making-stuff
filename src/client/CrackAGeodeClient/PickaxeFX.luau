-- PickaxeFX: client-side pickaxe FEEL. Plays the swing the instant any crack
-- input happens (mobile CRACK button, desktop node click, Auto-Crack), lands an
-- impact moment (sound + camera nudge) when the server confirms the crack,
-- keeps a subtle idle sway so the tool never looks frozen, and animates OTHER
-- players' swings from their confirmed cracks. Zero perceived input delay: the
-- swing never waits on the server; validation continues server-side as before.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

local PickaxeFX = {}
local player = Players.LocalPlayer

local SWING_DUR = 0.3
local SWING_GAP = 0.14 -- min time between swing starts (hold-loop spam guard)

local swings = {} -- [character] = { t0, base = grip C1 at rest, weld }
local nudge = 0   -- camera impact nudge (decays fast)
local idleBase, idleWeld = nil, nil

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

local function startSwing(char)
	if not char then return end
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
	-- windup whoosh (built-in asset, no upload needed)
	local snd = Instance.new("Sound")
	snd.SoundId = "rbxasset://sounds/swordslash.wav"
	snd.Volume = 0.3
	snd.PlaybackSpeed = 1.25 + math.random() * 0.15
	snd.Parent = char:FindFirstChild("HumanoidRootPart") or workspace
	snd:Play()
	Debris:AddItem(snd, 1.2)
end

-- public: local instant swing — call on any crack INPUT
function PickaxeFX.Swing()
	startSwing(player.Character)
end

-- public: a confirmed crack (server CrackFX event)
function PickaxeFX.OnCrack(data, isMine)
	if isMine then
		-- impact moment. If no swing is in flight (Auto-Crack, or a desktop click
		-- the mouse hook missed), play one now so the hit still reads.
		local st = swings[player.Character]
		if not (st and os.clock() - st.t0 < SWING_DUR) then
			startSwing(player.Character)
		end
		nudge = 1
	else
		local other = data.userId and Players:GetPlayerByUserId(data.userId)
		if other and other ~= player and other.Character then
			startSwing(other.Character)
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
			cam.CFrame = cam.CFrame * CFrame.Angles(-0.012 * nudge, 0.006 * nudge, 0)
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
		hl.FillColor = Color3.fromRGB(255, 206, 120)
		hl.FillTransparency = 0.92
		hl.OutlineColor = Color3.fromRGB(255, 206, 120)
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