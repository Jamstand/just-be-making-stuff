-- Clothesline: The Great Dryer spawns a sock every few seconds; each sock rides the line on one
-- linear Tween (no per-sock loops) and falls into the Lint Trap if nobody buys it.
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Clothesline = {}
local S

local onLine = {} -- uid -> { sock = Sock, tween = Tween, prompt = ProximityPrompt }
local lineCount = 0

function Clothesline.Init(s)
	S = s
	-- Spin the dryer drum (one loop for decor)
	local drum = S.Map.Dryer.Drum
	local swirl = S.Map.Dryer.Swirl
	RunService.Heartbeat:Connect(function(dt)
		drum.CFrame = drum.CFrame * CFrame.Angles(dt * 2.5, 0, 0)
		swirl.CFrame = swirl.CFrame * CFrame.Angles(dt * 1.5, dt * 2, 0)
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
	local tween = TweenService:Create(leg, TweenInfo.new(duration, Enum.EasingStyle.Linear), { CFrame = S.Map.LinePoint(S.Map.LineLength()) })
	tween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed and sock.state == "line" then
			Clothesline.Despawn(sock)
		end
	end)
	onLine[sock.uid] = { sock = sock, tween = tween, prompt = prompt }
	lineCount += 1
	tween:Play()

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
	entry.tween:Cancel()
	entry.prompt:Destroy()
	onLine[sock.uid] = nil
	lineCount -= 1
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
