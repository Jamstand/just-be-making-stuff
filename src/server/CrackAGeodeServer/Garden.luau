-- GardenService: offline-growth Geode Garden. Plots accrue value from os.time()
-- deltas against savedEarnRate — no background compute. Overgrown at 24h = jackpot login.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Garden = {}
local S
local stationOf = {}
local moundsOf = {}
local usedStations = {}
local clickConnOf = {}

function Garden.PlotCount(player)
	local p = S.Data.Cache[player]
	if not p then return 3 end
	local n = 3 + (p.perks.ExtraPlot and 1 or 0)
	if S.Monetize and S.Monetize.Owns(player, "VIP") then n += 2 end
	return math.min(n, 12)
end

function Garden.CapSeconds(player)
	local p = S.Data.Cache[player]
	return (p and p.perks.OfflineCap) and 172800 or 86400
end

function Garden.Elapsed(player)
	local p = S.Data.Cache[player]
	if not p then return 0 end
	if p.lastHarvest == 0 then
		p.lastHarvest = os.time()
		return 0
	end
	return math.min(os.time() - p.lastHarvest, Garden.CapSeconds(player))
end

function Garden.IsOvergrown(player)
	return Garden.Elapsed(player) >= 86400
end

function Garden.Value(player)
	if not S then return 0 end
	local p = S.Data.Cache[player]
	if not p then return 0 end
	local mult = Garden.IsOvergrown(player) and 2 or 1
	return S.Config.Balance.GardenRate * p.savedEarnRate * Garden.Elapsed(player) * Garden.PlotCount(player) * mult / 60
end

function Garden.Refresh(player)
	local station = stationOf[player]
	local mounds = moundsOf[player]
	if not (station and mounds) then return end
	local frac = math.clamp(Garden.Elapsed(player) / 86400, 0, 1)
	local overgrown = Garden.IsOvergrown(player)
	for _, mound in ipairs(mounds) do
		local scale = 0.7 + 1.6 * frac
		TweenService:Create(mound, TweenInfo.new(0.6), {
			Size = Vector3.new(2.4 * scale, 1.6 * scale, 2.4 * scale),
			Color = overgrown and Color3.fromRGB(255, 205, 80) or Color3.fromRGB(120, 190, 140),
		}):Play()
		mound.Material = overgrown and Enum.Material.Neon or Enum.Material.Slate
	end
end

function Garden.Harvest(player)
	local p = S.Data.Cache[player]
	if not p then return { ok = false, err = "Loading..." } end
	local elapsed = Garden.Elapsed(player)
	if elapsed < 60 then return { ok = false, err = "Nothing grown yet — come back later!" } end
	local overgrown = Garden.IsOvergrown(player)
	local amount = S.Econ.AwardRaw(player, Garden.Value(player))
	S.Data.SaveSoon(player) -- garden harvests are worth persisting promptly
	if overgrown then
		-- Overgrown jackpot logs a guaranteed Emerald in the collection index
		local bitIndex = (4 - 1) * 4 + 0
		if bit32.band(p.indexMask, bit32.lshift(1, bitIndex)) == 0 then
			p.indexMask = bit32.bor(p.indexMask, bit32.lshift(1, bitIndex))
			S.Remotes.OrbitSync:FireAllClients({ userId = player.UserId, mask = p.indexMask, best = p.bestRarity })
		end
	end
	p.lastHarvest = os.time()
	Garden.Refresh(player)
	S.Econ.Push(player)
	S.Remotes.Announce:FireClient(player, {
		kind = "garden",
		text = (overgrown and "🌟 OVERGROWN harvest: +" or "🌱 Garden harvest: +") .. S.Config.Fmt(amount) .. " Gems!",
		color = overgrown and Color3.fromRGB(255, 210, 90) or Color3.fromRGB(120, 255, 170),
	})
	return { ok = true, amount = amount, overgrown = overgrown }
end

local function claimStation(player)
	local p = S.Data.WaitFor(player)
	if not p or stationOf[player] then return end
	local gardens = workspace.CrackAGeode.Gardens
	for i = 1, 12 do
		if not usedStations[i] then
			usedStations[i] = player
			local station = gardens:FindFirstChild("GardenStation" .. i)
			if not station then return end
			stationOf[player] = station
			station.Base.Sign.Text.Text = "🌱 " .. player.DisplayName .. "'s Garden"

			local mounds = {}
			local center = station.Base.Position
			local count = Garden.PlotCount(player)
			for m = 1, count do
				local a = (m / count) * math.pi * 2
				local mound = Instance.new("Part")
				mound.Name = "Mound" .. m
				mound.Size = Vector3.new(1.7, 1.1, 1.7)
				mound.CFrame = CFrame.new(center + Vector3.new(math.cos(a) * 4.4, 0.9, math.sin(a) * 4.4))
				mound.Anchored = true
				mound.CanCollide = false
				mound.Material = Enum.Material.Slate
				mound.Color = Color3.fromRGB(120, 190, 140)
				mound.Parent = station
				local mesh = Instance.new("SpecialMesh")
				mesh.MeshType = Enum.MeshType.Sphere
				mesh.Parent = mound
				table.insert(mounds, mound)
			end
			moundsOf[player] = mounds

			local click = station.Base:FindFirstChildOfClass("ClickDetector")
			if not click then
				click = Instance.new("ClickDetector")
				click.MaxActivationDistance = 22
				click.Parent = station.Base
			end
			clickConnOf[player] = click.MouseClick:Connect(function(clicker)
				if clicker == player then Garden.Harvest(player) end
			end)

			Garden.Refresh(player)
			return
		end
	end
end

function Garden.Init(services)
	S = services

	Players.PlayerAdded:Connect(function(player)
		task.spawn(claimStation, player)
	end)
	task.defer(function()
		for _, p in ipairs(Players:GetPlayers()) do
			task.spawn(claimStation, p)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local station = stationOf[player]
		if station then
			station.Base.Sign.Text.Text = "🌱 Geode Garden"
			for _, mound in ipairs(moundsOf[player] or {}) do
				mound:Destroy()
			end
			for i, owner in pairs(usedStations) do
				if owner == player then usedStations[i] = nil end
			end
		end
		stationOf[player] = nil
		moundsOf[player] = nil
		if clickConnOf[player] then
			clickConnOf[player]:Disconnect()
			clickConnOf[player] = nil
		end
	end)

	local lastHarvestCall = {}
	S.Remotes.HarvestGarden.OnServerInvoke = function(player)
		if not S.Ready then return { ok = false, err = "Starting up…" } end
		local now = os.clock()
		if lastHarvestCall[player] and now - lastHarvestCall[player] < 0.3 then
			return { ok = false, err = "Slow down!" }
		end
		lastHarvestCall[player] = now
		return Garden.Harvest(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastHarvestCall[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(6)
			for player in pairs(stationOf) do
				Garden.Refresh(player)
			end
		end
	end)
end

return Garden
