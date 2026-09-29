-- Clothesline: The Great Dryer spawns a sock every few seconds. Each line sock's position is a pure
-- function of server time (LineStart/LineDuration attributes): every client moves it locally and
-- smoothly (see StealASockClient.SockFX), the server only computes the same position when it
-- needs to validate a purchase. Unbought socks fall into the Lint Trap.
local RunService = game:GetService("RunService")

local Clothesline = {}
local S

local onLine = {} -- uid -> { sock = Sock, prompt = ProximityPrompt, token = number }
local lineCount = 0

function Clothesline.Init(s)
	S = s
	-- Spin the dryer drum and the cosmic swirl (one loop for decor)
	local drum = S.Map.Dryer.Drum
	local swirl = S.Map.Dryer.Swirl
	local core = S.Map.Dryer.Core
	RunService.Heartbeat:Connect(function(dt)
		drum.CFrame = drum.CFrame * CFrame.Angles(dt * 2.5, 0, 0)
		swirl.CFrame = swirl.CFrame * CFrame.Angles(dt * 1.5, dt * 2, 0)
		core.CFrame = core.CFrame * CFrame.Angles(-dt * 3, dt, 0)
	end)
	task.spawn(function()
		while true do
			task.wait(S.Config.Economy.DryerSpawnInterval)
			if lineCount < S.Config.Economy.MaxSocksOnLine then
				local ok, err = pcall(Clothesline.SpawnOne)
				if not ok then
					warn("[Clothesline] spawn failed: " .. tostring(err))
				end
			end
		end
	end)
end

function Clothesline.Count(): number
	return lineCount
end

local function promptText(sock): (string, string)
	local tier = S.Registry.Tier(sock)
	local m = S.Config.Mutation.Table[sock.mutation]
	local price = S.Registry.PriceOf(sock)
	local income = S.Registry.IncomeOf(sock, 0)
	local object = S.Registry.DisplayName(sock) .. " • " .. tier.display .. (if m and m.display ~= "" then " • " .. m.display else "")
	local action = "Buy $" .. S.Util.FormatCash(price) .. "  ($" .. S.Util.FormatRate(income) .. "/s)"
	return object, action
end

function Clothesline.SpawnOne()
	local typeId, side = S.Registry.RollType()
	local mutation = S.Registry.RollMutation()
	local sock = S.Registry.Create(typeId, side, mutation, 0)
	local model = S.Factory.Build(sock)
	S.Factory.SetClothespin(model, true)
	sock.state = "line"
	sock.lineStart = os.clock()
	model:PivotTo(S.Map.LinePoint(0))
	model.Parent = S.Map.Folders.Line

	local leg = model.PrimaryPart
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BuyPrompt"
	prompt.ObjectText, prompt.ActionText = promptText(sock)
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = leg
	prompt.Triggered:Connect(function(player)
		S.Purchase.TryBuy(player, sock)
	end)

	local duration = S.Map.LineLength() / S.Config.Economy.ClotheslineSpeed
	model:SetAttribute("State", "line")
	model:SetAttribute("LineStart", workspace:GetServerTimeNow())
	model:SetAttribute("LineDuration", duration)
	local entry = { sock = sock, prompt = prompt, token = 0 }
	onLine[sock.uid] = entry
	lineCount += 1
	task.delay(duration + 0.6, function()
		if onLine[sock.uid] == entry and sock.state == "line" then
			Clothesline.Despawn(sock)
		end
	end)

	local t = S.Registry.Type(sock)
	if t.announceSpawn then
		S.Announce("⚠️ " .. t.name .. " just came out of the Dryer! ⚠️", S.Registry.Tier(sock).color)
	end
end

-- Takes a sock off the line (bought). The caller decides where it goes next.
function Clothesline.Remove(sock)
	local entry = onLine[sock.uid]
	if not entry then
		return
	end
	entry.prompt:Destroy()
	onLine[sock.uid] = nil
	lineCount -= 1
	-- park the server-side model where every client currently sees it, so the buy hop starts there
	if sock.model then
		sock.model:PivotTo(CFrame.new(Clothesline.PositionOf(sock)))
	end
end

-- Where the sock is right now on the line (same formula the clients use).
function Clothesline.PositionOf(sock): Vector3
	local model = sock.model
	local t0 = model and model:GetAttribute("LineStart")
	local dur = model and model:GetAttribute("LineDuration")
	if not t0 or not dur then
		return if model then model:GetPivot().Position else Vector3.zero
	end
	local progress = math.clamp((workspace:GetServerTimeNow() - t0) / dur, 0, 1)
	return S.Map.LinePoint(progress * S.Map.LineLength()).Position
end

-- Fell into the Lint Trap.
function Clothesline.Despawn(sock)
	Clothesline.Remove(sock)
	S.Registry.Destroy(sock.uid)
end

-- 0..1 progress along the line (Match Radar uses this in Phase 2)
function Clothesline.Progress(sock): number
	if not sock.lineStart then
		return 0
	end
	local duration = S.Map.LineLength() / S.Config.Economy.ClotheslineSpeed
	return math.clamp((os.clock() - sock.lineStart) / duration, 0, 1)
end

return Clothesline
