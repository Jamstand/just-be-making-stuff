-- Pair: THE HOOK. Owning both halves of a type in one drawer pairs them (x2.5 each); same
-- mutation on both halves makes a Perfect Pair (x2 more). Draws a thread Beam between the halves
-- and a PAIRED badge, and sets the model attributes Paired / PairUid (SockAnim, on the client).
-- Recompute() runs after every drawer change.
local Pair = {}
local S

local function clearVisuals(sock)
	local model = sock.model
	local leg = model and model.PrimaryPart
	if not leg then
		return
	end
	for _, name in ipairs({ "PairBeam", "PairAttachment", "PairBadge" }) do
		local inst = leg:FindFirstChild(name)
		if inst then
			inst:Destroy()
		end
	end
end

local function badge(sock, text: string, color: Color3)
	local leg = sock.model and sock.model.PrimaryPart
	if not leg then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "PairBadge"
	gui.Adornee = leg
	gui.Size = UDim2.fromOffset(160, 30)
	gui.StudsOffset = Vector3.new(0, leg.Size.Y / 2 + 3.6, 0)
	gui.MaxDistance = 70
	gui.LightInfluence = 0
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = color
	t.BackgroundTransparency = 0.1
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.4
	t.Text = text
	t.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = t
	gui.Parent = leg
end

local function thread(a, b, color: Color3)
	local legA = a.model and a.model.PrimaryPart
	local legB = b.model and b.model.PrimaryPart
	if not legA or not legB then
		return
	end
	local att0 = Instance.new("Attachment")
	att0.Name = "PairAttachment"
	att0.Position = Vector3.new(0, legA.Size.Y / 2, 0)
	att0.Parent = legA
	local att1 = Instance.new("Attachment")
	att1.Name = "PairAttachment"
	att1.Position = Vector3.new(0, legB.Size.Y / 2, 0)
	att1.Parent = legB
	local beam = Instance.new("Beam")
	beam.Name = "PairBeam"
	beam.Attachment0 = att0
	beam.Attachment1 = att1
	beam.Color = ColorSequence.new(color)
	beam.Width0 = 0.5
	beam.Width1 = 0.5
	beam.CurveSize0 = 4
	beam.CurveSize1 = 4
	beam.Segments = 8
	beam.FaceCamera = true
	beam.LightEmission = 0.6
	beam.Parent = legA
end

function Pair.Init(s)
	S = s
end

local function pairUp(a, b, perfect: boolean, color: Color3)
	a.paired, b.paired = true, true
	a.perfect, b.perfect = perfect, perfect
	a.pairWith, b.pairWith = b.uid, a.uid
	thread(a, b, color)
	local text = if perfect then "PERFECT PAIR" else "PAIRED"
	local badgeColor = if perfect then Color3.fromRGB(255, 190, 40) else Color3.fromRGB(80, 200, 120)
	badge(a, text, badgeColor)
	badge(b, text, badgeColor)
end

-- `quiet` skips announcements (used when restoring a saved drawer).
function Pair.Recompute(record, quiet: boolean?)
	local previous = {}
	local socks = S.Base.SlotSocks(record)
	local byType = {}
	for _, sock in pairs(socks) do
		if sock.paired and sock.pairWith then
			previous[math.min(sock.uid, sock.pairWith) .. ":" .. math.max(sock.uid, sock.pairWith)] = true
		end
		sock.paired, sock.perfect, sock.pairWith = false, false, nil
		clearVisuals(sock)
		local group = byType[sock.typeId]
		if not group then
			group = { L = {}, R = {}, S = {} }
			byType[sock.typeId] = group
		end
		table.insert(group[sock.side], sock)
	end

	local current = {}
	local formed = {}
	for typeId, group in pairs(byType) do
		local t = S.Config.Sock.ById[typeId]
		local color = S.Config.Rarity.Tiers[t.rarity].color
		if t.alwaysPaired then
			for _, sock in ipairs(group.S) do
				sock.paired = true
				badge(sock, "PAIRED", Color3.fromRGB(80, 200, 120))
			end
		elseif not t.single and not t.noMatch then
			local lefts, rights = group.L, group.R
			-- Perfect pairs first (same mutation), then anything left over.
			local usedL, usedR = {}, {}
			for i, l in ipairs(lefts) do
				for j, r in ipairs(rights) do
					if not usedL[i] and not usedR[j] and l.mutation == r.mutation then
						usedL[i], usedR[j] = true, true
						pairUp(l, r, true, color)
					end
				end
			end
			for i, l in ipairs(lefts) do
				if not usedL[i] then
					for j, r in ipairs(rights) do
						if not usedR[j] then
							usedL[i], usedR[j] = true, true
							pairUp(l, r, false, color)
							break
						end
					end
				end
			end
			for i, l in ipairs(lefts) do
				if usedL[i] and l.pairWith then
					local key = math.min(l.uid, l.pairWith) .. ":" .. math.max(l.uid, l.pairWith)
					current[key] = true
					if not previous[key] then
						table.insert(formed, l)
					end
				end
			end
		end
	end

	-- the client's SockAnim reads these: a pair that forms dances, paired socks bop together
	for _, sock in pairs(socks) do
		if sock.model then
			sock.model:SetAttribute("Paired", sock.paired == true)
			sock.model:SetAttribute("PairUid", sock.pairWith or 0)
		end
	end

	-- the Sockdex remembers pairs (quietly: new-type rewards come from Dex.Record at buy/steal/drop)
	if record.player and S.Dex then
		for _, sock in pairs(socks) do
			if sock.paired then
				S.Dex.Record(record.player, sock, true)
			end
		end
	end

	if not quiet and record.player then
		local profile = S.Data.Get(record.player)
		for _, l in ipairs(formed) do
			if profile then
				profile.Data.stats.pairsCompleted += 1
			end
			local t = S.Registry.Type(l)
			local tier = S.Registry.Tier(l)
			local what = (if l.perfect then "PERFECT " else "") .. t.name .. " pair"
			local other = l.pairWith and S.Registry.Get(l.pairWith)
			for _, half in ipairs({ l, other }) do
				if half and half.model and half.model.PrimaryPart then
					S.FX(if l.perfect then "perfect" else "pair", half.model.PrimaryPart.Position, tier.color)
				end
			end
			S.Toast(record.player, "PAIRED! " .. what .. " (x" .. (if l.perfect then S.Config.Economy.PairBonus * S.Config.Economy.PerfectPairBonus else S.Config.Economy.PairBonus) .. " income)", "good")
			if tier.rank >= S.Config.Rarity.AnnounceFromRank then
				S.Announce(record.player.DisplayName .. " completed a " .. what .. "! 🧦🧦", tier.color)
			end
		end
	end
end

return Pair
