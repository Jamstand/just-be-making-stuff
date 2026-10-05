--[[
    Global top-10 board for ranked 1v1 rating, shown in the lobby.
    Ratings go into an OrderedDataStore in small batches.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Ranks = require(Shared.Ranks)

local LeaderboardService = {}

local pending = {} -- [userId] = rating
local nameCache = {}
local store = nil
local rows = {}
local statusLabel = nil

local function getStore()
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(Config.Data.LeaderboardStore)
	end)
	if ok then
		store = result
	end
	return store
end

local function nameFor(userId)
	if nameCache[userId] then
		return nameCache[userId]
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		nameCache[userId] = player.DisplayName
		return player.DisplayName
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	nameCache[userId] = ok and name or ("Player " .. userId)
	return nameCache[userId]
end

local function buildBoard()
	local lobby = workspace:WaitForChild("Lobby")
	local board = Instance.new("Part")
	board.Name = "Leaderboard"
	board.Anchored = true
	board.CanCollide = true
	board.Size = Vector3.new(28, 17, 1)
	board.CFrame = CFrame.new(0, 11, -50)
	board.Color = Color3.fromRGB(28, 34, 62)
	board.Material = Enum.Material.SmoothPlastic
	board.Parent = lobby

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = board

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0.14, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 205, 80)
	title.Text = "TOP RANKED · 1v1"
	title.Parent = gui

	statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(1, 0, 0.06, 0)
	statusLabel.Position = UDim2.fromScale(0, 0.93)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextScaled = true
	statusLabel.TextColor3 = Color3.fromRGB(160, 170, 210)
	statusLabel.Text = "Loading..."
	statusLabel.Parent = gui

	for i = 1, Config.Data.LeaderboardSize do
		local row = Instance.new("TextLabel")
		row.Size = UDim2.new(0.9, 0, 0.075, 0)
		row.Position = UDim2.new(0.05, 0, 0.15 + (i - 1) * 0.077, 0)
		row.BackgroundTransparency = i % 2 == 0 and 1 or 0.85
		row.BackgroundColor3 = Color3.new(1, 1, 1)
		row.BorderSizePixel = 0
		row.Font = Enum.Font.GothamBold
		row.TextScaled = true
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextColor3 = Color3.new(1, 1, 1)
		row.Text = ""
		row.Parent = gui
		rows[i] = row
	end
end

local function refresh()
	local ds = getStore()
	if not ds then
		statusLabel.Text = "Leaderboard needs a published place with API access."
		return
	end
	local ok, pages = pcall(function()
		return ds:GetSortedAsync(false, Config.Data.LeaderboardSize)
	end)
	if not ok then
		statusLabel.Text = "Couldn't load the leaderboard right now."
		return
	end
	local entries = pages:GetCurrentPage()
	for i, row in rows do
		local entry = entries[i]
		if entry then
			local userId = tonumber(entry.key)
			local rating = entry.value
			row.Text = string.format(
				"  %d.  %s   —   %d  (%s)",
				i,
				userId and nameFor(userId) or "?",
				rating,
				Ranks.tier(rating).Name
			)
			row.TextColor3 = Ranks.tier(rating).Color
		else
			row.Text = ""
		end
	end
	statusLabel.Text = #entries == 0 and "No ranked matches yet. Be the first!"
		or ("Updated " .. os.date("!%H:%M") .. " UTC")
end

local function flush()
	local ds = getStore()
	if not ds then
		pending = {}
		return
	end
	local batch = pending
	pending = {}
	for userId, rating in batch do
		pcall(function()
			ds:SetAsync(tostring(userId), math.floor(rating))
		end)
	end
end

function LeaderboardService.submit(player, rating)
	pending[player.UserId] = rating
end

function LeaderboardService.init() end

function LeaderboardService.start()
	buildBoard()
	task.spawn(function()
		while true do
			refresh()
			task.wait(Config.Data.LeaderboardRefreshSeconds)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(30)
			flush()
		end
	end)
	game:BindToClose(flush)
end

return LeaderboardService
