--[[
    Mirrors Coins + Gems from PlayerData onto leaderstats so the values
    show up in the Roblox in-game leaderboard.
]]

local Players = game:GetService("Players")

local function waitForGlobal(name: string)
	local start = os.clock()
	while not (_G.CoinRush and _G.CoinRush[name]) do
		if os.clock() - start > 15 then
			warn(("[Leaderboard] %s not ready after 15s"):format(name))
			return nil
		end
		task.wait()
	end
	return _G.CoinRush[name]
end

local PlayerData = waitForGlobal("PlayerData")

local function ensureLeaderstats(player: Player)
	local existing = player:FindFirstChild("leaderstats")
	if existing then return existing end
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = 0
	coins.Parent = folder
	local gems = Instance.new("IntValue")
	gems.Name = "Gems"
	gems.Value = 0
	gems.Parent = folder
	folder.Parent = player
	return folder
end

local function sync(player: Player, data)
	local stats = ensureLeaderstats(player)
	local coins = stats:FindFirstChild("Coins")
	local gems = stats:FindFirstChild("Gems")
	if coins and coins:IsA("IntValue") then
		coins.Value = math.floor(data.Coins or 0)
	end
	if gems and gems:IsA("IntValue") then
		gems.Value = math.floor(data.Gems or 0)
	end
end

local function bindPlayer(player: Player)
	ensureLeaderstats(player)
	if not PlayerData then return end
	local data = PlayerData.Get(player)
	if data then
		sync(player, data)
	else
		task.spawn(function()
			for _ = 1, 30 do
				task.wait(0.5)
				local d = PlayerData.Get(player)
				if d then
					sync(player, d)
					return
				end
			end
		end)
	end
end

Players.PlayerAdded:Connect(bindPlayer)
for _, player in Players:GetPlayers() do
	bindPlayer(player)
end

if PlayerData and PlayerData.Updated then
	PlayerData.Updated:Connect(sync)
end
