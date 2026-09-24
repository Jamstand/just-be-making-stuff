-- Nameplates: one BillboardGui per player's Head showing the presence the server
-- replicates through Player attributes (Rebirths, Ascensions, PetName / PetEmoji /
-- PetColor, IsVIP, Title) plus Premium from Player.MembershipType (replicates).
--   line 1: "{👑 }{DisplayName}{ ⭐} · R{Rebirths}{ · A{Ascensions}}{ · Title}"  (SG.Tier colour)
--   line 2: "{PetEmoji} {PetName}"                                            (hidden when no pet)
-- Old server (no attributes) → name only. Text is rebuilt ONLY from one
-- player.AttributeChanged connection per player (coalesced 0.5 s) and on
-- CharacterAdded — zero per-frame Luau. Signpost=false keeps Signposts away;
-- Humanoid.DisplayDistanceType = None removes the default Roblox name so the
-- plate is the only label; a legacy server VIPTag billboard is hidden. The local
-- player's own plate is built but disabled (hidden by default). MaxDistance is
-- 45 / 70 / 100 by Quality.Tier and follows Quality.Changed("Tier").
--
--   Nameplates.Init(Quality)
--   Nameplates.OnTap = function(userId) end   -- assigned by init.client (→ UI.OpenProfile)

local Players = game:GetService("Players")
local SG = require(game:GetService("ReplicatedStorage"):WaitForChild("StyleGuide"))

local Nameplates = {}
Nameplates.OnTap = nil

local Quality
local player = Players.LocalPlayer
local entries = {} -- [Player] = { player, bb, pill, stroke, line1, line2, attrConn, charConn, pending }

local MAX_DIST = { [0] = 45, [1] = 70, [2] = 100 }
local COALESCE = 0.5
local SIZE_TWO = UDim2.new(4.2, 0, 1.1, 0)
local SIZE_ONE = UDim2.new(4.2, 0, 0.66, 0)

local function maxDistance()
	local t = (Quality and Quality.Tier) or 2
	return MAX_DIST[t] or 100
end

local function isPremium(pl)
	local ok, mt = pcall(function() return pl.MembershipType end)
	return ok and mt == Enum.MembershipType.Premium
end

local tierColor = SG.Tier or function() return SG.Color.Violet end

