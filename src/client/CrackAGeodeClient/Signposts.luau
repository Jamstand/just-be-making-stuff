-- Screen-clamped world signposts. Roblox clips a BillboardGui at the viewport
-- edge, so a station label near the screen border ("UPGRADES" etc.) renders
-- half-cut — ugly on short landscape phones. This module watches every sign
-- under the CrackAGeode folder (and NexusFX's camera-parented cards); the moment
-- one would clip, its billboard is swapped for a screen-space pill pinned just
-- inside the edge, so labels only ever read whole. Fully off-screen signs simply
-- don't render, as before.
--
-- Perf contract (CM-1): label lists are cached when a sign is tracked (no
-- GetDescendants per tick), the loop runs at 20 Hz (10 Hz under Reduce FX and for
-- signs beyond 55 % of their MaxDistance), signs past MaxDistance early-out, and
-- transparency / Enabled are written only when they change (> 0.02). Any
-- BillboardGui with attribute Signpost == false (nameplates, pets, cheer pops)
-- is never tracked.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local SG = require(game:GetService("ReplicatedStorage"):WaitForChild("StyleGuide"))

local Signposts = {}
local Quality

local EDGE = 6 -- px margin pills keep from screen edges
local EDGE_TOP = 60 -- recomputed in Init from the real top-bar inset

function Signposts.Init(quality)
	Quality = quality
	EDGE_TOP = GuiService:GetGuiInset().Y + 8

	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "SignpostGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- pill coords come from WorldToViewportPoint
	gui.DisplayOrder = 9 -- below GeodeHUD (10): pills never sit over panels
	gui.Parent = player:WaitForChild("PlayerGui")

	local tracked = {} -- array of entries (see track)
	local seen = {}    -- [bb] = true, so the initial scan and DescendantAdded never double-track
	local function track(bb)
		if not bb.Parent or seen[bb] then return end
		if bb:GetAttribute("Signpost") == false then return end
		local part = bb.Parent
		if not (part and part:IsA("BasePart")) then return end
		local labels, images, words, color = {}, {}, {}, nil
		for _, c in ipairs(bb:GetDescendants()) do
			if c:IsA("TextLabel") then
				labels[#labels + 1] = c
				if c.Text ~= "" then
					table.insert(words, c.Text)
					color = c.TextColor3 -- last label = the name row's colour
				end
			elseif c:IsA("ImageLabel") then
				images[#images + 1] = c
			end
		end
		if #words == 0 then return end
		seen[bb] = true
		local pill = Instance.new("TextLabel")
		pill.Name = bb:GetFullName():gsub("%W", "_")
		pill.Text = table.concat(words, " ")
		pill.Font = SG.Font.Display
		pill.TextSize = 14
		pill.TextColor3 = color or SG.Color.Text
		pill.TextStrokeTransparency = 0.6
		pill.BackgroundColor3 = SG.Color.Bg1
		pill.BackgroundTransparency = 0.25
		pill.BorderSizePixel = 0
		pill.AutomaticSize = Enum.AutomaticSize.X
		pill.Size = UDim2.fromOffset(0, 24)
		pill.AnchorPoint = Vector2.new(0.5, 0.5)
		pill.Visible = false
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = pill
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 10)
		pad.PaddingRight = UDim.new(0, 10)
		pad.Parent = pill
		pill.Parent = gui
		local entry = {
			bb = bb, part = part, pill = pill,
			labels = labels, images = images,
			fade = -1,          -- last written transparency (-1 = never)
			enabled = nil,      -- last written bb.Enabled
			pillShown = false,  -- last written pill.Visible
			slow = false,       -- beyond 55 % of MaxDistance → half rate
		}
		-- labels added after tracking (builders that fill a card over a few
		-- frames) join the cached list; no per-tick scan needed
		bb.DescendantAdded:Connect(function(c)
			if c:IsA("TextLabel") then
				labels[#labels + 1] = c
			elseif c:IsA("ImageLabel") then
				images[#images + 1] = c
			end
		end)
		table.insert(tracked, entry)
	end

	task.spawn(function()
		local root = workspace:WaitForChild("CrackAGeode", 30)
		if not root then return end
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BillboardGui") then track(d) end
		end
		root.DescendantAdded:Connect(function(d)
			if d:IsA("BillboardGui") then task.defer(track, d) end
		end)
		-- NexusFX zone cards ride camera-parented anchor parts; they were clipping
		-- at screen edges untracked — clamp them exactly like world signs
		local cam = workspace.CurrentCamera
		if cam then
			for _, d in ipairs(cam:GetDescendants()) do
				if d:IsA("BillboardGui") then track(d) end
			end
			cam.DescendantAdded:Connect(function(d)
				if d:IsA("BillboardGui") then task.defer(track, d) end
			end)
		end
	end)

	local function setEnabled(t, v)
		if t.enabled ~= v then
			t.enabled = v
			t.bb.Enabled = v
		end
	end
	local function showPill(t, v)
		if t.pillShown ~= v then
			t.pillShown = v
			t.pill.Visible = v
		end
	end
	local function setFade(t, fade)
		if math.abs(fade - t.fade) <= 0.02 then return end
		t.fade = fade
		local strokeT = math.max(0.2, fade)
		for _, c in ipairs(t.labels) do
			c.TextTransparency = fade
			c.TextStrokeTransparency = strokeT
		end
		for _, c in ipairs(t.images) do
			c.ImageTransparency = fade
		end
	end

	local acc, ticks = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		local hz = (Quality and Quality.Tier <= 0) and 10 or 20
		if acc < 1 / hz then return end
		acc = 0
		ticks += 1
		local cam = workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		local halfTan = math.tan(math.rad(cam.FieldOfView) / 2)
		local camPos = cam.CFrame.Position
		for i = #tracked, 1, -1 do
			local t = tracked[i]
			local bb = t.bb
			if not bb.Parent then
				-- destroyed sign (transient FX billboards): drop it and its pill
				seen[bb] = nil
				t.pill:Destroy()
				table.remove(tracked, i)
			elseif not (t.slow and ticks % 2 == 1) then
				local worldPos = t.part.Position + bb.StudsOffset
				local dist = (camPos - worldPos).Magnitude
				local maxD = bb.MaxDistance
				if dist > maxD then
					-- out of range: the engine won't draw it anyway; half rate until it nears
					t.slow = true
					setEnabled(t, true)
					showPill(t, false)
				else
					local fadeStart = maxD * 0.55
					t.slow = dist > fadeStart
					local p = cam:WorldToViewportPoint(worldPos)
					if p.Z > 0 then
						-- projected on-screen size of the billboard at this depth
						local pxPerStud = vp.Y / (2 * p.Z * halfTan)
						local w = bb.Size.X.Scale * pxPerStud
						local h = bb.Size.Y.Scale * pxPerStud
						local clipped = (p.X - w / 2 < 0) or (p.X + w / 2 > vp.X)
							or (p.Y - h / 2 < 0) or (p.Y + h / 2 > vp.Y)
						local anyVisible = (p.X + w / 2 > 0) and (p.X - w / 2 < vp.X)
							and (p.Y + h / 2 > 0) and (p.Y - h / 2 < vp.Y)
						setEnabled(t, not clipped)
						-- distance fade: labels shrink naturally (world-scale), and past
						-- 55% of MaxDistance their text fades out so far labels never
						-- pile into overlapping clutter (QA)
						if not clipped then
							setFade(t, math.clamp((dist - fadeStart) / math.max(1, maxD - fadeStart), 0, 1))
						end
						if clipped and anyVisible then
							local pill = t.pill
							local pw = math.max(40, pill.AbsoluteSize.X)
							local ph = math.max(24, pill.AbsoluteSize.Y)
							pill.Position = UDim2.fromOffset(
								math.clamp(p.X, EDGE + pw / 2, math.max(EDGE + pw / 2, vp.X - EDGE - pw / 2)),
								math.clamp(p.Y, EDGE_TOP + ph / 2, math.max(EDGE_TOP + ph / 2, vp.Y - EDGE - ph / 2)))
							showPill(t, true)
						else
							showPill(t, false)
						end
					else
						setEnabled(t, true) -- behind the camera: engine won't draw it anyway
						showPill(t, false)
					end
				end
			end
		end
	end)
end

return Signposts
