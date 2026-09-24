-- Screen-clamped world signposts. Roblox clips a BillboardGui at the viewport
-- edge, so a station label near the screen border ("UPGRADES" etc.) renders
-- half-cut — ugly on short landscape phones. This module watches every sign
-- under the CrackAGeode folder; the moment one would clip, its billboard is
-- swapped for a screen-space pill pinned just inside the edge, so labels only
-- ever read whole. Fully off-screen signs simply don't render, as before.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local SG = require(game:GetService("ReplicatedStorage"):WaitForChild("StyleGuide"))

local Signposts = {}

local EDGE = 6 -- px margin pills keep from screen edges
local EDGE_TOP = 60 -- keep clear of the Roblox top bar

function Signposts.Init()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "SignpostGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- pill coords come from WorldToViewportPoint
	gui.DisplayOrder = 9 -- below GeodeHUD (10): pills never sit over panels
	gui.Parent = player:WaitForChild("PlayerGui")

	local tracked = {}
	local function track(bb)
		local part = bb.Parent
		if not (part and part:IsA("BasePart")) then return end
		local words, color = {}, nil
		for _, c in ipairs(bb:GetDescendants()) do
			if c:IsA("TextLabel") and c.Text ~= "" then
				table.insert(words, c.Text)
				color = c.TextColor3 -- last label = the name row's colour
			end
		end
		if #words == 0 then return end
		local pill = Instance.new("TextLabel")
		pill.Name = bb:GetFullName():gsub("%W", "_")
		pill.Text = table.concat(words, " ")
		pill.Font = Enum.Font.GothamBlack
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
		table.insert(tracked, { bb = bb, part = part, pill = pill })
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

	RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		local halfTan = math.tan(math.rad(cam.FieldOfView) / 2)
		for _, t in ipairs(tracked) do
			local bb, pill = t.bb, t.pill
			local show = false
			if bb.Parent then
				local worldPos = t.part.Position + bb.StudsOffset
				local p = cam:WorldToViewportPoint(worldPos)
				local dist = (cam.CFrame.Position - worldPos).Magnitude
				if p.Z > 0 and dist <= bb.MaxDistance then
					-- projected on-screen size of the billboard at this depth
					local pxPerStud = vp.Y / (2 * p.Z * halfTan)
					local w = bb.Size.X.Scale * pxPerStud
					local h = bb.Size.Y.Scale * pxPerStud
					local clipped = (p.X - w / 2 < 0) or (p.X + w / 2 > vp.X)
						or (p.Y - h / 2 < 0) or (p.Y + h / 2 > vp.Y)
					local anyVisible = (p.X + w / 2 > 0) and (p.X - w / 2 < vp.X)
						and (p.Y + h / 2 > 0) and (p.Y - h / 2 < vp.Y)
					bb.Enabled = not clipped
					-- distance fade: labels shrink naturally (world-scale), and past
					-- 55% of MaxDistance their text fades out so far labels never
					-- pile into overlapping clutter (QA)
					if bb.Enabled then
						local fadeStart = bb.MaxDistance * 0.55
						local fade = math.clamp((dist - fadeStart) / math.max(1, bb.MaxDistance - fadeStart), 0, 1)
						for _, c in ipairs(bb:GetDescendants()) do
							if c:IsA("TextLabel") then
								c.TextTransparency = fade
								c.TextStrokeTransparency = math.max(0.2, fade)
							elseif c:IsA("ImageLabel") then
								c.ImageTransparency = fade
							end
						end
					end
					if clipped and anyVisible then
						show = true
						local pw = math.max(40, pill.AbsoluteSize.X)
						local ph = math.max(24, pill.AbsoluteSize.Y)
						pill.Position = UDim2.fromOffset(
							math.clamp(p.X, EDGE + pw / 2, math.max(EDGE + pw / 2, vp.X - EDGE - pw / 2)),
							math.clamp(p.Y, EDGE_TOP + ph / 2, math.max(EDGE_TOP + ph / 2, vp.Y - EDGE - ph / 2)))
					end
				else
					bb.Enabled = true -- out of range/behind: engine won't draw it anyway
				end
			end
			pill.Visible = show
		end
	end)
end

return Signposts