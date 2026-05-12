-- Mirrors persistent currencies onto the in-game leaderboard.
-- Reads initial values from PlayerDataService after it has loaded the player.

local Players = game:GetService("Players")

local function waitForData(player: Player, timeout: number?)
	local deadline = os.clock() + (timeout or 10)
	while os.clock() < deadline do
		local svc = _G.PlayerDataService
		if svc then
			local data = svc.Get(player)
			if data then return data end
		end
		task.wait(0.1)
	end
	return nil
end

local function attach(player: Player)
	local data = waitForData(player, 15)

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = data and data.Coins or 0
	coins.Parent = leaderstats

	local gems = Instance.new("IntValue")
	gems.Name = "Gems"
	gems.Value = data and data.Gems or 0
	gems.Parent = leaderstats

	leaderstats.Parent = player
end

Players.PlayerAdded:Connect(attach)
for _, player in Players:GetPlayers() do task.spawn(attach, player) end
