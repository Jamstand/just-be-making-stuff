-- SocialFX: cheer reactions over players (plan CM-5). The wire value is an index
-- into Config.Social.Reactions (👏 🔥 💎 🎉 👋 💜) — never free text.
--
--   SocialFX.Send(targetUserId, idx)   client debounce Config.Social.CheerGap + 0.25 s (strictly
--                                      longer than the server's S.Guard gap, so a legitimately
--                                      spaced cheer is never dropped to network jitter), never a
--                                      self-target, then Remotes.Cheer:FireServer(target, idx)
--   SocialFX.OnCheer(data)             {fromUserId, toUserId, idx, t}: skipped under
--                                      Quality.ReduceFX, when Social pings are off, when the
--                                      sender is blocked (StarterGui GetBlockedUserIds, cached at
--                                      Init) or the target is > 120 studs away; otherwise one of
--                                      8 pooled BillboardGuis (Signpost=false) pops the reaction
--                                      above the target's nameplate (1.6 s pop-rise-fade,
--                                      SG.Motion.pop), a pooled ParticleEmitter snapped to the
--                                      target HRP emits 12 sparkles, and a brief screen sparkle
--                                      (no shake) plays when the target is the local player.
--                                      Pool exhausted → the cheer is dropped, nothing allocates.
--   SocialFX.SetEnabled(bool)          Social pings (also follows Quality.Changed("socialPings"))
--   SocialFX.IsBlocked(userId)         true when the sender is on the cached block list
--   SocialFX.IsEnabled()               current Social pings state
--                                      (init.client gates the "X cheered you!" toast on both)
--
-- Nothing pooled ever rides a destroyable character: the BillboardGuis live in PlayerGui and
-- point at the target Head through Adornee, the sparkle emitters sit on invisible anchored
-- parts in a client-created workspace.GeodeSocialFX folder (CFrame snapped to the HRP on
-- pop). A target dying / leaving mid-pop therefore cannot destroy a slot, and release()
-- self-heals (rebuilds the slot) if one still vanished, so the pool never shrinks.
-- The screen sparkle lives in its own ScreenGui GeodeSocialFX (DisplayOrder 45).

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SG = require(ReplicatedStorage:WaitForChild("StyleGuide"))

local SocialFX = {}

local Config, Quality
local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local POOL = 8
local SPARK_POOL = 12
local LIFE = 1.6
local MAX_DIST = 120
local SEND_MARGIN = 0.25 -- s on top of CheerGap: the client debounce must exceed the server gap
local PARK = CFrame.new(0, -500, 0)
local DEFAULT_REACTIONS = { "👏", "🔥", "💎", "🎉", "👋", "💜" }

local enabled = true
local lastSend = -math.huge
local blocked = {}     -- [userId] = true
local pool = {}        -- { i, bb, label, scale, part, pe, busy, gen, tweens }
local sparkPool = {}   -- TextLabels for the local-target screen sparkle
local playerGui, fxFolder, screenGui

-- ===== helpers =====
local function social()
	return (Config and Config.Social) or {}
end

local function reactions()
	local r = social().Reactions
	return type(r) == "table" and r or DEFAULT_REACTIONS
end

local function isInt(x)
	return type(x) == "number" and x == x and x == math.floor(x)
end

local function myPosition()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then return hrp.Position end
	local cam = workspace.CurrentCamera
	return cam and cam.CFrame.Position or nil
end

local function cancelTweens(slot)
	for _, tw in ipairs(slot.tweens) do tw:Cancel() end
	table.clear(slot.tweens)
end

-- client-created, local-only folder for the sparkle parts (outside CrackAGeode and the
-- camera, so Signposts / the light cull ignore it and a camera reset cannot wipe it)
local function ensureFxFolder()
	if fxFolder and fxFolder.Parent == workspace then return fxFolder end
	local f = workspace:FindFirstChild("GeodeSocialFX")
	if not f then
		f = Instance.new("Folder")
		f.Name = "GeodeSocialFX"
		f.Parent = workspace
	end
	fxFolder = f
	return f
end