local function buildText(pl)
	local rebirths = pl:GetAttribute("Rebirths")
	local ascensions = pl:GetAttribute("Ascensions")
	local isVIP = pl:GetAttribute("IsVIP") == true
	local title = pl:GetAttribute("Title")
	local petName = pl:GetAttribute("PetName")
	local petEmoji = pl:GetAttribute("PetEmoji")

	local parts = { (isVIP and "👑 " or "") .. pl.DisplayName .. (isPremium(pl) and " ⭐" or "") }
	if type(rebirths) == "number" and rebirths == rebirths then
		parts[#parts + 1] = "R" .. tostring(math.floor(rebirths))
		if type(ascensions) == "number" and ascensions > 0 then
			parts[#parts + 1] = "A" .. tostring(math.floor(ascensions))
		end
	end
	if type(title) == "string" and title ~= "" then parts[#parts + 1] = title end
	local line1 = table.concat(parts, " · ")

	local line2 = ""
	if type(petName) == "string" and petName ~= "" then
		local emoji = (type(petEmoji) == "string" and petEmoji ~= "") and (petEmoji .. " ") or ""
		line2 = emoji .. petName
	end
	return line1, line2, tierColor(rebirths, ascensions)
end

local function render(e)
	if not (e.bb and e.bb.Parent) then return end
	local pl = e.player
	local line1, line2, color = buildText(pl)
	local hasPet = line2 ~= ""
	if e.line1.Text ~= line1 then e.line1.Text = line1 end
	e.line1.TextColor3 = color
	e.stroke.Color = color
	if e.line2.Text ~= line2 then e.line2.Text = line2 end
	local petColor = pl:GetAttribute("PetColor")
	e.line2.TextColor3 = (typeof(petColor) == "Color3") and petColor:Lerp(Color3.new(1, 1, 1), 0.35) or SG.Color.TextDim
	if e.line2.Visible ~= hasPet then e.line2.Visible = hasPet end
	local size = hasPet and SIZE_TWO or SIZE_ONE
	if e.bb.Size ~= size then e.bb.Size = size end
	local l1 = hasPet and UDim2.new(1, -8, 0.6, 0) or UDim2.new(1, -8, 1, 0)
	if e.line1.Size ~= l1 then e.line1.Size = l1 end
end

local function buildPlate(e, head)
	if e.bb then e.bb:Destroy() end
	local bb = Instance.new("BillboardGui")
	bb.Name = "Nameplate"
	bb.Size = SIZE_TWO
	bb.StudsOffset = Vector3.new(0, 2.1, 0)
	bb.AlwaysOnTop = false
	bb.MaxDistance = maxDistance()
	bb.LightInfluence = 0
	bb.Active = true -- GuiButtons inside receive taps
	bb.Enabled = e.player ~= player -- own plate hidden by default
	bb:SetAttribute("Signpost", false)

	local pill = SG.new("Frame", {
		Name = "Pill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = SG.Color.Bg1,
		BackgroundTransparency = 0.25, BorderSizePixel = 0,
	}, bb)
	SG.corner(pill, "pill")
	local stroke = SG.stroke(pill, SG.Color.Violet, "hair", 0.35)
	SG.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical, SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center,
	}, pill)
	local line1 = SG.new("TextButton", {
		Name = "Line1", Size = UDim2.new(1, -8, 0.6, 0), BackgroundTransparency = 1, Text = "",
		TextScaled = true, Font = SG.Font.Heading, TextColor3 = SG.Color.Text, TextStrokeTransparency = 0.6,
		TextTruncate = Enum.TextTruncate.AtEnd, AutoButtonColor = false, LayoutOrder = 1,
	}, pill)
	SG.new("UITextSizeConstraint", { MinTextSize = 10, MaxTextSize = 18 }, line1)
	local line2 = SG.new("TextLabel", {
		Name = "Line2", Size = UDim2.new(1, -8, 0.4, 0), BackgroundTransparency = 1, Text = "",
		TextScaled = true, Font = SG.Font.Body, TextColor3 = SG.Color.TextDim, TextStrokeTransparency = 0.7,
		TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 2, Visible = false,
	}, pill)
	SG.new("UITextSizeConstraint", { MinTextSize = 9, MaxTextSize = 14 }, line2)
	line1.Activated:Connect(function()
		local fn = Nameplates.OnTap
		if type(fn) == "function" then
			local ok, err = pcall(fn, e.player.UserId)
			if not ok then warn("[Nameplates] OnTap: " .. tostring(err)) end
		end
	end)

	e.bb, e.pill, e.stroke, e.line1, e.line2 = bb, pill, stroke, line1, line2
	bb.Parent = head
	render(e)
end

local function hideVIPTag(inst)
	if inst.Name == "VIPTag" and inst:IsA("BillboardGui") then inst.Enabled = false end
end

local function onCharacter(e, char)
	if not char then return end
	task.spawn(function()
		local head = char:WaitForChild("Head", 10)
		if not head then return end
		local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
		-- the player may have left or respawned while we waited
		if entries[e.player] ~= e or e.player.Character ~= char or not head.Parent then return end
		if hum then
			pcall(function() hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end)
		end
		-- legacy server VIPTag (older server build): the crown lives on the plate now
		for _, c in ipairs(head:GetChildren()) do hideVIPTag(c) end
		head.ChildAdded:Connect(hideVIPTag) -- dies with the character
		buildPlate(e, head)
	end)
end

local function markDirty(e)
	if e.pending then return end
	e.pending = true
	task.delay(COALESCE, function()
		e.pending = false
		if entries[e.player] ~= e then return end
		render(e)
	end)
end

local function addPlayer(pl)
	if entries[pl] then return end
	local e = { player = pl, pending = false }
	entries[pl] = e
	e.attrConn = pl.AttributeChanged:Connect(function() markDirty(e) end) -- ONE per player
	e.charConn = pl.CharacterAdded:Connect(function(char) onCharacter(e, char) end)
	if pl.Character then onCharacter(e, pl.Character) end
end

local function removePlayer(pl)
	local e = entries[pl]
	if not e then return end
	entries[pl] = nil
	if e.attrConn then e.attrConn:Disconnect() end
	if e.charConn then e.charConn:Disconnect() end
	if e.bb then e.bb:Destroy() end
end

function Nameplates.Init(quality)
	Quality = quality
	for _, pl in ipairs(Players:GetPlayers()) do addPlayer(pl) end
	Players.PlayerAdded:Connect(addPlayer)
	Players.PlayerRemoving:Connect(removePlayer)
	if Quality and Quality.Changed then
		Quality.Changed:Connect(function(field)
			if field ~= "Tier" then return end
			local d = maxDistance()
			for _, e in pairs(entries) do
				if e.bb and e.bb.Parent then e.bb.MaxDistance = d end
			end
		end)
	end
end

return Nameplates
