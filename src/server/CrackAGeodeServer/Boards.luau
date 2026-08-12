-- BoardsService: the two leaderboard walls + live rarity feed near spawn.
-- Online-session rankings (OrderedDataStore global boards can be added post-publish).

local Players = game:GetService("Players")

local Boards = {}
local S
local feed = {}

local function setList(boardName, text)
	local boards = workspace.CrackAGeode:FindFirstChild("Boards")
	local b = boards and boards:FindFirstChild(boardName)
	if b and b:FindFirstChild("Gui") then
		b.Gui.List.Text = text
	end
end

function Boards.Feed(name, rarName, mutKey)
	table.insert(feed, 1, "⭐ " .. name .. " — " .. (mutKey and (mutKey .. " ") or "") .. rarName)
	if #feed > 9 then table.remove(feed) end
	setList("RarityFeed", table.concat(feed, "\n"))
end

local function refresh()
	local rows = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local p = S.Data.Cache[player]
		if p then
			table.insert(rows, { name = player.DisplayName, gems = p.totalGems, rebirths = p.rebirths })
		end
	end
	table.sort(rows, function(a, b) return a.gems > b.gems end)
	local gemLines = {}
	for i = 1, math.min(#rows, 8) do
		table.insert(gemLines, i .. ". " .. rows[i].name .. " — " .. S.Config.Fmt(rows[i].gems))
	end
	setList("TopGems", #gemLines > 0 and table.concat(gemLines, "\n") or "Be the first!")

	table.sort(rows, function(a, b) return a.rebirths > b.rebirths end)
	local rbLines = {}
	for i = 1, math.min(#rows, 8) do
		table.insert(rbLines, i .. ". " .. rows[i].name .. " — " .. rows[i].rebirths .. " 🔄")
	end
	setList("TopRebirths", #rbLines > 0 and table.concat(rbLines, "\n") or "Be the first!")
end

function Boards.Init(services)
	S = services
	setList("RarityFeed", "Crack geodes to make history!")
	task.spawn(function()
		while true do
			refresh()
			task.wait(12)
		end
	end)
end

return Boards