-- ===== pool =====
local function makeSlot(i)
	local bb = Instance.new("BillboardGui")
	bb.Name = "CheerPop" .. i
	bb.Size = UDim2.new(1.6, 0, 1.6, 0)
	bb.StudsOffset = Vector3.new(0, 3.3, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = MAX_DIST
	bb.LightInfluence = 0
	bb.Enabled = false
	bb:SetAttribute("Signpost", false)
	bb.Parent = playerGui -- renders through Adornee; never parented under a character
	local label = SG.label({
		Name = "Emoji", Size = UDim2.fromScale(1, 1), Text = "", Font = SG.Font.Display,
		TextStrokeTransparency = 0.5,
	}, bb)
	local scale = Instance.new("UIScale")
	scale.Parent = label

	-- sparkle source: an invisible anchored part snapped to the target HRP on pop
	local part = Instance.new("Part")
	part.Name = "CheerSparkles" .. i
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = PARK
	part.Parent = ensureFxFolder()
	local att = Instance.new("Attachment")
	att.Parent = part
	local pe = Instance.new("ParticleEmitter")
	pe.Enabled = false
	pe.Rate = 0
	pe.Color = ColorSequence.new(SG.Color.GoldSoft or SG.Color.Gold, SG.Color.Magenta)
	pe.LightEmission = 1
	pe.Lifetime = NumberRange.new(0.5, 1.0)
	pe.Speed = NumberRange.new(4, 7)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	pe.Acceleration = Vector3.new(0, -6, 0)
	pe.Parent = att

	return { i = i, bb = bb, label = label, scale = scale, part = part, pe = pe, busy = false, gen = 0, tweens = {} }
end

local function takeSlot()
	for _, slot in ipairs(pool) do
		if not slot.busy then
			slot.busy = true
			slot.gen += 1
			return slot
		end
	end
	return nil
end

-- Idle again. Every write is pcall'd and the slot is rebuilt if one of its instances
-- vanished (a destroyed instance's Parent is locked), so slot.busy is ALWAYS cleared and
-- the pool never loses a slot for the session.
local function release(slot)
	cancelTweens(slot)
	local ok = pcall(function()
		slot.bb.Enabled = false
		slot.bb.Adornee = nil
		slot.part.CFrame = PARK
	end)
	if not ok or slot.bb.Parent == nil or slot.part.Parent == nil then
		pcall(function() slot.bb:Destroy() end)
		pcall(function() slot.part:Destroy() end)
		local ok2, fresh = pcall(makeSlot, slot.i)
		if ok2 and fresh then pool[slot.i] = fresh end
	end
	slot.busy = false
end

local function pop(slot, head, hrp, emoji)
	local gen = slot.gen
	local start = Vector3.new((math.random() - 0.5) * 1.4, 3.3, 0)
	local ok = pcall(function()
		slot.label.Text = emoji
		slot.label.TextTransparency = 0
		slot.label.TextStrokeTransparency = 0.5
		slot.scale.Scale = 0.35
		slot.bb.StudsOffset = start
		slot.bb.Adornee = head -- the character may die mid-pop; the billboard just stops rendering
		slot.bb.Enabled = true
		slot.part.CFrame = hrp.CFrame
	end)
	if not ok then
		release(slot)
		return
	end

	local rise = TweenService:Create(slot.bb, TweenInfo.new(LIFE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ StudsOffset = start + Vector3.new(0, 1.4, 0) })
	local grow = TweenService:Create(slot.scale, SG.Motion.pop, { Scale = 1 })
	local fade = TweenService:Create(slot.label, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, LIFE - 0.6),
		{ TextTransparency = 1, TextStrokeTransparency = 1 })
	slot.tweens[1], slot.tweens[2], slot.tweens[3] = rise, grow, fade
	rise:Play()
	grow:Play()
	fade:Play()

	slot.pe:Emit(12)

	task.delay(LIFE, function()
		if slot.gen ~= gen then return end
		release(slot)
	end)
end

-- brief screen sparkle for a cheer aimed at the local player (pooled labels, no shake)
local function sparkle(emoji)
	if not screenGui then return end
	local W, H = screenGui.AbsoluteSize.X, screenGui.AbsoluteSize.Y
	if W <= 1 or H <= 1 then return end
	local used = 0
	for _, l in ipairs(sparkPool) do
		if used >= 6 then break end
		if not l.Visible then
			used += 1
			l.Text = emoji
			l.TextTransparency = 0
			l.TextStrokeTransparency = 0.5
			l.Position = UDim2.fromOffset(W * (0.3 + math.random() * 0.4), H * (0.55 + math.random() * 0.25))
			l.Visible = true
			local tw = TweenService:Create(l, TweenInfo.new(1.1 + math.random() * 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = l.Position - UDim2.fromOffset((math.random() - 0.5) * 60, 90 + math.random() * 50),
				TextTransparency = 1, TextStrokeTransparency = 1,
			})
			tw.Completed:Once(function() l.Visible = false end)
			tw:Play()
		end
	end
end

-- ===== blocked users (cached; live updates when the core exposes them) =====
local function loadBlocked()
	task.spawn(function()
		local ok, ids = pcall(function() return StarterGui:GetCore("GetBlockedUserIds") end)
		if not (ok and type(ids) == "table") then
			ok, ids = pcall(function() return player:GetBlockedUserIdsAsync() end)
		end
		if ok and type(ids) == "table" then
			for _, id in ipairs(ids) do
				if type(id) == "number" then blocked[id] = true end
			end
		end
		pcall(function()
			local ev = StarterGui:GetCore("PlayerBlockedEvent")
			ev.Event:Connect(function(pl)
				if typeof(pl) == "Instance" and pl:IsA("Player") then blocked[pl.UserId] = true end
			end)
		end)
		pcall(function()
			local ev = StarterGui:GetCore("PlayerUnblockedEvent")
			ev.Event:Connect(function(pl)
				if typeof(pl) == "Instance" and pl:IsA("Player") then blocked[pl.UserId] = nil end
			end)
		end)
	end)
end

-- ===== public API =====
function SocialFX.Send(targetUserId, idx)
	-- any non-zero integer (Studio local-server players are negative); the server is the authority
	if not isInt(targetUserId) or targetUserId == 0 then return false end
	if targetUserId == player.UserId then return false end -- a self-cheer never leaves the client
	if not isInt(idx) or idx < 1 or idx > #reactions() then return false end
	-- strictly longer than the server's S.Guard gap (same CheerGap) so jitter can never
	-- land two accepted sends < gap apart on the server clock and drop the second silently
	local gap = (tonumber(social().CheerGap) or 2) + SEND_MARGIN
	local now = os.clock()
	if now - lastSend < gap then return false end
	local remote = Remotes:FindFirstChild("Cheer")
	if not (remote and remote:IsA("RemoteEvent")) then return false end
	lastSend = now
	remote:FireServer(targetUserId, idx)
	return true
end

function SocialFX.OnCheer(data)
	if type(data) ~= "table" then return end
	if not enabled then return end
	if Quality and Quality.ReduceFX then return end
	local from, to = data.fromUserId, data.toUserId
	if type(to) ~= "number" then return end
	if type(from) == "number" and blocked[from] then return end
	local target = Players:GetPlayerByUserId(to)
	local char = target and target.Character
	local head = char and char:FindFirstChild("Head")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (head and hrp) then return end
	local origin = myPosition()
	if origin and (hrp.Position - origin).Magnitude > MAX_DIST then return end
	local slot = takeSlot()
	if not slot then return end -- all 8 busy: drop, never allocate
	local idx = tonumber(data.idx)
	local emoji = (idx and reactions()[idx]) or reactions()[1] or "👏"
	pop(slot, head, hrp, emoji)
	if to == player.UserId then sparkle(emoji) end
end

function SocialFX.SetEnabled(on)
	enabled = on ~= false
end

-- gates for the "X cheered you!" toast (UI.OnCheerReceived has no block list of its own)
function SocialFX.IsBlocked(userId)
	return type(userId) == "number" and blocked[userId] == true
end

function SocialFX.IsEnabled()
	return enabled
end

function SocialFX.Init(config, quality)
	Config, Quality = config, quality
	if Quality and type(Quality.Settings) == "table" then
		enabled = Quality.Settings.socialPings ~= false
	end

	playerGui = player:WaitForChild("PlayerGui")
	ensureFxFolder()

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GeodeSocialFX"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 45
	screenGui.Parent = playerGui
	for i = 1, SPARK_POOL do
		sparkPool[i] = SG.label({
			Name = "Spark" .. i, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(40, 40),
			Text = "", Font = SG.Font.Display, TextStrokeTransparency = 0.5, Visible = false,
		}, screenGui)
	end

	for i = 1, POOL do pool[i] = makeSlot(i) end
	loadBlocked()

	if Quality and Quality.Changed then
		Quality.Changed:Connect(function(field)
			if field == "socialPings" and type(Quality.Settings) == "table" then
				enabled = Quality.Settings.socialPings ~= false
			end
		end)
	end
end

return SocialFX
